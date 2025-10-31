#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import "MetalRoomRenderer.h"

@interface RoomInteractiveView : MTKView
@property (nonatomic, assign) MetalRoomRenderer *roomRenderer;
@end

@implementation RoomInteractiveView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; if (self.window) [self.window makeFirstResponder:self]; }
- (void)keyDown:(NSEvent *)event { if (![self.roomRenderer handleKeyEventWithCode:event.keyCode pressed:YES]) [super keyDown:event]; }
- (void)keyUp:(NSEvent *)event { if (![self.roomRenderer handleKeyEventWithCode:event.keyCode pressed:NO]) [super keyUp:event]; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { NSLog(@"Metal not supported"); return 1; }

        NSRect frame = NSMakeRect(200, 200, 1024, 768);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"Metal Room (Sphere Bounce)"];

    RoomInteractiveView *view = [[RoomInteractiveView alloc] initWithFrame:frame device:device];
    MetalRoomRenderer *renderer = [[MetalRoomRenderer alloc] initWithMetalKitView:view];
        view.delegate = renderer;
    view.roomRenderer = renderer;
        [window setContentView:view];
    [window setInitialFirstResponder:view];
    [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Local event monitor to guarantee key events reach the renderer and prevent system beep
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                        handler:^NSEvent * _Nullable(NSEvent *event) {
      BOOL isDown = (event.type == NSEventTypeKeyDown);
      if ([renderer handleKeyEventWithCode:event.keyCode pressed:isDown]) {
        return nil; // consume to avoid beep
      }
      return event;
    }];

    // Global monitor as backup (cannot prevent beep, but ensures renderer sees keys)
    [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                         handler:^(NSEvent * _Nonnull event) {
      BOOL isDown = (event.type == NSEventTypeKeyDown);
      [renderer handleKeyEventWithCode:event.keyCode pressed:isDown];
    }];

    // Optional: spawn a simple UDP listener on localhost:9999 for external acceleration commands "ax ay az\n"
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      int sock = socket(AF_INET, SOCK_DGRAM, 0);
      if (sock < 0) return;
      struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
      addr.sin_family = AF_INET; addr.sin_port = htons(9999); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(sock); return; }
      for (;;) {
        char buf[256]; struct sockaddr_in from; socklen_t fromlen = sizeof(from);
        ssize_t n = recvfrom(sock, buf, sizeof(buf)-1, 0, (struct sockaddr*)&from, &fromlen);
        if (n <= 0) continue; buf[n] = '\0';
        float ax=0, ay=0, az=0; if (sscanf(buf, "%f %f %f", &ax, &ay, &az) == 3) {
          dispatch_async(dispatch_get_main_queue(), ^{ [renderer applyExternalAccelerationX:ax Y:ay Z:az]; });
        }
      }
    });

        [NSApp run];
    }
    return 0;
}
