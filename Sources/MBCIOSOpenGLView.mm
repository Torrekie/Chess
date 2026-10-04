#import "MBCIOSOpenGLView.h"
#import "MBCIOSGLBridge.h"

#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <QuartzCore/CAEAGLLayer.h>
#include "../ThirdParty/gl4es/include/GL/gl.h"
#include <cmath>

static NSString * const MBCIOSOpenGLErrorDomain = @"ChessOpenGLError";

static NSError *MBCIOSOpenGLError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:MBCIOSOpenGLErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation MBCIOSOpenGLView {
    EAGLContext *_context;
    void *_glState;
    NSError *_initializationError;
    CGSize _drawableSize;
    CGSize _allocatedBoundsSize;
    CGFloat _allocatedScale;
    GLuint _drawableFramebuffer;
    GLuint _drawableColor;
    GLuint _multisampleFramebuffer;
    GLuint _multisampleColor;
    GLuint _depthBuffer;
    GLuint _stencilBuffer;
    NSInteger _sampleCount;
    BOOL _rendererRetired;
    BOOL _renderingActive;
    BOOL _frameScheduled;
    BOOL _needsFrame;
    BOOL _lastFramePresented;
}

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) [self initializeOpenGLSurface];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) [self initializeOpenGLSurface];
    return self;
}

- (void)initializeOpenGLSurface
{
    NSAssert([NSThread isMainThread], @"OpenGL views must be created on the main thread.");
    self.contentScaleFactor = UIScreen.mainScreen.scale;
    self.backgroundColor = UIColor.blackColor;
    self.opaque = YES;
    CAEAGLLayer *drawable = (CAEAGLLayer *)self.layer;
    drawable.opaque = YES;
    drawable.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO,
                                    kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    _sampleCount = 1;
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_context) {
        _initializationError = MBCIOSOpenGLError(1, NSLocalizedString(@"OpenGL ES could not be initialized.", nil));
        return;
    }
    EAGLContext *previousContext = EAGLContext.currentContext;
    void *previousState = MBCIOSGLCurrentState();
    if ([EAGLContext setCurrentContext:_context] && MBCIOSGLInitialize()) {
        _glState = MBCIOSGLCreateState();
    }
    [EAGLContext setCurrentContext:previousContext];
    MBCIOSGLActivateState(previousState);
    if (!_glState) {
        _initializationError = MBCIOSOpenGLError(2, NSLocalizedString(@"The OpenGL renderer could not be initialized.", nil));
        _context = nil;
    }
}

- (CGSize)drawableSize { return _drawableSize; }
- (BOOL)drawablePrepared { return _drawableFramebuffer != 0; }
- (BOOL)hasGLContext { return _context != nil && _glState != NULL && !_rendererRetired; }
- (BOOL)isRendererRetired { return _rendererRetired; }
- (BOOL)isRenderingActive { return _renderingActive; }
- (NSInteger)sampleCount { return _sampleCount; }
- (BOOL)lastFramePresented { return _lastFramePresented; }

- (void)performWithGLContext:(void (^)(void))block
{
    NSAssert([NSThread isMainThread], @"OpenGL rendering must run on the main thread.");
    if (!block || !self.hasGLContext) return;
    EAGLContext *context = _context;
    EAGLContext *previousContext = EAGLContext.currentContext;
    void *previousState = MBCIOSGLCurrentState();
    void *state = _glState;
    int previousWidth = 0, previousHeight = 0;
    MBCIOSGLGetDrawableSize(&previousWidth, &previousHeight);
    if (![EAGLContext setCurrentContext:context]) return;
    MBCIOSGLActivateState(state);
    MBCIOSGLSetDrawableSize((int)_drawableSize.width, (int)_drawableSize.height);
    @try {
        block();
    } @finally {
        if (_glState != state) {
            if (previousState == state) previousState = NULL;
            if (previousContext == context) previousContext = nil;
        }
        [EAGLContext setCurrentContext:previousContext];
        MBCIOSGLActivateState(previousState);
        MBCIOSGLSetDrawableSize(previousWidth, previousHeight);
    }
}

