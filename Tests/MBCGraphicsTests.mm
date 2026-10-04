#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "MBCGraphicsTestDefaults.h"
#import "MBCIOSOpenGLView.h"
#import "MBCIOSRendererPreferences.h"
#import "MBCOpenGL.h"
#import "ChessIOSViewController.h"
#import "MBCBoard.h"
#import "MBCBoardView.h"
#import "MBCBoardViewTextures.h"
#import "MBCMetalCamera.h"

/* Exercise real board texture initialization without compiling the full
 * fixed-function scene's shaders on the simulator. */
@interface MBCStaticTextureBoardView : MBCBoardView
@end
@implementation MBCStaticTextureBoardView
- (void)drawPosition
{
    [self loadColors];
    glClear(GL_COLOR_BUFFER_BIT);
    [self presentDrawable];
}
@end


@implementation MBCGraphicsTestDefaults {
    NSString *_suiteName;
    Method _standardDefaultsMethod;
    IMP _originalImplementation;
    IMP _replacementImplementation;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSAssert(NSThread.isMainThread, @"Defaults fixtures run on the main thread.");
        NSUserDefaults *original = NSUserDefaults.standardUserDefaults;
        _suiteName = [@"com.apple.Chess.RendererTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:_suiteName];
        [_defaults registerDefaults:[original volatileDomainForName:NSRegistrationDomain] ?: @{}];
        _standardDefaultsMethod = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        _originalImplementation = method_getImplementation(_standardDefaultsMethod);
        NSUserDefaults *isolated = _defaults;
        _replacementImplementation = imp_implementationWithBlock(^NSUserDefaults *(id receiver) {
            (void)receiver;
            return isolated;
        });
        method_setImplementation(_standardDefaultsMethod, _replacementImplementation);
    }
    return self;
}

- (void)restore
{
    if (!_originalImplementation) return;
    method_setImplementation(_standardDefaultsMethod, _originalImplementation);
    imp_removeBlock(_replacementImplementation);
    _originalImplementation = NULL;
    [_defaults removePersistentDomainForName:_suiteName];
}

- (void)dealloc { [self restore]; }
@end

static void MBCOnMainThread(void (^block)(void))
{
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

/* Both views deliberately use the same list identifier. Their fixed-function
 * shader output must remain independent after another context has drawn. */
static void MBCDrawListPixel(MBCIOSOpenGLView *surface, BOOL compile,
                            float red, float blue, GLubyte pixel[4])
{
    [surface performWithGLContext:^{
        GLint previousFramebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
        GLuint texture = 0, framebuffer = 0;
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 8, 8, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, texture, 0);
        XCTAssertEqual(glCheckFramebufferStatus(GL_FRAMEBUFFER), (GLenum)GL_FRAMEBUFFER_COMPLETE);
        @try {
            glViewport(0, 0, 8, 8);
            glDisable(GL_LIGHTING);
            glDisable(GL_TEXTURE_2D);
            glDisable(GL_DEPTH_TEST);
            glDisable(GL_STENCIL_TEST);
            glDisable(GL_BLEND);
            glDisable(GL_CULL_FACE);
            glMatrixMode(GL_PROJECTION);
            glLoadIdentity();
            glMatrixMode(GL_MODELVIEW);
            glLoadIdentity();
            glClearColor(0, 0, 0, 1);
            glClear(GL_COLOR_BUFFER_BIT);
            if (compile) {
                glNewList(1, GL_COMPILE);
                glColor4f(red, 0, blue, 1);
                glBegin(GL_QUADS);
                glVertex3f(-1, -1, 0);
                glVertex3f(1, -1, 0);
                glVertex3f(1, 1, 0);
                glVertex3f(-1, 1, 0);
                glEnd();
                glEndList();
            }
            glCallList(1);
            glReadPixels(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            XCTAssertEqual(glGetError(), (GLenum)GL_NO_ERROR);
        } @finally {
            glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previousFramebuffer);
            glDeleteFramebuffers(1, &framebuffer);
            glDeleteTextures(1, &texture);
        }
    }];
}

