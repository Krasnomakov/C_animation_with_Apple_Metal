#import "MetalMazeRenderer.h"
#import <simd/simd.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#import <stdlib.h>
#import <stdint.h>
#include <unordered_set>
#include <vector>
#include <algorithm>

static vector_float2 gMazeSeed = {0.0f, 0.0f};

static const float kCellSize = 14.0f;
static const float kWallThickness = 1.2f;
static const float kHalfHeight = 3.5f;

static inline float MazeHash21(vector_float2 p) {
    vector_float2 v = p * (vector_float2){123.34f, 345.45f} + gMazeSeed * 37.0f;
    vector_float2 fr = (vector_float2){v.x - floorf(v.x), v.y - floorf(v.y)};
    float d = simd_dot(fr, fr + (vector_float2){34.345f, 34.345f});
    fr += d;
    return fr.x * fr.y - floorf(fr.x * fr.y);
}

static inline BOOL MazeHasWallX(int cx, int cz) {
    vector_float2 pA = (vector_float2){(float)cx, (float)cz};
    float rA = MazeHash21(pA);
    vector_float2 pB = (vector_float2){(float)(cx + 1), (float)cz};
    float rB = MazeHash21(pB);
    BOOL openA = (rA < 0.35f);
    BOOL openB = (rB < 0.35f);
    if (openA && openB) return NO;
    vector_float2 pE = (vector_float2){(float)cx + 0.5f, (float)cz};
    float rE = MazeHash21(pE * 1.9f);
    return rE > 0.22f;
}

static inline BOOL MazeHasWallZ(int cx, int cz) {
    vector_float2 pA = (vector_float2){(float)cx, (float)cz};
    float rA = MazeHash21(pA);
    vector_float2 pB = (vector_float2){(float)cx, (float)(cz + 1)};
    float rB = MazeHash21(pB);
    BOOL openA = (rA >= 0.35f && rA < 0.70f) || (rA >= 0.70f);
    BOOL openB = (rB >= 0.35f && rB < 0.70f) || (rB >= 0.70f);
    if (openA && openB) return NO;
    vector_float2 pE = (vector_float2){(float)cx, (float)cz + 0.5f};
    float rE = MazeHash21(pE * 2.3f);
    return rE > 0.22f;
}

static inline float sdBox(vector_float3 p, vector_float3 b) {
    vector_float3 q = (vector_float3){fabsf(p.x) - b.x, fabsf(p.y) - b.y, fabsf(p.z) - b.z};
    vector_float3 maxQ = (vector_float3){fmaxf(q.x, 0.0f), fmaxf(q.y, 0.0f), fmaxf(q.z, 0.0f)};
    float outside = simd_length(maxQ);
    float inside = fminf(fmaxf(q.x, fmaxf(q.y, q.z)), 0.0f);
    return outside + inside;
}

static inline float GetCellExpansion(vector_float2 xz, float time) {
    float s1 = sinf(xz.x * 0.016f + time * 0.08f);
    float s2 = cosf(xz.y * 0.016f - time * 0.06f);
    float factor = s1 * s2 * 0.5f + 0.5f;
    return 1.0f + 0.85f * factor;
}

static inline float GetLoopElevation(float x, float z, float time) {
    float zone = sinf(x * 0.020f + time * 0.09f) * cosf(z * 0.020f - time * 0.07f) * 0.5f + 0.5f;
    float loopWeight = fminf(fmaxf((zone - 0.30f) / 0.45f, 0.0f), 1.0f);
    loopWeight = loopWeight * loopWeight * (3.0f - 2.0f * loopWeight);

    float loopRadius = 32.0f;
    float archZ = (1.0f - cosf(z / loopRadius)) * loopRadius;
    float archX = (1.0f - cosf(x / loopRadius)) * loopRadius;
    float totalLoop = (archZ + archX) * 0.5f * loopWeight * 1.8f;

    float elev = (sinf(x * 0.035f + time * 0.15f) + cosf(z * 0.035f - time * 0.12f)) * 2.0f;
    return totalLoop + elev * (1.0f - loopWeight * 0.5f);
}

static inline vector_float3 WarpInceptionLoops(vector_float3 p, float time) {
    float elev = GetLoopElevation(p.x, p.z, time);
    p.y -= elev;
    return p;
}

#define MAX_HOLES 20
#define MAX_GPU_VOXELS 128
#define TOTAL_CPU_VOXELS 256
#define TRAIL_CAPACITY 20

struct VoxelParticle {
    vector_float3 position;
    vector_float3 velocity;
    vector_float3 color;
    float size;
    float age;
};

struct GPUShaderVoxel {
    simd_float4 positionAndSize; // xyz = pos, w = size
    simd_float4 color;           // rgb = color, w = age
};

static std::vector<vector_float3> gHoleCenters;
static float gCurrentSimulationTime = 0.0f;

