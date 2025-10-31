#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "MetalMazeRenderer.h"

static id sMazeEventMonitor = nil;

@interface MazeInteractiveView : MTKView
@property (nonatomic, assign) MetalMazeRenderer *mazeRenderer;
@end

@implementation MazeInteractiveView
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self.window makeFirstResponder:self];
    }
}

- (void)keyDown:(NSEvent *)event {
    [self.mazeRenderer activateManualControl];
    if (![self.mazeRenderer handleKeyEventWithCode:event.keyCode pressed:YES]) {
        [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    if (![self.mazeRenderer handleKeyEventWithCode:event.keyCode pressed:NO]) {
        [super keyUp:event];
    }
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            NSLog(@"Metal is not supported on this device");
            return 1;
        }

        NSRect frame = NSMakeRect(200, 200, 1024, 768);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Metal Infinite Maze"]; 

    MazeInteractiveView *mtkView = [[MazeInteractiveView alloc] initWithFrame:frame device:device];
    MetalMazeRenderer *renderer = [[MetalMazeRenderer alloc] initWithMetalKitView:mtkView];
        mtkView.delegate = renderer;
    mtkView.mazeRenderer = renderer;
    [window setContentView:mtkView];
    [window setInitialFirstResponder:mtkView];
    [window makeFirstResponder:mtkView];
        [window makeKeyAndOrderFront:nil];

        __block MetalMazeRenderer *keyboardRenderer = renderer;
        if (sMazeEventMonitor) {
            [NSEvent removeMonitor:sMazeEventMonitor];
            [sMazeEventMonitor release];
            sMazeEventMonitor = nil;
        }
        id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                           handler:^NSEvent * _Nullable(NSEvent *event) {
            if (!keyboardRenderer) {
                return event;
            }
            BOOL isDown = (event.type == NSEventTypeKeyDown);
            if (isDown) {
                [keyboardRenderer activateManualControl];
            }
            if ([keyboardRenderer handleKeyEventWithCode:event.keyCode pressed:isDown]) {
                return nil;
            }
            return event;
        }];
        sMazeEventMonitor = [monitor retain];

        [NSApp run];
    }
    return 0;
}
