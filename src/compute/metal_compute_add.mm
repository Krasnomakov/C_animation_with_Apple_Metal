#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static void hexdump(const void* data, size_t count) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < count; ++i) {
        printf("%02X ", p[i]);
        if ((i+1) % 16 == 0) printf("\n");
    }
    if (count % 16) printf("\n");
}

int main(int argc, const char** argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "Metal not supported.\n");
            return 1;
        }
        NSLog(@"Using device: %@", device.name);

        NSError* error = nil;
        // Load our compute kernels from source file
    NSString* kernelPath = @"src/compute/compute_kernels.metal";
    NSString* absPath = @SOURCE_ROOT_DIR;
    absPath = [absPath stringByAppendingPathComponent:kernelPath];
        NSString* src = [NSString stringWithContentsOfFile:absPath encoding:NSUTF8StringEncoding error:&error];
        if (!src) {
            NSLog(@"Failed to read kernel source at %@: %@", absPath, error);
            return 2;
        }

        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&error];
        if (!lib) {
            NSLog(@"Failed to compile library: %@", error);
            return 3;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"vec_add"];
        if (!fn) {
            NSLog(@"Kernel 'vec_add' not found in library");
            return 4;
        }
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&error];
        if (!pso) {
            NSLog(@"Failed to create compute pipeline: %@", error);
            return 5;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];

        // Prepare small input buffers
        const uint N = 64;
        float A[N], B[N];
        for (uint i = 0; i < N; ++i) { A[i] = (float)i; B[i] = (float)(2*i); }

    MTLResourceOptions opts = MTLResourceStorageModeShared; // Best for Apple Silicon unified memory
    id<MTLBuffer> bufA = [device newBufferWithBytes:A length:sizeof(A) options:opts];
    id<MTLBuffer> bufB = [device newBufferWithBytes:B length:sizeof(B) options:opts];
    id<MTLBuffer> bufC = [device newBufferWithLength:sizeof(A) options:opts];
    id<MTLBuffer> bufN = [device newBufferWithBytes:&N length:sizeof(N) options:opts];

        // Encode commands
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"vec_add command buffer";
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        enc.label = @"vec_add encoder";
        [enc setComputePipelineState:pso];
        [enc setBuffer:bufA offset:0 atIndex:0];
        [enc setBuffer:bufB offset:0 atIndex:1];
        [enc setBuffer:bufC offset:0 atIndex:2];
        [enc setBuffer:bufN offset:0 atIndex:3];

        MTLSize tgSize = MTLSizeMake(MIN(pso.maxTotalThreadsPerThreadgroup, 64), 1, 1);
        MTLSize grid = MTLSizeMake(N, 1, 1);
        [enc dispatchThreads:grid threadsPerThreadgroup:tgSize];
        [enc endEncoding];

        [cb commit];
        [cb waitUntilCompleted];

        // Read back and validate
        float* C = (float*)bufC.contents;
        bool ok = true;
        for (uint i = 0; i < N; ++i) {
            float want = A[i] + B[i];
            if (fabsf(C[i] - want) > 1e-6f) {
                ok = false;
                NSLog(@"Mismatch at %u: got %f want %f", i, C[i], want);
                break;
            }
        }
        if (ok) {
            NSLog(@"vec_add OK. First 8 results:");
            for (uint i = 0; i < 8; ++i) printf("C[%u]=%.1f\n", i, C[i]);
        }
    }
    return 0;
}
