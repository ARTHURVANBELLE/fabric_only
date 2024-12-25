struct ClothVertex {
    position: vec3<f32>,
    color: vec3<f32>,
    velocity: vec3<f32>,
};

struct EnvironmentData {
    sphere_center: vec3<f32>,
    sphere_radius: f32,
    dt: f32,
    structural_stiffness: f32,
    shear_stiffness: f32,     
    bending_stiffness: f32,
    vertex_mass: f32,
    vertex_damping: f32,
    structural_rest_length: f32,
    shear_rest_length: f32,
    bending_rest_length: f32,
    grid_width: u32,
    grid_height: u32,
};

@group(1) @binding(0) var<storage, read_write> vertices: array<ClothVertex>;
@group(1) @binding(1) var<uniform> environment_data: EnvironmentData;

const GRAVITY: vec3<f32> = vec3<f32>(0.0, -0.05, 0.0);
const RESTITUTION: f32 = 0.3;

fn distance_to_sphere(pos: vec3<f32>, center: vec3<f32>, radius: f32) -> f32 {
    return length(pos - center) - radius;
}

fn resolve_sphere_collision(initial_vertex: ClothVertex, next_pos: vec3<f32>, environment_data: EnvironmentData) -> ClothVertex {
    let to_center = next_pos - environment_data.sphere_center;
    let dist = length(to_center);
    
    if (dist < environment_data.sphere_radius) {
        let normal = normalize(to_center);
        let penetration = environment_data.sphere_radius - dist;
        
        // Position correction
        let corrected_pos = environment_data.sphere_center + normal * environment_data.sphere_radius;
        
        // Velocity reflection with friction
        let normal_velocity = dot(initial_vertex.velocity, normal) * normal;
        let tangent_velocity = initial_vertex.velocity - normal_velocity;
        let reflected_velocity = tangent_velocity * environment_data.vertex_damping - normal_velocity * RESTITUTION;

        return ClothVertex(
            corrected_pos, 
            initial_vertex.color, 
            reflected_velocity
        );
    }

    return ClothVertex(next_pos, initial_vertex.color, initial_vertex.velocity);
}

fn resolve_spring_behavior(
    pos: vec3<f32>, next_pos: vec3<f32>, environment_data: EnvironmentData, clamped_dt: f32,
    left_neighbor_pos: vec3<f32>, has_left_neighbor: bool,
    top_left_neighbor_pos: vec3<f32>, has_top_left_neighbor: bool,
    two_left_neighbor_pos: vec3<f32>, has_two_left_neighbor: bool) -> vec3<f32> {
        
    // Calculate the spring forces
    var force = vec3<f32>(0.0, 0.0, 0.0);

    // Structural springs
    if (has_left_neighbor) {
        let current_length = length(next_pos - left_neighbor_pos);
        let structural_force = environment_data.structural_stiffness * (current_length - environment_data.structural_rest_length) * normalize(next_pos - left_neighbor_pos);
        force += structural_force;
    }

    // Shear springs
    if (has_top_left_neighbor) {
        let shear_current_length = length(next_pos - top_left_neighbor_pos);
        let shear_force = environment_data.shear_stiffness * (shear_current_length - environment_data.shear_rest_length) * normalize(next_pos - top_left_neighbor_pos);
        force += shear_force;
    }

    // Bending springs
    if (has_two_left_neighbor) {
        let bending_current_length = length(next_pos - two_left_neighbor_pos);
        let bending_force = environment_data.bending_stiffness * (bending_current_length - environment_data.bending_rest_length) * normalize(next_pos - two_left_neighbor_pos);
        force += bending_force;
    }

    // Apply damping
    let damping_force = -environment_data.vertex_damping * (next_pos - pos) / clamped_dt;
    force += damping_force;

    // Limit the force applied on the vertices
    let max_force = 50.0;
    force = normalize(force) * min(length(force), max_force);

    // Update position based on forces
    let acceleration = force / environment_data.vertex_mass;
    let new_pos = next_pos + acceleration * clamped_dt * clamped_dt;

    return new_pos;
}

@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= arrayLength(&vertices)) {
        return;
    }

    // Clamp the delta_time to be sure of the stability of the simulation
    let clamped_dt = min(environment_data.dt, 0.05);
    
    // Fetch current vertex data
    var vertex = vertices[index];
    
    // Apply gravity and damping
    vertex.velocity += GRAVITY * clamped_dt;
    
    // Get next position
    var next_pos = vertex.position + vertex.velocity * clamped_dt;
    
    // Sphere collision resolution
    var next_vertex = resolve_sphere_collision(vertex, next_pos, environment_data);

    // Calculate indices of neighboring vertices
    let left_index = index - 1;
    let top_left_index = index - environment_data.grid_width - 1;
    let two_left_index = index - 2;
    
    // Check if neighbors exist
    let has_left_neighbor = (index % environment_data.grid_width != 0) && (left_index < arrayLength(&vertices));
    let has_top_left_neighbor = (index >= environment_data.grid_width && (index % environment_data.grid_width != 0)) && (top_left_index < arrayLength(&vertices));
    let has_two_left_neighbor = (index % environment_data.grid_width > 1) && (two_left_index < arrayLength(&vertices));

    // Fetch positions of neighboring vertices
    var left_neighbor_pos = vec3<f32>(0.0, 0.0, 0.0);
    var top_left_neighbor_pos = vec3<f32>(0.0, 0.0, 0.0);
    var two_left_neighbor_pos = vec3<f32>(0.0, 0.0, 0.0);

    if has_left_neighbor {
        left_neighbor_pos = vertices[left_index].position;
    }
    if has_top_left_neighbor {
        top_left_neighbor_pos = vertices[top_left_index].position;
    }
    if has_two_left_neighbor {
        two_left_neighbor_pos = vertices[two_left_index].position;
    }
    
    // Spring behavior and update position
    //next_vertex.position = resolve_spring_behavior(
    //    vertex.position, 
    //    next_vertex.position, 
    //    environment_data, clamped_dt,
    //    left_neighbor_pos, has_left_neighbor,
    //    top_left_neighbor_pos, has_top_left_neighbor,
    //    two_left_neighbor_pos, has_two_left_neighbor
    //);
    
    // Recheck sphere collision after spring forces and correct if needed
    //next_vertex = resolve_sphere_collision(vertex, next_vertex.position, environment_data);
    
    // Store back
    vertices[index] = next_vertex;
}