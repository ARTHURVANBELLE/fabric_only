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
    position: [f32; 4], // Changed to vec4
    color: [f32; 4],
    mass: f32,
    velocity: [f32; 4], // Changed to vec4
    fixed: f32,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct SphereData {
    center: [f32; 4],  // 16 bytes
    radius: f32,       // 4 bytes
    _padding: [f32; 7],  // 28 bytes of padding to make it 32-byte aligned
}

// Simulation parameters
#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct SimParams {
    grid_rows: u32,
    grid_cols: u32,
    spring_stiffness: f32,
    rest_length: f32,
}

impl SphereData {
    fn new(center: [f32; 3], radius: f32) -> Self {
        Self {
            center: [center[0], center[1], center[2], 0.0],
            radius,
            _padding: [0.0; 7],
        }
    }
}

// Add this function to create the fabric indices
pub fn create_fabric_indices(rows: u32, cols: u32) -> Vec<u32> {
    let mut indices = Vec::new();
    for row in 0..rows-1 {
        for col in 0..cols-1 {
            let top_left = row * cols + col;
            let top_right = top_left + 1;
            let bottom_left = (row + 1) * cols + col;
            let bottom_right = bottom_left + 1;

            // First triangle
            indices.push(top_left);
            indices.push(bottom_left);
            indices.push(top_right);

            // Second triangle
            indices.push(top_right);
            indices.push(bottom_left);
            indices.push(bottom_right);
        }
    }
    indices
}

impl Vertex {
    fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                // Location 0: Position
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Location 1: Color
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 4]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Location 2: Mass
                wgpu::VertexAttribute {
                    offset: (std::mem::size_of::<[f32; 4]>()
                        + std::mem::size_of::<[f32; 4]>()) as wgpu::BufferAddress,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32,
                },
                // Location 3: Velocity
                wgpu::VertexAttribute {
                    offset: (std::mem::size_of::<[f32; 4]>() * 2
                        + std::mem::size_of::<f32>()) as wgpu::BufferAddress,
                    shader_location: 3,
                    format: wgpu::VertexFormat::Float32x4,
                },
                // Location 4: fixed
                wgpu::VertexAttribute {
                    offset: (std::mem::size_of::<[f32; 4]>() * 2
                        + std::mem::size_of::<[f32; 4]>()
                        + std::mem::size_of::<f32>()) as wgpu::BufferAddress,
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
    sphere_buffer: wgpu::Buffer,
    sim_param_buffer: wgpu::Buffer,
    fabric_storage_buffer: wgpu::Buffer,
    fabric_vertex_buffer: wgpu::Buffer,
    fabric_index_buffer: wgpu::Buffer,
    sim_params: SimParams,
}

