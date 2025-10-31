#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static float cpu_sum(const float* a, uint n) {
    double acc = 0.0;
    for (uint i = 0; i < n; ++i) acc += a[i];
    return (float)acc;
}

int main(int argc, const char** argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "Metal not supported.\n"); return 1; }
        NSLog(@"Using device: %@", device.name);

        NSError* error = nil;
    NSString* kernelPath = @"src/compute/compute_kernels.metal";
    NSString* absPath = @SOURCE_ROOT_DIR;
    absPath = [absPath stringByAppendingPathComponent:kernelPath];
        NSString* src = [NSString stringWithContentsOfFile:absPath encoding:NSUTF8StringEncoding error:&error];
        if (!src) { NSLog(@"Failed to read kernel source: %@", error); return 2; }

        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&error];
        if (!lib) { NSLog(@"Failed to compile library: %@", error); return 3; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"reduce_sum"];
        if (!fn) { NSLog(@"Kernel 'reduce_sum' not found"); return 4; }
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&error];
        if (!pso) { NSLog(@"Failed to create pipeline: %@", error); return 5; }

        id<MTLCommandQueue> queue = [device newCommandQueue];

        const uint N = 1u << 20; // 1,048,576 elements
        NSMutableData* data = [NSMutableData dataWithLength:N * sizeof(float)];
        float* arr = (float*)data.mutableBytes;
        for (uint i = 0; i < N; ++i) arr[i] = 1.0f; // easy to validate: result should be N

    MTLResourceOptions opts = MTLResourceStorageModeShared;
    id<MTLBuffer> inBuf = [device newBufferWithBytes:arr length:data.length options:opts];

        // Choose threadgroup size up to 256
        uint tgSizeX = MIN(256, pso.maxTotalThreadsPerThreadgroup);
        // Number of threadgroups to cover N
        uint numTGs = (N + tgSizeX - 1) / tgSizeX;
    id<MTLBuffer> partialBuf = [device newBufferWithLength:numTGs * sizeof(float) options:opts];
    id<MTLBuffer> nBuf = [device newBufferWithBytes:&N length:sizeof(N) options:opts];

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:inBuf offset:0 atIndex:0];
        [enc setBuffer:partialBuf offset:0 atIndex:1];
        [enc setBuffer:nBuf offset:0 atIndex:2];

        MTLSize tg = MTLSizeMake(tgSizeX, 1, 1);
        MTLSize grid = MTLSizeMake(numTGs * tgSizeX, 1, 1);
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        // CPU finalize
        float* partials = (float*)partialBuf.contents;
        double total = 0.0;
        for (uint i = 0; i < numTGs; ++i) total += partials[i];
        float gpuTotal = (float)total;
        float cpuTotal = cpu_sum(arr, N);

        NSLog(@"reduce_sum GPU=%.1f CPU=%.1f N=%u threadgroups=%u tgSize=%u", gpuTotal, cpuTotal, N, numTGs, tgSizeX);
        if (fabsf(gpuTotal - cpuTotal) > 1e-3f) {
            NSLog(@"Mismatch!");
            return 6;
        }
    }
    return 0;
}
