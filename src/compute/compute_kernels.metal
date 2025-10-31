#include <metal_stdlib>
using namespace metal;

// Simple element-wise vector addition: C = A + B
kernel void vec_add(
    device const float* inA [[buffer(0)]],
    device const float* inB [[buffer(1)]],
    device float* outC [[buffer(2)]],
    constant uint& n [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid < n) {
        outC[gid] = inA[gid] + inB[gid];
    }
}

// One-pass per-threadgroup reduction to partial sums.
// Each threadgroup writes one partial sum to outPartial[threadgroup_id.x].
// Host can do a final CPU sum of the partials for simplicity.
kernel void reduce_sum(
    device const float* inData [[buffer(0)]],
    device float* outPartial [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint tid [[thread_index_in_threadgroup]],
    uint gid [[thread_position_in_grid]],
    uint tgid [[threadgroup_position_in_grid]])
{
    threadgroup float sdata[256]; // Max threadgroup size we plan to use from host

    float v = 0.0f;
    if (gid < n) {
        v = inData[gid];
    }
    sdata[tid] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Binary tree reduction in shared memory
    uint size = min((uint)256, n - (tgid * 256));
    for (uint stride = size >> 1; stride > 0; stride >>= 1) {
        if (tid < stride) {
            sdata[tid] += sdata[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        outPartial[tgid] = sdata[0];
    }
}
