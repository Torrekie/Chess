#import <XCTest/XCTest.h>
#import "MBCGraphicsTestDefaults.h"
#import "ChessIOSViewController.h"
#import "MBCBoard.h"
#import "MBCBoardMTLView.h"
#import "MBCBoardView.h"
#import "MBCIOSBoardBackend.h"
#import "MBCIOSChessEngine.h"
#import "MBCIOSGameLibrary.h"
#import "MBCIOSRendererPreferences.h"
#import "MBCIOSChessSquareElement.h"
#import "MBCIOSOpenGLView.h"
#import "MBCOpenGL.h"
#import "MBCPlayer.h"
#import "MBCUserDefaults.h"

/* Declare the shell's existing internal seams without changing the app API. */
@interface ChessIOSViewController (RendererTests) <MBCIOSRendererParticipant>
@property (nonatomic, strong) MBCIOSBoardBackend *boardBackend;
@property (nonatomic, strong) MBCIOSBoardBackend *preparedBoardBackend;
@property (nonatomic, strong) MBCIOSChessEngine *engine;
@property (nonatomic, strong) MBCIOSGameLibrary *gameLibrary;
@property (nonatomic, strong) NSMutableArray<MBCMove *> *pendingMoveAnimations;
@property (nonatomic, strong) MBCMove *activeMoveAnimation;
@property (nonatomic, strong) NSMutableDictionary *gameMetadata;
@property (nonatomic) BOOL rendererChanging;
@property (nonatomic) BOOL rendererChangePending;
- (BOOL)rendererSceneIsForeground;
- (void)enqueueMove:(MBCMove *)move;
- (void)applyPendingRendererChange;
- (void)handleApplicationDidBecomeActive:(NSNotification *)notification;
- (void)cancelMoveAnimation;
- (void)finishMoveAnimation;
- (NSDictionary *)currentGameSnapshot;
- (void)showDocumentError:(NSError *)error;
- (void)updateGameCenterAchievementsForMove:(MBCMove *)move remote:(BOOL)remote;
@end

/* Autosaves and legacy migration stay inside this test's temporary library.
 * Foreground eligibility is controllable without backgrounding the host. */
@interface MBCRendererTestController : ChessIOSViewController <MBCIOSRendererParticipant>
@property (nonatomic, strong) MBCIOSGameLibrary *isolatedLibrary;
@property (nonatomic) BOOL eligibleForRendering;
@property (nonatomic, strong) NSError *rendererError;
@end

@implementation MBCRendererTestController
- (MBCIOSGameLibrary *)gameLibrary { return self.isolatedLibrary; }
- (void)setGameLibrary:(MBCIOSGameLibrary *)library { (void)library; }
- (BOOL)rendererSceneIsForeground
{
    return self.eligibleForRendering && [super rendererSceneIsForeground];
}
- (void)showDocumentError:(NSError *)error { self.rendererError = error; }
- (void)updateGameCenterAchievementsForMove:(MBCMove *)move remote:(BOOL)remote
{
    (void)move;
    (void)remote;
}
@end

/* Delayed frame completions isolate switching races from GPU availability. */
@interface MBCRendererStateTestView : MBCBoardMTLView
@property (nonatomic, copy) NSDictionary *presentationState;
@end
@implementation MBCRendererStateTestView
- (void)setStyleForBoard:(NSString *)board pieces:(NSString *)pieces { (void)board; (void)pieces; }
- (void)drawNow {}
- (void)needsUpdate {}
- (NSDictionary *)iosCapturePresentationState { return self.presentationState ?: @{}; }
- (void)iosRestorePresentationState:(NSDictionary *)state { self.presentationState = state; }
@end

