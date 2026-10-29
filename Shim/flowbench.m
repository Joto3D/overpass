// flowbench.m: STANDALONE benchmark + correctness check for FGFlowEstimator.
// This file has a main() and is NOT part of the injected dylib; scripts/
// bundle.sh only compiles fgshim.m. Build and run by hand:
//
//   clang -fobjc-arc -O2 -arch arm64 -framework Foundation -framework Metal \
//         -framework QuartzCore -o /tmp/flowbench Shim/flowbench.m Shim/fgflow.m
//   /tmp/flowbench            # all resolutions
//   /tmp/flowbench 1920 1080  # one resolution
//
// WHY IT MEASURES WHAT IT MEASURES:
//   * Source frames are BGRA8Unorm PRIVATE textures (copied in with a blit),
//     because that is what a CAMetalLayer drawable looks like to the
//     estimator; a Shared texture could sample at a different speed.
//   * "GPU" times come from MTLCommandBuffer GPUStartTime/GPUEndTime: pure
//     on-GPU execution of the estimator's one command buffer, with no
//     scheduling latency. "wall" is CPU encode + commit + waitUntilCompleted,
//     i.e. what a caller that had to wait would observe (it includes the
//     ~100s of microseconds of submit-to-start latency).
//   * "steady" = one new frame's pyramid + the flow solve (what the shim pays
//     per frame, since the previous frame's pyramid is retained). "cold" =
//     both pyramids + the solve (first frame after a reset / resize).
//   * The scene has known motion so the numbers are not just speed: a
//     solver that is fast because it returns zeros would fail the accuracy
//     check printed next to the timing.
//   * The content is SYNTHETIC multi-octave value noise with two rigid
//     motions. It validates the algorithm and its speed. It says nothing
//     about quality on real game footage (motion blur, particles, UI,
//     transparency), which this benchmark cannot judge.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <math.h>
#import "fgflow.h"

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

// ---- synthetic scene ------------------------------------------------------
static uint32_t hash2(int x, int y, uint32_t seed) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}
static float lattice(int x, int y, uint32_t seed) { return (hash2(x, y, seed) & 0xFFFF) / 65535.0f; }
/// Multi-octave bilinear value noise in [0,1]. Octave cells 64..4 px give
/// structure at every pyramid level, like real textured geometry does.
static float fbm(float x, float y, uint32_t seed) {
    float sum = 0, amp = 0.5f, norm = 0;
    for (int o = 0; o < 5; o++) {
        float cell = 64.0f / (float)(1 << o);
        float fx = x / cell, fy = y / cell;
        int ix = (int)floorf(fx), iy = (int)floorf(fy);
        float tx = fx - ix, ty = fy - iy;
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
        float a = lattice(ix, iy, seed + o), b = lattice(ix + 1, iy, seed + o);
        float c = lattice(ix, iy + 1, seed + o), d = lattice(ix + 1, iy + 1, seed + o);
        sum += amp * ((a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty);
        norm += amp; amp *= 0.55f;
    }
    return sum / norm;
}
static void shade(float x, float y, uint32_t seed, uint8_t *bgra) {
    float v = fbm(x, y, seed), w = fbm(x, y, seed + 977);
    bgra[0] = (uint8_t)(255.0f * (0.5f * (v + w)));
    bgra[1] = (uint8_t)(255.0f * w);
    bgra[2] = (uint8_t)(255.0f * v);
    bgra[3] = 255;
}

typedef struct { int bgDx, bgDy, fgDx, fgDy; int rx0, ry0, rx1, ry1; } Scene;  // rect = fg in frame 1

/// Frame 1: background plus a foreground rectangle. Frame 2: the SAME
/// background translated by (bgDx,bgDy) and the foreground (its own texture,
/// carried with it) translated by (fgDx,fgDy). Ground truth is therefore two
/// exact integer-pixel rigid motions.
static void render(int w, int h, const Scene *s, int frame, uint8_t *out) {
    int ox = frame ? s->bgDx : 0, oy = frame ? s->bgDy : 0;
    int fx = frame ? s->fgDx : 0, fy = frame ? s->fgDy : 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint8_t *p = out + ((size_t)y * w + x) * 4;
        int ux = x - fx - s->rx0, uy = y - fy - s->ry0;
        if (ux >= 0 && uy >= 0 && ux < s->rx1 - s->rx0 && uy < s->ry1 - s->ry0)
            shade((float)ux, (float)uy, 5000, p);
        else
            shade((float)(x - ox), (float)(y - oy), 1, p);
    }
}

static id<MTLTexture> privateCopy(id<MTLDevice> dev, id<MTLCommandQueue> q, const uint8_t *px, int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> sh = [dev newTextureWithDescriptor:d];
    [sh replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:(NSUInteger)w * 4];
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> pr = [dev newTextureWithDescriptor:d];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:sh toTexture:pr];
    [b endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    return pr;
}