static void MBCCheckTextureUpload(MBCIOSOpenGLView *surface)
{
    [surface performWithGLContext:^{
        GLint previousFramebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
        GLuint textures[2] = {}, framebuffer = 0;
        glGenTextures(2, textures);
        glBindTexture(GL_TEXTURE_2D, textures[0]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[0], 0);
        XCTAssertEqual(glCheckFramebufferStatus(GL_FRAMEBUFFER), (GLenum)GL_FRAMEBUFFER_COMPLETE);
        @try {
            /* BGRA rows: red/green, then blue/white. Texture Y is reversed
             * exactly as in the legacy camera setup. */
            const GLubyte texels[] = {0,0,255,128, 0,255,0,255, 255,0,0,255, 255,255,255,255};
            glBindTexture(GL_TEXTURE_2D, textures[1]);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_BGRA_EXT, GL_UNSIGNED_BYTE, texels);
            glEnable(GL_TEXTURE_2D);
            glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
            glMatrixMode(GL_TEXTURE);
            glLoadIdentity();
            glScalef(1, -1, 0);
            glMatrixMode(GL_MODELVIEW);
            glViewport(0, 0, 2, 2);
            glColor4f(1, 1, 1, 0.5);
            glBegin(GL_QUADS);
            glTexCoord2f(0, 0); glVertex3f(-1, -1, 0);
            glTexCoord2f(1, 0); glVertex3f(1, -1, 0);
            glTexCoord2f(1, 1); glVertex3f(1, 1, 0);
            glTexCoord2f(0, 1); glVertex3f(-1, 1, 0);
            glEnd();
            GLubyte pixels[16] = {};
            glReadPixels(0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            const GLubyte expected[] = {0,0,255,128, 255,255,255,128, 255,0,0,64, 0,255,0,128};
            for (NSUInteger i = 0; i < sizeof(pixels); ++i)
                XCTAssertEqualWithAccuracy(pixels[i], expected[i], 2);
            XCTAssertEqual(glGetError(), (GLenum)GL_NO_ERROR);
        } @finally {
            glMatrixMode(GL_TEXTURE);
            glLoadIdentity();
            glMatrixMode(GL_MODELVIEW);
            glDisable(GL_TEXTURE_2D);
            glBindTexture(GL_TEXTURE_2D, 0);
            glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previousFramebuffer);
            glDeleteFramebuffers(1, &framebuffer);
            glDeleteTextures(2, textures);
        }
    }];
}

@interface MBCGraphicsTests : XCTestCase
@end

@implementation MBCGraphicsTests
- (void)testMetalCameraBoardPickingRoundTrip
{
    MBCMetalCamera *camera = [[MBCMetalCamera alloc] initWithSize:simd_make_float2(1280, 960)];
    [camera updateSize:simd_make_float2(1280, 960)];
    camera.azimuth = 163;
    camera.elevation = 52;
    camera.distance = 185 * 1.15;
    [camera translateOnBoardPlaneBy:simd_make_float2(4, -3)];
    /* The camera uses single-precision matrices. Require a round trip within
     * one percent of a square and verify the selected row and column. */
    for (int square = 0; square < kBoardSquares; ++square) {
        MBCPosition center = {{(square & 7) * 10.f - 35.f, 0.f, 35.f - (square >> 3) * 10.f}};
        CGPoint point = [camera projectPositionFromModelToScreen:center];
        vector_float2 pixels = simd_make_float2(point.x, 960 - point.y);
        MBCPosition picked = [camera unProjectPositionFromScreenToModel:pixels knownY:0.f];
        XCTAssertEqualWithAccuracy(picked[0], center[0], .1, @"square %d", square);
        XCTAssertEqualWithAccuracy(picked[2], center[2], .1, @"square %d", square);
        XCTAssertEqual((int)((picked[0] + 40.f) / 10.f), square & 7);
        XCTAssertEqual((int)((40.f - picked[2]) / 10.f), square >> 3);
    }
}

- (void)testBoardPreflightInitializesStaticTextures
{
    MBCOnMainThread(^{
        UIWindowScene *scene = nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class] &&
                candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
        XCTAssertNotNil(scene);
        if (!scene) return;
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = scene.screen.bounds;
        window.windowLevel = UIWindowLevelNormal - 1;
        window.rootViewController = [[UIViewController alloc] init];
        MBCStaticTextureBoardView *view = [[MBCStaticTextureBoardView alloc]
            initWithFrame:CGRectMake(0, 0, 64, 64)];
        MBCBoard *board = [[MBCBoard alloc] init];
        [board startGame:kVarNormal];
        [view setBoard:board];
        [view startGame:kVarNormal playing:kBothSides];
        [view setStyleForBoard:@"Grass" pieces:@"Fur"];
        [window.rootViewController.view addSubview:view];
        window.hidden = NO;
        @try {
            NSError *error = nil;
            XCTAssertTrue([view iosPrepareRendererWithError:&error], @"%@", error);
            XCTAssertTrue(view.lastFramePresented);
        } @finally {
            [view iosRetireRendererWithCompletion:nil];
            window.hidden = YES;
            window.rootViewController = nil;
        }
    });
}

