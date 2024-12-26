use wgpu_bootstrap::{
    cgmath, egui,
    util::{geometry::icosphere, orbit_camera::{CameraUniform, OrbitCamera}},
    wgpu::{self, util::DeviceExt, BindGroup, PipelineCompilationOptions},
    App, Context,
};
use rand::Rng;
use cgmath::prelude::*;
use std::{borrow::Borrow, default, ops::Range, str};

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex {
    position: [f32; 3], // 12 bytes => must be of 16 bytes in compute shader : we need a padding of 4 bytes
    _pad1: f32,         // 4 bytes padding
    color: [f32; 3],    // 12 bytes
    _pad2: f32,         // 4 bytes padding
    velocity: [f32; 3], // 12 bytes
    _pad3: f32,         // 4 bytes padding
}

impl Vertex {
    fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: 2 * std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32x3,
                },
            ],
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone, Debug, bytemuck::Pod, bytemuck::Zeroable)]
// pub struct EnvironmentData  {   // must be of 96 bytes
//     sphere_center: [f32; 3],    // 12 bytes
//     _pad1: f32,                 // 4 bytes padding
//     sphere_radius: f32,         // 4 bytes
//     delta_time: f32,            // 4 bytes
//     gravity: [f32; 3],          // 12 bytes
//     _pad2: f32,                 // 4 bytes padding
//     sphere_damping: f32,        // 4 bytes
//     structural_stiffness: f32,  // 4 bytes
//     shear_stiffness: f32,       // 4 bytes
//     bending_stiffness: f32,     // 4 bytes
//     vertex_mass: f32,           // 4 bytes
//     vertex_damping: f32,        // 4 bytes
//     structural_max_length: f32, // 4 bytes
//     shear_max_length: f32,      // 4 bytes
//     bending_max_length: f32,    // 4 bytes
//     grid_width: u32,            // 4 bytes
//     grid_height: u32,           // 4 bytes
//     _pad3: [f32; 3],            // 12 bytes padding
// }

pub struct EnvironmentData {
    values1: [f32; 4],      // sphere_center (x, y, z) + sphere_radius
    values2: [f32; 4],      // gravity (x, y, z) + delta_time
    values3: [f32; 4],      // sphere_damping, structural_stiffness, shear_stiffness, bending_stiffness
    values4: [f32; 4],      // vertex_mass, vertex_damping, structural_max_length, shear_max_length
    values5: [f32; 4],      // bending_max_length, padding 
    values6: [u32; 4],      // grid_width, grid_height, padding
}
impl EnvironmentData {
    pub fn new(center: cgmath::Vector3<f32>, radius: f32, delta_time: f32) -> Self {
        let sphere_center: cgmath::Vector3<f32> = center.into();
        let gravity: [f32; 3] = [0.0, -1.0, 0.0];
        let sphere_damping: f32 = 0.3;
        let structural_stiffness: f32 = 0.1;
        let shear_stiffness: f32 = 0.1;
        let bending_stiffness: f32 = 0.1;
        let vertex_mass: f32 = 0.5;
        let vertex_damping: f32 = 0.6;
        let structural_max_length: f32 = 0.05;
        let shear_max_length: f32 = 0.075;
        let bending_max_length: f32 = 0.1;
        let grid_width: u32 = 60;
        let grid_height: u32 = 60;

        Self {
            values1: [sphere_center[0], sphere_center[1], sphere_center[2], radius],
            values2: [gravity[0], gravity[1], gravity[2], delta_time],
            values3: [sphere_damping, structural_stiffness, shear_stiffness, bending_stiffness],
            values4: [vertex_mass, vertex_damping, structural_max_length, shear_max_length],
            values5: [bending_max_length, 0.0, 0.0, 0.0],
            values6: [grid_width, grid_height, 0, 0],
        }
    }

    pub fn update_delta_time(&mut self, delta_time: f32) {
        self.values2[3] = delta_time;
    }
    
    pub fn desc() -> wgpu::BindGroupLayoutEntry {
        wgpu::BindGroupLayoutEntry {
            binding: 1,
            visibility: wgpu::ShaderStages::COMPUTE,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }
    }

    pub fn buffer(&self, context: &Context) -> wgpu::Buffer {
        context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Uniform Buffer"),
            contents: bytemuck::cast_slice(&[*self]),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::STORAGE,
        })
    }
    pub fn bind_group(&self, context: &Context, layout: &wgpu::BindGroupLayout) -> wgpu::BindGroup {
        let buffer = self.buffer(context);
        context.device().create_bind_group(&wgpu::BindGroupDescriptor {
            layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &buffer,
                    offset: 0,
                    size: None,
                }),
            }],
            label: Some("Sphere Bind Group"),
        })
    }
}

