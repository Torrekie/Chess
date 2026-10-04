#import "ChessIOSAppDelegate.h"
#import "ChessIOSViewController.h"
#import "MBCIOSGameStore.h"
#import "MBCIOSGameCenterManager.h"
#import "ChessIOSSceneDelegate.h"

static NSString *const kChessSceneGameIdentifiersDefaultsKey = @"ChessSceneGameIdentifiers";

@interface ChessIOSAppDelegate ()
@property (nonatomic) BOOL didAuthenticateInitialScene;
@property (nonatomic, strong) NSMutableSet<NSString *> *discardedSceneIdentifiers;
- (void)saveActiveGame;
- (void)saveActiveGameRecoveringConflicts;
@end

@implementation ChessIOSAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;
    [MBCIOSGameStore registerDefaults];
    return YES;
}

- (BOOL)claimInitialScene
{
    // A new window must get its own game while another one is connected.
    // If the last window was closed without terminating the process, the
    // next connection may resume the last-opened game as a single window.
    NSUInteger connectedChessWindows = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene.delegate isKindOfClass:[ChessIOSSceneDelegate class]]) continue;
        if (((ChessIOSSceneDelegate *)scene.delegate).viewController)
            ++connectedChessWindows;
    }
    BOOL initialScene = connectedChessWindows == 0;
    NSLog(@"Chess scene claim: connected windows=%lu initial=%@",
          (unsigned long)connectedChessWindows, initialScene ? @"YES" : @"NO");
    return initialScene;
}

- (NSString *)gameIdentifierForSceneSession:(UISceneSession *)session
{
    NSString *sessionIdentifier = session.persistentIdentifier;
    if (!sessionIdentifier.length) return nil;
    @synchronized (self) {
        id identifier = [[[NSUserDefaults standardUserDefaults]
            dictionaryForKey:kChessSceneGameIdentifiersDefaultsKey]
            objectForKey:sessionIdentifier];
        return [identifier isKindOfClass:[NSString class]] && [identifier length]
            ? identifier : nil;
    }
}

- (void)recordGameIdentifier:(NSString *)identifier forSceneSession:(UISceneSession *)session
{
    NSString *sessionIdentifier = session.persistentIdentifier;
    if (!sessionIdentifier.length || !identifier.length) return;
    @synchronized (self) {
        if ([self.discardedSceneIdentifiers containsObject:sessionIdentifier]) return;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary<NSString *, NSString *> *identifiers =
            [[defaults dictionaryForKey:kChessSceneGameIdentifiersDefaultsKey] mutableCopy]
                ?: [NSMutableDictionary dictionary];
        if ([identifiers[sessionIdentifier] isEqualToString:identifier]) return;
        identifiers[sessionIdentifier] = identifier;
        [defaults setObject:identifiers forKey:kChessSceneGameIdentifiersDefaultsKey];
        if (![defaults synchronize])
            NSLog(@"Chess scene mapping could not be flushed for %@", sessionIdentifier);
        NSLog(@"Chess scene mapping: session=%@ game=%@", sessionIdentifier, identifier);
    }
}

- (void)sceneDidConnectController:(ChessIOSViewController *)viewController
{
    if (!viewController) return;
    MBCIOSGameCenterManager *gameCenterManager = viewController.gameCenterManager;
    [gameCenterManager becomePreferredEventTarget];
    if (self.didAuthenticateInitialScene) return;
    self.didAuthenticateInitialScene = YES;
    [gameCenterManager authenticateFromPresenter:viewController];
}

- (void)sceneDidBecomeActiveWithController:(ChessIOSViewController *)viewController
{
    if (!viewController) return;
    MBCIOSGameCenterManager *manager = viewController.gameCenterManager;
    [manager becomePreferredEventTarget];
    [manager authenticateFromPresenter:viewController];
}

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                 options:(UISceneConnectionOptions *)options
{
    NSMutableArray<NSString *> *activityDescriptions = [NSMutableArray array];
    for (NSUserActivity *activity in options.userActivities) {
        [activityDescriptions addObject:[NSString stringWithFormat:@"%@:%@",
            activity.activityType, activity.targetContentIdentifier ?: @"-"]];
    }
    NSLog(@"Chess scene configuration: session=%@ role=%@ multiple=%@ connected=%lu activities=%@ URLs=%lu",
          connectingSceneSession.persistentIdentifier, connectingSceneSession.role,
          application.supportsMultipleScenes ? @"YES" : @"NO",
          (unsigned long)application.connectedScenes.count, activityDescriptions,
          (unsigned long)options.URLContexts.count);
    UISceneConfiguration *configuration =
        [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                       sessionRole:connectingSceneSession.role];
    configuration.delegateClass = [ChessIOSSceneDelegate class];
    return configuration;
}

- (void)application:(UIApplication *)application
    didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions
{
    (void)application;
    @synchronized (self) {
        if (!self.discardedSceneIdentifiers)
            self.discardedSceneIdentifiers = [NSMutableSet set];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary<NSString *, NSString *> *identifiers =
            [[defaults dictionaryForKey:kChessSceneGameIdentifiersDefaultsKey] mutableCopy]
                ?: [NSMutableDictionary dictionary];
        BOOL changed = NO;
        for (UISceneSession *session in sceneSessions) {
            NSString *sessionIdentifier = session.persistentIdentifier;
            if (!sessionIdentifier.length) continue;
            [self.discardedSceneIdentifiers addObject:sessionIdentifier];
            if (identifiers[sessionIdentifier]) {
                [identifiers removeObjectForKey:sessionIdentifier];
                changed = YES;
            }
            NSLog(@"Chess scene discarded: session=%@", sessionIdentifier);
        }
        if (!changed) return;
        if (identifiers.count)
            [defaults setObject:identifiers forKey:kChessSceneGameIdentifiersDefaultsKey];
        else
            [defaults removeObjectForKey:kChessSceneGameIdentifiersDefaultsKey];
        if (![defaults synchronize])
            NSLog(@"Chess discarded scene mappings could not be flushed");
    }
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    (void)options;
    if (!url) return NO;
    // UIKit normally delivers document URLs to the matching scene. If an
    // external caller uses the app-delegate callback, prefer its key window.
    ChessIOSSceneDelegate *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene.delegate isKindOfClass:[ChessIOSSceneDelegate class]]) continue;
        ChessIOSSceneDelegate *delegate = (ChessIOSSceneDelegate *)scene.delegate;
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            delegate.window.isKeyWindow)
            return [delegate importURL:url];
        if (scene.activationState == UISceneActivationStateForegroundActive || !fallback)
            fallback = delegate;
    }
    return fallback ? [fallback importURL:url] : NO;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    (void)application;
    [self saveActiveGameRecoveringConflicts];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    (void)application;
    [self saveActiveGameRecoveringConflicts];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    (void)application;
    [self saveActiveGame];
}

- (void)saveActiveGame
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene.delegate isKindOfClass:[ChessIOSSceneDelegate class]]) continue;
        [(ChessIOSSceneDelegate *)scene.delegate saveActiveGame];
    }
}

- (void)saveActiveGameRecoveringConflicts
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene.delegate isKindOfClass:[ChessIOSSceneDelegate class]]) continue;
        [(ChessIOSSceneDelegate *)scene.delegate saveActiveGameRecoveringConflict];
    }
}

@end