- (void)testIndependentDrawablesDisplayListsAndRetirement
{
    MBCOnMainThread(^{
        UIWindowScene *scene = nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class] &&
                candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
        XCTAssertNotNil(scene);
        if (!scene) return;
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = scene.screen.bounds;
        window.windowLevel = UIWindowLevelNormal - 1;
        window.rootViewController = [[UIViewController alloc] init];
        MBCIOSOpenGLView *first = [[MBCIOSOpenGLView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        MBCIOSOpenGLView *second = [[MBCIOSOpenGLView alloc] initWithFrame:CGRectMake(64, 0, 64, 64)];
        [window.rootViewController.view addSubview:first];
        [window.rootViewController.view addSubview:second];
        window.hidden = NO;
        @try {
            NSError *error = nil;
            XCTAssertTrue([first prepareDrawableWithError:&error], @"%@", error);
            XCTAssertTrue([second prepareDrawableWithError:&error], @"%@", error);
            XCTAssertGreaterThan(first.drawableSize.width, 0);
            XCTAssertGreaterThan(second.drawableSize.height, 0);
            [first performWithGLContext:^{
                GLint colorAttachmentType = 0;
                glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                    GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &colorAttachmentType);
                XCTAssertEqual(colorAttachmentType, GL_RENDERBUFFER);
                glLightModeli(GL_LIGHT_MODEL_LOCAL_VIEWER, 1);
                glLightModeli(GL_LIGHT_MODEL_COLOR_CONTROL, GL_SEPARATE_SPECULAR_COLOR);
                GLint localViewer = 0, colorControl = 0;
                glGetIntegerv(GL_LIGHT_MODEL_LOCAL_VIEWER, &localViewer);
                glGetIntegerv(GL_LIGHT_MODEL_COLOR_CONTROL, &colorControl);
                XCTAssertEqual(localViewer, 1);
                XCTAssertEqual(colorControl, GL_SEPARATE_SPECULAR_COLOR);
                XCTAssertEqual(glCheckFramebufferStatus(GL_FRAMEBUFFER), (GLenum)GL_FRAMEBUFFER_COMPLETE);
            }];
            GLubyte pixel[4] = {};
            MBCDrawListPixel(first, YES, 1, 0, pixel);
            XCTAssertGreaterThan(pixel[0], 224);
            XCTAssertLessThan(pixel[2], 16);
            MBCDrawListPixel(second, YES, 0, 1, pixel);
            XCTAssertGreaterThan(pixel[2], 224);
            XCTAssertLessThan(pixel[0], 16);
            MBCDrawListPixel(first, NO, 0, 0, pixel);
            XCTAssertGreaterThan(pixel[0], 224);
            XCTAssertLessThan(pixel[2], 16);
            [first iosRetireRendererWithCompletion:nil];
            XCTAssertFalse(first.hasGLContext);
            MBCDrawListPixel(second, NO, 0, 0, pixel);
            XCTAssertGreaterThan(pixel[2], 224);
            XCTAssertLessThan(pixel[0], 16);
            MBCCheckTextureUpload(second);
            second.frame = CGRectMake(64, 0, 80, 48);
            XCTAssertTrue([second prepareDrawableWithError:&error], @"%@", error);
            XCTAssertTrue([second presentDrawable]);
            XCTAssertTrue(second.lastFramePresented);
            [second performWithGLContext:^{
                /* A failed fixed-function program must not count as a
                 * successfully presented replacement renderer. */
                GLuint unlinkedProgram = glCreateProgram();
                XCTAssertNotEqual(unlinkedProgram, 0u);
                XCTAssertFalse([second presentDrawable]);
                XCTAssertFalse(second.lastFramePresented);
                glDeleteProgram(unlinkedProgram);
                XCTAssertTrue([second presentDrawable]);
            }];
        } @finally {
            [first iosRetireRendererWithCompletion:nil];
            [second iosRetireRendererWithCompletion:nil];
            window.hidden = YES;
            window.rootViewController = nil;
        }
    });
}
@end

@interface MBCRendererParticipant : NSObject <MBCIOSRendererParticipant>
@property (nonatomic) BOOL foreground;
@property (nonatomic) BOOL fails;
@property (nonatomic) NSUInteger preparationCount;
@property (nonatomic) NSUInteger requestCount;
@property (nonatomic) NSUInteger requestedRevision;
@property (nonatomic) MBCIOSRendererKind requestedKind;
@property (nonatomic, strong) MBCIOSBoardBackend *prepared;
@end

@implementation MBCRendererParticipant
- (BOOL)rendererSceneIsForeground { return self.foreground; }
- (MBCIOSBoardBackend *)prepareRenderer:(MBCIOSRendererKind)kind error:(NSError **)error
{
    ++self.preparationCount;
    if (self.fails) {
        if (error) *error = [NSError errorWithDomain:@"RendererTests" code:1 userInfo:nil];
        return nil;
    }
    return [[MBCIOSBoardBackend alloc] init];
}
- (void)requestRenderer:(MBCIOSRendererKind)kind revision:(NSUInteger)revision
              prepared:(MBCIOSBoardBackend *)prepared
{
    ++self.requestCount;
    self.requestedKind = kind;
    self.requestedRevision = revision;
    self.prepared = prepared;
}
@end