static float MazeDistance(vector_float3 rawP) {
    float scale = GetCellExpansion((vector_float2){rawP.x, rawP.z}, gCurrentSimulationTime);
    vector_float3 p = WarpInceptionLoops(rawP, gCurrentSimulationTime) / scale;

    int cx = (int)floorf(p.x / kCellSize);
    int cz = (int)floorf(p.z / kCellSize);
    float cellCenterX = ((float)cx + 0.5f) * kCellSize;
    float cellCenterZ = ((float)cz + 0.5f) * kCellSize;
    vector_float2 local = (vector_float2){ p.x - cellCenterX, p.z - cellCenterZ };

    float minD = 1e5f;

    // 4 Walls
    if (MazeHasWallX(cx, cz)) {
        vector_float3 q = (vector_float3){local.x - kCellSize * 0.5f, p.y, local.y};
        minD = fminf(minD, sdBox(q, (vector_float3){kWallThickness * 0.5f, kHalfHeight, kCellSize * 0.5f}));
    }
    if (MazeHasWallX(cx - 1, cz)) {
        vector_float3 q = (vector_float3){local.x + kCellSize * 0.5f, p.y, local.y};
        minD = fminf(minD, sdBox(q, (vector_float3){kWallThickness * 0.5f, kHalfHeight, kCellSize * 0.5f}));
    }
    if (MazeHasWallZ(cx, cz)) {
        vector_float3 q = (vector_float3){local.x, p.y, local.y - kCellSize * 0.5f};
        minD = fminf(minD, sdBox(q, (vector_float3){kCellSize * 0.5f, kHalfHeight, kWallThickness * 0.5f}));
    }
    if (MazeHasWallZ(cx, cz - 1)) {
        vector_float3 q = (vector_float3){local.x, p.y, local.y + kCellSize * 0.5f};
        minD = fminf(minD, sdBox(q, (vector_float3){kCellSize * 0.5f, kHalfHeight, kWallThickness * 0.5f}));
    }

    // Corner Pillars
    vector_float3 pCorner = (vector_float3){fabsf(local.x) - kCellSize * 0.5f, p.y, fabsf(local.y) - kCellSize * 0.5f};
    minD = fminf(minD, sdBox(pCorner, (vector_float3){kWallThickness * 0.6f, kHalfHeight, kWallThickness * 0.6f}));

    float dFloor = p.y + kHalfHeight;
    float dCeil = kHalfHeight - p.y;
    return fminf(minD, fminf(dFloor, dCeil)) * scale;
}

static vector_float3 MazeNormal(vector_float3 p) {
    const float eps = 0.005f;
    float d = MazeDistance(p);
    float dx = MazeDistance((vector_float3){p.x + eps, p.y, p.z}) - d;
    float dy = MazeDistance((vector_float3){p.x, p.y + eps, p.z}) - d;
    float dz = MazeDistance((vector_float3){p.x, p.y, p.z + eps}) - d;
    vector_float3 n = (vector_float3){dx, dy, dz};
    float len = simd_length(n);
    if (len < 1e-5f) return (vector_float3){0.0f, 1.0f, 0.0f};
    return n / len;
}

typedef struct {
    simd_float4 cameraPosition; // xyz = eye, w = time
    simd_float4 cameraForward;  // xyz = forward, w = glitch flash
    simd_float4 cameraRight;    // xyz = right, w = aspect ratio
    simd_float4 cameraUp;       // xyz = up, w = unused
    simd_float4 entityPosition; // xyz = orb position, w = orb radius
    simd_float4 seed;           // xy = seed, z = numVoxels, w = numHoles
    simd_float4 orbVelocity;    // xyz = velocity, w = trail count
    simd_float4 orbTrail[TRAIL_CAPACITY];
    simd_float4 destroyedBricks[MAX_HOLES];
} MazeUniforms;

@interface MetalMazeRenderer () {
    vector_float3 _trailHistory[TRAIL_CAPACITY];
    std::vector<VoxelParticle> _cpuVoxels;
    id<MTLBuffer> _voxelBuffer;
}
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, assign) float time;
@property (nonatomic, assign) vector_float3 playerPosition;
@property (nonatomic, assign) float yaw;
@property (nonatomic, assign) float pitch;
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
@property (nonatomic, assign) float orbRadius;
@property (nonatomic, assign) BOOL manualControlActive;
@property (nonatomic, assign) vector_float2 mazeSeed;
@property (nonatomic, assign) int trailCount;
@property (nonatomic, assign) vector_float3 lastRecordedPos;
@property (nonatomic, assign) float glitchFlashTimer;

- (void)updateOrbWithDelta:(float)deltaTime;
- (void)recordOrbTrailPosition:(vector_float3)pos;
- (void)destroyBrickAt:(vector_float3)impactPos withVel:(vector_float3)vel;
@end

@implementation MetalMazeRenderer

