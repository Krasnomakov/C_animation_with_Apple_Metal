#import "MetalMazeRenderer.h"
#import <simd/simd.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#import <stdlib.h>
#import <stdint.h>

static vector_float2 gMazeSeed = {0.0f, 0.0f};

static inline float fractf(float value) {
    return value - floorf(value);
}

static inline vector_float2 floor2(vector_float2 value) {
    return (vector_float2){floorf(value.x), floorf(value.y)};
}

static float MazeHash21(vector_float2 p);

static inline vector_float2 fract2(vector_float2 value) {
    return value - floor2(value);
}
typedef NS_OPTIONS(uint8_t, MazeCorridorMask) {
    MazeCorridorMaskX = 1 << 0,
    MazeCorridorMaskZ = 1 << 1,
};

static inline vector_float2 MazeGridForPosition(vector_float3 p) {
    const float cellSize = 8.0f;
    vector_float2 posXZ = (vector_float2){p.x, p.z};
    return floor2((posXZ + cellSize * 0.5f) / cellSize);
}

static inline vector_int2 MazeCellForPosition(vector_float3 p) {
    vector_float2 grid = MazeGridForPosition(p);
    return (vector_int2){(int)grid.x, (int)grid.y};
}

static inline vector_float3 MazeCenterForCell(vector_int2 cell, float height) {
    const float cellSize = 8.0f;
    return (vector_float3){(float)cell.x * cellSize, height, (float)cell.y * cellSize};
}

static inline uint8_t MazeCorridorMaskForCellSeeded(vector_int2 cell, vector_float2 seed) {
    vector_float2 cellFloat = (vector_float2){(float)cell.x, (float)cell.y};
    float r = MazeHash21(cellFloat + seed * 37.0f);
    if (r < 0.35f) {
        return MazeCorridorMaskX;
    }
    if (r < 0.7f) {
        return MazeCorridorMaskZ;
    }
    return MazeCorridorMaskX | MazeCorridorMaskZ;
}

static inline BOOL MazeCellsConnected(vector_int2 a, vector_int2 b) {
    vector_int2 delta = (vector_int2){b.x - a.x, b.y - a.y};
    BOOL axisX = (delta.x != 0);
    BOOL axisZ = (delta.y != 0);
    if ((axisX && axisZ) || (!axisX && !axisZ)) {
        return NO;
    }

    // deterministic per-seed corridor openness for both cells
    // ensures edges interlock across the infinite grid
    uint8_t maskA = MazeCorridorMaskForCellSeeded(a, gMazeSeed);
    uint8_t maskB = MazeCorridorMaskForCellSeeded(b, gMazeSeed);
    if (axisX) {
        return (maskA & MazeCorridorMaskX) && (maskB & MazeCorridorMaskX);
    }
    return (maskA & MazeCorridorMaskZ) && (maskB & MazeCorridorMaskZ);
}

static float MazeHash21(vector_float2 p) {
    vector_float2 v = fract2(p * (vector_float2){123.34f, 345.45f});
    float d = simd_dot(v, v + (vector_float2){34.345f, 34.345f});
    v += d;
    return fractf(v.x * v.y);
}

static float MazeDistance(vector_float3 p) {
    const float cellSize = 8.0f;
    const float halfCell = cellSize * 0.5f;
    const float corridorHalf = 0.85f;
    const float height = 1.2f;

    vector_float2 posXZ = simd_make_float2(p.x, p.z);
    vector_float2 grid = floor2((posXZ + cellSize * 0.5f) / cellSize);
    vector_float2 local = posXZ - (grid + 0.5f) * cellSize;

    float hallwayX = fmaxf(fmaxf(fabsf(local.x) - halfCell, fabsf(local.y) - corridorHalf), fabsf(p.y) - height);
    float hallwayZ = fmaxf(fmaxf(fabsf(local.y) - halfCell, fabsf(local.x) - corridorHalf), fabsf(p.y) - height);

    float r = MazeHash21(grid);
    float corridor = (r < 0.35f) ? hallwayX : (r < 0.7f ? hallwayZ : fminf(hallwayX, hallwayZ));

    float floorDist = p.y + height;
    float ceilingDist = height - p.y;

    return fminf(fabsf(corridor), fminf(floorDist, ceilingDist));
}

