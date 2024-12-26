struct ClothVertex {
    position: vec3<f32>,
    color: vec3<f32>,
    velocity: vec3<f32>,
};

struct EnvironmentDataPacked {
    values1: vec4<f32>,      // sphere_center (x, y, z) + sphere_radius
    values2: vec4<f32>,      // gravity (x, y, z) + delta_time
    values3: vec4<f32>,      // sphere_damping, structural_stiffness, shear_stiffness, bending_stiffness
    values4: vec4<f32>,      // vertex_mass, vertex_damping, structural_max_length, shear_max_length
    values5: vec4<f32>,      // bending_max_length, padding
    values6: vec4<u32>,      // grid_width, grid_height, padding
};

struct EnvironmentData {
    sphere_center: vec3<f32>,
    sphere_radius: f32,   
    dt: f32,         
    gravity: vec3<f32>,  
    sphere_damping: f32,
    structural_stiffness: f32,
    shear_stiffness: f32,     
    bending_stiffness: f32,
    vertex_mass: f32,
    vertex_damping: f32,
    structural_max_length: f32,
    shear_max_length: f32,
    bending_max_length: f32,  
    grid_width: u32,
    grid_height: u32,
};

@group(1) @binding(0) var<storage, read_write> vertices: array<ClothVertex>;
@group(1) @binding(1) var<uniform> environment_data_packed: EnvironmentDataPacked;

fn unpack_environment_data(packedData: EnvironmentDataPacked) -> EnvironmentData {
    return EnvironmentData(
        packedData.values1.xyz,
        packedData.values1.w,
        packedData.values2.z,
        packedData.values2.xyz,
        packedData.values3.x,
        packedData.values3.y,
        packedData.values3.z,
        packedData.values3.w,
        packedData.values4.x,
        packedData.values4.y,
        packedData.values4.z,
        packedData.values4.w,
        packedData.values5.x,
        packedData.values6.x,
        packedData.values6.y
    );
}

fn resolve_sphere_collision(vertex: ClothVertex, environment_data: EnvironmentData) -> ClothVertex {
    let to_center = vertex.position - environment_data.sphere_center;
    let dist = length(to_center);
    
    // If the vertex is inside or close to the sphere
    if (dist < environment_data.sphere_radius + 0.05) {
        // Calculate the normal vector from the sphere's center to the vertex
        let normal = normalize(to_center);
        
        let displacement = normal * (environment_data.sphere_radius + 0.05 - dist) * 0.05;
        let corrected_pos = vertex.position + displacement;

        // Reflect the velocity along the normal
        let velocity_normal_component = dot(vertex.velocity, normal);
        let reflected_velocity = vertex.velocity - 2.0 * velocity_normal_component * normal;
        
        // Apply sphere damping to the reflected velocity (to simulate bounce)
        let new_velocity = reflected_velocity * environment_data.sphere_damping;

        // Return the updated vertex with corrected position and new velocity
        return ClothVertex(corrected_pos, vertex.color, new_velocity);
    }

    return ClothVertex(vertex.position, vertex.color, vertex.velocity);
}

fn get_spring_force(vertex: ClothVertex, neighbor: ClothVertex, stiffness: f32, max_length: f32) -> vec3<f32> {
    let delta = vertex.position - neighbor.position;
    let current_length = length(delta);
    var force = -stiffness * delta * (current_length) / max_length;
    if (current_length > max_length) {
        force -= stiffness * delta * (current_length - max_length);
    }
    return force;
}