- (instancetype)initWithMetalKitView:(MTKView *)view {
    self = [super init];
    if (self) {
        _device = view.device;
        _commandQueue = [_device newCommandQueue];
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        view.clearColor = MTLClearColorMake(0.01, 0.01, 0.03, 1.0);
        view.framebufferOnly = NO;
        view.preferredFramesPerSecond = 60;
        view.enableSetNeedsDisplay = NO;
        view.paused = NO;
        view.layer.contentsScale = 1.0;

        _voxelBuffer = [_device newBufferWithLength:sizeof(GPUShaderVoxel) * MAX_GPU_VOXELS
                                            options:MTLResourceStorageModeShared];

        _time = 0.0f;
        _eyeBaseHeight = 1.0f;
        _orbRadius = 0.60f;
        float initElev = GetLoopElevation(7.0f, 7.0f, 0.0f);
        _orbPosition = (vector_float3){7.0f, initElev, 7.0f};
        _orbVelocity = (vector_float3){7.2f, 0.0f, 4.8f};
        _playerPosition = (vector_float3){7.0f, initElev + 1.2f, 1.5f};
        _yaw = 0.0f;
        _pitch = 0.0f;
        _lastFrameTimestamp = 0.0;
        _manualControlActive = NO;
        _trailCount = 0;
        _lastRecordedPos = _orbPosition;
        _glitchFlashTimer = 0.0f;

        gHoleCenters.clear();
        _cpuVoxels.clear();

        _mazeSeed = (vector_float2){ (float)arc4random_uniform(10000) / 10000.0f,
                                     (float)arc4random_uniform(10000) / 10000.0f };
        gMazeSeed = _mazeSeed;

        [self recordOrbTrailPosition:_orbPosition];

        static const char *kMazeShader = R"METAL(
#include <metal_stdlib>
using namespace metal;

#define MAX_HOLES 20
#define TRAIL_CAPACITY 20

struct Uniforms {
    float4 cameraPosition;
    float4 cameraForward;
    float4 cameraRight;
    float4 cameraUp;
    float4 entityPosition;
    float4 seed;
    float4 orbVelocity;
    float4 orbTrail[TRAIL_CAPACITY];
    float4 destroyedBricks[MAX_HOLES];
};

struct GPUShaderVoxel {
    float4 positionAndSize; // xyz = pos, w = size
    float4 color;           // rgb = color, w = age
};

float hash21_seed(float2 p, float2 s) {
    float2 v = p * float2(123.34, 345.45) + s * 37.0;
    float2 fr = fract(v);
    float d = dot(fr, fr + float2(34.345, 34.345));
    fr += d;
    return fract(fr.x * fr.y);
}

float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdSegment(float3 p, float3 a, float3 b) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h);
}

float getCellExpansion(float2 xz, float time) {
    float s1 = sin(xz.x * 0.016 + time * 0.08);
    float s2 = cos(xz.y * 0.016 - time * 0.06);
    float factor = s1 * s2 * 0.5 + 0.5;
    return 1.0 + 0.85 * factor;
}

float getLoopElevation(float2 xz, float time) {
    float zone = sin(xz.x * 0.020 + time * 0.09) * cos(xz.y * 0.020 - time * 0.07) * 0.5 + 0.5;
    float loopWeight = smoothstep(0.30, 0.75, zone);

    float loopRadius = 32.0;
    float archZ = (1.0 - cos(xz.y / loopRadius)) * loopRadius;
    float archX = (1.0 - cos(xz.x / loopRadius)) * loopRadius;
    float totalLoop = (archZ + archX) * 0.5 * loopWeight * 1.8;

    float elev = (sin(xz.x * 0.035 + time * 0.15) + cos(xz.y * 0.035 - time * 0.12)) * 2.0;
    return totalLoop + elev * (1.0 - loopWeight * 0.5);
}

float3 warpInceptionLoops(float3 p, float time) {
    float elev = getLoopElevation(p.xz, time);
    p.y -= elev;
    return p;
}

bool hasWallX(int cx, int cz, float2 seed) {
    float2 pA = float2(float(cx), float(cz));
    float rA = hash21_seed(pA, seed);
    float2 pB = float2(float(cx + 1), float(cz));
    float rB = hash21_seed(pB, seed);
    bool openA = (rA < 0.35);
    bool openB = (rB < 0.35);
    if (openA && openB) return false;
    float2 pE = float2(float(cx) + 0.5, float(cz));
    float rE = hash21_seed(pE, seed * 1.9);
    return rE > 0.22;
}

bool hasWallZ(int cx, int cz, float2 seed) {
    float2 pA = float2(float(cx), float(cz));
    float rA = hash21_seed(pA, seed);
    float2 pB = float2(float(cx), float(cz + 1));
    float rB = hash21_seed(pB, seed);
    bool openA = (rA >= 0.35 && rA < 0.70) || (rA >= 0.70);
    bool openB = (rB >= 0.35 && rB < 0.70) || (rB >= 0.70);
    if (openA && openB) return false;
    float2 pE = float2(float(cx), float(cz) + 0.5);
    float rE = hash21_seed(pE, seed * 2.3);
    return rE > 0.22;
}

