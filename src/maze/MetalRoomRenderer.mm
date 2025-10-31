#import "MetalRoomRenderer.h"
#import <simd/simd.h>
#import <CoreFoundation/CoreFoundation.h>

typedef struct {
    simd_float4 cameraPosition;  // xyz = eye, w = time
    simd_float4 cameraForward;
    simd_float4 cameraRight;     // w = aspect
    simd_float4 cameraUp;
    simd_float4 sphere;          // xyz = pos, w = radius
    simd_float4 roomHalf;        // xyz = half extents, w unused
} RoomUniforms;

@interface MetalRoomRenderer ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, assign) float time;
@property (nonatomic, assign) vector_float3 eye;
@property (nonatomic, assign) vector_float3 forward;
@property (nonatomic, assign) vector_float3 up;
@property (nonatomic, assign) vector_float3 right;
@property (nonatomic, assign) vector_float3 spherePos;
@property (nonatomic, assign) vector_float3 sphereVel;
@property (nonatomic, assign) float sphereRadius;
@property (nonatomic, assign) vector_float3 roomHalf;
@property (nonatomic, assign) CFTimeInterval lastFrameTimestamp;
@property (nonatomic, assign) vector_float3 accel;
@property (nonatomic, assign) BOOL keyForward;
@property (nonatomic, assign) BOOL keyBackward;
@property (nonatomic, assign) BOOL keyLeft;
@property (nonatomic, assign) BOOL keyRight;
@end

@implementation MetalRoomRenderer

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (!self) return nil;

    _device = view.device;
    _commandQueue = [_device newCommandQueue];
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.clearColor = MTLClearColorMake(0.02, 0.02, 0.05, 1.0);
    view.framebufferOnly = NO;
    view.preferredFramesPerSecond = 60;

    _eye = (vector_float3){0.0f, 0.6f, -3.8f};
    _forward = (vector_float3){0.0f, 0.0f, 1.0f};
    _right = (vector_float3){1.0f, 0.0f, 0.0f};
    _up = (vector_float3){0.0f, 1.0f, 0.0f};

    _roomHalf = (vector_float3){5.0f, 1.8f, 5.0f};
    _sphereRadius = 0.35f;
    _spherePos = (vector_float3){0.0f, 0.2f, 0.0f};
    _sphereVel = (vector_float3){3.6f, 1.4f, 3.0f};
    _lastFrameTimestamp = 0.0;
    _accel = (vector_float3){0.0f, 0.0f, 0.0f};
    _keyForward = _keyBackward = _keyLeft = _keyRight = NO;

    static const char *kRoomShader = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VSOut { float4 position [[position]]; float2 uv; };

vertex VSOut vertex_main(uint vid [[vertex_id]]) {
    const float2 positions[4] = { {-1,-1},{1,-1},{-1,1},{1,1} };
    const float2 uvs[4] = { {0,0},{1,0},{0,1},{1,1} };
    VSOut o; o.position = float4(positions[vid],0,1); o.uv = uvs[vid]; return o;
}

struct Uniforms {
    float4 cameraPosition;
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 sphere;   // xyz pos, w radius
    float4 roomHalf; // xyz half extents
};

float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float mapScene(float3 p, constant Uniforms &u, thread int &matId) {
    float roomSurface = abs(sdBox(p, u.roomHalf.xyz)) - 0.005;
    float sphere = length(p - u.sphere.xyz) - u.sphere.w;
    if (sphere < roomSurface) { matId = 1; return sphere; } // 1 = sphere
    matId = 2; return roomSurface; // 2 = wall
}

float trace(float3 ro, float3 rd, constant Uniforms &u, thread int &matId) {
    float t = 0.0;
    matId = 0;
    for (int i=0;i<160;i++) {
        float3 pos = ro + rd * t;
        int id; float d = mapScene(pos, u, id);
        if (d < 0.001) { matId = id; return t; }
        t += d;
        if (t > 100.0) break;
    }
    return 1e6;
}

float3 calcNormal(float3 p, constant Uniforms &u) {
    const float e = 0.0015;
    int tmp;
    float3 n = float3(
        mapScene(p + float3(e,0,0), u, tmp) - mapScene(p - float3(e,0,0), u, tmp),
        mapScene(p + float3(0,e,0), u, tmp) - mapScene(p - float3(0,e,0), u, tmp),
        mapScene(p + float3(0,0,e), u, tmp) - mapScene(p - float3(0,0,e), u, tmp)
    );
    return normalize(n);
}

