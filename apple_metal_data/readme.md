Links and notes about Apple Metal and GPU topics

- Metal benchmarks and performance notes: https://github.com/philipturner/metal-benchmarks
- Metal Shading Language (MSL) reference: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
- Metal best practices: https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf and WWDC videos
- GPU Frame Capture & tools: use Xcode’s Metal frame capture to inspect pipelines and timing.

See working samples in this repo:
- Compute: `metal_compute_add`, `metal_compute_reduce`
- Rendering: `metal_triangle`, `metal_room`, `metal_maze`

Notes on metal_stdlib:
- The standard library is available in `.metal` via `#include <metal_stdlib>` and `using namespace metal;`
- Prefer `threadgroup` memory and barriers for reductions and scans; see `reduce_sum` in `src/compute/compute_kernels.metal`.
