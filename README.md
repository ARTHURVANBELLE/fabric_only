# GPU-Accelerated Cloth Simulation

A real-time cloth simulation implemented in Rust and WGSL (WebGPU Shading Language), demonstrating physical simulation of fabric interacting with a sphere using spring-mass dynamics.

## Features

- Real-time cloth simulation using a spring-mass system
- GPU-accelerated computation using WGSL compute shaders
- Multiple types of spring constraints:
  - Structural springs (direct neighbors)
  - Shear springs (diagonal connections)
  - Bending springs (secondary neighbors)
- Sphere collision detection and response
- Adaptive spring stiffness for more realistic behavior
- Position-based relaxation for improved stability
- Interactive camera controls with orbit and zoom functionality

## Technical Details

### Physics Model

The simulation uses a mass-spring model with the following characteristics:
- Each vertex in the cloth mesh represents a mass point
- Springs connect these points in three configurations:
  - Structural springs maintain the basic grid structure
  - Shear springs resist diagonal deformation
  - Bending springs provide resistance to folding
- Semi-implicit Euler integration for stable physics updates
- Non-linear spring behavior to prevent excessive stretching
- Velocity damping for stability

### Implementation

- Written in Rust using the `wgpu_bootstrap` framework
- Compute shader implementation in WGSL for parallel processing
- Vertex data structure aligned for optimal GPU memory access
- Efficient grid-based spring connection system
- Configurable simulation parameters:
  - Spring stiffness coefficients
  - Rest lengths
  - Damping factors
  - Time step size
  - Grid dimensions

## Performance Considerations

- GPU-optimized data structures with proper memory alignment
- Workgroup size of 256 threads for efficient GPU utilization
- Clamped time steps for numerical stability
- Limited maximum forces to prevent instability
- Position-based movement limitations for additional stability

## Requirements

- Rust toolchain
- GPU with WebGPU support
- `wgpu_bootstrap` and dependencies

## Usage

1. Clone the repository
2. Install dependencies:
```bash
cargo build
```
3. Run the simulation:
```bash
cargo run
```

## Controls

- Orbit: Click and drag with the mouse
- Zoom: Mouse wheel
- The cloth automatically interacts with the sphere in the scene

## Configuration

Key simulation parameters can be adjusted in the code:

```rust
let fabric_side_length = 6.0;
let grid_rows: u32 = 100;
let grid_cols: u32 = 100;
let k_spring = 0.12;
let ball_radius = 1.0;
```

Additional physics parameters:

```rust
struct SimParams2 {
    stiffness: [25.0, 15.0, 5.0, 0.0],     // Structural, shear, and bending stiffness
    rest_length: [0.06, 0.085, 0.12, 0.0],  // Rest lengths for different spring types
    gravity: [0.0, -6.8, 0.0, 0.0],         // Gravity vector
}
```