@interface MBCDelayedFrameBackend : MBCIOSBoardBackend
@property (nonatomic) MBCIOSRendererKind testKind;
@property (nonatomic, strong) MBCRendererStateTestView *testView;
@property (nonatomic, copy) void (^frameCompletion)(NSError *);
@property (nonatomic) NSUInteger retirementCount;
- (void)completeFrame;
@end
@implementation MBCDelayedFrameBackend
- (MBCIOSRendererKind)kind { return self.testKind; }
- (UIView<MBCIOSBoardPresentation> *)view { return self.testView; }
- (BOOL)prepareWithError:(NSError **)error { if (error) *error = nil; return YES; }
- (void)setRenderingActive:(BOOL)active { (void)active; }
- (void)renderFirstFrameWithCompletion:(void (^)(NSError *))completion { self.frameCompletion = completion; }
- (void)retireWithCompletion:(void (^)(void))completion
{
    ++self.retirementCount;
    if (completion) completion();
}
- (void)completeFrame
{
    void (^completion)(NSError *) = self.frameCompletion;
    self.frameCompletion = nil;
    if (completion) completion(nil);
}
@end

@interface MBCRendererStateTestController : MBCRendererTestController
@property (nonatomic) NSUInteger preparationCount;
@end
@implementation MBCRendererStateTestController
- (void)loadView { self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 512, 384)]; }
- (void)viewDidLoad {}
- (BOOL)rendererSceneIsForeground { return self.eligibleForRendering; }
- (void)updateLoadedGameState {}
- (void)autosaveCurrentGame {}
- (MBCIOSBoardBackend *)prepareRenderer:(MBCIOSRendererKind)kind error:(NSError **)error
{
    if (error) *error = nil;
    ++self.preparationCount;
    MBCDelayedFrameBackend *backend = [[MBCDelayedFrameBackend alloc] init];
    backend.testKind = kind;
    backend.testView = [[MBCRendererStateTestView alloc] initWithFrame:self.view.bounds];
    backend.testView.translatesAutoresizingMaskIntoConstraints = NO;
    return backend;
}
@end

@interface MBCTerminalRendererTestBoard : MBCBoard
@end
@implementation MBCTerminalRendererTestBoard
- (MBCMoveCode)outcome { return kCmdBlackWins; }
@end

@interface MBCRendererTestEngine : MBCIOSChessEngine
@property (nonatomic, copy) NSURL *isolatedDirectory;
@end

