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
    max_length: f32,
    sphere_center: vec4<f32>,
    sphere_radius: f32,
}

struct EnvironmentData {
    sphere_center: vec4<f32>,
    sphere_radius: f32,   
    dt: f32,         
    gravity: vec4<f32>,  
    sphere_damping: f32,
    structural_stiffness: f32,
    shear_stiffness: f32,     
    bending_stiffness: f32,
    vertex_damping: f32,
    structural_max_length: f32,
    shear_max_length: f32,
    bending_max_length: f32,  
    grid_width: u32,
    grid_height: u32,
};

// Recalculated rest lengths for 6.0 side length and 100x100 grid
const STRUCTURAL_REST_LENGTH: f32 = 0.06;  // 6.0 / (100 - 1)
const SHEAR_REST_LENGTH: f32 = 0.085;      // STRUCTURAL_REST_LENGTH * sqrt(2)
const BENDING_REST_LENGTH: f32 = 0.12;     // STRUCTURAL_REST_LENGTH * 2

// Adjusted constants for stability
const DELTATIME = 0.006;
const GRAVITY = vec4<f32>(0.0, -5.5, 0.0, 0.0);
const SPHEREDAMPING = 0.5;
const VERTEXDAMPING = 0.8;  // Increased damping for stability

// Maximum stretch factors (more generous to prevent hard constraints)
const STRUCTURALMAX = STRUCTURAL_REST_LENGTH * 1.2;
const SHEARMAX = SHEAR_REST_LENGTH * 1.2;
const BENDINGMAX = BENDING_REST_LENGTH * 1.2;

// Reduced stiffness values for more stable behavior
const STRUCT_STIFF = 25.0;
const SHEAR_STIFF = 15.0;
const BEND_STIFF = 5.0;


@group(0) @binding(0) var<storage, read_write> vertices: array<Vertex>;
@group(0) @binding(1) var<uniform> params: SimParams;

fn unpack_environment_data(params: SimParams) -> EnvironmentData {
    return EnvironmentData(
        params.sphere_center,
        params.sphere_radius,
        DELTATIME,
        GRAVITY,
        SPHEREDAMPING,
        STRUCT_STIFF,
        SHEAR_STIFF ,
        BEND_STIFF,
        VERTEXDAMPING,
        STRUCTURALMAX,
        SHEARMAX,
        BENDINGMAX,
        params.grid_rows,
        params.grid_cols
    );
}