@interface MBCRendererPreferenceTests : XCTestCase
@end

@implementation MBCRendererPreferenceTests
- (void)testCancelAndUneditedLegacyStyles
{
    MBCOnMainThread(^{
        MBCGraphicsTestDefaults *fixture = [[MBCGraphicsTestDefaults alloc] init];
        NSUserDefaults *defaults = fixture.defaults;
        NSArray *keys = @[@"MBCSpeakMoves", @"MBCSpeakHumanMoves", @"MBCDefaultVoice", @"MBCAlternateVoice", MBCIOSRendererPreferenceKey];
        NSMutableDictionary *original = [NSMutableDictionary dictionary];
        for (NSString *key in keys) original[key] = [defaults objectForKey:key] ?: NSNull.null;
        @try {
            __block BOOL confirmed = YES;
            MBCIOSPreferencesViewController *cancelled = [[MBCIOSPreferencesViewController alloc]
                initWithBoardStyle:@"Grass" pieceStyle:@"Fur" autoRotateBoard:YES
                completion:^(BOOL accepted, NSString *board, NSString *pieces, BOOL rotate) { confirmed = accepted; }];
            cancelled.rendererKind = MBCIOSRendererOpenGL;
            [cancelled loadViewIfNeeded];
            [cancelled cancelSelection];
            XCTAssertFalse(confirmed);
            for (NSString *key in keys)
                XCTAssertEqualObjects([defaults objectForKey:key] ?: NSNull.null, original[key]);
            __block NSString *boardStyle = nil, *pieceStyle = nil;
            MBCIOSPreferencesViewController *accepted = [[MBCIOSPreferencesViewController alloc]
                initWithBoardStyle:@"Grass" pieceStyle:@"Fur" autoRotateBoard:YES
                completion:^(BOOL confirmed, NSString *board, NSString *pieces, BOOL rotate) {
                    XCTAssertTrue(confirmed);
                    boardStyle = board;
                    pieceStyle = pieces;
                }];
            accepted.rendererKind = MBCIOSRendererMetal;
            [accepted loadViewIfNeeded];
            [accepted commitSelection];
            XCTAssertEqualObjects(boardStyle, @"Grass");
            XCTAssertEqualObjects(pieceStyle, @"Fur");
        } @finally {
            [fixture restore];
        }
    });
}

- (void)testPreflightFailurePreservesPreferenceAndSuccessfulRequestIncludesBackgroundScenes
{
    MBCOnMainThread(^{
        MBCGraphicsTestDefaults *fixture = [[MBCGraphicsTestDefaults alloc] init];
        NSUserDefaults *defaults = fixture.defaults;
        MBCIOSRendererPreferences *preferences = [[MBCIOSRendererPreferences alloc] init];
        MBCRendererParticipant *foreground = [[MBCRendererParticipant alloc] init];
        foreground.foreground = YES;
        foreground.fails = YES;
        MBCRendererParticipant *background = [[MBCRendererParticipant alloc] init];
        [preferences addParticipant:foreground];
        [preferences addParticipant:background];
        @try {
            [defaults removeObjectForKey:MBCIOSRendererPreferenceKey];
            XCTAssertEqual(preferences.desiredRenderer, MBCIOSRendererMetal);
            NSUInteger revision = preferences.revision;
            NSError *error = nil;
            XCTAssertFalse([preferences selectRenderer:MBCIOSRendererOpenGL error:&error]);
            XCTAssertNotNil(error);
            XCTAssertEqual(preferences.desiredRenderer, MBCIOSRendererMetal);
            XCTAssertEqual(preferences.revision, revision);
            XCTAssertEqual(foreground.requestCount, 0u);
            XCTAssertEqual(background.preparationCount, 0u);
            foreground.fails = NO;
            XCTAssertTrue([preferences selectRenderer:MBCIOSRendererOpenGL error:&error]);
            XCTAssertEqual(preferences.desiredRenderer, MBCIOSRendererOpenGL);
            XCTAssertGreaterThan(preferences.revision, revision);
            XCTAssertEqual(foreground.requestCount, 1u);
            XCTAssertNotNil(foreground.prepared);
            XCTAssertEqual(background.requestCount, 1u);
            XCTAssertNil(background.prepared);
            XCTAssertEqual(background.requestedRevision, foreground.requestedRevision);
            XCTAssertEqual(background.requestedKind, MBCIOSRendererOpenGL);
        } @finally {
            [fixture restore];
        }
    });
}
@end
