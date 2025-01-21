use wgpu_bootstrap::{
    cgmath, egui,
    util::{
        geometry::icosphere,
        orbit_camera::{CameraUniform, OrbitCamera},
    },
    wgpu::{self, util::DeviceExt, ComputePass},
    App, Context,
};

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex {
    position: [f32; 4],    // 16 bytes (0-15)
    color: [f32; 4],       // 16 bytes (16-31)
    mass: f32,             // 4 bytes  (32-35)
    padding1: [f32; 3],    // 12 bytes padding to align velocity
    velocity: [f32; 4],    // 16 bytes (48-63)
    fixed: f32,            // 4 bytes  (64-67)
    padding2: [f32; 3],    // 12 bytes final padding
}

// Simulation parameters
#[repr(C, align(16))]  // Added align(16) to force 16-byte alignment
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct SimParams1 {
    grid_k_radius: [f32; 4],  // grid_rows, grid_cols, k_spring and sphere_radius 16 bytes
    sphere_center: [f32; 4],  // 16 bytes
}
#[repr(C, align(16))]  // Added align(16) to force 16-byte alignment
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct SimParams2 {
    stiffness: [f32; 4],    // 16 bytes, aligned to 16
    rest_length: [f32; 4],  // 16 bytes, aligned to 16
    gravity: [f32; 4],      // 16 bytes, aligned to 16
    _padding: [f32; 4]      // 16-byte alignment
}

impl Vertex {
    fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                // Position
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Color
                wgpu::VertexAttribute {
                    offset: 16,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Mass
                wgpu::VertexAttribute {
                    offset: 32,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32,
                },
                // Velocity
                wgpu::VertexAttribute {
                    offset: 48,
                    shader_location: 3,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Fixed
                wgpu::VertexAttribute {
                    offset: 64,
                    shader_location: 4,
                    format: wgpu::VertexFormat::Float32,
                },
            ],
        }
    }
}


pub struct InstanceApp {
    sphere_vertex_buffer: wgpu::Buffer,
    sphere_index_buffer: wgpu::Buffer,
    render_pipeline: wgpu::RenderPipeline,
    compute_pipeline: wgpu::ComputePipeline,
    num_sphere_indices: u32,
    camera: OrbitCamera,
    compute_bind_group: wgpu::BindGroup,
    sim_params1_buffer: wgpu::Buffer,
    sim_params2_buffer: wgpu::Buffer,
    fabric_vertex_buffer: wgpu::Buffer,
    fabric_index_buffer: wgpu::Buffer,
    sim_params1: SimParams1,
    sim_params2: SimParams2,
}

