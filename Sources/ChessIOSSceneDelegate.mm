#import "ChessIOSSceneDelegate.h"

#import "ChessIOSAppDelegate.h"
#import "ChessIOSViewController.h"
#import "MBCIOSGameLibrary.h"
#import "MBCIOSGameStore.h"

static NSString *const kChessSceneActivityType = @"com.apple.Chess.game";
static NSString *const kChessSceneGameIdentifierKey = @"GameIdentifier";
static NSString *const kChessSceneImportActivityType = @"com.apple.Chess.import";
static NSString *const kChessSceneImportTokenKey = @"ImportToken";
static NSString *const kChessSceneImportFileNameKey = @"ImportFileName";
static char kChessActiveGameRecordObservationContext;

typedef void (^MBCSceneImportCompletion)(NSURL *url, BOOL succeeded, NSError *error);

@interface MBCSceneImportTask : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) BOOL removesStagedFile;
@property (nonatomic, copy) MBCSceneImportCompletion completion;
@end

@implementation MBCSceneImportTask
@end

static NSURL *MBCSceneImportDirectory(NSError **error)
{
    NSURL *support = [MBCIOSGameStore applicationSupportDirectoryWithError:error];
    return support ? [support URLByAppendingPathComponent:@"SceneImports" isDirectory:YES] : nil;
}

static NSURL *MBCSceneStagedURLForActivity(NSUserActivity *activity)
{
    if (![activity.activityType isEqualToString:kChessSceneImportActivityType]) return nil;
    NSString *token = activity.userInfo[kChessSceneImportTokenKey];
    NSString *fileName = activity.userInfo[kChessSceneImportFileNameKey];
    if (![token isKindOfClass:[NSString class]] || ![[NSUUID alloc] initWithUUIDString:token] ||
        ![fileName isKindOfClass:[NSString class]] || !fileName.length ||
        ![fileName.lastPathComponent isEqualToString:fileName]) return nil;
    NSURL *root = MBCSceneImportDirectory(nil);
    return [[root URLByAppendingPathComponent:token isDirectory:YES]
        URLByAppendingPathComponent:fileName isDirectory:NO];
}

static NSUserActivity *MBCSceneImportActivityForURL(NSURL *url)
{
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:kChessSceneImportActivityType];
    activity.title = url.lastPathComponent;
    activity.eligibleForHandoff = NO;
    activity.eligibleForSearch = NO;
    [activity addUserInfoEntriesFromDictionary:@{
        kChessSceneImportTokenKey: url.URLByDeletingLastPathComponent.lastPathComponent,
        kChessSceneImportFileNameKey: url.lastPathComponent
    }];
    return activity;
}

static NSString *MBCSceneGameIdentifier(NSUserActivity *activity)
{
    if (![activity.activityType isEqualToString:kChessSceneActivityType]) return nil;
    id identifier = activity.userInfo[kChessSceneGameIdentifierKey];
    return [identifier isKindOfClass:[NSString class]] && [identifier length] > 0
        ? identifier : nil;
}

@interface ChessIOSSceneDelegate ()
@property (nonatomic, strong, readwrite) ChessIOSViewController *viewController;
@property (nonatomic) BOOL handledLaunchURL;
@property (nonatomic, strong) NSMutableArray<MBCSceneImportTask *> *importTasks;
@property (nonatomic) BOOL importInProgress;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingImportReports;
@property (nonatomic) BOOL pendingImportSuccess;
@property (nonatomic) BOOL importReportCheckScheduled;
@property (nonatomic, strong) UIView *importSuccessBanner;
@property (nonatomic) NSUInteger importSuccessBannerGeneration;
@property (nonatomic) BOOL observesActiveGameRecord;
- (void)saveActiveGameRecoveringConflict:(BOOL)recoverConflict;
- (void)refreshSessionRestorationActivity;
- (BOOL)enqueueImportURL:(NSURL *)url removesStagedFile:(BOOL)removesStagedFile
              completion:(MBCSceneImportCompletion)completion;
