// fgflow.m: implementation of FGFlowEstimator (see fgflow.h for the contract).
//
// ALGORITHM (all on the GPU, all in one compute encoder per frame):
//   1. Pyramid. Level 0 is the source colour converted to luma AND halved in
//      one pass (2x2 box of BT.601 luma); each further level is a 2x2 box
//      downsample. Stored as R8Unorm. Level 0 is half resolution on purpose:
//      motion at 1 source pixel precision is not needed for interpolation and
//      a full-resolution solve would cost 4x for nothing.
//   2. Coarsest level: exhaustive +-kCoarseRadius search per block.
//   3. Every finer level: seed each block from the 4 nearest PARENT vectors
//      (own parent quadrant + horizontal/vertical/diagonal neighbour, scaled
//      x2) plus zero, keep the best, then greedy 3x3 refinement for a fixed
//      number of iterations. Using the neighbours' vectors as extra seeds is
//      what stops a motion boundary from being smeared by whichever parent
//      block happens to sit under a child.
//   4. Finest level only: parabolic sub-pixel fit on the SAD surface.
//
// BLOCK GEOMETRY: one vector per 4x4 pixels of its level, matched with an
// 8x8 SAD window centred on that 4x4 cell (so neighbouring windows overlap
// by half). At 1080p that is a 240x135 field, one vector per 8x8 SOURCE
// pixels. Chosen because: a window smaller than ~8 px is unreliable on
// game content (flat sky, repeated texture), and a stride equal to the
// window would give blocky seams that the later warp would have to hide.
//
// The reference (previous-frame) 8x8 window is loaded into registers once
// per thread and reused for every candidate, which halves texture reads
// versus re-reading both frames per candidate.
//
// The MSL is an inline string compiled with newLibraryWithSource: because
// the shim is one injected dylib with no bundle resources. There is no
// offline `metal` compiler on this machine (Command Line Tools only:
// `xcrun --find metal` fails), so a runtime compile is the only option
// anyway. Consequence: the stringify macro below collapses newlines, so the
// MSL must not use `//` comments or `#` directives -- use /* */ only.
//
// MEASURED (29 Oct 2026, Apple M4 10-core GPU, Darwin 27, arm64, -O2; by
// Shim/flowbench.m: 300 isolated runs after 40 warm-ups, GPU time from
// GPUStartTime/GPUEndTime, wall = encode+commit+waitUntilCompleted). Two
// complete benchmark runs were taken; where they differed both are shown
// (small GPU workloads move with GPU clock state, run-to-run swing was
// ~20-100% at the small sizes, so do not read the second digit):
//
//     source res   steady GPU median   steady wall median   cold GPU median
//     320x180      0.43 / 0.81 ms       1.02 / 1.41 ms       0.44 / 0.84 ms
//     1280x720     0.95 / 1.29 ms       1.85 / 1.91 ms       0.99 / 1.36 ms
//     1920x1080    1.41 / 1.73 ms       2.31 / 2.29 ms       1.45 / 1.84 ms
//     2560x1440    2.22 / 2.27 ms       3.13 / 3.10 ms       2.37 / 2.43 ms
//     3840x2160    3.18 / 3.18 ms       4.15 / 3.95 ms       3.59 / 3.41 ms
//
// (steady = new frame's pyramid + flow; cold = both pyramids + flow.) The
// 5 ms/pair-at-1080p target is met with margin on an otherwise idle GPU:
// worst observed 1080p p95 was 3.3 ms WALL. NOT measured: any contention
// with a game rendering on the same GPU, which is the real condition.
//
// Findings worth not re-deriving:
//   * The flow solve is >93% of the time; the pyramid build for a 1080p
//     frame is only 0.05-0.09 ms. So the time is in the SAD loops (one
//     thread per vector, ~21 candidates x 64 texels), not in the pyramid
//     or dispatch count. (Inference from the split; no GPU profiler was
//     run, so "texture-read bound" is a guess.) Candidates and window size
//     are what to trim if a budget gets tight.
//   * Wall exceeds GPU by ~0.6-0.9 ms even though an EMPTY command buffer
//     commits+waits in ~0.02 ms. Not diagnosed further (likely GPU
//     wake/launch of real work rather than our CPU encode, UNVERIFIED). It
//     is pipelined away (throughput 1.5 ms/frame at
//     1080p vs 2.3 wall), which is why the shim never waits.
//   * Accuracy on synthetic noise with two known rigid motions (flow
//     compared in source pixels, windows clear of region edges): 1080p
//     background mean EPE 0.41 px, 99.1% within 1 px; foreground mean EPE
//     0.32 px, 95.0% within 1 px. The ~0.9% of background vectors that
//     fail are one coherent patch near x~600-620,y~364-420 whose winning
//     SAD (0.007-0.02) is as low as correct matches get: i.e. a
//     low-texture patch where the data are ambiguous and nothing but the
//     tiny tie-break term constrains the answer. No spatial smoothness /
//     median filter exists yet; that is the obvious next quality step and
//     is NOT tried. 4K mean EPE rose to 1.4 px from a similar ~1.3% of
//     outliers, not from a general loss of precision (98.7% within 1 px).
//   * UNPROVEN: quality on real game footage (motion blur, particles,
//     transparency, HUD, scene cuts), and occlusion handling (the z channel
//     is produced but nothing consumes it).
//   * Runtime MSL compile: 389 ms the very first time on a machine, ~1-2 ms
//     on later runs in the same session (system shader cache), 347 ms again
//     under Rosetta/x86_64. Always create the estimator off the render
//     thread (fgshim.m does).
#import "fgflow.h"

