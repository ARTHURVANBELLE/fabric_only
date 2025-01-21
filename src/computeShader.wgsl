struct Vertex {
    @location(0) position: vec4<f32>,  // 16-byte aligned
    @location(1) color: vec4<f32>,     // 16-byte aligned
    @location(2) mass: f32,
    @align(16) @location(3) velocity: vec4<f32>,  // 16-byte aligned
    @location(4) fixed: f32,
}

struct SimParams1 {
    @align(16) grid_k_radius: vec4<f32>,
    @align(16) sphere_center: vec4<f32>,
}

struct SimParams2 {
    @align(16) stiffness: vec4<f32>,
    @align(16) rest_length: vec4<f32>,
    @align(16) gravity: vec4<f32>,
    @align(16) _padding: vec4<f32>,
}

struct Parameters {
    sphere_center: vec4<f32>,
    sphere_radius: f32,
    dt: f32,
    gravity: vec4<f32>,
    sphere_damping: f32,
    structural_stiffness: f32,
    shear_stiffness: f32,
    bending_stiffness: f32,
    vertex_damping: f32,
    structural_rest_length: f32,
    shear_rest_length: f32,
    bending_rest_length: f32,
    structural_max_length: f32,
    shear_max_length: f32,
    bending_max_length: f32,
    grid_width: u32,
    grid_height: u32,
};

// Adjusted constants for stability
const DELTATIME = 0.0016;
const SPHEREDAMPING = 0.5;

@group(0) @binding(0) var<storage, read_write> vertices: array<Vertex>;
@group(0) @binding(1) var<uniform> params1: SimParams1;
@group(0) @binding(2) var<uniform> params2: SimParams2;

fn unpack_parameters(params1: SimParams1, params2: SimParams2) -> Parameters {
    return Parameters(
        params1.sphere_center,   //sphere_center,
        params1.grid_k_radius.w, //sphere_radius
        DELTATIME,
        params2.gravity,
        SPHEREDAMPING,
        params2.stiffness.x,
        params2.stiffness.y,
        params2.stiffness.z,
        params1.grid_k_radius.z, //vertex_damping
        params2.rest_length.x,
        params2.rest_length.y,
        params2.rest_length.z,
        params2.rest_length.x * params1.grid_k_radius.z,
        params2.rest_length.y * params1.grid_k_radius.z,
        params2.rest_length.z * params1.grid_k_radius.z,
        u32(params1.grid_k_radius.x), //grid_width
        u32(params1.grid_k_radius.y), //grid_height
    );
}


fn resolve_sphere_collision(vertex: Vertex, parameters: Parameters) -> Vertex {
    if (vertex.fixed > 0.5) {
        return vertex;
    }

    let pos_3 = vertex.position.xyz;
    let center_3 = parameters.sphere_center.xyz;
    let CS = pos_3 - center_3;
    let dist = length(CS);

    // Expand collision detection range slightly
    if (dist < parameters.sphere_radius + 0.1) {
        let dir = CS / dist;
        
        // Ensure minimum distance from sphere
        let min_offset = max(0.05, dist - parameters.sphere_radius);
        let new_pos = center_3 + dir * (parameters.sphere_radius + min_offset);
        
        let normal_vel = dot(vertex.velocity.xyz, dir) * dir;
        let tangent_vel = vertex.velocity.xyz - normal_vel;
        
        // Reduce tangential velocity more aggressively
        let friction = 1.0;
        // Add velocity clamping
        let max_speed = 5.0;
        let raw_velocity = (tangent_vel * friction) - (normal_vel * 0.7);
        let new_velocity = normalize(raw_velocity) * min(length(raw_velocity), max_speed);
        
        return Vertex(
            vec4<f32>(new_pos, vertex.position.w),
            vertex.color,
            vertex.mass,
            vec4<f32>(new_velocity, 0.0),
            vertex.fixed
        );
    }
    return vertex;
}

fn get_spring_force(vertex: Vertex, neighbor: Vertex, stiffness: f32, rest_length: f32) -> vec4<f32> {
    let delta = neighbor.position - vertex.position;
    let current_length = length(delta);
    
    if (current_length == 0.0) {
        return vec4<f32>(0.0);
    }
    
    let direction = delta / current_length;
    
    // Add non-linear spring behavior to prevent excessive stretching
    var displacement = current_length - rest_length;
    let stretch_factor = current_length / rest_length;
    
    // Progressive stiffness increase when stretched
    var effective_stiffness = stiffness;
    if (stretch_factor > 1.1) {
        effective_stiffness *= stretch_factor * stretch_factor;
    }
    
    let force = direction * displacement * effective_stiffness;
    
    // Limit maximum force magnitude for stability
    let max_force = 100.0;
    let force_magnitude = length(force);
    if (force_magnitude > max_force) {
        return force * (max_force / force_magnitude);
    }
    
    return force;
}