float mapMazeFast(float3 rawP, constant Uniforms &u) {
    float time = u.cameraPosition.w;
    float scale = getCellExpansion(rawP.xz, time);
    float3 p = warpInceptionLoops(rawP, time) / scale;

    const float kCellSize = 14.0;
    const float kW = 1.2;
    const float kH = 3.5;

    int cx = int(floor(p.x / kCellSize));
    int cz = int(floor(p.z / kCellSize));
    float cellCenterX = (float(cx) + 0.5) * kCellSize;
    float cellCenterZ = (float(cz) + 0.5) * kCellSize;
    float2 local = p.xz - float2(cellCenterX, cellCenterZ);

    float minD = 1e5;

    // 4 Walls
    if (hasWallX(cx, cz, u.seed.xy)) {
        float3 q = float3(local.x - kCellSize * 0.5, p.y, local.y);
        minD = min(minD, sdBox(q, float3(kW * 0.5, kH, kCellSize * 0.5)));
    }
    if (hasWallX(cx - 1, cz, u.seed.xy)) {
        float3 q = float3(local.x + kCellSize * 0.5, p.y, local.y);
        minD = min(minD, sdBox(q, float3(kW * 0.5, kH, kCellSize * 0.5)));
    }
    if (hasWallZ(cx, cz, u.seed.xy)) {
        float3 q = float3(local.x, p.y, local.y - kCellSize * 0.5);
        minD = min(minD, sdBox(q, float3(kCellSize * 0.5, kH, kW * 0.5)));
    }
    if (hasWallZ(cx, cz - 1, u.seed.xy)) {
        float3 q = float3(local.x, p.y, local.y + kCellSize * 0.5);
        minD = min(minD, sdBox(q, float3(kCellSize * 0.5, kH, kW * 0.5)));
    }

    // Corner Pillars
    float3 pCorner = float3(abs(local.x) - kCellSize * 0.5, p.y, abs(local.y) - kCellSize * 0.5);
    minD = min(minD, sdBox(pCorner, float3(kW * 0.6, kH, kW * 0.6)));

    // Holes
    int numHoles = min(int(u.seed.w), MAX_HOLES);
    for (int i = 0; i < numHoles; ++i) {
        float hScale = getCellExpansion(u.destroyedBricks[i].xz, time);
        float3 wHole = warpInceptionLoops(u.destroyedBricks[i].xyz, time) / hScale;
        float dHole = sdBox(p - wHole, float3(kW * 1.3, 1.8, 2.6));
        minD = max(minD, -dHole);
    }

    float dFloor = p.y + kH;
    float dCeil = kH - p.y;
    return min(minD, min(dFloor, dCeil)) * scale;
}

float mapScene(float3 p, constant Uniforms &u, thread int &matId) {
    float dMaze = mapMazeFast(p, u);
    float dOrb = length(p - u.entityPosition.xyz) - u.entityPosition.w;

    if (dOrb < dMaze) {
        matId = 2; // Orb
        return dOrb;
    }
    matId = 1; // Maze
    return dMaze;
}

float traceScene(float3 ro, float3 rd, constant Uniforms &u, thread int &matId) {
    float dist = 0.22;
    matId = 0;

    // If camera ray origin touches or enters geometry, skip past interior to open space
    for (int k = 0; k < 6; ++k) {
        float3 pos = ro + rd * dist;
        int tmpM;
        float d = mapScene(pos, u, tmpM);
        if (d <= 0.005) {
            dist += max(-d + 0.15, 0.22);
        } else {
            break;
        }
    }

    for (int i = 0; i < 48; ++i) {
        float3 pos = ro + rd * dist;
        int currentMat;
        float d = mapScene(pos, u, currentMat);

        if (d < 0.005) {
            matId = currentMat;
            return dist;
        }
        dist += d;
        if (dist > 260.0) break;
    }
    return 1e6;
}