typedef struct {
    simd_float4 cameraPosition;
    simd_float4 cameraForward;
    simd_float4 cameraRight;
    simd_float4 cameraUp;
    simd_float4 entityPosition;
    simd_float4 seed;
} MazeUniforms;

@interface MetalMazeRenderer ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, assign) float time;
@property (nonatomic, assign) vector_float3 playerPosition;
@property (nonatomic, assign) float yaw;
@property (nonatomic, assign) float eyeBaseHeight;
@property (nonatomic, assign) BOOL moveForward;
@property (nonatomic, assign) BOOL moveBackward;
@property (nonatomic, assign) BOOL turnLeft;
@property (nonatomic, assign) BOOL turnRight;
@property (nonatomic, assign) BOOL strafeLeft;
@property (nonatomic, assign) BOOL strafeRight;
@property (nonatomic, assign) CFTimeInterval lastFrameTimestamp;
@property (nonatomic, assign) vector_float3 orbPosition;
@property (nonatomic, assign) vector_float3 orbVelocity;
@property (nonatomic, assign) vector_int2 orbCell;
@property (nonatomic, assign) vector_int2 orbTargetCell;
@property (nonatomic, assign) vector_int2 orbPreviousCell;
@property (nonatomic, assign) vector_float3 orbTargetPosition;
@property (nonatomic, assign) float orbSpeed;
@property (nonatomic, assign) float orbRadius;
@property (nonatomic, assign) BOOL manualControlActive;
@property (nonatomic, assign) vector_float2 mazeSeed;
- (void)updateOrbWithDelta:(float)deltaTime;
- (void)chooseNewOrbDirection;
@end

@implementation MetalMazeRenderer

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.05, 1.0);
        view.framebufferOnly = NO;
        view.preferredFramesPerSecond = 60;
        view.enableSetNeedsDisplay = NO;
        view.paused = NO;

        _eyeBaseHeight = 0.35f;
        _playerPosition = (vector_float3){0.0f, _eyeBaseHeight, 0.0f};
        _yaw = (float)M_PI_2;
        _lastFrameTimestamp = 0.0;
        _orbRadius = 0.22f;
        _orbSpeed = 2.6f;
        float orbHeight = _eyeBaseHeight + 0.2f;
        vector_int2 startCell = (vector_int2){0, 0};
        _orbCell = startCell;
        _orbTargetCell = startCell;
        _orbPreviousCell = startCell;
        _orbPosition = MazeCenterForCell(startCell, orbHeight);
        _orbTargetPosition = _orbPosition;
        _orbVelocity = (vector_float3){0.0f, 0.0f, 0.0f};
        _manualControlActive = NO;
    // Initialize maze seed deterministically; could be randomized.
    _mazeSeed = (vector_float2){ arc4random_uniform(10000) / 10000.0f,
                     arc4random_uniform(10000) / 10000.0f };
    gMazeSeed = _mazeSeed;
    [self chooseNewOrbDirection];

        static const char *kMazeShader = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 cameraPosition;
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 entityPosition;
    float4 seed;
};