- (void)performNextImport;
- (void)finishDeferredInitialImportIfIdle;
- (void)handleURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts;
- (void)presentPendingImportReports;
- (void)queueImportReport:(NSString *)report;
- (void)queueImportSuccess;
- (void)showImportSuccessBanner;
- (void)enqueueImportBatch:(NSArray<NSURL *> *)urls removesStagedFiles:(BOOL)removesStagedFiles;
- (NSURL *)stageImportURL:(NSURL *)url error:(NSError **)error;
@end

@implementation ChessIOSSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
                                  options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    ChessIOSAppDelegate *appDelegate =
        (ChessIOSAppDelegate *)UIApplication.sharedApplication.delegate;
    BOOL initialScene = [appDelegate claimInitialScene];

    NSString *gameIdentifier = nil;
    NSUserActivity *importActivity = nil;
    BOOL requestedNewWindow = NO;
    NSMutableArray<NSString *> *activityDescriptions = [NSMutableArray array];
    for (NSUserActivity *activity in connectionOptions.userActivities) {
        [activityDescriptions addObject:[NSString stringWithFormat:@"%@:%@",
            activity.activityType, activity.targetContentIdentifier ?: @"-"]];
        if ([activity.activityType isEqualToString:kChessSceneImportActivityType])
            importActivity = activity;
        if (!gameIdentifier.length) gameIdentifier = MBCSceneGameIdentifier(activity);
        if ([activity.activityType isEqualToString:kChessSceneActivityType] &&
            activity.targetContentIdentifier.length && !gameIdentifier.length)
            requestedNewWindow = YES;
    }
    NSString *mappedIdentifier = nil;
    if (!gameIdentifier.length && !requestedNewWindow) {
        NSUserActivity *restoration = session.stateRestorationActivity;
        if (!importActivity &&
            [restoration.activityType isEqualToString:kChessSceneImportActivityType])
            importActivity = restoration;
        // UIKit can recreate a session without delivering its restoration
        // activity. The session's durable game mapping is authoritative then.
        mappedIdentifier = [appDelegate gameIdentifierForSceneSession:session];
        gameIdentifier = mappedIdentifier.length ? mappedIdentifier :
            MBCSceneGameIdentifier(restoration);
    }
    NSLog(@"Chess scene connecting: session=%@ initial=%@ newWindow=%@ game=%@ mapped=%@ activities=%@ URLs=%lu restoration=%@",
          session.persistentIdentifier, initialScene ? @"YES" : @"NO",
          requestedNewWindow ? @"YES" : @"NO", gameIdentifier ?: @"-",
          mappedIdentifier ?: @"-", activityDescriptions,
          (unsigned long)connectionOptions.URLContexts.count,
          session.stateRestorationActivity.activityType ?: @"-");

    ChessIOSViewController *controller = [[ChessIOSViewController alloc] init];
    BOOL hasLaunchImport = importActivity != nil || connectionOptions.URLContexts.count > 0;
    controller.defersInitialLibrarySaveForImport = hasLaunchImport;
    if (gameIdentifier.length) {
        controller.preferredInitialGameIdentifier = gameIdentifier;
    } else if (!initialScene || requestedNewWindow || hasLaunchImport) {
        // A new window and an import launch start from their own temporary
        // board. The first ordinary scene still opens the last-used game.
        controller.startsWithNewLibraryGame = YES;
    }
    self.viewController = controller;
    // The controller changes records for New Game, Library, Save As, imports,
    // and conflict recovery. Observe the record itself so the scene mapping
    // follows each identity change before the next lifecycle callback.
    [controller addObserver:self forKeyPath:@"activeGameRecord" options:0
                   context:&kChessActiveGameRecordObservationContext];
    self.observesActiveGameRecord = YES;
    self.importTasks = [NSMutableArray array];
    self.pendingImportReports = [NSMutableArray array];
    self.handledLaunchURL = hasLaunchImport;
    if (importActivity) session.stateRestorationActivity = importActivity;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    NSLog(@"Chess scene visible: session=%@ game=%@ key=%@",
          session.persistentIdentifier, controller.activeGameIdentifier ?: @"-",
          self.window.isKeyWindow ? @"YES" : @"NO");
    [appDelegate sceneDidConnectController:controller];
    if (importActivity) {
        // Keep the staged import as the restoration activity until its record
        // has been created; a process restart can then retry this handoff.
        NSURL *stagedURL = MBCSceneStagedURLForActivity(importActivity);
        if (stagedURL) {
            [self enqueueImportURL:stagedURL removesStagedFile:YES completion:nil];
        } else {
            [self.pendingImportReports addObject:
                NSLocalizedString(@"The document handoff could not be restored.", nil)];
            [self refreshSessionRestorationActivity];
        }
    } else {
        [self refreshSessionRestorationActivity];
    }
    [self handleURLContexts:connectionOptions.URLContexts];
    if (hasLaunchImport) {
        // Import completion can be synchronous; wait until all launch URLs
        // have been enqueued before deciding whether a fallback game is needed.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishDeferredInitialImportIfIdle];
        });
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    [self refreshSessionRestorationActivity];
    NSLog(@"Chess scene active: session=%@ game=%@",
          scene.session.persistentIdentifier,
          self.viewController.activeGameIdentifier ?: @"-");
    ChessIOSAppDelegate *appDelegate =
        (ChessIOSAppDelegate *)UIApplication.sharedApplication.delegate;
    [appDelegate sceneDidBecomeActiveWithController:self.viewController];
    [self presentPendingImportReports];
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    (void)scene;
    [self saveActiveGame];
}