impl InstanceApp {
    pub fn new(context: &Context) -> Self {

        // Fabric properties
        let fabric_side_length = 6.0;
        let grid_rows: u32 = 100;
        let grid_cols: u32 = 100;
        let k_spring = 0.12;
        let ball_radius = 1.0;

        // Generate fabric vertices
        let fabric_vertices: Vec<Vertex> = (0..grid_rows)
            .flat_map(|row| {
                (0..grid_cols).map(move |col| {
                    let x = (col as f32 / (grid_cols - 1) as f32) * fabric_side_length - fabric_side_length / 2.0;
                    let y = 2.0;
                    let z = (row as f32 / (grid_rows - 1) as f32) * fabric_side_length - fabric_side_length / 2.0;

                    Vertex {
                        position: [x, y, z, 1.0],
                        color: [0.26, 0.65, 0.96, 1.0], // Green for the fabric
                        mass: 0.1,
                        padding1: [0.0; 3],
                        velocity: [0.0, 0.0, 0.0, 1.0],
                        fixed: 0.0,
                        padding2: [0.0; 3],
                    }
                })
            })
            .collect();

         // Generate fabric indices (two triangles per grid cell)
        let mut fabric_indices: Vec<u32> = Vec::new();
        for row in 0..grid_rows - 1 {
            for col in 0..grid_cols - 1 {
                let top_left = row * grid_cols + col;
                let top_right = top_left + 1;
                let bottom_left = top_left + grid_cols;
                let bottom_right = bottom_left + 1;

                // Add two triangles for the cell
                fabric_indices.extend_from_slice(&[
                    top_left, bottom_left, bottom_right, // Triangle 1
                    top_left, bottom_right, top_right,  // Triangle 2
                ]);
            }
        }

        println!("Fabric vertices: {}", fabric_vertices.len());
        println!("Fabric indices: {}", fabric_indices.len());

        let (ball_positions, ball_indices) = icosphere(5);
        let ball_vertices: Vec<Vertex> = ball_positions
            .iter()
            .map(|position| Vertex {
                position: [position.x * ball_radius, position.y * ball_radius, position.z * ball_radius, 1.0],
                color: [1.0, 0.0, 0.0, 1.0], // Red for the ball
                mass: 1.0,
                padding1: [0.0; 3],
                velocity: [0.0, 0.0, 0.0, 1.0],
                fixed: 1.0,
                padding2: [0.0; 3],
            })
            .collect();

        // Combine vertices and indices for rendering
        let mut vertices: Vec<Vertex> = Vec::new();
        vertices.extend(&ball_vertices);

        let mut indices = Vec::new();
        indices.extend(ball_indices.clone());

        let sim_params1 = SimParams1 {
            grid_k_radius: [grid_rows as f32, grid_cols as f32, k_spring, 1.4],
            sphere_center: [0.0, 0.0, 0.0, 0.0],
        };
        let sim_params2 = SimParams2 {
            stiffness: [25.0, 15.0, 5.0, 0.0],
            rest_length: [0.06, 0.085, 0.12, 0.0],
            gravity: [0.0, -6.8, 0.0, 0.0],
            _padding: [0.0; 4]
        };

        println!("SimParams1 -- Size: {}, Alignment: {}", std::mem::size_of::<SimParams1>(), std::mem::align_of::<SimParams1>());
        println!("SimParams2 -- Size: {}, Alignment: {}", std::mem::size_of::<SimParams2>(), std::mem::align_of::<SimParams2>());

        let sim_params1_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sim Param 1 Buffer"),
            contents: bytemuck::cast_slice(&[sim_params1]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            });

        let sim_params2_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sim Param 2 Buffer"),
            contents: bytemuck::cast_slice(&[sim_params2]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            });

        let fabric_vertex_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Fabric Vertex Buffer"),
            contents: bytemuck::cast_slice(&fabric_vertices),
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });

        let fabric_index_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Fabric Index Buffer"),
            contents: bytemuck::cast_slice(&fabric_indices),
            usage: wgpu::BufferUsages::INDEX | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::STORAGE,
        });

        let sphere_vertex_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Vertex Buffer"),
            contents: bytemuck::cast_slice(&ball_vertices),
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::STORAGE| wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::VERTEX,
        });

        let sphere_index_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Index Buffer"),
            contents: bytemuck::cast_slice(&ball_indices),
            usage: wgpu::BufferUsages::INDEX | wgpu::BufferUsages::STORAGE| wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::VERTEX,
        });

        println!("Buffer size: {}", std::mem::size_of::<Vertex>() * fabric_vertices.len());

        // Shaders and pipeline
        let shader = context.device().create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        // Create the compute shader
        let compute_shader = context.device().create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Compute Shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("computeShader.wgsl").into()),
        });

        let camera_bind_group_layout = context.device().create_bind_group_layout(&CameraUniform::desc());

        let pipeline_layout = context.device().create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Render Pipeline Layout"),
            bind_group_layouts: &[&camera_bind_group_layout],
            push_constant_ranges: &[],
        });

        let compute_bind_group_layout = context
        .device()
        .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Compute Bind Group Layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: false },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        let compute_bind_group = context.device().create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Compute Bind Group"),
            layout: &compute_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: fabric_vertex_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: sim_params1_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: sim_params2_buffer.as_entire_binding(),
                },
            ],
        });

        // Create the compute pipeline
        let compute_pipeline = context
        .device()
        .create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            module: &compute_shader,
            entry_point: "cs_main",
            layout: Some(&context.device().create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("Compute Pipeline Layout"),
                bind_group_layouts: &[&compute_bind_group_layout],
                push_constant_ranges: &[],
            })),
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            cache: None,
            label: Some("Compute Pipeline"),
        });

        // Create render pipeline
        let render_pipeline =
        context
            .device()
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("Render Pipeline"),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: "vs_main",
                    buffers: &[Vertex::desc()],
                    compilation_options: wgpu::PipelineCompilationOptions::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: "fs_main",
                    targets: &[Some(wgpu::ColorTargetState {
                        format: context.format(),
                        blend: Some(wgpu::BlendState::REPLACE),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                    compilation_options: wgpu::PipelineCompilationOptions::default(),
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::TriangleList,
                    strip_index_format: None,
                    front_face: wgpu::FrontFace::Ccw,
                    cull_mode: None,
                    polygon_mode: wgpu::PolygonMode::Fill,
                    unclipped_depth: false,
                    conservative: false,
                },
                depth_stencil: Some(wgpu::DepthStencilState {
                    format: context.depth_stencil_format(),
                    depth_write_enabled: true,
                    depth_compare: wgpu::CompareFunction::Less,
                    stencil: wgpu::StencilState::default(),
                    bias: wgpu::DepthBiasState::default(),
                }),
                multisample: wgpu::MultisampleState {
                    count: 1,
                    mask: !0,
                    alpha_to_coverage_enabled: false,
                },
                multiview: None,
                cache: None,
            });

        // Camera setup
        let aspect = context.size().x / context.size().y;
        let mut camera = OrbitCamera::new(context, 45.0, aspect, 0.5, 100.0);
        camera.set_radius(7.0).update(context);

        let num_sphere_indices = ball_indices.len() as u32;

        InstanceApp {
            sphere_vertex_buffer,
            sphere_index_buffer,
            render_pipeline,
            compute_pipeline,
            num_sphere_indices,
            camera,
            compute_bind_group,
            sim_params1_buffer,
            sim_params2_buffer,
            fabric_vertex_buffer,
            fabric_index_buffer,
            sim_params1,
            sim_params2,
        }
    }
}

