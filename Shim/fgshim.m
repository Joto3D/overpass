// fgshim: Metal present-hook dylib. FRAME COUNTER ONLY -- it observes and
// logs presents; it never delays, reorders, duplicates, or generates a
// frame, and it always calls through to the original implementation.
//
// How Overpass uses it: when a bottle's "Frame counter" diagnostic is on,
// `WineRunner.environment(for:engine:)` sets DYLD_INSERT_LIBRARIES to this
// dylib (built by scripts/bundle.sh into Contents/Resources/libfgshim.dylib,
// universal x86_64+arm64 because Wine runs under Rosetta). Every line is
// written to stderr prefixed "fgshim:", which Overpass's ProcessRunner
// already tees into the per-run log file under
// ~/Library/Application Support/Overpass/Logs/. FGSHIM_LOG_EVERY=N (env,
// via the bottle's custom environment variables) logs only every Nth present.
//
// WHY SEVEN SELECTORS ARE HOOKED (established by binary analysis of the
// engines; none of these is redundant):
//   * D3DMetal 3.0 presents via -[<MTLCommandBuffer> presentDrawable:]
//     (and the atTime:/afterMinimumDuration: variants).
//   * D3DMetal 4.0b3 has two backends. Its MTL4 path (likely the default on
//     macOS 27) presents via -[<CAMetalDrawable> present] /
//     presentAfterMinimumDuration: and NEVER calls presentDrawable:.
//   * MoltenVK never calls presentDrawable: either. It calls
//     -[drawable present] / presentAtTime: from a scheduled-handler block
//     running on a Metal callback thread.
// Hooking only one family would silently read 0 fps on the other engines.
// A cb-level present later triggers the drawable-level present internally,
// so cb hooks remember the drawable (mark_seen) and the drawable hooks skip
// it (take_seen) -- one frame is counted exactly once.
//
// THREADING: for MoltenVK the present fires on a DIFFERENT thread from the
// -[CAMetalLayer nextDrawable] call that produced the drawable. So nothing
// here pairs a nextDrawable with a present using thread-local state; all
// counters are process-global (atomics / os_unfair_lock).
//
// Verified (prototype): builds universal, injects into every Wine child
// process under Rosetta without crashing, and counted 120 presents for 120
// frames against a native Metal control program.
//
// Verified against a real game (29 October 2026): UNIGINE Superposition
// 1.1 (engine 2.5-dev, "Binary: Windows 64-bit", Direct3D11) in the GPTK
// `gptk-3.0-3` bottle, launched from the installed Overpass.app so the
// dylib came from Contents/Resources. The whole chain fired:
//
//     first nextDrawable call (layer=CAMetalLayer)
//     discovered MTLCommandBuffer class AGXG16GFamilyCommandBuffer
//     hooked cb.presentDrawable: / :atTime: / :afterMinimumDuration:
//     discovered drawable class CAMetalDrawable
//     hooked drawable.present / presentAtTime: / presentAfterMinimumDuration:
//     exit pid 12242: presents=172 drawables=172
//
// So D3DMetal takes the cb.presentDrawable: family off a real AGX command
// buffer, and the mark_seen/take_seen de-duplication holds: presents and
// drawables came out equal (172/172), i.e. exactly one count per frame and
// no double-counting from the drawable-level hook firing underneath.
// Only the one render process reports a non-zero count; the other four
// Wine processes the shim loads into report presents=0, as expected.
//
// OPTIONAL OPTICAL-FLOW STAGE (FGSHIM_FLOW=1, DEFAULT OFF): the first
// building block of real frame generation. We only ever see the final colour
// texture -- no motion vectors, no depth -- so motion has to be estimated
// from two consecutive colour frames. Shim/fgflow.m is a pyramidal
// coarse-to-fine block-matching estimator on Metal compute (its own header
// documents the algorithm and the measured timings). With FGSHIM_FLOW unset
// or 0 NOTHING below the flag checks runs: no estimator, no queue, no shader
// compile, no extra log lines, and the counter output is exactly as before.
// With it set, on the cb.presentDrawable: path only, the shim:
//   * adds a completed-handler to the HOST command buffer. The game's
//     drawable texture is only final once that buffer has finished on the
//     GPU, and the present hook runs BEFORE commit, so this is the earliest
//     point at which reading the texture is correct;
//   * from that handler submits the estimator on its OWN queue (never the
//     game's) and returns -- nothing waits, and the present path itself only
//     does an atomic compare-exchange and one addCompletedHandler;
//   * drops the frame (counted, logged) if the previous estimate is still
//     running, instead of queueing -- a slow estimator must cost us pairs,
//     never game frame time;
//   * creates the estimator (a ~100s of ms runtime MSL compile) on a utility
//     queue, not on the game's render thread; frames before it is ready are
//     dropped.
// The flow result itself is not consumed yet: nothing warps, interpolates or
// presents. This stage only produces and times the flow field.
//
// KNOWN LIMITS OF THIS STAGE (read before building on it):
//   * UNPROVEN IN A REAL GAME. It was exercised only by a native Metal test
//     program (Shim/flowsmoke.m), never inside Wine/D3DMetal.
//   * A CAMetalLayer is framebufferOnly by default, which makes the drawable
//     texture unreadable by a compute kernel. By default we detect that,
//     log it once, and do nothing (we will not silently change the host's
//     layer). FGSHIM_FLOW_FORCE_READABLE=1 opts in to setting
//     framebufferOnly=NO, which is a host-visible change and may cost the
//     game some compositing efficiency. Whether D3DMetal's layer is already
//     readable is NOT yet known.
//   * Holding the drawable until our GPU work ends delays its return to the
//     layer's drawable pool by roughly the estimate time. With a small
//     maximumDrawableCount this could in principle stall the game's next
//     nextDrawable; not measured.
//   * The drawable-level present family (D3DMetal 4.0b3 MTL4 path,
//     MoltenVK) has no command buffer to order against, so flow is NOT run
//     there; the shim logs this once instead of reading a half-rendered
//     texture.
//
// A valid target must be 64-bit and D3D11/D3D12 -- see the symbol counts
// in `FrameCounterShim.swift` for why D3D9 and 32-bit builds can never
// register a present no matter how well they render.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <os/lock.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdlib.h>
// Single translation unit on purpose: scripts/bundle.sh compiles only
// fgshim.m into the dylib, so pulling the estimator in textually keeps that
// build line (and the universal x86_64+arm64 slice) unchanged.
#include "fgflow.m"

