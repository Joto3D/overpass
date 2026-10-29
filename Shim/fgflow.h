// fgflow: pyramidal (coarse-to-fine) block-matching optical flow on Metal.
//
// WHY THIS EXISTS: the frame-generation shim only ever sees the final COLOUR
// texture of a game (no motion vectors, no depth), so Apple's
// MTLFXFrameInterpolator cannot be used in its normal configuration. Motion
// has to be estimated from two consecutive colour frames. This is that
// estimator and nothing else -- no warping, no interpolation, no presenting.
//
// This header is deliberately tiny: fgshim.m `#include`s fgflow.m directly
// so the injected dylib stays a SINGLE translation unit and
// scripts/bundle.sh needs no change; the standalone benchmark
// (flowbench.m) links fgflow.m on its own and uses this header.
#import <Metal/Metal.h>

/// Estimates dense-ish forward optical flow (previous frame -> current frame)
/// between two consecutive colour frames of a fixed size. Owns its OWN
/// MTLCommandQueue so it can never queue behind, stall, or reorder work on
/// the host game's queue. Not thread-safe: the caller must serialise
/// submissions (fgshim.m does so with an atomic busy flag).
@interface FGFlowEstimator : NSObject

/// Builds the pipelines (runtime MSL compile -- tens of milliseconds, so
/// callers on a latency-sensitive thread must create this off-thread) and
/// all pyramid/flow textures for `w` x `h` source frames. Returns nil and
/// fills `err` on failure instead of throwing, because it runs inside a host
/// process we must not crash.
+ (instancetype)estimatorWithDevice:(id<MTLDevice>)device
                                       width:(NSUInteger)w
                                      height:(NSUInteger)h
                                       error:(NSString * *)err;

@property (nonatomic, readonly) NSUInteger srcWidth;
@property (nonatomic, readonly) NSUInteger srcHeight;
/// Number of pyramid levels (level 0 is HALF source resolution).
@property (nonatomic, readonly) NSUInteger levelCount;
/// Size in vectors of the finest flow field.
@property (nonatomic, readonly) NSUInteger flowWidth;
@property (nonatomic, readonly) NSUInteger flowHeight;
/// Finest-level flow, RGBA16Float: x,y = displacement in LEVEL-0 pixels
/// (multiply by 2 for source pixels) of the content from the previous frame
/// to the current one; z = mean absolute luma difference of the winning
/// match (0..1, a confidence/occlusion cue); w unused. One vector per 4x4
/// level-0 pixels (8x8 source pixels). Overwritten by every submit.
@property (nonatomic, readonly) id<MTLTexture> flowTexture;
/// Benchmark diagnostic: build the pyramid only and skip the flow passes, so
/// the two stages can be timed separately.
@property (nonatomic) BOOL pyramidOnly;

/// Streaming entry point (what the shim uses): feed each new frame in order.
/// The first call only builds that frame's pyramid (no pair exists yet) and
/// reports producedFlow=NO. Later calls reuse the PREVIOUS frame's retained
/// pyramid, so steady-state cost is one pyramid build plus one flow solve.
/// Never blocks: it encodes, commits on the private queue and returns;
/// `done` runs on a Metal callback thread after the GPU finishes. The source
/// texture must stay alive and unmodified until `done` fires. Returns NO
/// (and never calls `done`) if the texture is unusable.
- (BOOL)submitFrame:(id<MTLTexture>)src
         completion:(void (^)(id<MTLCommandBuffer> cb, BOOL producedFlow))done;

/// Cold-pair entry point: builds BOTH pyramids and solves one flow in a
/// single command buffer, with no dependence on history. Used by the
/// benchmark to measure the worst case (e.g. right after a resolution
/// change) and by tests.
- (BOOL)submitPrev:(id<MTLTexture>)prev
              curr:(id<MTLTexture>)curr
        completion:(void (^)(id<MTLCommandBuffer> cb, BOOL producedFlow))done;

/// Forget the retained previous frame (e.g. after a present gap).
- (void)resetHistory;

/// Benchmark/test only: blocks, copies the finest flow field to the CPU as
/// tightly packed half4 (8 bytes per vector, flowWidth*flowHeight vectors).
- (NSData *)copyFlowSync;

@end
