// flowsmoke.m: native-Metal end-to-end smoke test for the shim's optional
// flow stage. NOT part of the injected dylib (it has a main()). It stands in
// for a game: it renders a textured pattern that scrolls by a KNOWN amount
// per frame into a CAMetalLayer drawable and presents it through
// -[MTLCommandBuffer presentDrawable:], the same call D3DMetal 3.0 makes.
// Injecting the built shim into it exercises the real hooks plus the flow
// stage, and FGSHIM_FLOW_DEBUG=1 makes the shim log the median flow vector,
// which must equal the known scroll if (and only if) the shim read the
// drawable's FINAL contents with correct ordering.
//
//   clang -dynamiclib -fobjc-arc -O2 -arch arm64 -framework Foundation \
//         -framework Metal -framework QuartzCore -o /tmp/libfgshim_test.dylib Shim/fgshim.m
//   clang -fobjc-arc -O2 -arch arm64 -framework Foundation -framework Metal \
//         -framework QuartzCore -o /tmp/flowsmoke Shim/flowsmoke.m
//   FGSHIM_FLOW=1 FGSHIM_FLOW_FORCE_READABLE=1 FGSHIM_FLOW_DEBUG=1 \
//     DYLD_INSERT_LIBRARIES=/tmp/libfgshim_test.dylib /tmp/flowsmoke [frames] [fps]
//
// It deliberately leaves the layer framebufferOnly=YES (the CAMetalLayer
// default, which is what a real game gets unless it opts out), so the run
// also proves the shim's two readable-texture behaviours.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <unistd.h>

// Per-frame scroll of the pattern in pixels. The shim should report this.
#define SCROLL_X 5
#define SCROLL_Y -3

static NSString *const kSrc =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; };\n"
     "vertex VOut vs(uint vid [[vertex_id]]) {\n"
     "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
     "  VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); return o; }\n"
     "float h(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }\n"
     "float vn(float2 p) { float2 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);\n"
     "  return mix(mix(h(i), h(i+float2(1,0)), f.x), mix(h(i+float2(0,1)), h(i+float2(1,1)), f.x), f.y); }\n"
     "fragment float4 fs(VOut in [[stage_in]], constant float2 &shift [[buffer(0)]]) {\n"
     "  float2 p = in.pos.xy - shift;\n"
     "  float v = 0.5*vn(p/32.0) + 0.3*vn(p/16.0) + 0.2*vn(p/6.0);\n"
     "  float w = 0.5*vn(p/24.0 + 7.0) + 0.5*vn(p/8.0 + 3.0);\n"
     "  return float4(v, w, 0.5*(v+w), 1); }\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        int frames = argc > 1 ? atoi(argv[1]) : 600;
        int fps = argc > 2 ? atoi(argv[2]) : 60;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) { fprintf(stderr, "compile: %s\n", err.localizedDescription.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { fprintf(stderr, "pso: %s\n", err.localizedDescription.UTF8String); return 1; }

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(1280, 720);
        printf("layer.framebufferOnly (as the app leaves it) = %d\n", layer.framebufferOnly);

        for (int f = 0; f < frames; f++) {
            @autoreleasepool {
                id<CAMetalDrawable> d = [layer nextDrawable];
                if (!d) { fprintf(stderr, "nextDrawable returned nil at frame %d\n", f); return 1; }
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = d.texture;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                [e setRenderPipelineState:ps];
                float shift[2] = {(float)(f * SCROLL_X), (float)(f * SCROLL_Y)};
                [e setFragmentBytes:shift length:sizeof shift atIndex:0];
                [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [e endEncoding];
                [cb presentDrawable:d];
                [cb commit];
                [cb waitUntilCompleted];   // stand-in for a game paced by vsync
            }
            usleep(1000000 / fps);
        }
        printf("done: %d frames; expected scroll per frame = (%d, %d) px\n", frames, SCROLL_X, SCROLL_Y);
    }
    return 0;
}