#define FG_MSL(...) #__VA_ARGS__

// Kept in sync with the Params struct in the MSL below.
typedef struct {
    int32_t radius;     // coarsest-level exhaustive search radius, in pixels
    int32_t iters;      // greedy 3x3 refinement iterations per finer level
    float   lambda;     // tie-break weight pulling vectors toward the prediction
    int32_t subpixel;   // 1 on the finest level only
} FGFlowParams;

// Exhaustive radius at the coarsest level. 5 at a 30x17 top level covers
// +-5*32 = +-160 level-0 px (+-320 source px) before any refinement, i.e.
// far beyond any per-frame motion at 60 fps; it is cheap because the
// coarsest grid has only a few dozen vectors.
static const int32_t kCoarseRadius = 5;
// 2 greedy iterations let a level correct its parent's guess by up to +-2
// px per level (cumulatively 2*(1+2+4+..) at level-0 scale).
static const int32_t kRefineIters = 2;
// Tiny (SAD is summed over 64 pixels, luma 0..1) so it only breaks ties --
// flat regions otherwise pick whichever candidate was evaluated first.
static const float kLambda = 0.02f;
// Stop adding pyramid levels once the next one would be smaller than this:
// below ~16 px a level carries no usable structure for an 8x8 window.
static const NSUInteger kMinLevelDim = 16;
static const NSUInteger kMaxLevels = 6;

