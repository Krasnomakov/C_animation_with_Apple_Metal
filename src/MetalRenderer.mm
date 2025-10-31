#import "MetalRenderer.h"
#import <simd/simd.h>

@interface MetalRenderer ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, assign) float time;
@end

@implementation MetalRenderer

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

        NSError *error = nil;

        // If there's no default library available, compile shader source at runtime.
        NSString *shaderSource = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VertexOut { float4 position [[position]]; float3 color; };\nvertex VertexOut vertex_main(uint vertexID [[vertex_id]], constant float &time [[buffer(1)]]) { float angle = time; float s = sin(angle); float c = cos(angle); float2 positions[3] = { {0.0,  0.6}, {-0.55, -0.3}, {0.55, -0.3} }; float3 colors[3] = { {1,0,0}, {0,1,0}, {0,0,1} }; float2 p = positions[vertexID]; float2 rot = float2(p.x * c - p.y * s, p.x * s + p.y * c); VertexOut out; out.position = float4(rot.x, rot.y, 0.0, 1.0); out.color = colors[vertexID]; return out; }\nfragment float4 fragment_main(VertexOut in [[stage_in]]) { return float4(in.color, 1.0); }";

        id<MTLLibrary> library = [_device newLibraryWithSource:shaderSource options:nil error:&error];
        if (!library) {
            NSLog(@"Failed to compile Metal shader library: %@", error);
            return nil;
        }

        id<MTLFunction> vertexFn = [library newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fragmentFn = [library newFunctionWithName:@"fragment_main"];

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vertexFn;
        pd.fragmentFunction = fragmentFn;
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat;

    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!_pipelineState) {
            NSLog(@"Failed to create pipeline state: %@", error);
            return nil;
        }
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // no-op
}

- (void)drawInMTKView:(MTKView *)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;

    // Update time
    self.time += 1.0f/60.0f;

    id<MTLCommandBuffer> cb = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:self.pipelineState];

    // Pass time as a small buffer
    float t = self.time;
    [enc setVertexBytes:&t length:sizeof(t) atIndex:1];

    // Draw triangle (3 vertices)
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end