float hash21_seed(float2 p, float2 s) {
    p += s * 37.0;
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

float mapScene(float3 p, constant Uniforms &u) {
    const float cellSize = 8.0;
    const float halfCell = cellSize * 0.5;
    const float corridorHalf = 0.85;
    const float height = 1.2;

    float2 grid = floor((p.xz + cellSize * 0.5) / cellSize);
    float2 local = p.xz - (grid + 0.5) * cellSize;

    float hallwayX = max(max(fabs(local.x) - halfCell, fabs(local.y) - corridorHalf), fabs(p.y) - height);
    float hallwayZ = max(max(fabs(local.y) - halfCell, fabs(local.x) - corridorHalf), fabs(p.y) - height);

    float r = hash21_seed(grid, u.seed.xy);
    float corridor = (r < 0.35) ? hallwayX : (r < 0.7 ? hallwayZ : min(hallwayX, hallwayZ));

    float floorDist = p.y + height;
    float ceilingDist = height - p.y;

    float mazeDist = min(fabs(corridor), min(floorDist, ceilingDist));
    float entityDist = length(p - u.entityPosition.xyz) - u.entityPosition.w;
    return min(mazeDist, entityDist);
}

float trace(float3 ro, float3 rd, constant Uniforms &u) {
    float dist = 0.0;
    for (int i = 0; i < 160; ++i) {
        float3 pos = ro + rd * dist;
        float d = mapScene(pos, u);
        if (d < 0.001) {
            return dist;
        }
        dist += d;
        if (dist > 180.0) {
            break;
        }
    }
    return 1e6;
}

float3 calcNormal(float3 p, constant Uniforms &u) {
    const float eps = 0.002;
    float3 n = float3(
        mapScene(p + float3(eps, 0.0, 0.0), u) - mapScene(p - float3(eps, 0.0, 0.0), u),
        mapScene(p + float3(0.0, eps, 0.0), u) - mapScene(p - float3(0.0, eps, 0.0), u),
        mapScene(p + float3(0.0, 0.0, eps), u) - mapScene(p - float3(0.0, 0.0, eps), u)
    );
    return normalize(n);
}

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vertex_main(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        {-1.0, -1.0},
        { 1.0, -1.0},
        {-1.0,  1.0},
        { 1.0,  1.0}
    };
    const float2 uvs[4] = {
        {0.0, 0.0},
        {1.0, 0.0},
        {0.0, 1.0},
        {1.0, 1.0}
    };

    VSOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 fragment_main(VSOut in [[stage_in]], constant Uniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    float aspect = uniforms.cameraRight.w;
    uv.x *= aspect;

    float3 ro = uniforms.cameraPosition.xyz;
    float3 forward = normalize(uniforms.cameraForward.xyz);
    float3 right = normalize(uniforms.cameraRight.xyz);
    float3 up = normalize(uniforms.cameraUp.xyz);
    float3 rd = normalize(forward + uv.x * right + uv.y * up);

    float travel = trace(ro, rd, uniforms);
    float3 sky = mix(float3(0.04, 0.05, 0.08), float3(0.12, 0.18, 0.28), clamp(in.uv.y, 0.0, 1.0));
    if (travel >= 1e6) {
        return float4(sky, 1.0);
    }

    float3 hit = ro + rd * travel;
    float3 normal = calcNormal(hit, uniforms);
    float3 lightDir = normalize(float3(0.4, 0.8, -0.2));
    float diff = clamp(dot(normal, lightDir), 0.0, 1.0);
    float3 viewDir = normalize(-rd);
    float3 halfVec = normalize(lightDir + viewDir);
    float spec = pow(clamp(dot(normal, halfVec), 0.0, 1.0), 32.0);

    float3 entityPos = uniforms.entityPosition.xyz;
    float entityRadius = uniforms.entityPosition.w;
    float entitySurface = length(hit - entityPos) - entityRadius;

    float3 color;
    if (fabs(entitySurface) < 0.02) {
        float sparkle = pow(clamp(dot(normal, halfVec), 0.0, 1.0), 16.0);
        float diffEntity = clamp(dot(normal, lightDir), 0.0, 1.0);
        color = float3(0.15, 0.7, 1.2) * (0.4 + 0.6 * diffEntity) + sparkle * 0.6;
    } else {
        const float cellSize = 8.0;
        float2 cell = floor((hit.xz + cellSize * 0.5) / cellSize);
        float cellTone = hash21_seed(cell, uniforms.seed.xy);
        float3 wallColor = mix(float3(0.85, 0.6, 0.35), float3(0.25, 0.5, 0.9), cellTone);
        float ao = clamp(1.0 - travel * 0.018, 0.2, 1.0);
        color = wallColor * (0.25 + 0.75 * diff) * ao + spec * 0.25;
    }

    float glowAmount = exp(-max(entitySurface, 0.0) * 6.0);
    color += glowAmount * float3(0.05, 0.3, 0.5);

    float fog = clamp(travel / 130.0, 0.0, 1.0);
    color = mix(color, sky, fog);

    return float4(color, 1.0);
}
)METAL";

        NSString *source = [NSString stringWithUTF8String:kMazeShader];
        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            NSLog(@"Failed to compile maze shader: %@", error);
            return nil;
        }

        id<MTLFunction> vertexFn = [library newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fragmentFn = [library newFunctionWithName:@"fragment_main"];

        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = vertexFn;
        desc.fragmentFunction = fragmentFn;
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;

        _pipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!_pipelineState) {
            NSLog(@"Failed to create maze pipeline: %@", error);
            return nil;
        }
    }
    return self;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) {
        return;
    }

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    float delta = (self.lastFrameTimestamp > 0.0) ? (float)(now - self.lastFrameTimestamp) : (1.0f / 60.0f);
    self.lastFrameTimestamp = now;
    delta = fminf(fmaxf(delta, 1.0f / 600.0f), 0.1f);

    [self updateSimulationWithDelta:delta];
    self.time += delta;

    BOOL moving = self.manualControlActive && (self.moveForward || self.moveBackward || self.strafeLeft || self.strafeRight);
    float bob = moving ? sinf(self.time * 6.0f) * 0.05f : 0.0f;
    vector_float3 eye = self.playerPosition;
    if (self.manualControlActive) {
        eye.y += bob;
    }

    vector_float3 forward;
    if (self.manualControlActive) {
        forward = simd_normalize((vector_float3){sinf(self.yaw), 0.0f, cosf(self.yaw)});
    } else {
        vector_float3 toOrb = self.orbPosition - eye;
        if (simd_length_squared(toOrb) < 1e-5f) {
            toOrb = (vector_float3){0.0f, 0.0f, 1.0f};
        }
        forward = simd_normalize(toOrb);
        self.yaw = atan2f(forward.x, forward.z);
    }

    vector_float3 upAxis = (vector_float3){0.0f, 1.0f, 0.0f};
    vector_float3 right = simd_normalize(simd_cross(upAxis, forward));
    vector_float3 up = simd_normalize(simd_cross(forward, right));

    float aspect = (view.drawableSize.height > 0.0) ? (float)(view.drawableSize.width / view.drawableSize.height) : 1.0f;
    vector_float3 entityPos = self.orbPosition;

    MazeUniforms uniforms;
    uniforms.cameraPosition = (simd_float4){eye.x, eye.y, eye.z, self.time};
    uniforms.cameraForward = (simd_float4){forward.x, forward.y, forward.z, 0.0f};
    uniforms.cameraRight = (simd_float4){right.x, right.y, right.z, aspect};
    uniforms.cameraUp = (simd_float4){up.x, up.y, up.z, 0.0f};
    uniforms.entityPosition = (simd_float4){entityPos.x, entityPos.y, entityPos.z, self.orbRadius};
    uniforms.seed = (simd_float4){ self.mazeSeed.x, self.mazeSeed.y, 0.0f, 0.0f };

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)updateSimulationWithDelta:(float)deltaTime {
    [self updateOrbWithDelta:deltaTime];

    if (!self.manualControlActive) {
        vector_float3 dir = self.orbVelocity;
        if (simd_length_squared(dir) > 1e-6f) {
            dir = simd_normalize(dir);
            self.yaw = atan2f(dir.x, dir.z);
        } else {
            dir = simd_normalize((vector_float3){sinf(self.yaw), 0.0f, cosf(self.yaw)});
        }

        float eyeHeight = self.eyeBaseHeight + 0.45f;
        const float distances[] = {3.4f, 2.8f, 2.2f, 1.6f, 1.2f};
        vector_float3 desired = self.orbPosition;
        desired.y = eyeHeight;
        for (int i = 0; i < (int)(sizeof(distances) / sizeof(distances[0])); ++i) {
            vector_float3 candidate = self.orbPosition - dir * distances[i];
            candidate.y = eyeHeight;
            if (MazeDistance(candidate) > 0.28f) {
                desired = candidate;
                break;
            }
        }

        if (MazeDistance(desired) <= 0.2f) {
            vector_int2 orbCell = MazeCellForPosition(self.orbPosition);
            desired = MazeCenterForCell(orbCell, eyeHeight);
        }

        self.playerPosition = desired;
        return;
    }

    const float turnSpeed = 1.7f;
    if (self.turnLeft) {
        self.yaw += turnSpeed * deltaTime;
    }
    if (self.turnRight) {
        self.yaw -= turnSpeed * deltaTime;
    }

    vector_float3 forward = (vector_float3){sinf(self.yaw), 0.0f, cosf(self.yaw)};
    vector_float3 right = (vector_float3){forward.z, 0.0f, -forward.x};

    vector_float3 velocity = (vector_float3){0.0f, 0.0f, 0.0f};
    if (self.moveForward) {
        velocity += forward;
    }
    if (self.moveBackward) {
        velocity -= forward;
    }
    if (self.strafeRight) {
        velocity += right;
    }
    if (self.strafeLeft) {
        velocity -= right;
    }

    if (simd_length_squared(velocity) > 0.0001f) {
        velocity = simd_normalize(velocity);
        const float moveSpeed = 5.5f;
        vector_float3 step = velocity * (moveSpeed * deltaTime);

        vector_float3 next = self.playerPosition;
        // sample capsule around player center for simple collision padding
        const float pad = 0.22f;
        vector_float3 tryX = next; tryX.x += step.x; tryX.y = self.eyeBaseHeight;
        if (MazeDistance(tryX) > pad) next.x = tryX.x;

        vector_float3 tryZ = next; tryZ.z += step.z; tryZ.y = self.eyeBaseHeight;
        if (MazeDistance(tryZ) > pad) next.z = tryZ.z;

        next.y = self.eyeBaseHeight;
        self.playerPosition = next;
    } else {
        vector_float3 reset = self.playerPosition;
        reset.y = self.eyeBaseHeight;
        self.playerPosition = reset;
    }
}

