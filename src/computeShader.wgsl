struct Vertex {
    position: vec4<f32>,
    color: vec4<f32>,
    mass: f32,
    velocity: vec4<f32>,
    fixed: f32,
};

struct SimParams {
    grid_rows: u32,
    grid_cols: u32,
    spring_stiffness: f32,
    rest_length: f32,
};

@group(0) @binding(0) var<storage, read_write> fabric: array<Vertex>;
@group(0) @binding(1) var<uniform> sphere_data: vec4<f32>;
@group(0) @binding(2) var<uniform> sim_params: SimParams;

@compute @workgroup_size(256)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let idx: u32 = global_id.x;

    // Ensure we don't access out-of-bounds elements
    if (idx >= arrayLength(&fabric)) {
        return;
    }

    // Retrieve the current vertex
    var vertex: Vertex = fabric[idx];

    vertex.position.y += 5.1;

    // Modify only the color field of the vertex (example: setting to red)
    vertex.color = vec4<f32>(1.0, 0.0, 0.0, 1.0); // RGBA (red)

    // Write the updated vertex back to the fabric array
    fabric[idx] = vertex;
}