@implementation MBCRendererTestEngine
- (NSString *)workingDirectory
{
    if (![[NSFileManager defaultManager] createDirectoryAtURL:self.isolatedDirectory
        withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return self.isolatedDirectory.path;
}
@end

static void MBCSwitchTestOnMain(void (^block)(void))
{
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

@interface MBCRendererSwitchTests : XCTestCase
@end

@implementation MBCRendererSwitchTests
- (MBCRendererStateTestController *)stateControllerWithBoard:(MBCBoard *)board
{
    MBCRendererStateTestController *controller = [[MBCRendererStateTestController alloc] init];
    controller.eligibleForRendering = YES;
    controller.board = board;
    controller.variant = kVarNormal;
    controller.side = kBothSides;
    controller.boardStyle = controller.pieceStyle = @"Wood";
    controller.gameMetadata = [NSMutableDictionary dictionary];
    controller.pendingMoveAnimations = [NSMutableArray array];
    controller.engine = [[MBCIOSChessEngine alloc] init];
    MBCDelayedFrameBackend *initial = (id)[controller prepareRenderer:MBCIOSRendererMetal error:nil];
    controller.boardBackend = initial;
    controller.boardView = initial.view;
    [initial.view setBoard:board];
    [initial.view startGame:kVarNormal playing:kBothSides];
    [controller.view addSubview:initial.view];
    controller.preparationCount = 0;
    return controller;
}

- (void)testSupersededPreflightIsRetiredAndLatestFramePreservesPresentationCommands
{
    MBCSwitchTestOnMain(^{
        MBCBoard *board = [[MBCBoard alloc] init];
        [board startGame:kVarNormal];
        MBCRendererStateTestController *controller = [self stateControllerWithBoard:board];
        MBCIOSChessEngine *engine = controller.engine;
        MBCDelayedFrameBackend *first = (id)[controller prepareRenderer:MBCIOSRendererOpenGL error:nil];
        [controller requestRenderer:MBCIOSRendererOpenGL revision:2 prepared:first];
        [controller applyPendingRendererChange];
        XCTAssertTrue(controller.rendererChanging);
        MBCDelayedFrameBackend *second = (id)[controller prepareRenderer:MBCIOSRendererOpenGL error:nil];
        [controller requestRenderer:MBCIOSRendererOpenGL revision:3 prepared:second];
        MBCDelayedFrameBackend *latest = (id)[controller prepareRenderer:MBCIOSRendererOpenGL error:nil];
        [controller requestRenderer:MBCIOSRendererOpenGL revision:4 prepared:latest];
        XCTAssertEqual(first.retirementCount, 0u);
        XCTAssertEqual(second.retirementCount, 1u);
        [first completeFrame];
        XCTAssertEqual(first.retirementCount, 1u);
        XCTAssertEqual(controller.preparedBoardBackend, latest);
        XCTAssertNotNil(latest.frameCompletion);
        XCTAssertEqual(controller.preparationCount, 3u);
        NSDictionary *latestState = @{@"azimuth": @0, @"elevation": @60, @"edgeLabels": @NO};
        [controller.boardView iosRestorePresentationState:latestState];
        [latest completeFrame];
        XCTAssertEqual(controller.boardBackend, latest);
        XCTAssertEqualObjects([controller.boardView iosCapturePresentationState], latestState);
        XCTAssertEqual(controller.board, board);
        XCTAssertEqual(controller.engine, engine);
        XCTAssertEqual(engine.moveSource, latest.view);
        XCTAssertEqual(latest.retirementCount, 0u);
        XCTAssertFalse(controller.rendererChanging);
        XCTAssertFalse(controller.rendererChangePending);
    });
}

- (void)testFinalMoveCompletionAppliesPendingRenderer
{
    MBCSwitchTestOnMain(^{
        MBCTerminalRendererTestBoard *board = [[MBCTerminalRendererTestBoard alloc] init];
        [board startGame:kVarNormal];
        MBCRendererStateTestController *controller = [self stateControllerWithBoard:board];
        MBCMove *move = [MBCMove moveFromEngineMove:@"e2e4"];
        [board makeMove:move];
        controller.activeMoveAnimation = move;
        MBCDelayedFrameBackend *next = (id)[controller prepareRenderer:MBCIOSRendererOpenGL error:nil];
        [controller requestRenderer:MBCIOSRendererOpenGL revision:2 prepared:next];
        [controller applyPendingRendererChange];
        XCTAssertFalse(controller.rendererChanging);
        [controller finishMoveAnimation];
        XCTAssertNil(controller.activeMoveAnimation);
        XCTAssertTrue(controller.rendererChanging);
        XCTAssertNotNil(next.frameCompletion);
        [next completeFrame];
        XCTAssertEqual(controller.boardBackend, next);
        XCTAssertEqual(controller.board, board);
        XCTAssertEqual(controller.board.outcome, kCmdBlackWins);
    });
}

- (BOOL)waitForController:(MBCRendererTestController *)controller
                 renderer:(MBCIOSRendererKind)renderer moves:(int)moves
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        (void)object;
        (void)bindings;
        return controller.rendererError ||
            (controller.boardBackend.kind == renderer && !controller.rendererChanging &&
             !controller.activeMoveAnimation && controller.pendingMoveAnimations.count == 0 &&
             controller.board.numMoves == moves);
    }];
    XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:controller];
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[expectation] timeout:20];
    XCTAssertEqual(result, XCTWaiterResultCompleted);
    XCTAssertNil(controller.rendererError, @"%@", controller.rendererError);
    XCTAssertEqual(controller.boardBackend.kind, renderer);
    return result == XCTWaiterResultCompleted && !controller.rendererError &&
        controller.boardBackend.kind == renderer;
}