- (void)updateOrbWithDelta:(float)deltaTime {
    float height = self.eyeBaseHeight + 0.2f;
    vector_float3 position = self.orbPosition;
    position.y = height;
    self.orbPosition = position;

    vector_float3 toTarget = self.orbTargetPosition - self.orbPosition;
    float distance = simd_length(toTarget);

    if (distance < 0.001f) {
        self.orbPosition = self.orbTargetPosition;
        self.orbVelocity = (vector_float3){0.0f, 0.0f, 0.0f};
        vector_int2 previousCell = self.orbCell;
        self.orbCell = self.orbTargetCell;
        self.orbPreviousCell = previousCell;
        [self chooseNewOrbDirection];
        return;
    }

    vector_float3 direction = toTarget / distance;
    float step = self.orbSpeed * deltaTime;
    if (step >= distance) {
        self.orbPosition = self.orbTargetPosition;
        self.orbVelocity = direction * self.orbSpeed;
        vector_int2 previousCell = self.orbCell;
        self.orbCell = self.orbTargetCell;
        self.orbPreviousCell = previousCell;
        [self chooseNewOrbDirection];
    } else {
        self.orbPosition += direction * step;
        self.orbVelocity = direction * self.orbSpeed;
    }
}

- (void)chooseNewOrbDirection {
    float height = self.eyeBaseHeight + 0.2f;
    vector_int2 currentCell = MazeCellForPosition(self.orbPosition);
    self.orbCell = currentCell;
    self.orbPosition = MazeCenterForCell(currentCell, height);
    vector_int2 lastCell = self.orbPreviousCell;

    static const vector_int2 offsets[4] = {
        { 1, 0},
        {-1, 0},
        { 0, 1},
        { 0,-1}
    };

    vector_int2 candidates[4];
    int candidateCount = 0;
    vector_int2 fallback[4];
    int fallbackCount = 0;

    for (int i = 0; i < 4; ++i) {
        vector_int2 neighbor = (vector_int2){currentCell.x + offsets[i].x, currentCell.y + offsets[i].y};
        if (!MazeCellsConnected(currentCell, neighbor)) {
            continue;
        }

        if (neighbor.x == lastCell.x && neighbor.y == lastCell.y) {
            fallback[fallbackCount++] = neighbor;
            continue;
        }

        candidates[candidateCount++] = neighbor;
    }

    vector_int2 chosenCell;
    if (candidateCount > 0) {
        uint32_t idx = (candidateCount == 1) ? 0 : arc4random_uniform((uint32_t)candidateCount);
        chosenCell = candidates[idx];
    } else if (fallbackCount > 0) {
        uint32_t idx = (fallbackCount == 1) ? 0 : arc4random_uniform((uint32_t)fallbackCount);
        chosenCell = fallback[idx];
    } else {
        self.orbTargetCell = currentCell;
        self.orbTargetPosition = MazeCenterForCell(currentCell, height);
        self.orbVelocity = (vector_float3){0.0f, 0.0f, 0.0f};
        return;
    }

    self.orbTargetCell = chosenCell;
    self.orbTargetPosition = MazeCenterForCell(chosenCell, height);

    vector_float3 delta = self.orbTargetPosition - self.orbPosition;
    float distance = simd_length(delta);
    if (distance < 1e-4f) {
        self.orbVelocity = (vector_float3){0.0f, 0.0f, 0.0f};
    } else {
        vector_float3 dir = delta / distance;
        self.orbVelocity = dir * self.orbSpeed;
    }

    self.orbPreviousCell = currentCell;
}