- (void)sceneDidEnterBackground:(UIScene *)scene
{
    (void)scene;
    [self saveActiveGameRecoveringConflict];
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    NSLog(@"Chess scene disconnecting: session=%@ game=%@",
          scene.session.persistentIdentifier,
          self.viewController.activeGameIdentifier ?: @"-");
    [self saveActiveGameRecoveringConflict];
    if (self.observesActiveGameRecord) {
        [self.viewController removeObserver:self forKeyPath:@"activeGameRecord"
                                   context:&kChessActiveGameRecordObservationContext];
        self.observesActiveGameRecord = NO;
    }
    MBCIOSGameCenterManager *manager = self.viewController.gameCenterManager;
    [manager releaseActiveMatch];
    manager.delegate = nil;
    self.window = nil;
    self.viewController = nil;
}

- (void)saveActiveGame
{
    [self saveActiveGameRecoveringConflict:NO];
}

- (void)saveActiveGameRecoveringConflict
{
    [self saveActiveGameRecoveringConflict:YES];
}

- (void)saveActiveGameRecoveringConflict:(BOOL)recoverConflict
{
    if (!self.viewController) return;
    NSError *error = nil;
    BOOL saved = [self.viewController saveCurrentGame:&error];
    if (saved) {
        [self refreshSessionRestorationActivity];
    } else if (error) {
        if ([error.domain isEqualToString:MBCIOSGameLibraryErrorDomain] &&
            error.code == MBCIOSGameLibraryErrorConflict) {
            // Keep the other scene's revision and make this scene's live
            // board durable before the system can discard this window.
            if (recoverConflict) {
                NSError *recoveryError = nil;
                if ([self.viewController saveCurrentBoardAsRecoveredCopy:&recoveryError]) {
                    NSLog(@"Chess scene recovered a conflicting game as %@",
                          self.viewController.activeGameIdentifier);
                    [self refreshSessionRestorationActivity];
                } else {
                    NSLog(@"Chess scene recovery failed for %@: %@ (save conflict: %@)",
                          self.viewController.activeGameIdentifier, recoveryError, error);
                }
            } else {
                NSLog(@"Chess scene save conflict for %@: %@",
                      self.viewController.activeGameIdentifier, error);
            }
        } else {
            NSLog(@"Chess scene autosave failed: %@", error);
        }
    } else {
        NSLog(@"Chess scene autosave failed without an error for %@",
              self.viewController.activeGameIdentifier);
    }
}

