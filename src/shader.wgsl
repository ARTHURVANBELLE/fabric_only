struct CameraUniform {
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;

struct VertexInput {
    @location(0) position: vec4<f32>,
    @location(1) color: vec4<f32>,
    @location(2) mass: f32,
    @location(3) velocity: vec4<f32>,
    @location(4) fixed: f32,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
/*
    if (model.fixed == 1.0) {
        out.color = vec4<f32>(1.0, 0.0, 0.0, 1.0);
    } else {
        out.color = vec4<f32>(0.0, 0.0, 1.0, 1.0);
    }
*/
    out.color = model.color;
    out.clip_position = camera.proj * camera.view * model.position;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