- (void)assertCamera:(NSDictionary *)expected view:(UIView<MBCIOSBoardPresentation> *)view
{
    NSDictionary *actual = [view iosCapturePresentationState];
    for (NSString *key in @[@"azimuth", @"elevation", @"zoomScale", @"panX", @"panZ"])
        XCTAssertEqualWithAccuracy([actual[key] doubleValue], [expected[key] doubleValue], 0.001,
                                   @"Camera field %@", key);
    XCTAssertEqualObjects(actual[@"edgeLabels"], expected[@"edgeLabels"]);
}

- (NSDictionary *)squareAccessibilityForView:(UIView<MBCIOSBoardPresentation> *)view
{
    NSMutableDictionary *squares = [NSMutableDictionary dictionary];
    for (MBCIOSChessSquareElement *element in view.accessibilityElements) {
        if (![element.accessibilityIdentifier hasPrefix:@"square-"]) continue;
        MBCPosition center = [view squareToPosition:element.square];
        CGPoint projected = [view iosProjectPosition:center];
        MBCPosition picked = [view iosUnprojectPoint:projected];
        XCTAssertEqual([view positionToSquare:&picked], element.square);
        XCTAssertEqualWithAccuracy(picked[0], center[0], 0.02);
        XCTAssertEqualWithAccuracy(picked[2], center[2], 0.02);
        XCTAssertTrue(CGRectContainsPoint(element.accessibilityFrameInContainerSpace, projected));
        squares[element.accessibilityIdentifier] = @{
            @"label": element.accessibilityLabel ?: @"",
            @"traits": @(element.accessibilityTraits),
            @"activatable": @(element.canActivate)
        };
    }
    XCTAssertEqual(squares.count, 64u);
    return squares;
}