- (void)refreshSessionRestorationActivity
{
    UIWindowScene *scene = self.window.windowScene;
    if (scene) {
        NSString *identifier = self.viewController.activeGameIdentifier;
        if (identifier.length) {
            ChessIOSAppDelegate *appDelegate =
                (ChessIOSAppDelegate *)UIApplication.sharedApplication.delegate;
            [appDelegate recordGameIdentifier:identifier forSceneSession:scene.session];
        }
        if (self.handledLaunchURL && self.viewController.defersInitialLibrarySaveForImport &&
            [scene.session.stateRestorationActivity.activityType
                isEqualToString:kChessSceneImportActivityType]) return;
        scene.session.stateRestorationActivity =
            [self stateRestorationActivityForScene:scene];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context
{
    if (context == &kChessActiveGameRecordObservationContext) {
        if (object == self.viewController) [self refreshSessionRestorationActivity];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)dealloc
{
    if (self.observesActiveGameRecord) {
        [self.viewController removeObserver:self forKeyPath:@"activeGameRecord"
                                   context:&kChessActiveGameRecordObservationContext];
    }
}

- (BOOL)importURL:(NSURL *)url
{
    return [self enqueueImportURL:url removesStagedFile:NO completion:nil];
}

- (BOOL)enqueueImportURL:(NSURL *)url removesStagedFile:(BOOL)removesStagedFile
              completion:(MBCSceneImportCompletion)completion
{
    if (!url || !self.viewController.documentController) return NO;
    if (!self.importTasks) self.importTasks = [NSMutableArray array];
    MBCSceneImportTask *task = [[MBCSceneImportTask alloc] init];
    task.url = url;
    task.removesStagedFile = removesStagedFile;
    task.completion = completion;
    [self.importTasks addObject:task];
    [self performNextImport];
    return YES;
}

- (void)performNextImport
{
    if (self.importInProgress || !self.importTasks.count || !self.viewController) return;
    self.importInProgress = YES;
    MBCSceneImportTask *task = self.importTasks.firstObject;
    ChessIOSViewController *controller = self.viewController;
    __weak ChessIOSSceneDelegate *weakSelf = self;
    [controller.documentController importDocumentAtURL:task.url
        completion:^(MBCBoard *board, MBCVariant variant, MBCSide side,
                     NSString *boardStyle, NSString *pieceStyle, NSError *loadError) {
        ChessIOSSceneDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *resultError = loadError;
        BOOL installed = NO;
        if (!resultError && board) {
            installed = [controller tryApplyImportedBoard:board variant:variant side:side
                                              boardStyle:boardStyle pieceStyle:pieceStyle
                                                   error:&resultError];
        }
        if (!installed && !resultError) {
            resultError = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSFileReadUnknownError
                                           userInfo:@{NSLocalizedDescriptionKey:
                NSLocalizedString(@"Chess could not open this document.", nil)}];
        }
        if (task.removesStagedFile) {
            NSURL *root = MBCSceneImportDirectory(nil);
            NSURL *folder = task.url.URLByDeletingLastPathComponent;
            if ([[folder URLByDeletingLastPathComponent].path isEqualToString:root.path]) {
                NSError *cleanupError = nil;
                if (![[NSFileManager defaultManager] removeItemAtURL:folder
                                                              error:&cleanupError]) {
                    NSLog(@"Chess could not remove staged import %@: %@", folder, cleanupError);
                }
            }
        }
        [strongSelf.importTasks removeObjectAtIndex:0];
        strongSelf.importInProgress = NO;
        [strongSelf refreshSessionRestorationActivity];
        if (task.completion) {
            task.completion(task.url, installed, resultError);
        } else if (installed) {
            [strongSelf queueImportSuccess];
        } else {
            [strongSelf queueImportReport:resultError.localizedDescription ?:
                NSLocalizedString(@"Import failed", nil)];
        }
        NSLog(@"Chess scene import %@: %@%@", installed ? @"succeeded" : @"failed",
              task.url.lastPathComponent, resultError ?
              [NSString stringWithFormat:@" (%@)", resultError] : @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf performNextImport];
            [strongSelf finishDeferredInitialImportIfIdle];
        });
    }];
}