static NSString *FGFlowSource(void) {
    return [@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:@FG_MSL(
        struct Params { int radius; int iters; float lambda; int subpixel; };

        /* Edge-clamped single luma read. */
        inline float px(texture2d<float, access::read> t, int2 p) {
            int2 m = int2(t.get_width(), t.get_height()) - 1;
            return t.read(uint2(clamp(p, int2(0), m))).r;
        }

        /* Load the 8x8 reference window (previous frame) once into registers. */
        inline void load_ref(texture2d<float, access::read> a, int2 org, thread float *r) {
            for (int y = 0; y < 8; y++) {
                for (int x = 0; x < 8; x++) { r[y * 8 + x] = px(a, org + int2(x, y)); }
            }
        }

        /* SAD of the register window against the current frame displaced by v.
           Interior windows skip the per-texel clamp: it is the hot loop. */
        inline float sad8(texture2d<float, access::read> b, int2 org, int2 v, thread const float *r) {
            int2 o = org + v;
            int2 sz = int2(b.get_width(), b.get_height());
            float s = 0.0f;
            if (all(o >= int2(0)) && all(o + int2(8) <= sz)) {
                for (int y = 0; y < 8; y++) {
                    for (int x = 0; x < 8; x++) {
                        s += abs(r[y * 8 + x] - b.read(uint2(o + int2(x, y))).r);
                    }
                }
            } else {
                for (int y = 0; y < 8; y++) {
                    for (int x = 0; x < 8; x++) { s += abs(r[y * 8 + x] - px(b, o + int2(x, y))); }
                }
            }
            return s;
        }

        /* Pyramid level 0: colour -> BT.601 luma, 2x2 box (so half resolution). */
        kernel void fg_luma_down(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            int2 m = int2(src.get_width(), src.get_height()) - 1;
            int2 s = int2(gid) * 2;
            const float3 k = float3(0.299f, 0.587f, 0.114f);
            float l = dot(src.read(uint2(min(s, m))).rgb, k)
                    + dot(src.read(uint2(min(s + int2(1, 0), m))).rgb, k)
                    + dot(src.read(uint2(min(s + int2(0, 1), m))).rgb, k)
                    + dot(src.read(uint2(min(s + int2(1, 1), m))).rgb, k);
            dst.write(float4(l * 0.25f, 0.0f, 0.0f, 1.0f), gid);
        }

        /* Pyramid level k+1 from level k: 2x2 box. */
        kernel void fg_down(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            int2 m = int2(src.get_width(), src.get_height()) - 1;
            int2 s = int2(gid) * 2;
            float l = src.read(uint2(min(s, m))).r
                    + src.read(uint2(min(s + int2(1, 0), m))).r
                    + src.read(uint2(min(s + int2(0, 1), m))).r
                    + src.read(uint2(min(s + int2(1, 1), m))).r;
            dst.write(float4(l * 0.25f, 0.0f, 0.0f, 1.0f), gid);
        }

        /* Coarsest level: exhaustive search, biased toward zero motion. */
        kernel void fg_flow_coarse(texture2d<float, access::read> A [[texture(0)]],
                                   texture2d<float, access::read> B [[texture(1)]],
                                   texture2d<half, access::write> F [[texture(2)]],
                                   constant Params &P [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= F.get_width() || gid.y >= F.get_height()) { return; }
            int2 org = int2(gid) * 4 - 2;
            float r[64];
            load_ref(A, org, r);
            float bestCost = 1e30f;
            float bestSad = 0.0f;
            int2 bv = int2(0);
            for (int dy = -P.radius; dy <= P.radius; dy++) {
                for (int dx = -P.radius; dx <= P.radius; dx++) {
                    float s = sad8(B, org, int2(dx, dy), r);
                    float c = s + P.lambda * float(abs(dx) + abs(dy));
                    if (c < bestCost) { bestCost = c; bestSad = s; bv = int2(dx, dy); }
                }
            }
            F.write(half4(half(bv.x), half(bv.y), half(bestSad * (1.0f / 64.0f)), half(0)), gid);
        }

        /* Finer levels: seed from the parent's 4 nearest vectors + zero, then
           greedy 3x3 refinement; optional parabolic sub-pixel fit. */
        kernel void fg_flow_refine(texture2d<float, access::read> A [[texture(0)]],
                                   texture2d<float, access::read> B [[texture(1)]],
                                   texture2d<half, access::write> F [[texture(2)]],
                                   texture2d<float, access::read> Fp [[texture(3)]],
                                   constant Params &P [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= F.get_width() || gid.y >= F.get_height()) { return; }
            int2 org = int2(gid) * 4 - 2;
            float r[64];
            load_ref(A, org, r);

            int2 pmax = int2(Fp.get_width(), Fp.get_height()) - 1;
            int2 pg = int2(gid) >> 1;
            int2 off = int2((gid.x & 1u) ? 1 : -1, (gid.y & 1u) ? 1 : -1);
            int2 pc[4];
            pc[0] = clamp(pg, int2(0), pmax);
            pc[1] = clamp(pg + int2(off.x, 0), int2(0), pmax);
            pc[2] = clamp(pg + int2(0, off.y), int2(0), pmax);
            pc[3] = clamp(pg + off, int2(0), pmax);

            /* Vectors double when moving to the next finer level. */
            int2 pred = int2(rint(Fp.read(uint2(pc[0])).xy * 2.0f));
            float bestCost = 1e30f;
            float bestSad = 0.0f;
            int2 bv = pred;
            for (int i = 0; i < 5; i++) {
                int2 c = (i < 4) ? int2(rint(Fp.read(uint2(pc[i])).xy * 2.0f)) : int2(0);
                float s = sad8(B, org, c, r);
                int2 d = abs(c - pred);
                float cost = s + P.lambda * float(d.x + d.y);
                if (cost < bestCost) { bestCost = cost; bestSad = s; bv = c; }
            }

            for (int it = 0; it < P.iters; it++) {
                int2 center = bv;
                for (int k = 0; k < 9; k++) {
                    if (k == 4) { continue; }
                    int2 c = center + int2(k % 3 - 1, k / 3 - 1);
                    float s = sad8(B, org, c, r);
                    int2 d = abs(c - pred);
                    float cost = s + P.lambda * float(d.x + d.y);
                    if (cost < bestCost) { bestCost = cost; bestSad = s; bv = c; }
                }
                if (all(bv == center)) { break; }
            }

            float2 fv = float2(bv);
            if (P.subpixel != 0) {
                float sl = sad8(B, org, bv + int2(-1, 0), r);
                float sr = sad8(B, org, bv + int2(1, 0), r);
                float su = sad8(B, org, bv + int2(0, -1), r);
                float sd = sad8(B, org, bv + int2(0, 1), r);
                float dxn = sl - 2.0f * bestSad + sr;
                float dyn = su - 2.0f * bestSad + sd;
                if (dxn > 1e-5f) { fv.x += clamp(0.5f * (sl - sr) / dxn, -0.5f, 0.5f); }
                if (dyn > 1e-5f) { fv.y += clamp(0.5f * (su - sd) / dyn, -0.5f, 0.5f); }
            }
            F.write(half4(half(fv.x), half(fv.y), half(bestSad * (1.0f / 64.0f)), half(0)), gid);
        }
    )];
}