static void fglog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fglog(const char *fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "fgshim: %s\n", buf);
}

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

// ---- present accounting -------------------------------------------------
static _Atomic unsigned long g_presents;
static _Atomic unsigned long g_drawables;
static double g_last_ms, g_win_start_ms, g_fps;
static unsigned long g_win_count;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static int g_log_every = 1;

static void note_present(const char *src) {
    double t = now_ms();
    unsigned long n = atomic_fetch_add(&g_presents, 1) + 1;
    os_unfair_lock_lock(&g_lock);
    double dt = g_last_ms > 0 ? t - g_last_ms : 0;
    g_last_ms = t;
    if (g_win_start_ms == 0) g_win_start_ms = t;
    g_win_count++;
    if (t - g_win_start_ms >= 500.0) {
        g_fps = g_win_count * 1000.0 / (t - g_win_start_ms);
        g_win_start_ms = t; g_win_count = 0;
    }
    double fps = g_fps;
    os_unfair_lock_unlock(&g_lock);
    if (g_log_every <= 1 || n % (unsigned long)g_log_every == 0)
        fglog("present #%lu via %s t=%.3fms dt=%.3fms fps=%.1f", n, src, t, dt, fps);
}

// ---- safe swizzling -----------------------------------------------------
static BOOL hook(Class c, SEL sel, IMP repl, IMP *orig, const char *tag) {
    if (!c) { fglog("hook skip %s: class missing", tag); return NO; }
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { fglog("hook skip %s: selector %s missing on %s", tag, sel_getName(sel), class_getName(c)); return NO; }
    if (*orig) { fglog("hook skip %s: already hooked", tag); return NO; }
    IMP o = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    // Add/replace on this exact class only (does not touch superclasses).
    class_replaceMethod(c, sel, repl, types);
    *orig = o;
    fglog("hooked %s (%s on %s)", tag, sel_getName(sel), class_getName(c));
    return YES;
}

