# Metal Room (Sphere Bounce) and Inputs

A minimal Metal demo on macOS that ray-marches a single rectangular room (AABB) and a bouncing sphere. Includes keyboard-based acceleration and a tiny UDP control path for external commands.

## What’s here
- `metal_room`: A stand-alone app that opens a window with an MTKView and renders a room and a sphere using a small inline Metal shader.
- CPU handles simple physics integration and wall collisions (including a virtual camera-plane wall so the sphere never goes behind the camera).
- Input:
  - Keyboard: arrows or WASD apply acceleration in the XZ plane.
  - UDP: send acceleration triples over localhost:9999 (e.g., via `nc`).

## Tech stack
- macOS frameworks: Cocoa, Metal, MetalKit
- Build system: CMake
- Language: Objective‑C++ for the renderer and app glue; Metal Shading Language for GPU code

## Build
From the repo root (one level above this folder):

```zsh
cd /Users/red/Documents/C_animation
# First configure (only needed once or when CMakeLists.txt changes)
cmake -S . -B build
# Build the room demo
cmake --build build --target metal_room
```

If you’ve already configured `build`, you can just run the last line to rebuild.

For additional samples (compute and a minimal renderer), see the root README’s “Metal compute and minimal rendering samples” section.

## Run
```zsh
cd /Users/red/Documents/C_animation/build
./metal_room
```

Notes:
- No sudo required.
- If the window doesn’t respond to keys initially, click inside the window once. The app also installs local/global key monitors to forward events.

## Controls (keyboard)
- Up / W: accelerate forward (+Z)
- Down / S: accelerate backward (−Z)
- Right / D: accelerate right (+X)
- Left / A: accelerate left (−X)

Acceleration applies while the key is held; the sphere continues moving with damping and bounces when it hits the room/camera walls.

## External control (UDP)
The app opens a UDP socket on `127.0.0.1:9999` and parses plain-text lines containing three floats: `ax ay az` (acceleration in m/s²‑ish).

Examples (in another terminal):
```zsh
# Accelerate +X
printf "4.0 0.0 0.0\n" | nc -u 127.0.0.1 9999
# Accelerate -Z
printf "0.0 0.0 -6.0\n" | nc -u 127.0.0.1 9999
# Stop acceleration
printf "0.0 0.0 0.0\n" | nc -u 127.0.0.1 9999
```

If port 9999 is busy, you can change it in `src/maze/metal_room_main.mm` (look for `htons(9999)`), rebuild, and run again.

## Files
- `src/maze/metal_room_main.mm`: Cocoa app entry point, MTKView setup, keyboard forwarding, and UDP listener.
- `src/maze/MetalRoomRenderer.h/.mm`: MTKView delegate, physics integration, uniforms, and inline Metal shader (full‑screen quad + ray‑march fragment shader for room & sphere).

## Troubleshooting
- Gray window: Check the terminal for a "shader compile failed" message. Fixes typically involve Metal function signatures; rebuild after edits.
- No keyboard input: Click inside the window once to focus. The app sets the MTKView as initial first responder and installs event monitors, but macOS may still need a click if another app had focus.
- High CPU: Lower the preferred FPS or reduce ray‑march steps in the shader.

## Customize
- Tweak room size, sphere radius/speed, restitution, and damping in `MetalRoomRenderer.mm`.
- Adjust camera position if you want a wider view (see `_eye`).
- Replace the simple lighting with your own material model.