impl InstanceApp {
    pub fn new(context: &Context) -> Self {

        let grid_rows = 16;
        let grid_cols = 16;

        let ball_radius = 1.2; // Adjust the ball radius as needed
        let (ball_positions, ball_indices) = icosphere(2);
        let ball_vertices: Vec<Vertex> = ball_positions
            .iter()
            .map(|position| Vertex {
                position: [position.x * ball_radius, position.y * ball_radius, position.z * ball_radius, 1.0],
                color: [1.0, 0.0, 0.0, 1.0], // Red for the ball
                mass: 1.0,
                velocity: [0.0, 0.0, 0.0, 1.0],
                fixed: 1.0,
            })
            .collect();

        // Combine vertices and indices for rendering
        let mut vertices: Vec<Vertex> = Vec::new();
        vertices.extend(&ball_vertices); // Borrow instead of moving

        let mut indices = Vec::new();
        indices.extend(ball_indices.clone()); // Clone to avoid move

        println!("Total vertices: {}", vertices.len());
        println!("Total indices: {}", indices.len());

        let sim_params = SimParams {
            grid_rows: grid_rows,
            grid_cols: grid_cols,
            spring_stiffness: 50.0,
            rest_length: 0.1,
        };
        let sim_param_buffer = context.device().create_buffer_init(
            &wgpu::util::BufferInitDescriptor {
                label: Some("Sim Param Buffer"),
                contents: bytemuck::cast_slice(&[sim_params]),
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            });
        
        let fabric_storage_buffer = context.device().create_buffer(&wgpu::BufferDescriptor {
            label: Some("Fabric Storage Buffer"),
            size: (grid_rows * grid_cols * std::mem::size_of::<Vertex>() as u32) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        
        let fabric_vertex_buffer = context.device().create_buffer(&wgpu::BufferDescriptor {
            label: Some("Fabric Vertex Buffer"),
            size: (grid_rows * grid_cols * std::mem::size_of::<Vertex>() as u32) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::STORAGE,
            mapped_at_creation: false,
        });

        let fabric_index_buffer = context.device().create_buffer(&wgpu::BufferDescriptor {
            label: Some("Fabric Index Buffer"),
            size: (grid_rows * grid_cols * 6) as wgpu::BufferAddress * std::mem::size_of::<u32>() as wgpu::BufferAddress,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::UNIFORM |wgpu::BufferUsages::INDEX,
            mapped_at_creation: false,
        });

        let fabric_indices = create_fabric_indices(grid_rows, grid_cols);
        context.queue().write_buffer(
            &fabric_index_buffer,
            0,
            bytemuck::cast_slice(&fabric_indices),
        );

        let sphere_data = SphereData::new([0.0, 0.0, 0.0], ball_radius); // Use your ball_radius
        let sphere_buffer = context.device().create_buffer_init(
        &wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Buffer"),
            contents: bytemuck::cast_slice(&[sphere_data]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::STORAGE,
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
                    resource: sphere_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: sim_param_buffer.as_entire_binding(),
                },
            ],
        });

        // Create the compute pipeline
        let compute_pipeline = context
        .device()
        .create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            module: &compute_shader,
            entry_point: "main",
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
        let camera = OrbitCamera::new(context, 45.0, aspect, 0.1, 100.0);

        let num_sphere_indices = ball_indices.len() as u32;

        InstanceApp {
            sphere_vertex_buffer,
            sphere_index_buffer,
            render_pipeline,
            compute_pipeline,
            num_sphere_indices,
            camera,
            compute_bind_group,
            sphere_buffer,
            sim_param_buffer,
            fabric_storage_buffer,
            fabric_vertex_buffer,
            fabric_index_buffer,
            sim_params,
        }
    }
}

impl App for InstanceApp {
    fn input(&mut self, input: egui::InputState, context: &Context) {
        self.camera.input(input.clone(), context);
        if input.raw_scroll_delta.y != 0.0 {
            let new_radius = (self.camera.radius() - input.raw_scroll_delta.y).max(0.1).min(500.0);
            self.camera.set_radius(new_radius).update(context);
        }
    }

    fn update(&mut self, delta_time: f32, context: &Context) {
        // Create a command encoder for compute dispatch
        let mut encoder = context.device().create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Compute Encoder"),
        });

        // Begin a compute pass
        {
            let mut compute_pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("Compute Pass"),
                timestamp_writes: None,
            });

            // Set the compute pipeline
            compute_pass.set_pipeline(&self.compute_pipeline);
            
            // Set the bind groups for the compute shader
            compute_pass.set_bind_group(0, &self.compute_bind_group, &[]);
            
            // Dispatch the compute shader
            let workgroup_count_x = (self.sim_params.grid_cols + 15) / 16;
            let workgroup_count_y = (self.sim_params.grid_rows + 15) / 16;
            compute_pass.dispatch_workgroups(workgroup_count_x, workgroup_count_y, 1);
        }

        // Copy the computed vertices to the vertex buffer
        encoder.copy_buffer_to_buffer(
            &self.fabric_storage_buffer,  // source buffer (computed vertices)
            0,                           // source offset
            &self.fabric_vertex_buffer,   // destination buffer (for rendering)
            0,                           // destination offset
            (self.sim_params.grid_rows * self.sim_params.grid_cols * std::mem::size_of::<Vertex>() as u32) as u64,
        );

        // Submit the compute work
        context.queue().submit(Some(encoder.finish()));
    }

    fn render(&self, render_pass: &mut wgpu::RenderPass<'_>) {
        // Set the render pipeline
        render_pass.set_pipeline(&self.render_pipeline);

        // Set the camera bind group
        render_pass.set_bind_group(0, self.camera.bind_group(), &[]);

        // Draw the sphere
        render_pass.set_vertex_buffer(0, self.sphere_vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.sphere_index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        render_pass.draw_indexed(0..self.num_sphere_indices, 0, 0..1);

        // Draw the fabric
        render_pass.set_vertex_buffer(0, self.fabric_vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.fabric_index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        
        // Calculate the number of indices for the fabric grid
        let num_cells = (self.sim_params.grid_rows - 1) * (self.sim_params.grid_cols - 1);
        let num_indices = num_cells * 6; // 6 indices per cell (2 triangles)
        render_pass.draw_indexed(0..num_indices, 0, 0..1);
    }
}