fragment float4 fragment_main(VSOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    uv.x *= u.cameraRight.w; // aspect
    float3 ro = u.cameraPosition.xyz;
    float3 f = normalize(u.cameraForward.xyz);
    float3 r = normalize(u.cameraRight.xyz);
    float3 up = normalize(u.cameraUp.xyz);
    float3 rd = normalize(f + uv.x * r + uv.y * up);

    int matId = 0;
    float t = trace(ro, rd, u, matId);
    float3 sky = mix(float3(0.04,0.05,0.08), float3(0.1,0.16,0.24), clamp(in.uv.y,0.0,1.0));
    if (t >= 1e6) return float4(sky,1);

    float3 p = ro + rd * t;
    float3 n = calcNormal(p, u);
    float3 L = normalize(float3(0.5,0.8,-0.2));
    float diff = max(dot(n,L), 0.0);
    float3 V = normalize(-rd);
    float3 H = normalize(L + V);
    float spec = pow(max(dot(n,H), 0.0), 48.0);

    float3 base = (matId == 1) ? float3(0.2,0.8,1.0) : float3(0.8,0.65,0.4);
    float3 col = base * (0.2 + 0.8 * diff) + spec * 0.3;
    float fog = clamp(t / 40.0, 0.0, 1.0);
    col = mix(col, sky, fog);
    return float4(col,1);
}
)METAL";

    NSString *source = [NSString stringWithUTF8String:kRoomShader];
    NSError *err = nil;
    _library = [_device newLibraryWithSource:source options:nil error:&err];
    if (!_library) { NSLog(@"Room shader compile failed: %@", err); return nil; }

    id<MTLFunction> vfn = [_library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> ffn = [_library newFunctionWithName:@"fragment_main"];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    err = nil;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipelineState) { NSLog(@"Room pipeline failed: %@", err); return nil; }

    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { (void)view; (void)size; }

- (void)integrateSphere:(float)dt {
    // Integrate simple motion and bounce on AABB walls + camera plane
    const float damping = 0.997f;
    const float restitution = 0.9f;
    vector_float3 pos = self.spherePos;
    vector_float3 vel = self.sphereVel;
    // Apply acceleration (keyboard or external)
    vector_float3 a = self.accel;
    vel += a * dt;
    pos += vel * dt;

    vector_float3 limit = self.roomHalf - (vector_float3){self.sphereRadius, self.sphereRadius, self.sphereRadius};

    if (pos.x > limit.x) { pos.x = limit.x; vel.x = -vel.x * restitution; }
    if (pos.x < -limit.x){ pos.x = -limit.x; vel.x = -vel.x * restitution; }
    if (pos.y > limit.y) { pos.y = limit.y; vel.y = -vel.y * restitution; }
    if (pos.y < -limit.y){ pos.y = -limit.y; vel.y = -vel.y * restitution; }
    if (pos.z > limit.z) { pos.z = limit.z; vel.z = -vel.z * restitution; }
    if (pos.z < -limit.z){ pos.z = -limit.z; vel.z = -vel.z * restitution; }

    // Virtual wall at the camera plane: keep sphere in front of the camera
    float planeZ = self.eye.z + self.sphereRadius + 0.08f;
    if (pos.z < planeZ) {
        pos.z = planeZ;
        if (vel.z < 0.0f) vel.z = -vel.z * restitution;
    }

    vel *= damping;
    self.spherePos = pos;
    self.sphereVel = vel;
}

- (void)applyExternalAccelerationX:(float)ax Y:(float)ay Z:(float)az {
    self.accel = (vector_float3){ax, ay, az};
}

- (BOOL)handleKeyEventWithCode:(unsigned short)keyCode pressed:(BOOL)isPressed {
    switch (keyCode) {
        case 126: /* Up */   self.keyForward = isPressed; break;
        case 125: /* Down */ self.keyBackward = isPressed; break;
        case 123: /* Left */ self.keyLeft = isPressed; break;
        case 124: /* Right */self.keyRight = isPressed; break;
        case 13:  /* W */    self.keyForward = isPressed; break;
        case 1:   /* S */    self.keyBackward = isPressed; break;
        case 0:   /* A */    self.keyLeft = isPressed; break;
        case 2:   /* D */    self.keyRight = isPressed; break;
        default: return NO;
    }
    // Map keys to acceleration in XZ plane
    vector_float3 a = (vector_float3){0,0,0};
    const float accelMag = 6.5f;
    if (self.keyForward)  a.z += accelMag;
    if (self.keyBackward) a.z -= accelMag;
    if (self.keyRight)    a.x += accelMag;
    if (self.keyLeft)     a.x -= accelMag;
    self.accel = a;
    return YES;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    float dt = (self.lastFrameTimestamp > 0.0) ? (float)(now - self.lastFrameTimestamp) : (1.0f/60.0f);
    self.lastFrameTimestamp = now;
    dt = fminf(fmaxf(dt, 1.0f/600.0f), 0.05f);

    [self integrateSphere:dt];
    self.time += dt;

    float aspect = (view.drawableSize.height > 0.0) ? (float)(view.drawableSize.width / view.drawableSize.height) : 1.0f;

    RoomUniforms u;
    u.cameraPosition = (simd_float4){self.eye.x, self.eye.y, self.eye.z, self.time};
    u.cameraForward  = (simd_float4){self.forward.x, self.forward.y, self.forward.z, 0};
    u.cameraRight    = (simd_float4){self.right.x, self.right.y, self.right.z, aspect};
    u.cameraUp       = (simd_float4){self.up.x, self.up.y, self.up.z, 0};
    u.sphere         = (simd_float4){self.spherePos.x, self.spherePos.y, self.spherePos.z, self.sphereRadius};
    u.roomHalf       = (simd_float4){self.roomHalf.x, self.roomHalf.y, self.roomHalf.z, 0};

    id<MTLCommandBuffer> cb = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:self.pipelineState];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
}

@end