// cb.presentDrawable: later triggers drawable.present internally; remember drawables
// already counted at the cb level so the drawable-level hook can skip them (no double count).
#define SEEN_N 16
static void *g_seen[SEEN_N]; static unsigned g_seen_i;
static void mark_seen(id d) {
    os_unfair_lock_lock(&g_lock); g_seen[g_seen_i++ % SEEN_N] = (__bridge void *)d; os_unfair_lock_unlock(&g_lock);
}
static BOOL take_seen(id d) {
    BOOL hit = NO;
    os_unfair_lock_lock(&g_lock);
    for (int i = 0; i < SEEN_N; i++) if (g_seen[i] == (__bridge void *)d) { g_seen[i] = NULL; hit = YES; break; }
    os_unfair_lock_unlock(&g_lock);
    return hit;
}

// ---- optional optical-flow stage (FGSHIM_FLOW=1; see header) ------------
// g_flow_on is written once in the constructor and may be cleared later if
// the estimator cannot be built; relaxed atomics are enough because nothing
// depends on ordering against it.
static _Atomic int g_flow_on;
static BOOL g_flow_force_readable;
static BOOL g_flow_debug;   // FGSHIM_FLOW_DEBUG=1: read the flow back and log its median (blocks a Metal callback thread; diagnostics only)
static FGFlowEstimator *g_flow_est;           // guarded by g_lock
static _Atomic int g_flow_creating, g_flow_busy;
static _Atomic unsigned long g_flow_pairs, g_flow_dropped, g_flow_unreadable, g_flow_gpu_us;

/// IEEE half -> float, hand-rolled because __fp16/_Float16 arithmetic is not
/// available on every slice of this universal build (x86_64 under Rosetta).
static float half_to_float(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) << 31, exp = (h >> 10) & 0x1F, man = h & 0x3FF, bits;
    if (exp == 0) {
        if (man == 0) bits = sign;
        else { exp = 127 - 14; while (!(man & 0x400)) { man <<= 1; exp--; } man &= 0x3FF; bits = sign | (exp << 23) | (man << 13); }
    } else if (exp == 31) bits = sign | 0x7F800000u | (man << 13);
    else bits = sign | ((exp + 112) << 23) | (man << 13);
    float f; memcpy(&f, &bits, 4); return f;
}
static int cmp_float(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return (x > y) - (x < y); }

/// Debug: median flow vector over the whole field, in SOURCE pixels. A
/// median (not mean) so a moving foreground object cannot mask the global
/// camera/background motion that a known test pattern is checked against.
static void flow_debug_log(FGFlowEstimator *est, unsigned long n) {
    NSData *d = [est copyFlowSync];
    size_t cnt = d.length / 8;
    if (!cnt) return;
    float *xs = malloc(cnt * sizeof(float)), *ys = malloc(cnt * sizeof(float));
    const uint16_t *h = d.bytes;
    for (size_t i = 0; i < cnt; i++) { xs[i] = 2.0f * half_to_float(h[i * 4]); ys[i] = 2.0f * half_to_float(h[i * 4 + 1]); }
    qsort(xs, cnt, sizeof(float), cmp_float); qsort(ys, cnt, sizeof(float), cmp_float);
    fglog("flow: pair #%lu median vector = (%.2f, %.2f) source px", n, xs[cnt / 2], ys[cnt / 2]);
    free(xs); free(ys);
}

