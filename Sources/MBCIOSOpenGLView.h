#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* A desktop-GL renderer draws inside this view's EAGL context. Drawable sizes
 * are pixels; UIKit interaction coordinates remain view points. */
@interface MBCIOSOpenGLView : UIView
@property (nonatomic, readonly) CGSize drawableSize;
@property (nonatomic, readonly) BOOL drawablePrepared;
@property (nonatomic, readonly) BOOL hasGLContext;
@property (nonatomic, readonly, getter=isRendererRetired) BOOL rendererRetired;
@property (nonatomic, readonly, getter=isRenderingActive) BOOL renderingActive;
@property (nonatomic, readonly) NSInteger sampleCount;
@property (nonatomic, readonly) BOOL lastFramePresented;

- (void)performWithGLContext:(void (^)(void))block;
- (BOOL)prepareDrawableWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)presentDrawable;
- (void)releaseDrawable;

- (BOOL)iosPrepareRendererWithError:(NSError * _Nullable * _Nullable)error;
- (void)iosSetRenderingActive:(BOOL)active;
- (void)iosRetireRendererWithCompletion:(nullable void (^)(void))completion;

/* Subclasses implement drawing and delete their GL resources in these hooks.
 * Both execute with the view's native and desktop-GL contexts active. */
- (void)drawBoardFrame;
- (void)releaseGLResources;
@end

NS_ASSUME_NONNULL_END