pub struct Sphere {
    vertex_buffer: wgpu::Buffer,
    index_buffer: wgpu::Buffer,
    num_indices: u32,
    vertices: Vec<Vertex>,
    environment_data: EnvironmentData,
}

impl Sphere {
    pub fn new(context: &Context, new_radius: f32, new_center: cgmath::Vector3<f32>) -> Self {
        let radius = new_radius;
        let center = new_center;

        let (mut positions, indices) = icosphere(2);
        
        for position in positions.iter_mut() {
            position.x = position.x * radius + center.x;
            position.y = position.y * radius + center.y;
            position.z = position.z * radius + center.z;
        }

        let vertices: Vec<Vertex> = positions
            .iter()
            .map(|v| {
                Vertex {
                    position: [v.x, v.y, v.z],
                    _pad1: 0.0,
                    color: [0.5, 0.5, 0.5], // Gray color
                    _pad2: 0.0,
                    velocity: [0.0, 0.0, 0.0], // Unused for sphere
                    _pad3: 0.0,
                }
            })
            .collect();

        let vertex_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Vertex Buffer"),
            contents: bytemuck::cast_slice(&vertices),
            usage: wgpu::BufferUsages::VERTEX,
        });

        let index_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Sphere Index Buffer"),
            contents: bytemuck::cast_slice(&indices),
            usage: wgpu::BufferUsages::INDEX,
        });

        let environment_data = EnvironmentData::new(center, radius, 0.00);

        Self {
            vertex_buffer,
            index_buffer,
            num_indices: indices.len() as u32,
            vertices,
            environment_data
        }   
    }

    pub fn render(&self, render_pass: &mut wgpu::RenderPass<'_>) {
        render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        render_pass.draw_indexed(0..self.num_indices, 0, 0..1);
    }
}

pub struct ClothApp {
    vertex_buffer: wgpu::Buffer,
    index_buffer: wgpu::Buffer,
    render_pipeline: wgpu::RenderPipeline,
    compute_pipeline: wgpu::ComputePipeline,
    num_indices: u32,
    camera: OrbitCamera,
    sphere: Sphere,
    vertices: Vec<Vertex>,
    vertex_storage_buffer: wgpu::Buffer,
    compute_bind_group_layout: wgpu::BindGroupLayout,
    compute_bind_group: BindGroup,
}