fn resolve_sphere_collision(vertex: Vertex, environment_data: EnvironmentData) -> Vertex {
    // Skip if vertex is fixed
    if (vertex.fixed > 0.5) {
        return vertex;
    }

    let to_center = vertex.position - environment_data.sphere_center;
    let pos_3 = vertex.position.xyz;
    let center_3 = environment_data.sphere_center.xyz;
    let to_center_3 = pos_3 - center_3;
    let dist = length(to_center_3);

    if (dist <= environment_data.sphere_radius + 0.2){ //&& vertex.position.y > 0.0) {
        let new_velocity = vec4<f32>(0.0,0.0,0.0,0.0);
        let color = vec4<f32>(0.5, 0.5, 0.5, 1.0);
        let fixed = f32(1.0);
        
        return Vertex(
            vertex.position,
            color,
            vertex.mass,
            new_velocity,
            fixed
        );
    }
/*
    // If inside or touching sphere
    if (dist <= environment_data.sphere_radius) {
        let normal = normalize(to_center);
        
        // Push vertex exactly to surface
        let corrected_pos = environment_data.sphere_center + normal * environment_data.sphere_radius;
        
        // Stop all velocity
        let new_velocity = vec4<f32>(0.0);
        let color = vec4<f32>(0.0, 1.0, 0.0, 1.0);
        
        return Vertex(
            corrected_pos,
            color,
            vertex.mass,
            new_velocity,
            vertex.fixed
        );
    }
*/
    if (vertex.position.y < -3.0) {
        let new_velocity = vec4<f32>(0.0,0.0,0.0,0.0);
        let color = vec4<f32>(0.0, 0.5, 0.5, 1.0);
        
        return Vertex(
            vertex.position,
            color,
            vertex.mass,
            new_velocity,
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

fn resolve_spring_behavior(index: u32, vertex: Vertex, environment_data: EnvironmentData, clamped_dt: f32) -> Vertex {
    // Skip if vertex is fixed
    if (vertex.fixed > 0.5) {
        return vertex;
    }

    var force = vec4<f32>(0.0);
    
    // Get current position in grid
    let row = index / environment_data.grid_width;
    let col = index % environment_data.grid_width;
    
    // Calculate neighbor existence flags
    let has_left = col > 0u;
    let has_right = col < environment_data.grid_width - 1u;
    let has_top = row > 0u;
    let has_bottom = row < environment_data.grid_height - 1u;
    
    let has_two_left = col >= 2u;
    let has_two_right = col < environment_data.grid_width - 2u;
    let has_two_top = row >= 2u;
    let has_two_bottom = row < environment_data.grid_height - 2u;

    // Structural springs (direct neighbors)
    if (has_left) {
        let left_index = index - 1u;
        force += get_spring_force(vertex, vertices[left_index], 
            environment_data.structural_stiffness, STRUCTURAL_REST_LENGTH);
    }

    if (has_right) {
        let right_index = index + 1u;
        force += get_spring_force(vertex, vertices[right_index], 
            environment_data.structural_stiffness, STRUCTURAL_REST_LENGTH);
    }

    if (has_top) {
        let top_index = index - environment_data.grid_width;
        force += get_spring_force(vertex, vertices[top_index], 
            environment_data.structural_stiffness, STRUCTURAL_REST_LENGTH);
    }

    if (has_bottom) {
        let bottom_index = index + environment_data.grid_width;
        force += get_spring_force(vertex, vertices[bottom_index], 
            environment_data.structural_stiffness, STRUCTURAL_REST_LENGTH);
    }

    // Shear springs (diagonal neighbors)
    if (has_top && has_left) {
        let top_left_index = index - environment_data.grid_width - 1u;
        force += get_spring_force(vertex, vertices[top_left_index], 
            environment_data.shear_stiffness, SHEAR_REST_LENGTH);
    }

    if (has_top && has_right) {
        let top_right_index = index - environment_data.grid_width + 1u;
        force += get_spring_force(vertex, vertices[top_right_index], 
            environment_data.shear_stiffness, SHEAR_REST_LENGTH);
    }

    if (has_bottom && has_left) {
        let bottom_left_index = index + environment_data.grid_width - 1u;
        force += get_spring_force(vertex, vertices[bottom_left_index], 
            environment_data.shear_stiffness, SHEAR_REST_LENGTH);
    }

    if (has_bottom && has_right) {
        let bottom_right_index = index + environment_data.grid_width + 1u;
        force += get_spring_force(vertex, vertices[bottom_right_index], 
            environment_data.shear_stiffness, SHEAR_REST_LENGTH);
    }

    // Bending springs (two vertices away)
    if (has_two_left) {
        let two_left_index = index - 2u;
        force += get_spring_force(vertex, vertices[two_left_index], 
            environment_data.bending_stiffness, BENDING_REST_LENGTH);
    }

    if (has_two_right) {
        let two_right_index = index + 2u;
        force += get_spring_force(vertex, vertices[two_right_index], 
            environment_data.bending_stiffness, BENDING_REST_LENGTH);
    }

    if (has_two_top) {
        let two_top_index = index - 2u * environment_data.grid_width;
        force += get_spring_force(vertex, vertices[two_top_index], 
            environment_data.bending_stiffness, BENDING_REST_LENGTH);
    }

    if (has_two_bottom) {
        let two_bottom_index = index + 2u * environment_data.grid_width;
        force += get_spring_force(vertex, vertices[two_bottom_index], 
            environment_data.bending_stiffness, BENDING_REST_LENGTH);
    }

    // Apply gravity
    force += environment_data.gravity * vertex.mass;
    
    // Apply damping proportional to velocity
    force += -environment_data.vertex_damping * vertex.velocity;
    
    // Semi-implicit Euler integration
    let acceleration = force / vertex.mass;
    let new_velocity = vertex.velocity + acceleration * clamped_dt;
    let new_position = vertex.position + new_velocity * clamped_dt;
    
    // Add position-based relaxation
    let final_position = vertex.position + new_velocity * clamped_dt;
    let max_movement = STRUCTURAL_REST_LENGTH * 0.5;
    let movement = final_position - vertex.position;
    let movement_length = length(movement);
    
    if (movement_length > max_movement) {
        let limited_movement = normalize(movement) * max_movement;
        return Vertex(
            vertex.position + limited_movement,
            vertex.color,
            vertex.mass,
            new_velocity * 0.9, // Reduce velocity when limiting movement
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
    let environment_data = unpack_environment_data(params);

    // Clamp the delta_time to be sure of the stability of the simulation
    let clamped_dt = clamp(environment_data.dt, 0.016, 0.033);

    // Fetch current vertex data
    var vertex = vertices[index];

    // Check sphere collision after spring forces and correct if needed
    vertex = resolve_sphere_collision(vertex, environment_data);

    vertex = resolve_spring_behavior(index, vertex, environment_data, clamped_dt);

    vertex = resolve_sphere_collision(vertex, environment_data);

    // Store back
    vertices[index] = vertex;
}