impl App for InstanceApp {
    fn input(&mut self, input: egui::InputState, context: &Context) {
        self.camera.input(input.clone(), context);
        if input.raw_scroll_delta.y != 0.0 {
            let new_radius = (self.camera.radius() - input.raw_scroll_delta.y / 10.0).max(5.0).min(500.0);
            self.camera.set_radius(new_radius).update(context);
        }
    }

    fn update(&mut self, delta_time: f32, context: &Context) {
        let mut encoder = context.device().create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Compute Encoder"),
        });
    
        let total_vertices = self.sim_params1.grid_k_radius[0] as u32 * self.sim_params1.grid_k_radius[1] as u32;
        let thread_group_size = 256u32;
        let thread_group_count = (total_vertices + thread_group_size - 1) / thread_group_size;
        
        {
            let mut compute_pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("Compute Pass"),
                timestamp_writes: None,
            });
    
            compute_pass.set_pipeline(&self.compute_pipeline);
            compute_pass.set_bind_group(0, &self.compute_bind_group, &[]);
            compute_pass.dispatch_workgroups(thread_group_count, 1, 1);
        }
        context.queue().submit(Some(encoder.finish()));
    }
    
    fn render(&self, render_pass: &mut wgpu::RenderPass<'_>) {
        // Draw the sphere
        render_pass.set_pipeline(&self.render_pipeline);
        render_pass.set_bind_group(0, self.camera.bind_group(), &[]);
        render_pass.set_vertex_buffer(0, self.sphere_vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.sphere_index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        render_pass.draw_indexed(0..self.num_sphere_indices, 0, 0..1);
    
        // Draw the fabric
        render_pass.set_pipeline(&self.render_pipeline);
        render_pass.set_bind_group(0, self.camera.bind_group(), &[]);
        render_pass.set_vertex_buffer(0, self.fabric_vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.fabric_index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        
        // Calculate total indices for grid
        let indices_per_cell = 6; // 2 triangles * 3 vertices
        let cells = (self.sim_params1.grid_k_radius[0] as u32 - 1) * (self.sim_params1.grid_k_radius[1] as u32- 1);
        let total_indices = indices_per_cell * cells;
        
        render_pass.draw_indexed(0..total_indices, 0, 0..1);
    }
}