@implementation FGFlowEstimator {
    id<MTLDevice> _dev;
    /* Private queue: the host's queue is never touched. */
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _psLuma, _psDown, _psCoarse, _psRefine;
    /* Two pyramid slots: one holds the previous frame, the other receives the
       current one, swapping each frame so the previous pyramid is never
       rebuilt. */
    NSArray<id<MTLTexture>> *_pyr[2];
    /* One flow field per level (index 0 = finest). */
    NSArray<id<MTLTexture>> *_flow;
    int _cur;
    BOOL _hasPrev;
}

+ (instancetype)estimatorWithDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h error:(NSString **)err {
    FGFlowEstimator *e = [[FGFlowEstimator alloc] init];
    NSString *msg = [e setupWithDevice:device width:w height:h];
    if (msg) { if (err) *err = msg; return nil; }
    return e;
}

- (NSString *)setupWithDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h {
    if (!device || w < 2 || h < 2) return @"bad device/size";
    _dev = device; _srcWidth = w; _srcHeight = h;
    _queue = [device newCommandQueue];
    if (!_queue) return @"newCommandQueue failed";

    NSError *ne = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:FGFlowSource() options:nil error:&ne];
    if (!lib) return [NSString stringWithFormat:@"MSL compile failed: %@", ne.localizedDescription];
    id<MTLComputePipelineState> __strong *dst[4] = {&_psLuma, &_psDown, &_psCoarse, &_psRefine};
    NSString *names[4] = {@"fg_luma_down", @"fg_down", @"fg_flow_coarse", @"fg_flow_refine"};
    for (int i = 0; i < 4; i++) {
        id<MTLFunction> f = [lib newFunctionWithName:names[i]];
        if (!f) return [NSString stringWithFormat:@"missing kernel %@", names[i]];
        *dst[i] = [device newComputePipelineStateWithFunction:f error:&ne];
        if (!*dst[i]) return [NSString stringWithFormat:@"pipeline %@: %@", names[i], ne.localizedDescription];
    }

    /* Level sizes: halve (rounding up) until the next level would be tiny. */
    NSMutableArray<NSValue *> *dims = [NSMutableArray array];
    NSUInteger lw = (w + 1) / 2, lh = (h + 1) / 2;
    [dims addObject:[NSValue valueWithSize:NSMakeSize(lw, lh)]];
    while (dims.count < kMaxLevels) {
        NSUInteger nw = (lw + 1) / 2, nh = (lh + 1) / 2;
        if (nw < kMinLevelDim || nh < kMinLevelDim) break;
        lw = nw; lh = nh;
        [dims addObject:[NSValue valueWithSize:NSMakeSize(lw, lh)]];
    }
    _levelCount = dims.count;

    for (int s = 0; s < 2; s++) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSValue *v in dims) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                           width:(NSUInteger)v.sizeValue.width height:(NSUInteger)v.sizeValue.height mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            d.storageMode = MTLStorageModePrivate;
            id<MTLTexture> t = [device newTextureWithDescriptor:d];
            if (!t) return @"pyramid texture alloc failed";
            [a addObject:t];
        }
        _pyr[s] = a;
    }
    NSMutableArray<id<MTLTexture>> *fl = [NSMutableArray array];
    for (NSValue *v in dims) {
        NSUInteger gw = ((NSUInteger)v.sizeValue.width + 3) / 4, gh = ((NSUInteger)v.sizeValue.height + 3) / 4;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                       width:gw height:gh mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [device newTextureWithDescriptor:d];
        if (!t) return @"flow texture alloc failed";
        [fl addObject:t];
    }
    _flow = fl;
    _flowWidth = fl[0].width; _flowHeight = fl[0].height;
    return nil;
}