// ---- stats ----------------------------------------------------------------
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static void report(const char *label, double *v, int n) {
    qsort(v, n, sizeof(double), cmpd);
    double sum = 0; for (int i = 0; i < n; i++) sum += v[i];
    printf("    %-34s median %7.3f  mean %7.3f  min %7.3f  p95 %7.3f  max %7.3f ms\n",
           label, v[n / 2], sum / n, v[0], v[(int)(n * 0.95)], v[n - 1]);
}

/// Submit and block; returns wall ms, fills gpu ms. The block is only for the
/// benchmark -- the shim never waits.
typedef BOOL (^Submit)(void (^done)(id<MTLCommandBuffer>, BOOL));
static void timeOne(Submit submit, double *wall, double *gpu) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block double g = 0;
    double t0 = now_ms();
    BOOL ok = submit(^(id<MTLCommandBuffer> cb, BOOL produced) {
        (void)produced;
        g = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
        dispatch_semaphore_signal(sem);
    });
    if (!ok) { fprintf(stderr, "submit refused\n"); exit(2); }
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    *wall = now_ms() - t0; *gpu = g;
}

static void runSize(id<MTLDevice> dev, int w, int h) {
    printf("\n=== %dx%d ===\n", w, h);
    Scene sc;
    sc.bgDx = (int)lround(w * 0.025); sc.bgDy = -(int)lround(h * 0.015);
    sc.fgDx = -(int)lround(w * 0.012); sc.fgDy = (int)lround(h * 0.020);
    sc.rx0 = w * 35 / 100; sc.rx1 = w * 65 / 100; sc.ry0 = h * 30 / 100; sc.ry1 = h * 70 / 100;
    uint8_t *f0 = malloc((size_t)w * h * 4), *f1 = malloc((size_t)w * h * 4);
    render(w, h, &sc, 0, f0); render(w, h, &sc, 1, f1);

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLTexture> A = privateCopy(dev, q, f0, w, h), B = privateCopy(dev, q, f1, w, h);
    free(f0); free(f1);

    NSString *err = nil;
    double c0 = now_ms();
    FGFlowEstimator *est = [FGFlowEstimator estimatorWithDevice:dev width:w height:h error:&err];
    if (!est) { printf("  estimator creation FAILED: %s\n", err.UTF8String); exit(1); }
    printf("  setup (runtime MSL compile + 4 pipelines + textures): %.1f ms; %lu levels; flow field %lux%lu\n",
           now_ms() - c0, (unsigned long)est.levelCount, (unsigned long)est.flowWidth, (unsigned long)est.flowHeight);

    // ---- accuracy (one cold pair) ----
    double wl, gp;
    timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitPrev:A curr:B completion:d]; }, &wl, &gp);
    NSData *fd = [est copyFlowSync];
    const __fp16 *fv = fd.bytes;
    int gw = (int)est.flowWidth, gh = (int)est.flowHeight;
    // Per-group EPE in SOURCE pixels (flow is in level-0 = half-res pixels).
    double sumE[3] = {0}; int cnt[3] = {0}, le1[3] = {0}, le2[3] = {0};
    int margin = 16;  // source px: window is 16 src px wide; keep clear of region edges
    int mvx = abs(sc.bgDx) + 16, mvy = abs(sc.bgDy) + 16;
    for (int gy = 0; gy < gh; gy++) for (int gx = 0; gx < gw; gx++) {
        // Window centre in source px: level-0 (gx*4+2) * 2; window spans +-8 src px.
        int cx = (gx * 4 + 2) * 2, cy = (gy * 4 + 2) * 2;
        int x0 = cx - 8, x1 = cx + 8, y0 = cy - 8, y1 = cy + 8;
        int grp = -1;
        // fg: window entirely inside the intersection of fg in both frames.
        int ix0 = MAX(sc.rx0, sc.rx0 + sc.fgDx) + margin, ix1 = MIN(sc.rx1, sc.rx1 + sc.fgDx) - margin;
        int iy0 = MAX(sc.ry0, sc.ry0 + sc.fgDy) + margin, iy1 = MIN(sc.ry1, sc.ry1 + sc.fgDy) - margin;
        if (x0 >= ix0 && x1 <= ix1 && y0 >= iy0 && y1 <= iy1) grp = 1;
        // bg: clear of both fg rects (plus margin) and of the image border (content enters there).
        int ux0 = MIN(sc.rx0, sc.rx0 + sc.fgDx) - margin, ux1 = MAX(sc.rx1, sc.rx1 + sc.fgDx) + margin;
        int uy0 = MIN(sc.ry0, sc.ry0 + sc.fgDy) - margin, uy1 = MAX(sc.ry1, sc.ry1 + sc.fgDy) + margin;
        BOOL clearOfFg = x1 <= ux0 || x0 >= ux1 || y1 <= uy0 || y0 >= uy1;
        if (grp < 0 && clearOfFg && x0 >= mvx && x1 <= w - mvx && y0 >= mvy && y1 <= h - mvy) grp = 0;
        if (grp < 0) continue;
        const __fp16 *p = fv + ((size_t)gy * gw + gx) * 4;
        double ex = 2.0 * p[0] - (grp ? sc.fgDx : sc.bgDx), ey = 2.0 * p[1] - (grp ? sc.fgDy : sc.bgDy);
        double e = sqrt(ex * ex + ey * ey);
        if (getenv("BENCH_OUTLIERS") && e > 2.0) printf("      outlier grp=%d grid(%d,%d) src(%d,%d) flow*2=(%.1f,%.1f) sad=%.4f\n", grp, gx, gy, cx, cy, 2.0 * p[0], 2.0 * p[1], (double)p[2]);
        sumE[grp] += e; cnt[grp]++; if (e <= 1.0) le1[grp]++; if (e <= 2.0) le2[grp]++;
    }
    const char *gn[2] = {"background", "foreground"};
    printf("  accuracy vs ground truth (synthetic noise scene; bg motion (%d,%d) px, fg motion (%d,%d) px, in SOURCE px):\n",
           sc.bgDx, sc.bgDy, sc.fgDx, sc.fgDy);
    for (int g = 0; g < 2; g++)
        printf("    %-10s vectors=%5d  mean EPE %.3f px  within 1px %.1f%%  within 2px %.1f%%\n", gn[g], cnt[g],
               cnt[g] ? sumE[g] / cnt[g] : -1.0, cnt[g] ? 100.0 * le1[g] / cnt[g] : 0.0, cnt[g] ? 100.0 * le2[g] / cnt[g] : 0.0);

    // ---- timing ----
    const int warm = 40, N = 300;
    double *wallv = malloc(sizeof(double) * N), *gpuv = malloc(sizeof(double) * N);

    for (int i = 0; i < warm; i++) timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitPrev:A curr:B completion:d]; }, &wl, &gp);
    for (int i = 0; i < N; i++) timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitPrev:A curr:B completion:d]; }, &wallv[i], &gpuv[i]);
    printf("  COLD pair (2 pyramids + flow), isolated, %d runs:\n", N);
    report("GPU", gpuv, N); report("wall (encode+commit+wait)", wallv, N);

    [est resetHistory];
    __block int flip = 0;
    NSArray<id<MTLTexture>> *seq = @[A, B];
    [est submitFrame:A completion:nil];  // prime: first frame produces no flow
    for (int i = 0; i < warm; i++) timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitFrame:seq[(++flip) & 1] completion:d]; }, &wl, &gp);
    for (int i = 0; i < N; i++) timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitFrame:seq[(++flip) & 1] completion:d]; }, &wallv[i], &gpuv[i]);
    printf("  STEADY-STATE pair (1 new pyramid + flow; what the shim pays per frame), isolated, %d runs:\n", N);
    report("GPU", gpuv, N); report("wall (encode+commit+wait)", wallv, N);

    est.pyramidOnly = YES;
    for (int i = 0; i < N; i++) timeOne(^BOOL(void (^d)(id<MTLCommandBuffer>, BOOL)) { return [est submitFrame:seq[(++flip) & 1] completion:d]; }, &wallv[i], &gpuv[i]);
    printf("  of which pyramid build alone (1 frame):\n");
    report("GPU", gpuv, N);
    est.pyramidOnly = NO;

    // Empty-ish command buffer: floor for submit->complete latency on this box.
    id<MTLCommandQueue> q2 = [dev newCommandQueue];
    for (int i = 0; i < N; i++) {
        double t0 = now_ms();
        id<MTLCommandBuffer> cb = [q2 commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; [e endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        wallv[i] = now_ms() - t0;
    }
    printf("  reference: empty command buffer commit+wait (latency floor):\n");
    report("wall", wallv, N);

    // Pipelined throughput: back-to-back, no waiting between frames.
    dispatch_group_t grp = dispatch_group_create();
    const int P = 200;
    double t0 = now_ms();
    for (int i = 0; i < P; i++) {
        dispatch_group_enter(grp);
        [est submitFrame:seq[(++flip) & 1] completion:^(id<MTLCommandBuffer> cb, BOOL p) { (void)cb; (void)p; dispatch_group_leave(grp); }];
    }
    dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
    printf("  pipelined throughput (%d frames back-to-back): %.3f ms/frame\n", P, (now_ms() - t0) / P);
    free(wallv); free(gpuv);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "no Metal device\n"); return 1; }
        printf("device: %s\n", dev.name.UTF8String);
        if (argc == 3) { runSize(dev, atoi(argv[1]), atoi(argv[2])); return 0; }
        runSize(dev, 320, 180);
        runSize(dev, 1280, 720);
        runSize(dev, 1920, 1080);
        runSize(dev, 2560, 1440);
        runSize(dev, 3840, 2160);
    }
    return 0;
}
