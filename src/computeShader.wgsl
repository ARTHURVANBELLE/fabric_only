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
    vertex_mass: f32,
    vertex_damping: f32,
    structural_max_length: f32,
    shear_max_length: f32,
    bending_max_length: f32,  
    grid_width: u32,
    grid_height: u32,
};

const DELTATIME = 0.016;
const GRAVITY = vec4<f32>(0.0, -0.5, 0.0, 0.0);
const SPHEREDAMPING = 0.5;
const VERTEXMASS = 1.0;
const VERTEXDAMPING = 0.6;


@group(0) @binding(0) var<storage, read_write> vertices: array<Vertex>;
@group(0) @binding(1) var<uniform> params: SimParams;

fn unpack_environment_data(params: SimParams) -> EnvironmentData {
    return EnvironmentData(
        params.sphere_center,
        params.sphere_radius,
        DELTATIME,
        GRAVITY,
        SPHEREDAMPING,
        params.spring_stiffness,
        params.spring_stiffness,
        params.spring_stiffness,
        VERTEXMASS,
        VERTEXDAMPING,
        params.max_length,
        params.max_length,
        params.max_length,
        params.grid_rows,
        params.grid_cols
    );
}

fn resolve_sphere_collision(vertex: Vertex, environment_data: EnvironmentData) -> Vertex {
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
        return Vertex(corrected_pos, vertex.color, 1.0, new_velocity, 0.0);
    }

    return Vertex(vertex.position, vertex.color, 1.0, vertex.velocity, 0.0);
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

    // Store back
    vertices[index] = vertex;
}






