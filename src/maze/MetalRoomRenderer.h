#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

@interface MetalRoomRenderer : NSObject<MTKViewDelegate>
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
- (BOOL)handleKeyEventWithCode:(unsigned short)keyCode pressed:(BOOL)isPressed;
- (void)applyExternalAccelerationX:(float)ax Y:(float)ay Z:(float)az; // Optional API hook
@end