- (void)testRealRendererSwitchPreservesGameAtAnimationBoundaryAndAdoptsAfterActivation
{
#if TARGET_OS_SIMULATOR
    XCTSkip(@"Full fixed-function scene shader compilation is validated on physical hardware.");
#endif
    MBCSwitchTestOnMain(^{
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

        MBCGraphicsTestDefaults *fixture = [[MBCGraphicsTestDefaults alloc] init];
        NSUserDefaults *defaults = fixture.defaults;
        BOOL originalIdleTimer = UIApplication.sharedApplication.idleTimerDisabled;
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"ChessRendererTests-" stringByAppendingString:NSUUID.UUID.UUIDString]]
            isDirectory:YES];
        MBCRendererTestController *controller = [[MBCRendererTestController alloc] init];
        controller.isolatedLibrary = [[MBCIOSGameLibrary alloc] initWithDirectoryURL:directory];
        controller.startsWithNewLibraryGame = YES;
        controller.defersInitialLibrarySaveForImport = YES;
        controller.eligibleForRendering = YES;
        MBCIOSRendererPreferences *preferences = [[MBCIOSRendererPreferences alloc] init];
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = scene.screen.bounds;
        window.windowLevel = UIWindowLevelNormal - 1;
        __block NSUInteger completedMoves = 0;
        id moveObserver = nil;
        @try {
            [defaults setObject:@"Metal" forKey:MBCIOSRendererPreferenceKey];
            [defaults setInteger:kHumanVsHuman forKey:kMBCNewGamePlayers];
            [defaults setInteger:kPlayEither forKey:kMBCNewGameSides];
            [defaults setObject:@"Wood" forKey:kMBCBoardStyle];
            [defaults setObject:@"Wood" forKey:kMBCPieceStyle];
            [defaults setBool:NO forKey:kMBCAutoRotateBoard];
            [defaults setBool:NO forKey:kMBCSpeakMoves];
            [defaults setBool:NO forKey:kMBCSpeakHumanMoves];
            window.rootViewController = controller;
            window.hidden = NO;
            [controller.view layoutIfNeeded];
            [MBCIOSRendererPreferences.sharedPreferences removeParticipant:controller];
            [preferences addParticipant:controller];
            XCTAssertTrue([controller.boardView isKindOfClass:MBCBoardMTLView.class]);
            XCTAssertNil(controller.activeGameIdentifier);
            if (![controller.boardView isKindOfClass:MBCBoardMTLView.class]) return;

            MBCBoard *board = controller.board;
            MBCRendererTestEngine *testEngine = [[MBCRendererTestEngine alloc] init];
            testEngine.isolatedDirectory = [directory URLByAppendingPathComponent:@"Engine" isDirectory:YES];
            controller.engine = testEngine;
            MBCIOSChessEngine *engine = controller.engine;
            engine.sessionIdentifier = @"RendererSwitchSession";
            engine.moveSource = controller.boardView;
            /* Black waits in force mode. Manually queued presentation moves
             * exercise the shell without asking this session to calculate. */
            [engine startGame:kVarNormal playing:kBlackSide searchTime:1 fromBoard:board];
            XCTAssertTrue(engine.isRunning);
            controller.gameMetadata[@"IOSRotateAfterEachMove"] = @NO;
            controller.gameMetadata[@"IOSConfirmNextTurn"] = @NO;
            NSDictionary *camera = @{@"azimuth": @163, @"elevation": @52, @"zoomScale": @1.15,
                                     @"panX": @4, @"panZ": @-3, @"edgeLabels": @NO};
            [controller.boardView iosRestorePresentationState:camera];
            [controller applyBoardStylePreference:@"Grass"];
            [controller applyPieceStylePreference:@"Fur"];
            moveObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:MBCEndMoveNotification object:controller queue:nil
                usingBlock:^(NSNotification *notification) { ++completedMoves; }];

            MBCMove *first = [MBCMove moveFromEngineMove:@"e2e4"];
            first->fAnimate = YES;
            MBCMove *second = [MBCMove moveFromEngineMove:@"e7e5"];
            second->fAnimate = NO;
            [controller enqueueMove:first];
            [controller enqueueMove:second];
            XCTAssertEqual(controller.activeMoveAnimation, first);
            XCTAssertEqual(controller.pendingMoveAnimations.firstObject, second);
            NSError *error = nil;
            XCTAssertTrue([preferences selectRenderer:MBCIOSRendererOpenGL error:&error], @"%@", error);
            [controller applyPendingRendererChange];
            XCTAssertTrue([controller.boardView isKindOfClass:MBCBoardMTLView.class]);
            XCTAssertTrue(controller.rendererChangePending);
            if (![self waitForController:controller renderer:MBCIOSRendererOpenGL moves:2]) return;
            XCTAssertTrue([controller.boardView isKindOfClass:MBCBoardView.class]);
            XCTAssertEqual(controller.board, board);
            XCTAssertEqual(controller.engine, engine);
            XCTAssertTrue(engine.isRunning);
            XCTAssertEqual(engine.moveSource, controller.boardView);
            XCTAssertEqualObjects(engine.sessionIdentifier, @"RendererSwitchSession");
            XCTAssertEqual(completedMoves, 2u);
            XCTAssertEqual(What([board curContents:Square('e', 4)]), White(PAWN));
            XCTAssertEqual(What([board curContents:Square('e', 5)]), Black(PAWN));
            [self assertCamera:camera view:controller.boardView];
            MBCIOSOpenGLView *surface = (MBCIOSOpenGLView *)controller.boardView;
            XCTAssertTrue(surface.lastFramePresented);
            [surface performWithGLContext:^{ XCTAssertEqual(glGetError(), (GLenum)GL_NO_ERROR); }];
            [controller.boardView drawNow];
            XCTAssertTrue(surface.lastFramePresented);
            [surface performWithGLContext:^{ XCTAssertEqual(glGetError(), (GLenum)GL_NO_ERROR); }];
            /* Shiny materials also exercise the legacy reflection/stencil
             * passes. Keep the game's canonical Grass/Fur choice intact. */
            [controller.boardView setStyleForBoard:@"Metal" pieces:@"Metal"];
            XCTAssertGreaterThan(controller.boardView.boardReflectivity, 0.f);
            [controller.boardView drawNow];
            XCTAssertTrue(surface.lastFramePresented);
            [surface performWithGLContext:^{ XCTAssertEqual(glGetError(), (GLenum)GL_NO_ERROR); }];
            [controller.boardView setStyleForBoard:@"Grass" pieces:@"Fur"];
            NSDictionary *glSquares = [self squareAccessibilityForView:controller.boardView];
            XCTAssertEqualObjects(controller.boardStyle, @"Grass");
            XCTAssertEqualObjects(controller.pieceStyle, @"Fur");

            /* Cancel does not call the renderer coordinator or persist a draft. */
            __block BOOL rendererCommitted = NO;
            MBCIOSPreferencesViewController *sheet = [[MBCIOSPreferencesViewController alloc]
                initWithBoardStyle:@"Grass" pieceStyle:@"Fur" autoRotateBoard:NO completion:nil];
            [sheet loadViewIfNeeded];
            sheet.rendererCompletion = ^BOOL(MBCIOSRendererKind kind) { rendererCommitted = YES; return YES; };
            sheet.rendererControl.selectedSegmentIndex = MBCIOSRendererMetal;
            [sheet cancelSelection];
            XCTAssertFalse(rendererCommitted);
            XCTAssertEqual(preferences.desiredRenderer, MBCIOSRendererOpenGL);

            /* An inactive scene retains its GL backend without preparing Metal. */
            [controller.boardBackend setRenderingActive:NO];
            controller.eligibleForRendering = NO;
            UIView<MBCIOSBoardPresentation> *inactiveView = controller.boardView;
            XCTAssertTrue([preferences selectRenderer:MBCIOSRendererMetal error:&error], @"%@", error);
            [controller applyPendingRendererChange];
            XCTAssertEqual(controller.boardView, inactiveView);
            XCTAssertNil(controller.preparedBoardBackend);
            XCTAssertTrue(controller.rendererChangePending);
            controller.eligibleForRendering = YES;
            [controller handleApplicationDidBecomeActive:nil];
            if (![self waitForController:controller renderer:MBCIOSRendererMetal moves:2]) return;
            XCTAssertTrue([controller.boardView isKindOfClass:MBCBoardMTLView.class]);
            XCTAssertEqual(controller.board, board);
            XCTAssertEqual(controller.engine, engine);
            XCTAssertTrue(engine.isRunning);
            XCTAssertEqual(engine.moveSource, controller.boardView);
            XCTAssertEqual(completedMoves, 2u);
            [self assertCamera:camera view:controller.boardView];
            XCTAssertEqualObjects([self squareAccessibilityForView:controller.boardView], glSquares);
            NSDictionary *game = [controller currentGameSnapshot];
            XCTAssertEqualObjects(game[@"BoardStyle"], @"Grass");
            XCTAssertEqualObjects(game[@"PieceStyle"], @"Fur");
            XCTAssertNil(game[MBCIOSRendererPreferenceKey]);
            XCTAssertNil(game[@"Renderer"]);
        } @finally {
            if (moveObserver) [[NSNotificationCenter defaultCenter] removeObserver:moveObserver];
            [preferences removeParticipant:controller];
            [MBCIOSRendererPreferences.sharedPreferences removeParticipant:controller];
            [controller cancelMoveAnimation];
            [controller.engine stop];
            [controller.boardBackend retireWithCompletion:nil];
            [controller.preparedBoardBackend retireWithCompletion:nil];
            window.hidden = YES;
            window.rootViewController = nil;
            [fixture restore];
            UIApplication.sharedApplication.idleTimerDisabled = originalIdleTimer;
            [[NSFileManager defaultManager] removeItemAtURL:directory error:nil];
        }
    });
}
@end
