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

const STRUCTURAL_REST_LENGTH: f32 = 0.004;  // fabric_side_length / (grid_size - 1)
const SHEAR_REST_LENGTH: f32 = 0.00566;     // STRUCTURAL_REST_LENGTH * sqrt(2)
const BENDING_REST_LENGTH: f32 = 0.008;     // STRUCTURAL_REST_LENGTH * 2

const DELTATIME = 0.016;
const GRAVITY = vec4<f32>(0.0, -0.5, 0.0, 0.0);
const SPHEREDAMPING = 0.5;
const VERTEXDAMPING = 0.6;
const STRUCTURALMAX = STRUCTURAL_REST_LENGTH * 1.5;
const SHEARMAX      = SHEAR_REST_LENGTH * 1.5;
const BENDINGMAX    = BENDING_REST_LENGTH * 1.5;

const STRUCT_STIFF = 50.0;
const SHEAR_STIFF = 25.0;
const BEND_STIFF = 10.0;


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
    let to_center = vertex.position - environment_data.sphere_center;
    let dist = length(to_center);
    
    // Skip if vertex is fixed
    if (vertex.fixed > 0.5) {
        return vertex;
    }
    
    if (dist < environment_data.sphere_radius + 0.1) {
        let normal = normalize(to_center);
        
        // Stronger position correction with proper scaling
        let penetration = environment_data.sphere_radius + 0.1 - dist;
        let corrected_pos = vertex.position + normal * penetration;
        
        // Project velocity onto tangent plane of sphere
        let velocity_normal = dot(vertex.velocity, normal) * normal;
        let velocity_tangent = vertex.velocity - velocity_normal;
        
        // Apply friction to tangential velocity
        let friction = 0.3; // Adjust as needed
        let new_velocity = velocity_tangent * (1.0 - friction);
        
        // If moving into sphere, bounce
        if (dot(vertex.velocity, normal) < 0.0) {
            let bounce_factor = 0.5; // Adjust for bounciness
            let reflected_velocity = -velocity_normal * bounce_factor;
            return Vertex(
                corrected_pos,
                vertex.color,
                vertex.mass,
                new_velocity + reflected_velocity,
                vertex.fixed
            );
        }
        
        return Vertex(corrected_pos, vertex.color, vertex.mass, new_velocity, vertex.fixed);
    }
    
    return vertex;
}

fn get_spring_force(vertex: Vertex, neighbor: Vertex, stiffness: f32, rest_length: f32) -> vec4<f32> {
    let delta = neighbor.position - vertex.position;  // Changed direction
    let current_length = length(delta);
    
    if (current_length == 0.0) {
        return vec4<f32>(0.0);
    }
    
    let direction = delta / current_length;
    // Force is proportional to displacement from rest length
    let displacement = current_length - rest_length;
    let force = direction * displacement * stiffness;
    
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
    
    return Vertex(new_position, vertex.color, vertex.mass, new_velocity, vertex.fixed);
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