impl ClothApp {
    pub fn new(context: &Context) -> Self {
        let width_range: Range<f32> = -1.5..1.5;
        let height_range: Range<f32> = -1.5..1.5;
        let step = 0.05;
        let mut positions = Vec::new();
        let mut indices = Vec::new();
    
        // Calculate the midpoints for centering
        let x_mid = (width_range.start + width_range.end - step) / 2.0;
        let z_mid = (height_range.start + height_range.end - step) / 2.0;
    
        // Generate positions
        let mut z: f32 = height_range.start;
        while z < height_range.end {
            let mut x: f32 = width_range.start;
            while x < width_range.end {
                positions.push(cgmath::Vector3::new(x - x_mid, 0.0, z - z_mid));
                x += step;
            }
            z += step;
        }
    
        let width = ((width_range.end - width_range.start) / step) as usize;
        let height = ((height_range.end - height_range.start) / step) as usize;
    
        // Generate indices
        for z in 0..(height - 1) {
            for x in 0..(width - 1) {
                let top_left = z * width + x;
                let top_right = top_left + 1;
                let bottom_left = top_left + width;
                let bottom_right = bottom_left + 1;
    
                // First triangle
                indices.push(top_left as u32);
                indices.push(bottom_left as u32);
                indices.push(bottom_right as u32);
    
                // Second triangle
                indices.push(top_left as u32);
                indices.push(bottom_right as u32);
                indices.push(top_right as u32);
            }
        }
    
        let vertices: Vec<Vertex> = positions
            .iter()
            .map(|position| Vertex {
                position: (*position).into(),
                _pad1: 0.0,
                color: [0.5, 0.75, 0.75],
                _pad2: 0.0,	
                velocity: [0.0, 0.0, 0.0],
                _pad3: 0.0,
            })
            .collect();
        
        let vertex_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Vertex Buffer"),
            contents: bytemuck::cast_slice(&vertices),
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });

        let index_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Index Buffer"),
            contents: bytemuck::cast_slice(&indices),
            usage: wgpu::BufferUsages::INDEX,
        });

        let num_indices = indices.len() as u32;

        let render_shader = context.device().create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("Render Shader"),
                source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        let compute_shader = context.device().create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Compute Shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("compute_shader.wgsl").into()),
        });

        let camera_bind_group_layout = context
            .device()
            .create_bind_group_layout(&CameraUniform::desc());

        let pipeline_layout = context.device()
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("Render Pipeline Layout"),
                bind_group_layouts: &[&camera_bind_group_layout],
                push_constant_ranges: &[],
            });

        let render_pipeline = context.device().create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Render Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &render_shader,
                entry_point: "vs_main",
                buffers: &[Vertex::desc()],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &render_shader,
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
            cache: None
        });

        let vertex_storage_buffer = context.device().create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Vertex Storage Buffer"),
            contents: bytemuck::cast_slice(&vertices),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC,
        });
        
        let aspect = context.size().x / context.size().y;
        let mut camera = OrbitCamera::new(context, 45.0, aspect, 0.1, 100.0);
        camera
            .set_polar(cgmath::point3(3.0, 0.0, 0.0))
            .update(context);

        
        let compute_bind_group_layout = context.device().create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
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
            ],
            label: Some("Compute Bind Group Layout"),
        });

        let sphere_radius = 1.0;
        let sphere_center = cgmath::Vector3 { x: (0.0), y: (-1.5), z: (0.0) };
        let sphere = Sphere::new(context, sphere_radius, sphere_center);

        let compute_bind_group = context.device().create_bind_group(&wgpu::BindGroupDescriptor {
            layout: &compute_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &vertex_storage_buffer,
                        offset: 0,
                        size: None,
                    }),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &sphere.environment_data.buffer(context),
                        offset: 0,
                        size: None,
                    }),
                }
            ],
            label: Some("Compute Bind Group"),
        });

        let compute_pipeline_layout = context.device().create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Compute Pipeline Layout"),
            bind_group_layouts: &[
                &compute_bind_group_layout,
                &compute_bind_group_layout,
            ],
            push_constant_ranges: &[],
        });

        let compute_pipeline = context.device().create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("Compute Pipeline"),
            layout: Some(&compute_pipeline_layout),
            module: &compute_shader,
            entry_point: "cs_main",
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            cache: None,
        });

        Self {
            vertex_buffer,
            index_buffer,
            render_pipeline,
            compute_pipeline,
            num_indices,
            camera,
            sphere,
            vertices,
            vertex_storage_buffer,
            compute_bind_group_layout,
            compute_bind_group,
        }
    }

    fn update(&mut self, context: &Context, delta_time: f32) {
        self.update_cloth(context, delta_time);
        self.camera.update(context);
    }

    fn update_cloth(&mut self, context: &Context, delta_time: f32) {
        self.sphere.environment_data.update_delta_time(delta_time);
    
        let mut encoder = context.device().create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Compute Encoder"),
        });
    
        let compute_bind_group = context.device().create_bind_group(&wgpu::BindGroupDescriptor {
            layout: &self.compute_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &self.vertex_storage_buffer,
                        offset: 0,
                        size: None,
                    }),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &self.sphere.environment_data.buffer(context),
                        offset: 0,
                        size: None,
                    }),
                }
            ],
            label: Some("Compute Bind Group"),
        });

        let mut compute_pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
            label: Some("Compute Pass"),
            timestamp_writes: None,
        });
        compute_pass.set_pipeline(&self.compute_pipeline);
        compute_pass.set_bind_group(0, &compute_bind_group, &[]);
        compute_pass.set_bind_group(1, &compute_bind_group, &[]);
        compute_pass.dispatch_workgroups(self.vertices.len() as u32, 1, 1);
    
        drop(compute_pass);
        
        // Add a copy operation to read back the modified vertices
        encoder.copy_buffer_to_buffer(
            &self.vertex_storage_buffer, 
            0, 
            &self.vertex_buffer, 
            0, 
            (self.vertices.len() * std::mem::size_of::<Vertex>()) as wgpu::BufferAddress
        );
    
        // Submit the commands
        context.queue().submit(Some(encoder.finish()));
    }
}

impl App for ClothApp {
    fn input(&mut self, input: egui::InputState, context: &Context) {
        self.camera.input(input, context);
    }

    fn update(&mut self, delta_time: f32, context: &Context) {
        self.update(context, delta_time);
    }

    fn render(&self, render_pass: &mut wgpu::RenderPass<'_>) {
        // Render vertices
        render_pass.set_pipeline(&self.render_pipeline);
        render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        render_pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        render_pass.set_bind_group(0, self.camera.bind_group(), &[]);

        render_pass.draw_indexed(0..self.num_indices, 0, 0..1);

        // Render the sphere
        //render_pass.set_vertex_buffer(0, self.cube.vertex_buffer.slice(..));
        //self.cube.render(render_pass);
        render_pass.set_vertex_buffer(0, self.sphere.vertex_buffer.slice(..));
        self.sphere.render(render_pass);
    }
}