float3 calcNormal(float3 p, constant Uniforms &u) {
    const float eps = 0.006;
    int tmpM;
    float d = mapScene(p, u, tmpM);
    float3 n = float3(
        mapScene(p + float3(eps, 0.0, 0.0), u, tmpM) - d,
        mapScene(p + float3(0.0, eps, 0.0), u, tmpM) - d,
        mapScene(p + float3(0.0, 0.0, eps), u, tmpM) - d
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

fragment float4 fragment_main(VSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               constant GPUShaderVoxel *voxels [[buffer(1)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    float aspect = u.cameraRight.w;
    uv.x *= aspect;

    float pixelGrid = 200.0;
    float2 pixelUV = floor(uv * pixelGrid) / pixelGrid;

    float time = u.cameraPosition.w;
    float glitchFlash = u.cameraForward.w;
    float glitchTrigger = sin(time * 8.0) * cos(time * 5.3);
    if (glitchTrigger > 0.93 || glitchFlash > 0.05) {
        pixelUV.x += sin(pixelUV.y * 40.0 + time * 25.0) * (0.02 + glitchFlash * 0.04);
    }

    float3 ro = u.cameraPosition.xyz;
    float3 forward = normalize(u.cameraForward.xyz);
    float3 right = normalize(u.cameraRight.xyz);
    float3 up = normalize(u.cameraUp.xyz);
    float3 rd = normalize(forward + pixelUV.x * right + pixelUV.y * up);

    int matId = 0;
    float travel = traceScene(ro, rd, u, matId);

    // Curved Horizon Sky
    float3 skyBase = mix(float3(0.01, 0.02, 0.06), float3(0.06, 0.10, 0.22), clamp(in.uv.y * 0.5 + 0.5, 0.0, 1.0));
    float skyGrid = pow(abs(sin(rd.x * 12.0 + rd.y * 6.0) * sin(rd.z * 12.0)), 8.0) * 0.3;
    float3 sky = skyBase + float3(0.15, 0.45, 0.9) * skyGrid;

    // Void trail glow
    float trailGlow = 0.0;
    int trailCount = int(u.orbVelocity.w);
    int activeSegments = min(trailCount - 1, 16);
    float3 hitPoint = (travel < 1e6) ? (ro + rd * travel) : (ro + rd * 50.0);

    for (int i = 0; i < activeSegments; ++i) {
        float4 ptA = u.orbTrail[i];
        float4 ptB = u.orbTrail[i + 1];
        if (ptA.w <= 0.01 || ptB.w <= 0.01) continue;

        float age = ptA.w;
        float3 posA = ptA.xyz + float3(
            sin(ptA.z * 0.8 + time * 4.0),
            cos(ptA.x * 0.8 + time * 3.5),
            sin(ptA.y * 1.2 + time * 5.0)
        ) * 0.15 * (1.0 - age);

        float dSeg = sdSegment(hitPoint, posA, ptB.xyz);
        trailGlow += exp(-dSeg * 0.8) * (0.35 + 0.65 * age);

        float3 mid = ro + rd * min(travel * 0.5, 12.0);
        float dMid = sdSegment(mid, posA, ptB.xyz);
        trailGlow += exp(-dMid * 1.3) * 0.25 * age;
    }

    float3 color = (travel >= 1e6) ? sky : float3(0.0);
    float3 lightDir = normalize(float3(0.4, 0.85, -0.35));

    if (travel < 1e6) {
        float3 hit = ro + rd * travel;
        float3 normal = calcNormal(hit, u);
        float diff = max(dot(normal, lightDir), 0.18);
        float3 viewDir = normalize(-rd);
        float3 halfVec = normalize(lightDir + viewDir);
        float spec = pow(max(dot(normal, halfVec), 0.0), 20.0);

        if (matId == 2) {
            // Glowing Orb Core
            float sparkle = pow(max(dot(normal, halfVec), 0.0), 24.0);
            float pulse = 0.9 + 0.1 * sin(time * 6.0);
            float3 orbCore = float3(0.2, 0.9, 1.3) * pulse;
            float3 orbRim = float3(1.0, 0.3, 0.9) * pow(1.0 - max(dot(normal, viewDir), 0.0), 2.5);
            color = orbCore * (0.5 + 0.5 * diff) + orbRim + sparkle * 0.95;
        } else {
            // Warped Inception Maze Walls
            float scale = getCellExpansion(hit.xz, time);
            float3 wHit = warpInceptionLoops(hit, time) / scale;
            const float kCellSize = 14.0;
            float2 cell = floor(wHit.xz / kCellSize);
            float cellTone = hash21_seed(cell, u.seed.xy);

            bool isFloor = (wHit.y < -3.4);
            bool isCeiling = (wHit.y > 3.4);

            float3 baseWall;
            if (isFloor) {
                baseWall = float3(0.06, 0.08, 0.14);
            } else if (isCeiling) {
                baseWall = float3(0.04, 0.05, 0.10);
            } else {
                baseWall = mix(float3(0.12, 0.18, 0.30), float3(0.30, 0.15, 0.38), cellTone);
            }

            // Smooth random straight-to-curvy modulation
            float tSlow = time * 0.32;
            float hA = sin(tSlow);
            float hB = sin(tSlow * 1.618 + 2.1);
            float hC = cos(tSlow * 0.618 + 4.3);
            float rawCurve = hA * 0.5 + hB * 0.3 + hC * 0.2;
            float curviness = smoothstep(-0.35, 0.65, rawCurve);

            float waveAmp = curviness * 0.42;
            float wavePhase = time * 3.5;
            float waveX = sin(wHit.y * 2.2 + wHit.z * 1.2 + wavePhase) * waveAmp;
            float waveY = cos(wHit.x * 2.0 + wHit.z * 2.0 + wavePhase * 1.2) * waveAmp;
            float waveZ = sin(wHit.x * 1.2 + wHit.y * 2.2 + wavePhase * 0.8) * waveAmp;

            float gridX = abs(fract((wHit.x + waveX) * 0.5) - 0.5);
            float gridY = abs(fract((wHit.y + waveY) * 0.5) - 0.5);
            float gridZ = abs(fract((wHit.z + waveZ) * 0.5) - 0.5);
            float lineGrid = step(0.44, max(gridX, max(gridY, gridZ)));

            float arcPulse = pow(abs(sin((wHit.x + wHit.z) * 1.5 - time * 5.0)), 6.0) * (0.3 + 0.7 * curviness);
            float3 electricColor = mix(float3(0.0, 0.95, 1.0), float3(0.95, 0.1, 1.0), sin(time * 2.5 + cellTone * 6.0) * 0.5 + 0.5);
            float3 gridGlow = electricColor * (lineGrid * 0.45 + lineGrid * arcPulse * 1.3);

            float ao = clamp(1.0 - travel * 0.005, 0.3, 1.0);
            color = baseWall * (0.35 + 0.65 * diff) * ao + gridGlow + spec * 0.35;
        }

        float fog = clamp(travel / 220.0, 0.0, 1.0);
        color = mix(color, sky, fog);
    }

    // Dense Micro-Voxel Ray-AABB Screen Test (Unified Memory Buffer Stream)
    int numVoxels = int(u.seed.z);
    for (int i = 0; i < numVoxels; ++i) {
        float4 vPos = voxels[i].positionAndSize;
        if (vPos.w <= 0.005) continue;

        float hSize = vPos.w * 0.5;
        float3 bMin = vPos.xyz - float3(hSize);
        float3 bMax = vPos.xyz + float3(hSize);

        float3 invD = 1.0 / (rd + sign(rd) * 1e-6);
        float3 t0 = (bMin - ro) * invD;
        float3 t1 = (bMax - ro) * invD;
        float3 tNear3 = min(t0, t1);
        float3 tFar3 = max(t0, t1);
        float tNear = max(max(tNear3.x, tNear3.y), tNear3.z);
        float tFar = min(min(tFar3.x, tFar3.y), tFar3.z);

        if (tNear > 0.0 && tNear < tFar && tNear < travel) {
            float3 pHit = ro + rd * tNear;
            float3 lHit = pHit - vPos.xyz;
            float3 aHit = abs(lHit);

            float3 cNorm = float3(0.0);
            if (aHit.x > aHit.y && aHit.x > aHit.z) cNorm.x = sign(lHit.x);
            else if (aHit.y > aHit.z) cNorm.y = sign(lHit.y);
            else cNorm.z = sign(lHit.z);

            float cDiff = max(dot(cNorm, lightDir), 0.25);
            float3 edgeDist = abs(aHit - hSize);
            float isEdge = step(min(min(edgeDist.x + edgeDist.y, edgeDist.y + edgeDist.z), edgeDist.x + edgeDist.z), 0.035);

            float3 vCol = voxels[i].color.rgb;
            color = vCol * (0.7 + 0.3 * cDiff) + float3(1.0) * isEdge * 0.85;
            travel = tNear;
        }
    }

    // Glowing neon void trail overlay
    float3 trailColor = mix(float3(0.0, 0.95, 1.0), float3(1.0, 0.1, 0.8), sin(time * 2.0) * 0.5 + 0.5);
    color += trailColor * clamp(trailGlow, 0.0, 1.6);

    // Glitch flash shockwave
    if (glitchFlash > 0.02) {
        color += float3(0.2, 0.6, 1.0) * glitchFlash * 1.5;
        color.r *= (1.0 + glitchFlash * 0.8);
    } else if (glitchTrigger > 0.93) {
        color.r *= 1.25;
        color.b *= 0.85;
    }

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

- (void)destroyBrickAt:(vector_float3)impactPos withVel:(vector_float3)vel {
    self.glitchFlashTimer = 0.22f;

    for (size_t i = 0; i < gHoleCenters.size(); ++i) {
        if (simd_distance_squared(impactPos, gHoleCenters[i]) < 3.5f) {
            return;
        }
    }

    gHoleCenters.push_back(impactPos);
    if (gHoleCenters.size() > MAX_HOLES) {
        gHoleCenters.erase(gHoleCenters.begin());
    }

    // Dense shower of 48 small geometric micro-voxels
    const int count = 48;
    for (int i = 0; i < count; ++i) {
        VoxelParticle vp;
        float ox = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 1.2f;
        float oy = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 1.2f;
        float oz = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 1.2f;
        vp.position = impactPos + (vector_float3){ox, oy, oz};

        float vx = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 7.0f;
        float vy = (float)arc4random_uniform(1000) / 1000.0f * 5.5f + 1.5f;
        float vz = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 7.0f;
        vp.velocity = (vector_float3){vx, vy, vz} + vel * 0.25f;

        float rCol = (float)arc4random_uniform(1000) / 1000.0f;
        if (rCol < 0.33f) {
            vp.color = (vector_float3){0.0f, 0.95f, 1.0f}; // Neon Cyan
        } else if (rCol < 0.66f) {
            vp.color = (vector_float3){1.0f, 0.1f, 0.85f}; // Hot Pink
        } else {
            vp.color = (vector_float3){1.0f, 0.75f, 0.1f}; // Amber Gold
        }

        vp.size = 0.10f + (float)arc4random_uniform(1000) / 1000.0f * 0.12f;
        vp.age = 1.0f;

        if (_cpuVoxels.size() < TOTAL_CPU_VOXELS) {
            _cpuVoxels.push_back(vp);
        } else {
            _cpuVoxels[arc4random_uniform((uint32_t)TOTAL_CPU_VOXELS)] = vp;
        }
    }
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

    self.time += delta;
    gCurrentSimulationTime = self.time;
    [self updateSimulationWithDelta:delta];

    if (self.glitchFlashTimer > 0.0f) {
        self.glitchFlashTimer -= delta;
    }

    BOOL moving = self.manualControlActive && (self.moveForward || self.moveBackward || self.strafeLeft || self.strafeRight);
    float bob = moving ? sinf(self.time * 6.0f) * 0.05f : 0.0f;
    vector_float3 eye = self.playerPosition;
    if (self.manualControlActive) {
        eye.y += bob;
    }

    vector_float3 forward;
    if (self.manualControlActive) {
        forward = simd_normalize((vector_float3){
            sinf(self.yaw) * cosf(self.pitch),
            sinf(self.pitch),
            cosf(self.yaw) * cosf(self.pitch)
        });
    } else {
        vector_float3 toOrb = self.orbPosition - eye;
        if (simd_length_squared(toOrb) < 1e-5f) {
            toOrb = (vector_float3){0.0f, 0.0f, 1.0f};
        }
        forward = simd_normalize(toOrb);
        self.yaw = atan2f(forward.x, forward.z);
        self.pitch = asinf(fmaxf(fminf(forward.y, 0.85f), -0.85f));
    }

    vector_float3 upAxis = (vector_float3){0.0f, 1.0f, 0.0f};
    vector_float3 right = simd_normalize(simd_cross(upAxis, forward));
    vector_float3 up = simd_normalize(simd_cross(forward, right));

    float aspect = (view.drawableSize.height > 0.0) ? (float)(view.drawableSize.width / view.drawableSize.height) : 1.0f;

    // CPU Frustum Culling
    GPUShaderVoxel *gpuVoxels = (GPUShaderVoxel *)_voxelBuffer.contents;
    int visibleVoxelCount = 0;

    for (size_t i = 0; i < _cpuVoxels.size() && visibleVoxelCount < MAX_GPU_VOXELS; ++i) {
        if (_cpuVoxels[i].age <= 0.0f) continue;

        vector_float3 toV = _cpuVoxels[i].position - eye;
        float dotFwd = simd_dot(toV, forward);
        if (dotFwd < -1.0f || simd_length_squared(toV) > 1800.0f) {
            continue;
        }

        gpuVoxels[visibleVoxelCount].positionAndSize = (simd_float4){
            _cpuVoxels[i].position.x,
            _cpuVoxels[i].position.y,
            _cpuVoxels[i].position.z,
            _cpuVoxels[i].size * _cpuVoxels[i].age
        };
        gpuVoxels[visibleVoxelCount].color = (simd_float4){
            _cpuVoxels[i].color.x,
            _cpuVoxels[i].color.y,
            _cpuVoxels[i].color.z,
            _cpuVoxels[i].age
        };
        visibleVoxelCount++;
    }

    MazeUniforms uniforms;
    uniforms.cameraPosition = (simd_float4){eye.x, eye.y, eye.z, self.time};
    uniforms.cameraForward = (simd_float4){forward.x, forward.y, forward.z, fmaxf(self.glitchFlashTimer, 0.0f)};
    uniforms.cameraRight = (simd_float4){right.x, right.y, right.z, aspect};
    uniforms.cameraUp = (simd_float4){up.x, up.y, up.z, 0.0f};
    uniforms.entityPosition = (simd_float4){self.orbPosition.x, self.orbPosition.y, self.orbPosition.z, self.orbRadius};
    uniforms.seed = (simd_float4){ self.mazeSeed.x, self.mazeSeed.y, (float)visibleVoxelCount, (float)gHoleCenters.size() };
    uniforms.orbVelocity = (simd_float4){ self.orbVelocity.x, self.orbVelocity.y, self.orbVelocity.z, (float)self.trailCount };

    for (int i = 0; i < TRAIL_CAPACITY; ++i) {
        if (i < self.trailCount) {
            float ageFactor = 1.0f - ((float)i / (float)TRAIL_CAPACITY);
            uniforms.orbTrail[i] = (simd_float4){
                _trailHistory[i].x,
                _trailHistory[i].y,
                _trailHistory[i].z,
                ageFactor
            };
        } else {
            uniforms.orbTrail[i] = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
        }
    }

    for (int i = 0; i < MAX_HOLES; ++i) {
        if (i < (int)gHoleCenters.size()) {
            vector_float3 hc = gHoleCenters[i];
            uniforms.destroyedBricks[i] = (simd_float4){hc.x, hc.y, hc.z, 1.0f};
        } else {
            uniforms.destroyedBricks[i] = (simd_float4){0.0f, 0.0f, 0.0f, 0.0f};
        }
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBuffer:_voxelBuffer offset:0 atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)updateSimulationWithDelta:(float)deltaTime {
    [self updateOrbWithDelta:deltaTime];

    // CPU Voxel Physics
    for (size_t i = 0; i < _cpuVoxels.size(); ++i) {
        if (_cpuVoxels[i].age <= 0.0f) continue;
        _cpuVoxels[i].velocity.y -= 14.0f * deltaTime;
        _cpuVoxels[i].position += _cpuVoxels[i].velocity * deltaTime;

        float floorLevel = GetLoopElevation(_cpuVoxels[i].position.x, _cpuVoxels[i].position.z, self.time) - kHalfHeight + _cpuVoxels[i].size * 0.5f;
        if (_cpuVoxels[i].position.y < floorLevel) {
            _cpuVoxels[i].position.y = floorLevel;
            _cpuVoxels[i].velocity.y = -_cpuVoxels[i].velocity.y * 0.40f;
            _cpuVoxels[i].velocity.x *= 0.85f;
            _cpuVoxels[i].velocity.z *= 0.85f;
        }

        _cpuVoxels[i].age -= deltaTime * 0.20f;
    }

    if (!self.manualControlActive) {
        vector_float3 orbDir = (vector_float3){self.orbVelocity.x, self.orbVelocity.y * 0.35f, self.orbVelocity.z};
        if (simd_length_squared(orbDir) > 1e-4f) {
            orbDir = simd_normalize(orbDir);
        } else {
            orbDir = (vector_float3){0.0f, 0.0f, 1.0f};
        }

        vector_float3 desiredCam = self.orbPosition - orbDir * 6.5f + (vector_float3){0.0f, 1.5f, 0.0f};
        if (MazeDistance(desiredCam) < 0.6f) {
            desiredCam = self.orbPosition - orbDir * 3.0f + (vector_float3){0.0f, 0.8f, 0.0f};
        }

        self.playerPosition += (desiredCam - self.playerPosition) * fminf(deltaTime * 4.0f, 1.0f);
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
        const float moveSpeed = 6.5f;
        vector_float3 step = velocity * (moveSpeed * deltaTime);

        vector_float3 next = self.playerPosition;
        const float pad = 0.4f;
        vector_float3 tryX = next; tryX.x += step.x;
        if (MazeDistance(tryX) > pad) next.x = tryX.x;

        vector_float3 tryZ = next; tryZ.z += step.z;
        if (MazeDistance(tryZ) > pad) next.z = tryZ.z;

        float elev = GetLoopElevation(next.x, next.z, self.time);
        next.y = elev + self.eyeBaseHeight;
        self.playerPosition = next;
    }
}

- (void)updateOrbWithDelta:(float)deltaTime {
    const float targetSpeed = 7.0f;

    if (simd_length_squared(self.orbVelocity) < 1e-4f) {
        float angle = (float)arc4random_uniform(6283) / 1000.0f;
        self.orbVelocity = (vector_float3){cosf(angle) * targetSpeed, 0.0f, sinf(angle) * targetSpeed};
    }

    float elev = GetLoopElevation(self.orbPosition.x, self.orbPosition.z, self.time);
    float targetY = elev + sinf(self.time * 2.2f) * 0.45f;
    vector_float3 vel = self.orbVelocity;
    vel.y += (targetY - self.orbPosition.y) * 4.5f * deltaTime;

    const int subSteps = 4;
    float subDt = deltaTime / (float)subSteps;
    vector_float3 pos = self.orbPosition;

    for (int step = 0; step < subSteps; ++step) {
        pos += vel * subDt;

        float dist = MazeDistance(pos);
        if (dist < self.orbRadius) {
            vector_float3 normal = MazeNormal(pos);
            float overlap = self.orbRadius - dist;
            pos += normal * (overlap + 0.035f);

            // Destroy brick / scatter micro-voxels at impact point
            vector_float3 impactPoint = pos - normal * self.orbRadius;
            [self destroyBrickAt:impactPoint withVel:vel];

            // Elastic Newtonian bounce off wall normal
            vector_float3 refl = simd_reflect(vel, normal);

            // Slight rotational perturbation to prevent infinite 2-wall ping-pong loops
            float randAngle = ((float)arc4random_uniform(1000) / 1000.0f - 0.5f) * 0.30f;
            float cosA = cosf(randAngle);
            float sinA = sinf(randAngle);
            vector_float3 bounceDir = (vector_float3){ refl.x * cosA - refl.z * sinA, refl.y * 0.4f, refl.x * sinA + refl.z * cosA };

            if (simd_length_squared(bounceDir) > 1e-4f) {
                vel = simd_normalize(bounceDir) * targetSpeed;
            } else {
                vel = normal * targetSpeed;
            }
        }
    }

    // Maintain consistent speed
    float currentSpeed = simd_length(vel);
    if (currentSpeed > 0.1f) {
        vel = simd_normalize(vel) * targetSpeed;
    }

    self.orbPosition = pos;
    self.orbVelocity = vel;

    [self recordOrbTrailPosition:pos];
}

- (void)recordOrbTrailPosition:(vector_float3)pos {
    float d = simd_distance(pos, self.lastRecordedPos);
    if (d < 0.15f && self.trailCount > 0) {
        return;
    }
    self.lastRecordedPos = pos;

    if (self.trailCount < TRAIL_CAPACITY) {
        self.trailCount++;
    }
    for (int i = self.trailCount - 1; i > 0; --i) {
        _trailHistory[i] = _trailHistory[i - 1];
    }
    _trailHistory[0] = pos;
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
}

@end