- (BOOL)allocateRenderbuffer:(GLuint *)renderbuffer format:(GLenum)format samples:(int)samples
{
    glGenRenderbuffers(1, renderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, *renderbuffer);
    if (!MBCIOSGLDriverAllocateStorage(format, samples, (int)_drawableSize.width,
                                      (int)_drawableSize.height)) return NO;
    return MBCIOSGLSyncRenderbufferStorage(*renderbuffer, format, (int)_drawableSize.width,
                                           (int)_drawableSize.height);
}

- (void)deleteDepthAndStencil
{
    if (_depthBuffer) glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, 0);
    if (_stencilBuffer) glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, 0);
    if (_stencilBuffer && _stencilBuffer != _depthBuffer) glDeleteRenderbuffers(1, &_stencilBuffer);
    if (_depthBuffer) glDeleteRenderbuffers(1, &_depthBuffer);
    _depthBuffer = 0;
    _stencilBuffer = 0;
}

- (BOOL)allocateDepthAndStencilWithSamples:(int)samples
{
    if (MBCIOSGLDriverHasExtension("GL_OES_packed_depth_stencil")) {
        if ([self allocateRenderbuffer:&_depthBuffer format:GL_DEPTH24_STENCIL8 samples:samples]) {
            _stencilBuffer = _depthBuffer;
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _stencilBuffer);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) return YES;
        }
        [self deleteDepthAndStencil];
        MBCIOSGLDriverClearErrors();
    }
    GLenum depthFormat = MBCIOSGLDriverHasExtension("GL_OES_depth24") ? GL_DEPTH_COMPONENT24 : GL_DEPTH_COMPONENT16;
    if (![self allocateRenderbuffer:&_depthBuffer format:depthFormat samples:samples] ||
        ![self allocateRenderbuffer:&_stencilBuffer format:GL_STENCIL_INDEX8 samples:samples]) return NO;
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _stencilBuffer);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

- (void)deleteMultisampleDrawable
{
    glBindFramebuffer(GL_FRAMEBUFFER, _multisampleFramebuffer);
    [self deleteDepthAndStencil];
    glBindFramebuffer(GL_FRAMEBUFFER, _drawableFramebuffer);
    if (_multisampleColor) glDeleteRenderbuffers(1, &_multisampleColor);
    if (_multisampleFramebuffer) glDeleteFramebuffers(1, &_multisampleFramebuffer);
    _multisampleColor = 0;
    _multisampleFramebuffer = 0;
    _sampleCount = 1;
}

- (void)deleteDrawableObjects
{
    glBindFramebuffer(GL_FRAMEBUFFER, _multisampleFramebuffer ?: _drawableFramebuffer);
    [self deleteDepthAndStencil];
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (_multisampleColor) glDeleteRenderbuffers(1, &_multisampleColor);
    if (_drawableColor) glDeleteRenderbuffers(1, &_drawableColor);
    if (_multisampleFramebuffer) glDeleteFramebuffers(1, &_multisampleFramebuffer);
    if (_drawableFramebuffer) glDeleteFramebuffers(1, &_drawableFramebuffer);
    _multisampleColor = 0;
    _drawableColor = 0;
    _multisampleFramebuffer = 0;
    _drawableFramebuffer = 0;
    _sampleCount = 1;
    _drawableSize = CGSizeZero;
    _allocatedBoundsSize = CGSizeZero;
    _allocatedScale = 0;
    _lastFramePresented = NO;
}

