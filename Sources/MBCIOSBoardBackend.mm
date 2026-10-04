#import "MBCIOSBoardBackend.h"
#import "MBCBoardMTLView.h"
#import "MBCBoardView.h"
#import "MBCMetalRenderer.h"
#import "MBCIOSOpenGLView.h"

@interface MBCIOSBoardBackend () <MTKViewDelegate>
@property (nonatomic, readwrite) MBCIOSRendererKind kind;
@property (nonatomic, strong, readwrite) UIView<MBCIOSBoardPresentation> *view;
@property (nonatomic, strong) MBCMetalRenderer *metalRenderer;
@end

@implementation MBCIOSBoardBackend

+ (void)deferRetirement:(MBCIOSBoardBackend *)backend completion:(void (^)(void))completion
{
    /* OpenGL destruction is deferred until the application can use its GPU
     * contexts again. The retained owner also keeps its view alive. */
    static NSMutableArray<NSDictionary *> *retirements;
    static id activationObserver;
    if (!retirements) retirements = [NSMutableArray array];
    NSMutableDictionary *entry = [@{@"backend": backend} mutableCopy];
    if (completion) entry[@"completion"] = [completion copy];
    [retirements addObject:entry];
    if (!activationObserver) {
        activationObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            NSArray<NSDictionary *> *pending = [retirements copy];
            [retirements removeAllObjects];
            [[NSNotificationCenter defaultCenter] removeObserver:activationObserver];
            activationObserver = nil;
            for (NSDictionary *item in pending) {
                MBCIOSBoardBackend *owner = item[@"backend"];
                [owner retireWithCompletion:item[@"completion"]];
            }
        }];
    }
}
+ (instancetype)backendWithKind:(MBCIOSRendererKind)kind frame:(CGRect)frame
                           board:(MBCBoard *)board variant:(MBCVariant)variant
                            side:(MBCSide)side boardStyle:(NSString *)boardStyle
                      pieceStyle:(NSString *)pieceStyle error:(NSError **)error
{
    if (error) *error = nil;
    MBCIOSBoardBackend *backend = [[self alloc] init];
    backend.kind = kind;
    @try {
        if (kind == MBCIOSRendererMetal) {
            id<MTLDevice> device = MBCMetalRenderer.defaultMTLDevice;
            if (!device) {
                if (error) *error = [NSError errorWithDomain:@"ChessRenderer" code:1
                    userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Metal is unavailable.", nil)}];
                return nil;
            }
            MBCBoardMTLView *view = [[MBCBoardMTLView alloc] initWithFrame:frame];
            view.device = device;
            view.paused = YES;
            view.enableSetNeedsDisplay = YES;
            backend.metalRenderer = [[MBCMetalRenderer alloc] initWithDevice:device mtkView:view];
            view.renderer = backend.metalRenderer;
            view.delegate = backend;
            backend.view = view;
        } else {
            backend.view = [[MBCBoardView alloc] initWithFrame:frame];
        }
        backend.view.translatesAutoresizingMaskIntoConstraints = NO;
        backend.view.userInteractionEnabled = NO;
        [backend.view setBoard:board];
        [backend.view startGame:variant playing:side];
        [backend.view setStyleForBoard:boardStyle pieces:pieceStyle];
        if (![backend prepareWithError:error]) return nil;
        return backend;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"ChessRenderer" code:2
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: NSLocalizedString(@"Unable to prepare the board renderer.", nil)}];
        return nil;
    }
}

- (BOOL)prepareWithError:(NSError **)error
{
    @try {
        if (![self.view iosPrepareRendererWithError:error]) return NO;
        if (self.kind == MBCIOSRendererOpenGL && ![(MBCIOSOpenGLView *)self.view lastFramePresented]) {
            if (error) *error = [NSError errorWithDomain:@"ChessRenderer" code:4
                userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to present the OpenGL board.", nil)}];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"ChessRenderer" code:2
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: NSLocalizedString(@"Unable to prepare the board renderer.", nil)}];
        return NO;
    }
}

- (void)setRenderingActive:(BOOL)active
{
    [self.view iosSetRenderingActive:active];
}

- (void)renderFirstFrameWithCompletion:(void (^)(NSError *error))completion
{
    @try {
        [self setRenderingActive:YES];
        if (self.kind == MBCIOSRendererMetal) {
            if (![(MTKView *)self.view currentDrawable]) {
                if (completion) completion([NSError errorWithDomain:@"ChessRenderer" code:5
                    userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"The Metal drawing surface is unavailable.", nil)}]);
                return;
            }
            [(MTKView *)self.view draw];
            MBCIOSBoardBackend *backend = self;
            [self.metalRenderer completePendingFramesWithCompletion:^{
                if (completion) completion(backend.metalRenderer.lastFrameError);
            }];
        } else {
            [self.view drawNow];
            BOOL presented = [(MBCIOSOpenGLView *)self.view lastFramePresented];
            NSError *error = presented ? nil : [NSError errorWithDomain:@"ChessRenderer" code:4
                userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Unable to present the OpenGL board.", nil)}];
            if (completion) completion(error);
        }
    } @catch (NSException *exception) {
        if (completion) completion([NSError errorWithDomain:@"ChessRenderer" code:6
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: NSLocalizedString(@"Unable to draw the board.", nil)}]);
    }
}

- (void)retireWithCompletion:(void (^)(void))completion
{
    if (self.kind == MBCIOSRendererOpenGL &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        [[self class] deferRetirement:self completion:completion];
        return;
    }
    MBCIOSBoardBackend *retiring = self;
    [self.view iosRetireRendererWithCompletion:^{
        (void)retiring;
        if (completion) completion();
    }];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    if ([self.view isOrientationTransitioning]) return;
    [self.metalRenderer drawableSizeWillChange:size];
}

- (void)drawInMTKView:(MTKView *)view
{
    [(MBCBoardMTLView *)self.view drawMetalContent];
}
@end