- (void)finishDeferredInitialImportIfIdle
{
    if (!self.viewController.defersInitialLibrarySaveForImport ||
        self.importInProgress || self.importTasks.count) return;
    NSError *error = nil;
    if (![self.viewController finishInitialSceneImportWithError:&error]) {
        NSLog(@"Chess scene could not save its fallback game: %@", error);
        [self queueImportReport:error.localizedDescription ?:
            NSLocalizedString(@"The new window could not save its game.", nil)];
    }
    [self refreshSessionRestorationActivity];
}

- (void)enqueueImportBatch:(NSArray<NSURL *> *)urls
        removesStagedFiles:(BOOL)removesStagedFiles
{
    if (!urls.count) return;
    __block NSUInteger remaining = urls.count;
    NSMutableArray<NSString *> *failures = [NSMutableArray arrayWithCapacity:urls.count];
    __block BOOL importedAny = NO;
    __weak ChessIOSSceneDelegate *weakSelf = self;
    for (NSURL *url in urls) {
        BOOL queued = [self enqueueImportURL:url removesStagedFile:removesStagedFiles
            completion:^(NSURL *finishedURL, BOOL succeeded, NSError *error) {
            (void)finishedURL;
            if (succeeded) importedAny = YES;
            else [failures addObject:error.localizedDescription ?:
                NSLocalizedString(@"Import failed", nil)];
            if (--remaining == 0) {
                if (failures.count)
                    [weakSelf queueImportReport:[failures componentsJoinedByString:@"\n"]];
                if (importedAny) [weakSelf queueImportSuccess];
            }
        }];
        if (!queued) {
            [failures addObject:NSLocalizedString(@"Import could not start", nil)];
            if (--remaining == 0) {
                [weakSelf queueImportReport:[failures componentsJoinedByString:@"\n"]];
                if (importedAny) [weakSelf queueImportSuccess];
            }
        }
    }
}

- (void)queueImportReport:(NSString *)report
{
    if (!report.length) return;
    if (!self.pendingImportReports) self.pendingImportReports = [NSMutableArray array];
    [self.pendingImportReports addObject:report];
    NSLog(@"Chess document import result: %@", report);
    [self presentPendingImportReports];
}

- (void)queueImportSuccess
{
    self.pendingImportSuccess = YES;
    [self presentPendingImportReports];
}

- (void)showImportSuccessBanner
{
    UIView *root = self.viewController.view;
    if (!root) return;
    [self.importSuccessBanner removeFromSuperview];

    NSString *message = NSLocalizedString(@"Imported", nil);
    UIView *banner = [[UIView alloc] initWithFrame:CGRectZero];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = UIColor.secondarySystemBackgroundColor;
    banner.layer.cornerRadius = 12.0;
    banner.layer.cornerCurve = kCACornerCurveContinuous;
    banner.layer.borderWidth = 0.5;
    banner.layer.borderColor = UIColor.separatorColor.CGColor;
    banner.userInteractionEnabled = NO;
    banner.isAccessibilityElement = YES;
    banner.accessibilityLabel = message;
    banner.accessibilityTraits = UIAccessibilityTraitStaticText;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:label];
    [root addSubview:banner];
    [NSLayoutConstraint activateConstraints:@[
        [banner.centerXAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerXAnchor],
        [banner.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12.0],
        [banner.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:20.0],
        [banner.trailingAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:18.0],
        [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-18.0],
        [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0]
    ]];
    self.importSuccessBanner = banner;
    NSUInteger generation = ++self.importSuccessBannerGeneration;
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        banner.alpha = 0.0;
        [UIView animateWithDuration:0.18 animations:^{ banner.alpha = 1.0; }];
    }
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    __weak ChessIOSSceneDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChessIOSSceneDelegate *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.importSuccessBannerGeneration) return;
        if (UIAccessibilityIsReduceMotionEnabled()) {
            [banner removeFromSuperview];
            strongSelf.importSuccessBanner = nil;
        } else {
            [UIView animateWithDuration:0.18 animations:^{ banner.alpha = 0.0; }
                             completion:^(BOOL finished) {
                (void)finished;
                [banner removeFromSuperview];
                if (generation == strongSelf.importSuccessBannerGeneration)
                    strongSelf.importSuccessBanner = nil;
            }];
        }
    });
}