- (BOOL)prepareDrawableWithError:(NSError **)error
{
    NSAssert([NSThread isMainThread], @"OpenGL drawables must be prepared on the main thread.");
    if (!self.hasGLContext) {
        if (error) *error = _initializationError ?: MBCIOSOpenGLError(3, NSLocalizedString(@"The OpenGL renderer is unavailable.", nil));
        return NO;
    }
    CGSize size = self.bounds.size;
    CGFloat scale = self.contentScaleFactor;
    if (size.width <= 0 || size.height <= 0 || scale <= 0 ||
        !std::isfinite(size.width) || !std::isfinite(size.height) || !std::isfinite(scale)) {
        if (error) *error = MBCIOSOpenGLError(4, NSLocalizedString(@"The board has no drawable area.", nil));
        return NO;
    }
    __block BOOL prepared = NO;
    __block NSError *failure = nil;
    [self performWithGLContext:^{
        if (self->_drawableFramebuffer && CGSizeEqualToSize(size, self->_allocatedBoundsSize) &&
            scale == self->_allocatedScale) {
            glBindFramebuffer(GL_FRAMEBUFFER, self->_multisampleFramebuffer ?: self->_drawableFramebuffer);
            prepared = YES;
            return;
        }
        [self deleteDrawableObjects];
        MBCIOSGLDriverClearErrors();
        for (int i = 0; i < 32 && glGetError() != GL_NO_ERROR; ++i) {}
        glGenFramebuffers(1, &self->_drawableFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, self->_drawableFramebuffer);
        glGenRenderbuffers(1, &self->_drawableColor);
        glBindRenderbuffer(GL_RENDERBUFFER, self->_drawableColor);
        if (![self->_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer]) {
            failure = MBCIOSOpenGLError(5, NSLocalizedString(@"The OpenGL drawable could not be allocated.", nil));
            [self deleteDrawableObjects];
            return;
        }
        GLint width = 0, height = 0;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
        if (width <= 0 || height <= 0 ||
            !MBCIOSGLSyncRenderbufferStorage(self->_drawableColor, GL_RGBA8, width, height)) {
            failure = MBCIOSOpenGLError(6, NSLocalizedString(@"The OpenGL drawable has an invalid size.", nil));
            [self deleteDrawableObjects];
            return;
        }
        self->_drawableSize = CGSizeMake(width, height);
        MBCIOSGLSetDrawableSize(width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self->_drawableColor);
        if (MBCIOSGLDriverMaximumSamples() >= 4) {
            glGenFramebuffers(1, &self->_multisampleFramebuffer);
            glBindFramebuffer(GL_FRAMEBUFFER, self->_multisampleFramebuffer);
            if ([self allocateRenderbuffer:&self->_multisampleColor format:GL_RGBA8 samples:4]) {
                glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self->_multisampleColor);
                if ([self allocateDepthAndStencilWithSamples:4]) self->_sampleCount = 4;
            }
            if (self->_sampleCount != 4) [self deleteMultisampleDrawable];
        }
        if (self->_sampleCount == 1 && ![self allocateDepthAndStencilWithSamples:1]) {
            failure = MBCIOSOpenGLError(7, NSLocalizedString(@"The OpenGL depth and stencil buffers could not be allocated.", nil));
            [self deleteDrawableObjects];
            return;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, self->_multisampleFramebuffer ?: self->_drawableFramebuffer);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        GLenum graphicsError = glGetError();
        if (status != GL_FRAMEBUFFER_COMPLETE || graphicsError != GL_NO_ERROR) {
            failure = [NSError errorWithDomain:MBCIOSOpenGLErrorDomain code:8
                userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"The OpenGL framebuffer is incomplete.", nil),
                           @"FramebufferStatus": @(status), @"OpenGLError": @(graphicsError)}];
            [self deleteDrawableObjects];
            return;
        }
        self->_allocatedBoundsSize = size;
        self->_allocatedScale = scale;
        glViewport(0, 0, width, height);
        prepared = YES;
    }];
    if (!prepared && error) *error = failure ?: MBCIOSOpenGLError(9, NSLocalizedString(@"The OpenGL context could not be activated.", nil));
    return prepared;
}

