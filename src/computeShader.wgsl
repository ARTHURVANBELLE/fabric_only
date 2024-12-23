struct FabricVertex {
    position: vec4<f32>,
    color: vec4<f32>,
    mass: f32,
    velocity: vec4<f32>,
    fixed: f32,
};

struct SphereData {
    center: vec4<f32>,
    radius: f32,
    _padding: vec3<f32>,
};

struct SimParams {
    grid_rows: u32,
    grid_cols: u32,
    spring_stiffness: f32,
    rest_length: f32,
};

@group(0) @binding(0) var<storage, read_write> fabric_vertices: array<FabricVertex>;
@group(0) @binding(1) var<uniform> sphere: SphereData;
@group(0) @binding(2) var<uniform> params: SimParams;

const GRAVITY: vec4<f32> = vec4<f32>(0.0, -9.81, 0.0, 0.0);
const DELTA_TIME: f32 = 0.016;
const DAMPING: f32 = 0.98;
const FLOOR_HEIGHT: f32 = -2.0;

// Get vertex index from grid coordinates
fn get_vertex_index(row: u32, col: u32) -> u32 {
    return row * params.grid_cols + col;
}

// Calculate spring force between two points
fn calculate_spring_force(pos1: vec3<f32>, pos2: vec3<f32>) -> vec3<f32> {
    let direction = pos2 - pos1;
    let distance = length(direction);
    let displacement = distance - params.rest_length;
    return normalize(direction) * displacement * params.spring_stiffness;
}

fn handle_sphere_collision(pos: vec4<f32>, vel: vec4<f32>) -> vec4<f32> {
    let to_center = pos.xyz - sphere.center.xyz;
    let distance = length(to_center);
    
    if (distance < sphere.radius) {
        let normal = normalize(to_center);
        // Add a small offset to prevent vertices from getting stuck inside
        let offset = sphere.radius + 0.01;
        return vec4<f32>(sphere.center.xyz + normal * offset, pos.w);
    }
    return pos;
}

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let row = id.y;
    let col = id.x;
    
    // Check if within grid bounds
    if (row >= params.grid_rows || col >= params.grid_cols) {
        return;
    }

    let index = get_vertex_index(row, col);
    var vertex = fabric_vertices[index];

    // Initialize vertex positions if this is the first frame
    if (vertex.position.w == 0.0) {
        // Create a grid of vertices centered at (0, 2, 0)
        let x = (f32(col) / f32(params.grid_cols - 1u) - 0.5) * 2.0;
        let z = (f32(row) / f32(params.grid_rows - 1u) - 0.5) * 2.0;
        vertex.position = vec4<f32>(x, 2.0, z, 1.0);
        vertex.color = vec4<f32>(0.0, 0.7, 1.0, 1.0);
        vertex.mass = 1.0;
        vertex.velocity = vec4<f32>(0.0);
        // Fix top row vertices
        vertex.fixed = f32(row == 0u);
        fabric_vertices[index] = vertex;
        return;
    }

    // Skip simulation for fixed vertices
    if (vertex.fixed > 0.0) {
        return;
    }

    var force = vec3<f32>(0.0);

    // Calculate spring forces from neighboring vertices
    let directions = array<vec2<i32>, 8>(
        vec2<i32>(-1, 0),  // Left
        vec2<i32>(1, 0),   // Right
        vec2<i32>(0, -1),  // Up
        vec2<i32>(0, 1),   // Down
        vec2<i32>(-1, -1), // Diagonal
        vec2<i32>(1, -1),  // Diagonal
        vec2<i32>(-1, 1),  // Diagonal
        vec2<i32>(1, 1)    // Diagonal
    );
/*
    let neighbors = array<vec2<i32>, 8>(
        vec2<i32>(-1, 0), vec2<i32>(1, 0), vec2<i32>(0, -1), vec2<i32>(0, 1),
        vec2<i32>(-1, -1), vec2<i32>(-1, 1), vec2<i32>(1, -1), vec2<i32>(1, 1)
    );

    for (var i = 0u; i < 8u; i++) {
        let neighbor = neighbors[i];
        let neighbor_row = i32(row) + neighbor.y;
        let neighbor_col = i32(col) + neighbor.x;

        if (neighbor_row >= 0 && neighbor_row < i32(params.grid_rows) &&
            neighbor_col >= 0 && neighbor_col < i32(params.grid_cols)) {
            let neighbor_idx = get_vertex_index(u32(neighbor_row), u32(neighbor_col));
            let neighbor_vertex = fabric_vertices[neighbor_idx];
            force += calculate_spring_force(vertex.position.xyz, neighbor_vertex.position.xyz);
        }
    }

*/
    // Apply forces
    let acceleration = (force + GRAVITY.xyz) / vertex.mass;
    vertex.velocity.x += acceleration.x * DELTA_TIME;
    vertex.velocity.y += acceleration.y * DELTA_TIME;  // Separate y-axis for damping
    vertex.velocity.z += acceleration.z * DELTA_TIME;  // Separate z-axis for damping
    vertex.velocity.x *= DAMPING;
    vertex.velocity.y *= DAMPING;
    vertex.velocity.z *= DAMPING;

    // Update position
    vertex.position.x += vertex.velocity.x * DELTA_TIME;
    vertex.position.y += vertex.velocity.y * DELTA_TIME;  // Separate y-axis for damping
    vertex.position.z += vertex.velocity.z * DELTA_TIME;  // Separate z-axis for damping

    // Handle collisions
    vertex.position = handle_sphere_collision(vertex.position, vertex.velocity);

    // Floor collision
    if (vertex.position.y < FLOOR_HEIGHT) {
        vertex.position.y = FLOOR_HEIGHT;
        vertex.velocity.y = -vertex.velocity.y * 0.5;  // Bounce with energy loss
    }

    fabric_vertices[index] = vertex;
}