fn resolve_spring_behavior(index: u32, vertex: ClothVertex, environment_data: EnvironmentData, clamped_dt: f32) -> ClothVertex {
    var force = vec3<f32>(0.0, 0.0, 0.0);
    
    // Get current position in grid
    let row = index / environment_data.grid_width;
    let col = index % environment_data.grid_width;
    
    // Calculate neighbor existence flags more accurately
    let has_left = col > 0;
    let has_right = col < environment_data.grid_width - 1;
    let has_top = row > 0;
    let has_bottom = row < environment_data.grid_height - 1;
    
    let has_two_left = col >= 2;
    let has_two_right = col < environment_data.grid_width - 2;
    let has_two_top = row >= 2;
    let has_two_bottom = row < environment_data.grid_height - 2;

    // Calculate indices only when needed
    // Structural springs (direct neighbors)
    if (has_left) {
        let left_index = index - 1;
        force += get_spring_force(vertex, vertices[left_index], environment_data.structural_stiffness, environment_data.structural_max_length);
    }

    if (has_right) {
        let right_index = index + 1;
        force += get_spring_force(vertex, vertices[right_index], environment_data.structural_stiffness, environment_data.structural_max_length);
    }

    if (has_top) {
        let top_index = index - environment_data.grid_width;
        force += get_spring_force(vertex, vertices[top_index], environment_data.structural_stiffness, environment_data.structural_max_length);
    }

    if (has_bottom) {
        let bottom_index = index + environment_data.grid_width;
        force += get_spring_force(vertex, vertices[bottom_index], environment_data.structural_stiffness, environment_data.structural_max_length);
    }

    // Shear springs (diagonal neighbors)
    if (has_top && has_left) {
        let top_left_index = index - environment_data.grid_width - 1;
        force += get_spring_force(vertex, vertices[top_left_index], environment_data.shear_stiffness, environment_data.shear_max_length);
    }

    if (has_top && has_right) {
        let top_right_index = index - environment_data.grid_width + 1;
        force += get_spring_force(vertex, vertices[top_right_index], environment_data.shear_stiffness, environment_data.shear_max_length);
    }

    if (has_bottom && has_left) {
        let bottom_left_index = index + environment_data.grid_width - 1;
        force += get_spring_force(vertex, vertices[bottom_left_index], environment_data.shear_stiffness, environment_data.shear_max_length);
    }

    if (has_bottom && has_right) {
        let bottom_right_index = index + environment_data.grid_width + 1;
        force += get_spring_force(vertex, vertices[bottom_right_index], environment_data.shear_stiffness, environment_data.shear_max_length);
    }

    // Bending springs (two vertices away)
    if (has_two_left) {
        let two_left_index = index - 2;
        force += get_spring_force(vertex, vertices[two_left_index], environment_data.bending_stiffness, environment_data.bending_max_length);
    }

    if (has_two_right) {
        let two_right_index = index + 2;
        force += get_spring_force(vertex, vertices[two_right_index], environment_data.bending_stiffness, environment_data.bending_max_length);
    }

    if (has_two_top) {
        let two_top_index = index - 2 * environment_data.grid_width;
        force += get_spring_force(vertex, vertices[two_top_index], environment_data.bending_stiffness, environment_data.bending_max_length);
    }

    if (has_two_bottom) {
        let two_bottom_index = index + 2 * environment_data.grid_width;
        force += get_spring_force(vertex, vertices[two_bottom_index], environment_data.bending_stiffness, environment_data.bending_max_length);
    }

    // Apply gravity
    force += environment_data.gravity * environment_data.vertex_mass; 

    // Update position based on forces
    var acceleration = force / environment_data.vertex_mass;

    // First velocity calculation
    var new_velocity = vertex.velocity + acceleration * clamped_dt;

    // Damping applied after
    let damping_force = -environment_data.vertex_damping * new_velocity;
    force += damping_force;

    // Second velocity calculation
    acceleration = force / environment_data.vertex_mass;
    new_velocity = vertex.velocity + acceleration * clamped_dt;

    var new_pos = vertex.position + new_velocity * clamped_dt;
    
    let new_vertex = ClothVertex(new_pos, vertex.color, new_velocity);

    return new_vertex;
}

@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= arrayLength(&vertices)) {
        return;
    }

    let environment_data = unpack_environment_data(environment_data_packed);
   
    //let gravity = vec3<f32>(0.0, -0.5, 0.0);

    // Clamp the delta_time to be sure of the stability of the simulation
    let clamped_dt = clamp(environment_data.dt, 0.016, 0.033);
    
    // Fetch current vertex data
    var vertex = vertices[index];

    // Check sphere collision after spring forces and correct if needed
    vertex = resolve_sphere_collision(vertex, environment_data);

    // Spring behavior and update position
    vertex = resolve_spring_behavior(index, vertex, environment_data, clamped_dt);

    // Check sphere collision after spring forces and correct if needed
    vertex = resolve_sphere_collision(vertex, environment_data);
    
    // Store back
    vertices[index] = vertex;
}