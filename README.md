# C_animation

A collection of small GPU/graphics experiments for macOS. Most samples use Apple’s Metal framework (compute and rendering). A legacy OpenGL (GLFW) example is included for contrast.

## Demo

Video: https://youtu.be/BVOkcFaubFk

## Repository structure

- `CMakeLists.txt` — top-level build configuration
- `README.md` — this overview
- `apple_metal_data/`
  - `readme.md` — curated links and notes about Metal and GPU topics
- `src/`
  - `main.cpp` — legacy OpenGL rotating cube (GLFW)
  - `README.md` — GLFW-specific build/run instructions
  - `compute/`
    - `compute_kernels.metal` — vector add and reduction kernels
    - `metal_compute_add.mm` — console app: GPU vector addition with validation
    - `metal_compute_reduce.mm` — console app: GPU parallel sum (partial reductions)
  - `triangle/`
    - `metal_triangle.mm` — minimal MetalKit renderer; draws a triangle and logs FPS
  - `maze/`
    - `metal_room_main.mm` — app entry and MTKView setup
    - `MetalRoomRenderer.h/.mm` — bouncing sphere in an AABB room; keyboard + UDP controls
    - `README.md` — controls, UDP commands, and troubleshooting
- `build/` — created by CMake (not tracked); contains built binaries

## Prerequisites (macOS)

- CMake
- Xcode Command Line Tools (clang, Apple frameworks)
- For the GLFW sample: Homebrew + glfw + pkg-config (see `src/README.md`)

## Build (CMake)

From the repository root:

```zsh
cmake -S . -B build
cmake --build build -- -j4
```

This produces binaries in `build/` (set may vary by tree):
- `metal_compute_add`
- `metal_compute_reduce`
- `metal_triangle`
- `metal_room`
- `metal_maze`
- `metal_cube`
- `simple_glfw_cube`

## Run

Compute (terminal):
```zsh
./build/metal_compute_add
./build/metal_compute_reduce
```

Rendering (windowed):
```zsh
./build/metal_triangle
./build/metal_room
```

For `metal_room` controls and UDP commands, see `src/maze/README.md`.

## Notes

- Compute kernels compile at runtime from `src/compute/compute_kernels.metal` — edit and rerun for fast iteration.
- On Apple Silicon, buffers use Shared storage to simplify CPU/GPU access.
- To inspect GPU work, run under Xcode and use Metal’s GPU Frame Capture.