/// Builds the estimator off the render thread. Failure disables flow for the
/// rest of the process (rather than retrying every frame): a broken shader
/// compile will not fix itself and retrying would burn CPU in the game.
static void flow_begin_create(id<MTLDevice> dev, NSUInteger w, NSUInteger h) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_flow_creating, &expected, 1)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *err = nil;
            double t0 = now_ms();
            FGFlowEstimator *est = [FGFlowEstimator estimatorWithDevice:dev width:w height:h error:&err];
            if (est) {
                os_unfair_lock_lock(&g_lock); g_flow_est = est; os_unfair_lock_unlock(&g_lock);
                fglog("flow: estimator ready for %lux%lu (%lu pyramid levels, flow field %lux%lu) in %.1fms",
                      (unsigned long)w, (unsigned long)h, (unsigned long)est.levelCount,
                      (unsigned long)est.flowWidth, (unsigned long)est.flowHeight, now_ms() - t0);
            } else {
                fglog("flow: estimator creation failed (%s); flow disabled", err ? err.UTF8String : "?");
                atomic_store(&g_flow_on, 0);
            }
            atomic_store(&g_flow_creating, 0);
        }
    });
}

/// Called from the cb.presentDrawable: hooks, BEFORE the host commits `cb`.
/// Must stay cheap and must never block or throw into the game.
static void flow_on_present(id cb, id drawable) {
    if (!atomic_load_explicit(&g_flow_on, memory_order_relaxed)) return;
    @try {
        if (![drawable respondsToSelector:@selector(texture)]) return;
        id<MTLTexture> tex = [(id<CAMetalDrawable>)drawable texture];
        if (!tex) return;
        if (!(tex.usage & MTLTextureUsageShaderRead)) {
            if (atomic_fetch_add(&g_flow_unreadable, 1) == 0)
                fglog("flow: drawable texture is not shader-readable (layer is framebufferOnly); "
                      "flow cannot run. Set FGSHIM_FLOW_FORCE_READABLE=1 to opt in to framebufferOnly=NO");
            return;
        }
        os_unfair_lock_lock(&g_lock); FGFlowEstimator *est = g_flow_est; os_unfair_lock_unlock(&g_lock);
        if (!est || est.srcWidth != tex.width || est.srcHeight != tex.height) {
            flow_begin_create(tex.device, tex.width, tex.height);
            atomic_fetch_add(&g_flow_dropped, 1);
            return;
        }
        int expected = 0;
        if (!atomic_compare_exchange_strong(&g_flow_busy, &expected, 1)) {
            atomic_fetch_add(&g_flow_dropped, 1);
            return;
        }
        @try {
            [(id<MTLCommandBuffer>)cb addCompletedHandler:^(id<MTLCommandBuffer> hostCb) {
                (void)hostCb;
                BOOL ok = NO;
                @try {
                    // `drawable` is captured (and so retained) until our GPU work is done.
                    ok = [est submitFrame:tex completion:^(id<MTLCommandBuffer> fcb, BOOL produced) {
                        (void)drawable;
                        if (produced) {
                            unsigned long n = atomic_fetch_add(&g_flow_pairs, 1) + 1;
                            unsigned long us = (unsigned long)((fcb.GPUEndTime - fcb.GPUStartTime) * 1e6);
                            unsigned long tot = atomic_fetch_add(&g_flow_gpu_us, us) + us;
                            if (n % 120 == 0)
                                fglog("flow: pairs=%lu dropped=%lu avg GPU %.3fms/pair (%lux%lu)", n,
                                      atomic_load(&g_flow_dropped), tot / 1000.0 / n,
                                      (unsigned long)est.srcWidth, (unsigned long)est.srcHeight);
                            if (g_flow_debug && n % 120 == 0) {
                                // OBSERVED HANG (29 Oct 2026): doing the blocking readback right
                                // here, on Metal's completion-handler thread, never returned and
                                // g_flow_busy stayed set forever (every later frame dropped). So
                                // the readback runs on a global queue, and busy stays set (the
                                // flow texture must not be overwritten) until it is done.
                                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                    @try { flow_debug_log(est, n); } @catch (...) {}
                                    atomic_store(&g_flow_busy, 0);
                                });
                                return;
                            }
                        }
                        atomic_store(&g_flow_busy, 0);
                    }];
                } @catch (...) { ok = NO; }
                if (!ok) atomic_store(&g_flow_busy, 0);
            }];
        } @catch (...) {
            // cb was already committed (or otherwise refused a handler): give up this frame.
            atomic_store(&g_flow_busy, 0);
        }
    } @catch (...) {}
}

