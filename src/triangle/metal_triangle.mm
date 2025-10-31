#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

@interface TriangleRenderer : NSObject<MTKViewDelegate>
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLRenderPipelineState> pso;
@property(nonatomic,assign) CFTimeInterval lastTime;
@property(nonatomic,assign) double fpsAccum;
@property(nonatomic,assign) int fpsFrames;
@end

@implementation TriangleRenderer
- (instancetype)initWithView:(MTKView*)view {
    if ((self = [super init])) {
        _device = view.device;
        _queue = [_device newCommandQueue];
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

        NSError* err = nil;
        static NSString* kSrc = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VSOut { float4 pos [[position]]; float3 col; };\nvertex VSOut vmain(uint vid [[vertex_id]]){ float2 P[3]={ float2(0.0,0.6), float2(-0.6,-0.6), float2(0.6,-0.6)}; float3 C[3]={ float3(1,0,0), float3(0,1,0), float3(0,0,1)}; VSOut o; o.pos=float4(P[vid],0,1); o.col=C[vid]; return o;}\nfragment float4 fmain(VSOut in [[stage_in]]){ return float4(in.col,1); }";
        id<MTLLibrary> lib = [_device newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) { NSLog(@"Shader compile error: %@", err); return nil; }
        id<MTLFunction> vf = [lib newFunctionWithName:@"vmain"];
        id<MTLFunction> ff = [lib newFunctionWithName:@"fmain"];
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf; pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat;
        _pso = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_pso) { NSLog(@"PSO error: %@", err); return nil; }
        _lastTime = CACurrentMediaTime();
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;

    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:self.pso];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];

    // FPS logging ~ once per second
    CFTimeInterval now = CACurrentMediaTime();
    self.fpsFrames += 1;
    self.fpsAccum += (now - self.lastTime);
    self.lastTime = now;
    if (self.fpsAccum >= 1.0) {
        double fps = self.fpsFrames / self.fpsAccum;
        NSLog(@"FPS: %.1f", fps);
        self.fpsFrames = 0; self.fpsAccum = 0.0;
    }
}
@end

int main(int argc, const char** argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { NSLog(@"No Metal device"); return 1; }
        NSApplication* app = [NSApplication sharedApplication];
        NSRect frame = NSMakeRect(200, 200, 800, 600);
        NSWindow* win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
                                                      backing:NSBackingStoreBuffered defer:NO];
        [win setTitle:@"Metal Triangle"]; 
        MTKView* view = [[MTKView alloc] initWithFrame:frame device:dev];
        TriangleRenderer* renderer = [[TriangleRenderer alloc] initWithView:view];
        view.delegate = renderer; view.enableSetNeedsDisplay = NO; view.paused = NO;
        [win setContentView:view]; [win makeKeyAndOrderFront:nil];
        [NSApp run];
    }
    return 0;
}
