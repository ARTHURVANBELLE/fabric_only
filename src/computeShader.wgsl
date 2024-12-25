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
    rest_length: f32,
    sphere_center: vec4<f32>,
    sphere_radius: f32,
}

const Gravity = 0.81;
const frameTime = 0.016;

@group(0) @binding(0) var<storage, read_write> vertices: array<Vertex>;
@group(0) @binding(1) var<uniform> params: SimParams;

@compute @workgroup_size(256)
fn cs_main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let index = global_id.x;
    if (index >= params.grid_rows * params.grid_cols) {
        return;
    }

    // Read the original vertex
    var vertex = vertices[index];
    
    if (vertex.fixed == 0.0) {
            vertex.velocity.y -= Gravity * frameTime;
            vertex.position.y += vertex.velocity.y * frameTime;

            if (vertex.position.y < -2.0) {
                vertex.position.y = -2.0;
                vertex.velocity.y = 0.0;
            }

            // Sphere collision
            let sphere_center = params.sphere_center.xyz;
            let sphere_radius = params.sphere_radius;
            let dist = distance(vertex.position.xyz, sphere_center);
            if (dist < sphere_radius) {
                let normal = normalize(vertex.position.xyz - sphere_center);
                vertex.position.x = sphere_center.x + normal.x * sphere_radius;
                vertex.position.y = sphere_center.y + normal.y * sphere_radius;
                vertex.position.z = sphere_center.z + normal.z * sphere_radius;
                /*
                vertex.velocity.x = - vertex.velocity.x ;
                vertex.velocity.y = - vertex.velocity.y;
                vertex.velocity.z = - vertex.velocity.z;
                */
            }
        }
    
    // Write back only the modified vertex
    vertices[index] = vertex;
}