/// The drawable-level present family has no command buffer we can order
/// against, so flow is skipped there. Said once so a silent "0 pairs" is not
/// mistaken for a bug.
static void flow_note_drawable_path(void) {
    static _Atomic int logged;
    if (atomic_load_explicit(&g_flow_on, memory_order_relaxed) && atomic_exchange(&logged, 1) == 0)
        fglog("flow: this app presents via drawable.present (no command buffer to order against); "
              "flow is only supported on the cb.presentDrawable: path");
}

// ---- MTLCommandBuffer presentDrawable family (concrete class) -----------
static IMP o_pd, o_pd_at, o_pd_after;
static void h_pd(id self, SEL _cmd, id d) {
    @try { mark_seen(d); note_present("cb.presentDrawable:"); } @catch (...) {}
    flow_on_present(self, d);
    ((void(*)(id,SEL,id))o_pd)(self, _cmd, d);
}
static void h_pd_at(id self, SEL _cmd, id d, CFTimeInterval t) {
    @try { mark_seen(d); note_present("cb.presentDrawable:atTime:"); } @catch (...) {}
    flow_on_present(self, d);
    ((void(*)(id,SEL,id,CFTimeInterval))o_pd_at)(self, _cmd, d, t);
}
static void h_pd_after(id self, SEL _cmd, id d, CFTimeInterval t) {
    @try { mark_seen(d); note_present("cb.presentDrawable:afterMinimumDuration:"); } @catch (...) {}
    flow_on_present(self, d);
    ((void(*)(id,SEL,id,CFTimeInterval))o_pd_after)(self, _cmd, d, t);
}

// ---- CAMetalDrawable present family (concrete class) --------------------
static IMP o_dp, o_dp_at, o_dp_after;
static void h_dp(id self, SEL _cmd) {
    @try { if (!take_seen(self)) { note_present("drawable.present"); flow_note_drawable_path(); } } @catch (...) {}
    ((void(*)(id,SEL))o_dp)(self, _cmd);
}
static void h_dp_at(id self, SEL _cmd, CFTimeInterval t) {
    @try { if (!take_seen(self)) { note_present("drawable.presentAtTime:"); flow_note_drawable_path(); } } @catch (...) {}
    ((void(*)(id,SEL,CFTimeInterval))o_dp_at)(self, _cmd, t);
}
static void h_dp_after(id self, SEL _cmd, CFTimeInterval t) {
    @try { if (!take_seen(self)) { note_present("drawable.presentAfterMinimumDuration:"); flow_note_drawable_path(); } } @catch (...) {}
    ((void(*)(id,SEL,CFTimeInterval))o_dp_after)(self, _cmd, t);
}

static void install_drawable_hooks(id drawable) {
    static BOOL done;
    if (done || !drawable) return;
    done = YES;
    Class c = object_getClass(drawable);
    fglog("discovered drawable class %s", class_getName(c));
    hook(c, @selector(present), (IMP)h_dp, &o_dp, "drawable.present");
    hook(c, @selector(presentAtTime:), (IMP)h_dp_at, &o_dp_at, "drawable.presentAtTime:");
    hook(c, @selector(presentAfterMinimumDuration:), (IMP)h_dp_after, &o_dp_after, "drawable.presentAfterMinimumDuration:");
}

static void install_cb_hooks(id<MTLDevice> dev) {
    static BOOL done;
    if (done || !dev) return;
    done = YES;
    @try {
        // Use a private queue so we never perturb the host's queue. Buffer is never committed.
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = q ? [q commandBuffer] : nil;
        if (!cb) { fglog("could not obtain a probe MTLCommandBuffer; cb hooks skipped"); return; }
        Class c = object_getClass(cb);
        fglog("discovered MTLCommandBuffer class %s", class_getName(c));
        hook(c, @selector(presentDrawable:), (IMP)h_pd, &o_pd, "cb.presentDrawable:");
        hook(c, @selector(presentDrawable:atTime:), (IMP)h_pd_at, &o_pd_at, "cb.presentDrawable:atTime:");
        hook(c, @selector(presentDrawable:afterMinimumDuration:), (IMP)h_pd_after, &o_pd_after, "cb.presentDrawable:afterMinimumDuration:");
    } @catch (NSException *e) {
        fglog("exception discovering cb class: %s", e.reason.UTF8String);
    }
}