- (void)presentPendingImportReports
{
    if ((!self.pendingImportReports.count && !self.pendingImportSuccess) ||
        !self.viewController.view.window ||
        self.window.windowScene.activationState != UISceneActivationStateForegroundActive) return;
    if (self.viewController.presentedViewController) {
        if (self.importReportCheckScheduled) return;
        self.importReportCheckScheduled = YES;
        __weak ChessIOSSceneDelegate *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            weakSelf.importReportCheckScheduled = NO;
            [weakSelf presentPendingImportReports];
        });
        return;
    }
    if (self.pendingImportReports.count) {
        NSString *message = [self.pendingImportReports componentsJoinedByString:@"\n"];
        [self.pendingImportReports removeAllObjects];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:NSLocalizedString(@"Import failed", nil)
                             message:message preferredStyle:UIAlertControllerStyleAlert];
        __weak ChessIOSSceneDelegate *weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf presentPendingImportReports];
            });
        }]];
        [self.viewController presentViewController:alert animated:YES completion:nil];
    } else {
        self.pendingImportSuccess = NO;
        [self showImportSuccessBanner];
    }
}

- (NSURL *)stageImportURL:(NSURL *)url error:(NSError **)error
{
    if (error) *error = nil;
    NSURL *root = MBCSceneImportDirectory(error);
    if (!root) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    NSURL *folder = [root URLByAppendingPathComponent:token isDirectory:YES];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files createDirectoryAtURL:folder withIntermediateDirectories:YES
                          attributes:nil error:error]) return nil;
    NSString *fileName = url.lastPathComponent;
    if (!fileName.length || [fileName isEqualToString:@"."] ||
        [fileName isEqualToString:@".."]) fileName = @"Imported";
    NSURL *stagedURL = [folder URLByAppendingPathComponent:fileName isDirectory:NO];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    BOOL copied = [files copyItemAtURL:url toURL:stagedURL error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) {
        [files removeItemAtURL:folder error:nil];
        return nil;
    }
    return stagedURL;
}