- (id<MTLTexture>)flowTexture { return _flow[0]; }

- (void)resetHistory { _hasPrev = NO; }

/// Encodes the pyramid for `src` into slot `s`. One dispatch per level; the
/// default serial dispatch type plus hazard tracking orders them, which is
/// why no explicit barriers appear here.
- (void)encodePyramid:(id<MTLComputeCommandEncoder>)enc src:(id<MTLTexture>)src slot:(int)s {
    NSArray<id<MTLTexture>> *p = _pyr[s];
    [enc setComputePipelineState:_psLuma];
    [enc setTexture:src atIndex:0];
    [enc setTexture:p[0] atIndex:1];
    [enc dispatchThreads:MTLSizeMake(p[0].width, p[0].height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [enc setComputePipelineState:_psDown];
    for (NSUInteger l = 1; l < p.count; l++) {
        [enc setTexture:p[l - 1] atIndex:0];
        [enc setTexture:p[l] atIndex:1];
        [enc dispatchThreads:MTLSizeMake(p[l].width, p[l].height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    }
}

/// Encodes the coarse-to-fine solve of previous slot `a` -> current slot `b`.
- (void)encodeFlow:(id<MTLComputeCommandEncoder>)enc from:(int)a to:(int)b {
    NSInteger top = (NSInteger)_levelCount - 1;
    for (NSInteger l = top; l >= 0; l--) {
        FGFlowParams prm = { kCoarseRadius, kRefineIters, kLambda, l == 0 ? 1 : 0 };
        id<MTLTexture> out = _flow[l];
        [enc setComputePipelineState:(l == top) ? _psCoarse : _psRefine];
        [enc setTexture:_pyr[a][l] atIndex:0];
        [enc setTexture:_pyr[b][l] atIndex:1];
        [enc setTexture:out atIndex:2];
        if (l != top) [enc setTexture:_flow[l + 1] atIndex:3];
        [enc setBytes:&prm length:sizeof prm atIndex:0];
        [enc dispatchThreads:MTLSizeMake(out.width, out.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
}

/// Rejects textures a compute kernel cannot legally read. A CAMetalLayer
/// drawable is usually framebufferOnly (render-target usage only), which
/// would otherwise be a Metal validation failure inside the host process.
- (BOOL)usable:(id<MTLTexture>)t {
    return t && t.textureType == MTLTextureType2D && t.sampleCount == 1 &&
           (t.usage & MTLTextureUsageShaderRead) && t.width == _srcWidth && t.height == _srcHeight;
}

- (BOOL)submitFrame:(id<MTLTexture>)src completion:(void (^)(id<MTLCommandBuffer>, BOOL))done {
    if (![self usable:src]) return NO;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    if (!cb) return NO;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!enc) return NO;
    int cur = _cur, prev = cur ^ 1;
    BOOL pair = _hasPrev && !_pyramidOnly;
    [self encodePyramid:enc src:src slot:cur];
    if (pair) [self encodeFlow:enc from:prev to:cur];
    [enc endEncoding];
    if (done) [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { done(c, pair); }];
    [cb commit];
    _hasPrev = YES;
    _cur = prev;
    return YES;
}

- (BOOL)submitPrev:(id<MTLTexture>)prev curr:(id<MTLTexture>)curr completion:(void (^)(id<MTLCommandBuffer>, BOOL))done {
    if (![self usable:prev] || ![self usable:curr]) return NO;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    if (!cb) return NO;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!enc) return NO;
    [self encodePyramid:enc src:prev slot:0];
    [self encodePyramid:enc src:curr slot:1];
    BOOL pair = !_pyramidOnly;
    if (pair) [self encodeFlow:enc from:0 to:1];
    [enc endEncoding];
    if (done) [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { done(c, pair); }];
    [cb commit];
    _hasPrev = NO;   /* slots now hold an arbitrary pair; do not stream from them */
    return YES;
}

- (NSData *)copyFlowSync {
    id<MTLTexture> t = _flow[0];
    NSUInteger bpr = t.width * 8;
    id<MTLBuffer> buf = [_dev newBufferWithLength:bpr * t.height options:MTLResourceStorageModeShared];
    if (!buf) return nil;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:buf destinationOffset:0
      destinationBytesPerRow:bpr destinationBytesPerImage:bpr * t.height];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return [NSData dataWithBytes:buf.contents length:buf.length];
}

@end
