struct Vertex {
    @location(0) position: vec4<f32>,  // 16-byte aligned
    @location(1) color: vec4<f32>,     // 16-byte aligned
    @location(2) mass: f32,            
    @align(16) @location(3) velocity: vec4<f32>,  // 16-byte aligned
    @location(4) fixed: f32,
}

struct SimParams {
    grid_rows: u32,
    grid_cols: u32,
    spring_stiffness: f32,
    rest_length: f32,
    sphere_center: vec4<f32>,
    sphere_radius: f32,
}

@group(0) @binding(0) var<storage, read_write> vertices: array<Vertex>;
@group(0) @binding(1) var<uniform> params: SimParams;

@compute @workgroup_size(256)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= params.grid_rows * params.grid_cols) {
        return;
    }

    // Read the original vertex
    var vertex = vertices[index];
    
    // Only modify the color - leave all other data untouched
    vertex.color = vec4<f32>(0.0, 0.0, 1.0, 1.0);
    
    // Write back only the modified vertex
    vertices[index] = vertex;
}