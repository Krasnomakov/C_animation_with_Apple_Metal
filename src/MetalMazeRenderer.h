#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

@interface MetalMazeRenderer : NSObject<MTKViewDelegate>
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
- (BOOL)handleKeyEventWithCode:(unsigned short)keyCode pressed:(BOOL)isPressed;
- (void)activateManualControl;
@end