- (void)handleURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
    if (!URLContexts.count) return;
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:URLContexts.count];
    for (UIOpenURLContext *context in URLContexts) {
        if (context.URL) [urls addObject:context.URL];
    }
    [urls sortUsingComparator:^NSComparisonResult(NSURL *first, NSURL *second) {
        return [first.absoluteString compare:second.absoluteString];
    }];
    if (!urls.count) return;
    self.handledLaunchURL = YES;
    UIApplication *application = UIApplication.sharedApplication;
    if (urls.count == 1) {
        [self importURL:urls.firstObject];
        return;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad ||
        !application.supportsMultipleScenes) {
        [self enqueueImportBatch:urls removesStagedFiles:NO];
        return;
    }

    // Each additional iPad document gets its own window. Copy the provider
    // URL before activation so the new scene can read it after this callback.
    [self importURL:urls.firstObject];
    NSMutableArray<NSURL *> *localFallbacks = [NSMutableArray array];
    for (NSUInteger index = 1; index < urls.count; ++index) {
        NSURL *originalURL = urls[index];
        NSError *stageError = nil;
        NSURL *stagedURL = [self stageImportURL:originalURL error:&stageError];
        if (!stagedURL) {
            NSLog(@"Chess scene could not stage %@ for another window: %@",
                  originalURL.lastPathComponent, stageError);
            [localFallbacks addObject:originalURL];
            continue;
        }
        NSUserActivity *activity = MBCSceneImportActivityForURL(stagedURL);
        UISceneActivationRequestOptions *options =
            [[UISceneActivationRequestOptions alloc] init];
        options.requestingScene = self.window.windowScene;
        __weak ChessIOSSceneDelegate *weakSelf = self;
        [application requestSceneSessionActivation:nil userActivity:activity
                                           options:options errorHandler:^(NSError *activationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![[NSFileManager defaultManager]
                        fileExistsAtPath:stagedURL.path]) return;
                ChessIOSSceneDelegate *target = weakSelf;
                if (!target.viewController) {
                    target = nil;
                    for (UIScene *candidate in application.connectedScenes) {
                        if ([candidate.delegate isKindOfClass:[ChessIOSSceneDelegate class]] &&
                            ((ChessIOSSceneDelegate *)candidate.delegate).viewController) {
                            target = (ChessIOSSceneDelegate *)candidate.delegate;
                            if (candidate.activationState ==
                                UISceneActivationStateForegroundActive) break;
                        }
                    }
                }
                if (target) {
                    NSLog(@"Chess new-window import failed for %@: %@; importing in an existing window",
                          originalURL.lastPathComponent, activationError);
                    [target enqueueImportBatch:@[stagedURL] removesStagedFiles:YES];
                } else {
                    NSLog(@"Chess new-window import failed for %@: %@; staged file retained at %@",
                          originalURL.lastPathComponent, activationError, stagedURL.path);
                }
            });
        }];
    }
    if (localFallbacks.count)
        [self enqueueImportBatch:localFallbacks removesStagedFiles:NO];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
    (void)scene;
    [self handleURLContexts:URLContexts];
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene
{
    NSString *identifier = self.viewController.activeGameIdentifier;
    if (!identifier.length) return nil;
    ChessIOSAppDelegate *appDelegate =
        (ChessIOSAppDelegate *)UIApplication.sharedApplication.delegate;
    [appDelegate recordGameIdentifier:identifier forSceneSession:scene.session];
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:kChessSceneActivityType];
    activity.title = @"Chess game";
    activity.eligibleForHandoff = NO;
    activity.eligibleForSearch = NO;
    [activity addUserInfoEntriesFromDictionary:@{kChessSceneGameIdentifierKey: identifier}];
    return activity;
}

- (void)scene:(UIScene *)scene
    restoreInteractionStateWithUserActivity:(NSUserActivity *)stateRestorationActivity
{
    if (self.handledLaunchURL) return;
    ChessIOSAppDelegate *appDelegate =
        (ChessIOSAppDelegate *)UIApplication.sharedApplication.delegate;
    NSString *identifier = [appDelegate gameIdentifierForSceneSession:scene.session] ?:
        MBCSceneGameIdentifier(stateRestorationActivity);
    if (identifier.length &&
        ![identifier isEqualToString:self.viewController.activeGameIdentifier]) {
        [self.viewController openLibraryGameWithIdentifier:identifier saveCurrent:YES];
    }
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity
{
    NSLog(@"Chess scene activity: session=%@ type=%@ target=%@",
          scene.session.persistentIdentifier, userActivity.activityType,
          userActivity.targetContentIdentifier ?: @"-");
    if ([userActivity.activityType isEqualToString:kChessSceneImportActivityType]) {
        NSURL *stagedURL = MBCSceneStagedURLForActivity(userActivity);
        if (stagedURL) {
            [self enqueueImportURL:stagedURL removesStagedFile:YES completion:nil];
        } else {
            [self queueImportReport:
                NSLocalizedString(@"The document handoff could not be restored.", nil)];
        }
        return;
    }
    NSString *identifier = MBCSceneGameIdentifier(userActivity);
    if (identifier.length &&
        ![identifier isEqualToString:self.viewController.activeGameIdentifier]) {
        [self.viewController openLibraryGameWithIdentifier:identifier saveCurrent:YES];
    }
}

@end
