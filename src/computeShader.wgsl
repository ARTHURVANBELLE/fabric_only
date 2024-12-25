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

@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let idx = global_id.x; // Each thread corresponds to one vertex

    // Ensure we do not go out of bounds
    let total_vertices = sim_params.grid_cols * sim_params.grid_rows;
    if (idx >= total_vertices) {
        return;
    }

    // Access the vertex from the fabric array
    var vertex = fabric[idx];
    //vertex.color = vec4<f32>(0.0, 0.0, 1.0, 1.0);

    // Example simulation logic (update vertex properties)
    if (vertex.fixed >= -1.0) {
        let dt = 0.016;
        let gravity = -0.81;
        vertex.velocity.y += gravity * dt;
        vertex.position.y += vertex.velocity.y * dt;
        vertex.velocity *= 0.99;
        //vertex.color = vec4<f32>(1.0, 0.0, 0.0, 1.0);
    }

    // Update the vertex back in the fabric array
    fabric[idx] = vertex;
}
