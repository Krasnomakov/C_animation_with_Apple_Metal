#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "MetalRenderer.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            NSLog(@"Metal is not supported on this device");
            return 1;
        }

        // Create window
        NSRect frame = NSMakeRect(100, 100, 800, 600);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Metal Rotating Triangle"]; 

        MTKView *mtkView = [[MTKView alloc] initWithFrame:frame device:device];
        MetalRenderer *renderer = [[MetalRenderer alloc] initWithMetalKitView:mtkView];
        mtkView.delegate = renderer;
        [window setContentView:mtkView];
        [window makeKeyAndOrderFront:nil];

        [NSApp run];
    }
    return 0;
}