// ---- CAMetalLayer nextDrawable ------------------------------------------
static IMP o_next;
static id h_next(id self, SEL _cmd) {
    // Opt-in only (FGSHIM_FLOW_FORCE_READABLE=1): must happen BEFORE the
    // drawable is handed out, since framebufferOnly is baked into its texture.
    if (g_flow_force_readable) {
        @try {
            if ([(CAMetalLayer *)self framebufferOnly]) {
                [(CAMetalLayer *)self setFramebufferOnly:NO];
                static _Atomic int told;
                if (atomic_exchange(&told, 1) == 0) fglog("flow: set framebufferOnly=NO on the CAMetalLayer (FGSHIM_FLOW_FORCE_READABLE)");
            }
        } @catch (...) {}
    }
    id d = ((id(*)(id,SEL))o_next)(self, _cmd);
    @try {
        atomic_fetch_add(&g_drawables, 1);
        static _Atomic int logged;
        if (atomic_exchange(&logged, 1) == 0) {
            fglog("first nextDrawable call (layer=%s)", class_getName(object_getClass(self)));
            id<MTLDevice> dev = [(CAMetalLayer *)self device];
            install_cb_hooks(dev);
        }
        install_drawable_hooks(d);
    } @catch (NSException *e) {
        fglog("exception in nextDrawable hook: %s", e.reason.UTF8String);
    }
    return d;
}

static BOOL install_layer_hooks(void) {
    static BOOL done;
    if (done) return YES;
    Class c = objc_getClass("CAMetalLayer");
    if (!c) return NO;
    done = YES;
    hook(c, @selector(nextDrawable), (IMP)h_next, &o_next, "CAMetalLayer.nextDrawable");
    return YES;
}

static void image_added(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    install_layer_hooks();
}

__attribute__((constructor))
static void fgshim_init(void) {
    @autoreleasepool {
        @try {
            const char *e = getenv("FGSHIM_LOG_EVERY");
            if (e && atoi(e) > 0) g_log_every = atoi(e);
            const char *fl = getenv("FGSHIM_FLOW");
            if (fl && atoi(fl) > 0) {
                atomic_store(&g_flow_on, 1);
                const char *fr = getenv("FGSHIM_FLOW_FORCE_READABLE");
                g_flow_force_readable = (fr && atoi(fr) > 0);
                const char *fd = getenv("FGSHIM_FLOW_DEBUG");
                g_flow_debug = (fd && atoi(fd) > 0);
                fglog("flow: enabled (FGSHIM_FLOW=1)%s", g_flow_force_readable ? ", force-readable layer" : "");
            }
            const char *pn = getprogname();
            fglog("loaded in pid %d (%s) arch=%s", getpid(), pn ? pn : "?",
#if defined(__x86_64__)
                  "x86_64"
#elif defined(__arm64__)
                  "arm64"
#else
                  "other"
#endif
            );
            if (!install_layer_hooks()) {
                fglog("CAMetalLayer not loaded yet; will retry as images load");
                _dyld_register_func_for_add_image(image_added);
            }
        } @catch (NSException *ex) {
            fglog("init exception (ignored): %s", ex.reason.UTF8String);
        }
    }
}

__attribute__((destructor))
static void fgshim_fini(void) {
    fglog("exit pid %d: presents=%lu drawables=%lu", getpid(),
          atomic_load(&g_presents), atomic_load(&g_drawables));
    if (atomic_load(&g_flow_on) || atomic_load(&g_flow_pairs)) {
        unsigned long n = atomic_load(&g_flow_pairs);
        fglog("exit pid %d: flow pairs=%lu dropped=%lu unreadable=%lu avgGPU=%.3fms", getpid(), n,
              atomic_load(&g_flow_dropped), atomic_load(&g_flow_unreadable),
              n ? atomic_load(&g_flow_gpu_us) / 1000.0 / n : 0.0);
    }
}