fn resolve_spring_behavior(index: u32, vertex: Vertex, parameters: Parameters) -> Vertex {
    // Skip if vertex is fixed
    if (vertex.fixed > 0.5) {
        return vertex;
    }

    var force = vec4<f32>(0.0);
    
    // Get current position in grid
    let row = index / parameters.grid_width;
    let col = index % parameters.grid_width;
    
    // Calculate neighbor existence flags
    let has_left = col > 0u;
    let has_right = col < parameters.grid_width - 1u;
    let has_top = row > 0u;
    let has_bottom = row < parameters.grid_height - 1u;
    
    let has_two_left = col >= 2u;
    let has_two_right = col < parameters.grid_width - 2u;
    let has_two_top = row >= 2u;
    let has_two_bottom = row < parameters.grid_height - 2u;

    // Structural springs (direct neighbors)
    if (has_left) {
        let left_index = index - 1u;
        force += get_spring_force(vertex, vertices[left_index], 
            parameters.structural_stiffness, parameters.structural_rest_length);
    }

    if (has_right) {
        let right_index = index + 1u;
        force += get_spring_force(vertex, vertices[right_index], 
            parameters.structural_stiffness, parameters.structural_rest_length);
    }

    if (has_top) {
        let top_index = index - parameters.grid_width;
        force += get_spring_force(vertex, vertices[top_index], 
            parameters.structural_stiffness, parameters.structural_rest_length);
    }

    if (has_bottom) {
        let bottom_index = index + parameters.grid_width;
        force += get_spring_force(vertex, vertices[bottom_index], 
            parameters.structural_stiffness, parameters.structural_rest_length);
    }

    // Shear springs (diagonal neighbors)
    if (has_top && has_left) {
        let top_left_index = index - parameters.grid_width - 1u;
        force += get_spring_force(vertex, vertices[top_left_index], 
            parameters.shear_stiffness, parameters.shear_rest_length);
    }

    if (has_top && has_right) {
        let top_right_index = index - parameters.grid_width + 1u;
        force += get_spring_force(vertex, vertices[top_right_index], 
            parameters.shear_stiffness, parameters.shear_rest_length);
    }

    if (has_bottom && has_left) {
        let bottom_left_index = index + parameters.grid_width - 1u;
        force += get_spring_force(vertex, vertices[bottom_left_index], 
            parameters.shear_stiffness, parameters.shear_rest_length);
    }

    if (has_bottom && has_right) {
        let bottom_right_index = index + parameters.grid_width + 1u;
        force += get_spring_force(vertex, vertices[bottom_right_index], 
            parameters.shear_stiffness, parameters.shear_rest_length);
    }

    // Bending springs (two vertices away)
    if (has_two_left) {
        let two_left_index = index - 2u;
        force += get_spring_force(vertex, vertices[two_left_index], 
            parameters.bending_stiffness, parameters.bending_rest_length);
    }

    if (has_two_right) {
        let two_right_index = index + 2u;
        force += get_spring_force(vertex, vertices[two_right_index], 
            parameters.bending_stiffness, parameters.bending_rest_length);
    }

    if (has_two_top) {
        let two_top_index = index - 2u * parameters.grid_width;
        force += get_spring_force(vertex, vertices[two_top_index], 
            parameters.bending_stiffness, parameters.bending_rest_length);
    }

    if (has_two_bottom) {
        let two_bottom_index = index + 2u * parameters.grid_width;
        force += get_spring_force(vertex, vertices[two_bottom_index], 
            parameters.bending_stiffness, parameters.bending_rest_length);
    }

    // Apply gravity
    force += parameters.gravity * vertex.mass;
    
    // Apply damping proportional to velocity
    force += -parameters.vertex_damping * vertex.velocity;
    
    // Semi-implicit Euler integration
    let acceleration = force / vertex.mass;
    let new_velocity = vertex.velocity + acceleration * parameters.dt;
    let new_position = vertex.position + new_velocity * parameters.dt;
    
    // Add position-based relaxation
    let final_position = vertex.position + new_velocity * parameters.dt;
    let max_movement = parameters.structural_rest_length * 0.5;
    let movement = final_position - vertex.position;
    let movement_length = length(movement);
    
    if (movement_length > max_movement) {
        let limited_movement = normalize(movement) * max_movement;
        return Vertex(
            vertex.position + limited_movement,
            vertex.color,
            vertex.mass,
            new_velocity * 0.9, // Reduce velocity
            vertex.fixed
        );
    }
    
    return Vertex(final_position, vertex.color, vertex.mass, new_velocity, vertex.fixed);
}


@compute @workgroup_size(256)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= arrayLength(&vertices)) {
        return;
    }
    var vertex = vertices[index];

    let parameters = unpack_parameters(params1, params2);

    vertex = resolve_spring_behavior(index, vertex, parameters);

    vertex = resolve_sphere_collision(vertex, parameters);

    vertices[index] = vertex;
}