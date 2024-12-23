struct SimParams {
    grid_rows: u32,
    grid_cols: u32,
    spring_stiffness: f32,
    rest_length: f32,
};

struct Vertex {
    position: vec4<f32>,
    color: vec4<f32>,
    mass: f32,
    velocity: vec4<f32>,
    fixed: f32,
};

@group(0) @binding(0) var<storage, read_write> fabric: array<Vertex>;
@group(0) @binding(1) var<uniform> sphere_data: vec4<f32>; // Sphere center and radius
@group(0) @binding(2) var<uniform> sim_params: SimParams;


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= arrayLength(&fabric)) {
        return;
    }

    var vertex = fabric[index];
    if (vertex.fixed == 0.0) { // Skip fixed points
        vertex.velocity.y -= 0.8 * 0.016; // Apply gravity
        vertex.position.y += vertex.velocity.y * 0.016; // Update position
    }
    fabric[index] = vertex;
}