- (BOOL)handleKeyEventWithCode:(unsigned short)keyCode pressed:(BOOL)isPressed {
    if (isPressed) {
        self.manualControlActive = YES;
    }
    switch (keyCode) {
        case 126: // Arrow Up
        case 13:  // W
            self.moveForward = isPressed;
            return YES;
        case 125: // Arrow Down
        case 1:   // S
            self.moveBackward = isPressed;
            return YES;
        case 123: // Arrow Left
            self.turnLeft = isPressed;
            return YES;
        case 124: // Arrow Right
            self.turnRight = isPressed;
            return YES;
        case 0:   // A
            self.strafeLeft = isPressed;
            return YES;
        case 2:   // D
            self.strafeRight = isPressed;
            return YES;
        default:
            return NO;
    }
}

- (void)activateManualControl {
    self.manualControlActive = YES;
    vector_float3 dir;
    if (simd_length_squared(self.orbVelocity) > 1e-6f) {
        dir = simd_normalize(self.orbVelocity);
        self.yaw = atan2f(dir.x, dir.z);
    } else {
        dir = simd_normalize((vector_float3){sinf(self.yaw), 0.0f, cosf(self.yaw)});
    }

    vector_float3 starting = self.orbPosition - dir * 0.6f;
    starting.y = self.eyeBaseHeight;
    if (MazeDistance(starting) <= 0.18f) {
        vector_int2 cell = MazeCellForPosition(self.orbPosition);
        starting = MazeCenterForCell(cell, self.eyeBaseHeight);
    }
    self.playerPosition = starting;
}

@end