- (BOOL)presentDrawable
{
    _lastFramePresented = NO;
    if (!self.drawablePrepared || _rendererRetired) return NO;
    __block BOOL presented = NO;
    [self performWithGLContext:^{
        glFlush();
        if (!MBCIOSGLProgramsLinked()) return;
        if (self->_multisampleFramebuffer &&
            !MBCIOSGLDriverResolveMultisample(self->_multisampleFramebuffer, self->_drawableFramebuffer)) {
            glBindFramebuffer(GL_FRAMEBUFFER, self->_multisampleFramebuffer);
            return;
        }
        glBindFramebuffer(GL_FRAMEBUFFER, self->_drawableFramebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, self->_drawableColor);
        presented = [self->_context presentRenderbuffer:GL_RENDERBUFFER];
        glBindFramebuffer(GL_FRAMEBUFFER, self->_multisampleFramebuffer ?: self->_drawableFramebuffer);
    }];
    _lastFramePresented = presented;
    return presented;
}

- (void)releaseDrawable
{
    [self performWithGLContext:^{
        glFinish();
        [self deleteDrawableObjects];
    }];
}

- (BOOL)iosPrepareRendererWithError:(NSError **)error
{
    return [self prepareDrawableWithError:error];
}

- (void)iosSetRenderingActive:(BOOL)active
{
    NSAssert([NSThread isMainThread], @"OpenGL views must be activated on the main thread.");
    if (_renderingActive && !active) {
        [self performWithGLContext:^{ glFinish(); }];
    }
    _renderingActive = active && !_rendererRetired;
    if (_renderingActive) [self setNeedsDisplay];
}

- (void)iosRetireRendererWithCompletion:(void (^)(void))completion
{
    NSAssert([NSThread isMainThread], @"OpenGL views must be retired on the main thread.");
    if (!_rendererRetired) {
        _renderingActive = NO;
        _needsFrame = NO;
        [self performWithGLContext:^{
            [self releaseGLResources];
            glFinish();
            [self deleteDrawableObjects];
            MBCIOSGLDestroyState(self->_glState);
            self->_glState = NULL;
        }];
        _rendererRetired = YES;
        _context = nil;
    }
    if (completion) completion();
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self setNeedsDisplay];
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window) {
        self.contentScaleFactor = self.window.screen.scale;
        [self setNeedsDisplay];
    }
}

- (void)setNeedsDisplay
{
    NSAssert([NSThread isMainThread], @"OpenGL drawing must be scheduled on the main thread.");
    if (_rendererRetired) return;
    _needsFrame = YES;
    if (!_renderingActive || _frameScheduled) return;
    _frameScheduled = YES;
    __weak MBCIOSOpenGLView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MBCIOSOpenGLView *view = weakSelf;
        if (!view) return;
        view->_frameScheduled = NO;
        if (!view->_renderingActive || view->_rendererRetired || !view->_needsFrame || !view.window) return;
        view->_needsFrame = NO;
        if (![view prepareDrawableWithError:nil]) return;
        [view performWithGLContext:^{ [view drawBoardFrame]; }];
    });
}

- (void)drawBoardFrame {}
- (void)releaseGLResources {}

- (void)dealloc
{
    if (_glState) {
        EAGLContext *previousContext = EAGLContext.currentContext;
        void *previousState = MBCIOSGLCurrentState();
        int previousWidth = 0, previousHeight = 0;
        MBCIOSGLGetDrawableSize(&previousWidth, &previousHeight);
        if ([EAGLContext setCurrentContext:_context]) {
            MBCIOSGLActivateState(_glState);
            MBCIOSGLSetDrawableSize((int)_drawableSize.width, (int)_drawableSize.height);
            glFinish();
            [self deleteDrawableObjects];
            MBCIOSGLDestroyState(_glState);
            if (previousState == _glState) {
                previousState = NULL;
                previousWidth = previousHeight = 0;
            }
        }
        [EAGLContext setCurrentContext:previousContext == _context ? nil : previousContext];
        MBCIOSGLActivateState(previousState);
        MBCIOSGLSetDrawableSize(previousWidth, previousHeight);
    }
}

@end
