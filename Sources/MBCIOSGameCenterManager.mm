/* iOS GameKit coordinator for Apple Chess turn-based games. */

#import "MBCIOSGameCenterManager.h"

#import "MBCIOSLocalization.h"
#import "MBCBoard.h"

static NSString * const kMBCIOSGameCenterErrorDomain =
    @"com.apple.Chess.iOSGameCenter";
static NSTimeInterval const kMBCIOSGameCenterTurnTimeout = 86400.0;

static NSError *MBCGameCenterError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:kMBCIOSGameCenterErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Game Center operation failed."}];
}

static NSString *MBCGameCenterVariantName(MBCVariant variant)
{
    if (variant < kVarNormal || variant > kVarLosers || !gVariantName[variant]) {
        return @"normal";
    }
    return gVariantName[variant];
}

static MBCVariant MBCGameCenterVariantFromDictionary(NSDictionary *dictionary)
{
    NSString *name = [dictionary[@"Variant"] isKindOfClass:[NSString class]]
        ? dictionary[@"Variant"] : nil;
    for (NSInteger value = kVarNormal; value <= kVarLosers; ++value) {
        if (name && [name isEqualToString:gVariantName[value]]) return (MBCVariant)value;
    }
    return kVarNormal;
}

static BOOL MBCGameCenterPlayerIDMatches(GKTurnBasedParticipant *participant,
                                         NSString *playerID)
{
    return participant.player.playerID.length &&
        [participant.player.playerID isEqualToString:playerID];
}

static NSHashTable<MBCIOSGameCenterManager *> *MBCGameCenterManagers(void)
{
    static NSHashTable<MBCIOSGameCenterManager *> *managers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ managers = [NSHashTable weakObjectsHashTable]; });
    return managers;
}

static NSMapTable<NSString *, MBCIOSGameCenterManager *> *MBCGameCenterMatchOwners(void)
{
    static NSMapTable<NSString *, MBCIOSGameCenterManager *> *owners;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        owners = [NSMapTable strongToWeakObjectsMapTable];
    });
    return owners;
}

@interface MBCIOSGameCenterManager ()
@property (nonatomic, readwrite, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, readwrite, nullable) NSError *lastError;
@property (nonatomic, readwrite, strong, nullable) GKTurnBasedMatch *activeMatch;
@property (nonatomic, readwrite) NSUInteger existingMatchCount;
@property (nonatomic, readwrite, getter=isLocalPlayerTurn) BOOL localPlayerTurn;
@property (nonatomic, weak) UIViewController *authenticationPresenter;
@property (nonatomic) MBCVariant pendingVariant;
@property (nonatomic) MBCSideCode pendingSideCode;
@property (nonatomic, strong) NSMutableSet<NSString *> *reportedAchievements;
@property (nonatomic, strong) NSMutableDictionary<NSString *, GKAchievement *> *achievements;
@property (nonatomic, strong) NSArray<GKTurnBasedMatch *> *existingMatches;
@property (nonatomic, copy, nullable) NSString *pendingResumeMatchID;
@property (nonatomic) BOOL authenticationHandlerInstalled;
@property (nonatomic) NSUInteger resumeRequestGeneration;
@property (nonatomic) NSUInteger activationGeneration;
@property (nonatomic) BOOL processHub;
@property (nonatomic) BOOL listenerRegistered;
@property (nonatomic, weak) MBCIOSGameCenterManager *preferredEventManager;
@property (nonatomic, copy, nullable) NSString *pendingActivationMatchID;
@property (nonatomic, copy, nullable) NSString *pendingDrawOfferMatchID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *lastDrawPayloadByMatchID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *declinedDrawPayloadByMatchID;
- (void)activateMatch:(GKTurnBasedMatch *)match
           completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (BOOL)mayActivateMatch:(GKTurnBasedMatch *)match error:(NSError **)error;
- (BOOL)reserveMatchID:(NSString *)matchID error:(NSError **)error;
- (void)abandonPendingMatchID:(NSString *)matchID;
- (void)commitActiveMatch:(GKTurnBasedMatch *)match;
- (void)quitUnownedMatch:(GKTurnBasedMatch *)match;
+ (MBCIOSGameCenterManager *)ownerForMatchID:(NSString *)matchID;
+ (MBCIOSGameCenterManager *)targetForUnownedMatch;
@end

@implementation MBCIOSGameCenterManager

+ (instancetype)sharedManager
{
    static MBCIOSGameCenterManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[MBCIOSGameCenterManager alloc] init];
        manager.processHub = YES;
    });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pendingVariant = kVarNormal;
        _pendingSideCode = kPlayEither;
        _reportedAchievements = [NSMutableSet set];
        _achievements = [NSMutableDictionary dictionary];
        _existingMatches = @[];
        _lastDrawPayloadByMatchID = [NSMutableDictionary dictionary];
        _declinedDrawPayloadByMatchID = [NSMutableDictionary dictionary];
        _authenticated = [GKLocalPlayer localPlayer].isAuthenticated;
        @synchronized([MBCIOSGameCenterManager class]) {
            [MBCGameCenterManagers() addObject:self];
        }
    }
    return self;
}

- (void)dealloc
{
    @synchronized([MBCIOSGameCenterManager class]) {
        NSMapTable *owners = MBCGameCenterMatchOwners();
        for (NSString *matchID in owners.keyEnumerator.allObjects) {
            if ([owners objectForKey:matchID] == self)
                [owners removeObjectForKey:matchID];
        }
        [MBCGameCenterManagers() removeObject:self];
    }
}

- (void)becomePreferredEventTarget
{
    MBCIOSGameCenterManager *hub = [MBCIOSGameCenterManager sharedManager];
    if (self == hub) return;
    @synchronized([MBCIOSGameCenterManager class]) {
        hub.preferredEventManager = self;
    }
}

- (void)releaseActiveMatch
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self releaseActiveMatch]; });
        return;
    }
    ++self.resumeRequestGeneration;
    ++self.activationGeneration;
    @synchronized([MBCIOSGameCenterManager class]) {
        NSMapTable *owners = MBCGameCenterMatchOwners();
        for (NSString *matchID in @[self.activeMatch.matchID ?: @"",
                                     self.pendingActivationMatchID ?: @""]) {
            if (matchID.length && [owners objectForKey:matchID] == self)
                [owners removeObjectForKey:matchID];
        }
    }
    self.activeMatch = nil;
    self.pendingActivationMatchID = nil;
    self.pendingResumeMatchID = nil;
    self.pendingDrawOfferMatchID = nil;
    [self.lastDrawPayloadByMatchID removeAllObjects];
    [self.declinedDrawPayloadByMatchID removeAllObjects];
    self.localPlayerTurn = NO;
}

- (GKLocalPlayer *)localPlayer
{
    return [GKLocalPlayer localPlayer];
}

- (UIViewController *)topViewControllerFromPresenter:(UIViewController *)presenter
{
    UIViewController *top = presenter;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)recordError:(NSError *)error
{
    if (!error) return;
    self.lastError = error;
    if (self.processHub) {
        NSArray<MBCIOSGameCenterManager *> *managers;
        @synchronized([MBCIOSGameCenterManager class]) {
            managers = MBCGameCenterManagers().allObjects;
        }
        for (MBCIOSGameCenterManager *manager in managers) {
            if (manager == self && !manager.delegate) continue;
            manager.lastError = error;
            dispatch_async(dispatch_get_main_queue(), ^{
                id<MBCIOSGameCenterManagerDelegate> delegate = manager.delegate;
                if (delegate) [delegate gameCenterManager:manager didFailWithError:error];
            });
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            id<MBCIOSGameCenterManagerDelegate> delegate = self.delegate;
            if (delegate) [delegate gameCenterManager:self didFailWithError:error];
        });
    }
}

- (void)publishAuthenticationState
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self publishAuthenticationState]; });
        return;
    }
    if (!self.processHub) {
        [[MBCIOSGameCenterManager sharedManager] publishAuthenticationState];
        return;
    }
    BOOL authenticated = self.localPlayer.isAuthenticated;
    NSArray<MBCIOSGameCenterManager *> *managers;
    @synchronized([MBCIOSGameCenterManager class]) {
        managers = MBCGameCenterManagers().allObjects;
    }
    for (MBCIOSGameCenterManager *manager in managers) {
        manager.authenticated = authenticated;
        if (!authenticated) {
            NSString *pendingID = manager.pendingResumeMatchID;
            [manager releaseActiveMatch];
            manager.pendingResumeMatchID = pendingID;
            manager.existingMatches = @[];
            manager.existingMatchCount = 0;
        }
        id<MBCIOSGameCenterManagerDelegate> delegate = manager.delegate;
        if (delegate) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [delegate gameCenterManager:manager didChangeAuthentication:authenticated];
            });
        }
    }
    if (authenticated) {
        if (!self.listenerRegistered) {
            [self.localPlayer registerListener:self];
            self.listenerRegistered = YES;
        }
        [self loadAchievements];
        [self loadExistingMatches];
        for (MBCIOSGameCenterManager *manager in managers) {
            NSString *pendingMatchID = manager.pendingResumeMatchID;
            manager.pendingResumeMatchID = nil;
            if (pendingMatchID.length)
                [manager resumeMatchWithID:pendingMatchID completion:nil];
        }
    } else {
        UIApplication.sharedApplication.applicationIconBadgeNumber = 0;
    }
}

- (void)authenticateFromPresenter:(UIViewController *)presenter
{
    MBCIOSGameCenterManager *hub = [MBCIOSGameCenterManager sharedManager];
    if (self != hub) {
        [self becomePreferredEventTarget];
        [hub authenticateFromPresenter:presenter];
        return;
    }
    self.authenticationPresenter = presenter;
    GKLocalPlayer *player = self.localPlayer;
    if (player.isAuthenticated) {
        [self publishAuthenticationState];
        return;
    }

    if (self.authenticationHandlerInstalled) return;
    self.authenticationHandlerInstalled = YES;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    player.authenticateHandler = ^(UIViewController *viewController, NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) [strongSelf recordError:error];
        if (viewController) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MBCIOSGameCenterManager *current = weakSelf;
                UIViewController *host = current.authenticationPresenter;
                if (!current || !host || host.presentedViewController == viewController) return;
                [[current topViewControllerFromPresenter:host]
                    presentViewController:viewController animated:YES completion:nil];
            });
        }
        [strongSelf publishAuthenticationState];
    };
    [self publishAuthenticationState];
}

- (void)presentDashboardFromPresenter:(UIViewController *)presenter
{
    if (!self.authenticated) {
        [self recordError:MBCGameCenterError(1,
            MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                  @"Game Center is unavailable until you sign in."))];
        return;
    }
    GKGameCenterViewController *viewController = [[GKGameCenterViewController alloc] init];
    viewController.gameCenterDelegate = self;
    /* This deprecated initializer/property pair is the iOS 13-compatible
     * path.  initWithState: was introduced in iOS 14. */
    viewController.viewState = GKGameCenterViewControllerStateDefault;
    [[self topViewControllerFromPresenter:presenter]
        presentViewController:viewController animated:YES completion:nil];
}

- (void)presentAchievementsFromPresenter:(UIViewController *)presenter
{
    if (!self.authenticated) {
        [self recordError:MBCGameCenterError(1,
            MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                  @"Game Center is unavailable until you sign in."))];
        return;
    }
    GKGameCenterViewController *viewController = [[GKGameCenterViewController alloc] init];
    viewController.gameCenterDelegate = self;
    viewController.viewState = GKGameCenterViewControllerStateAchievements;
    [[self topViewControllerFromPresenter:presenter]
        presentViewController:viewController animated:YES completion:nil];
}

- (uint32_t)playerAttributesForSideCode:(MBCSideCode)sideCode
{
    switch (sideCode) {
        case kPlayWhite: return 0xFFFF0000u;
        case kPlayBlack: return 0x0000FFFFu;
        case kPlayEither:
        default: return 0xFFFFFFFFu;
    }
}

- (void)presentMatchmakerForVariant:(MBCVariant)variant
                           sideCode:(MBCSideCode)sideCode
                          presenter:(UIViewController *)presenter
{
    if (!self.authenticated) {
        [self recordError:MBCGameCenterError(2,
            MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                  @"Game Center is unavailable until you sign in."))];
        return;
    }
    GKMatchRequest *request = [[GKMatchRequest alloc] init];
    request.minPlayers = 2;
    request.maxPlayers = 2;
    request.playerGroup = (uint32_t)variant;
    request.playerAttributes = [self playerAttributesForSideCode:sideCode];
    GKTurnBasedMatchmakerViewController *viewController =
        [[GKTurnBasedMatchmakerViewController alloc] initWithMatchRequest:request];
    viewController.showExistingMatches = YES;
    viewController.turnBasedMatchmakerDelegate = self;
    self.pendingVariant = variant;
    self.pendingSideCode = sideCode;
    [[self topViewControllerFromPresenter:presenter]
        presentViewController:viewController animated:YES completion:nil];
}

- (void)loadExistingMatches
{
    if (!self.processHub) {
        [[MBCIOSGameCenterManager sharedManager] loadExistingMatches];
        return;
    }
    [self fetchExistingMatchesWithCompletion:nil];
}

- (void)fetchExistingMatchesWithCompletion:
    (void (^)(NSArray<GKTurnBasedMatch *> *, NSError * _Nullable))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self fetchExistingMatchesWithCompletion:completion];
        });
        return;
    }
    if (!self.authenticated || !self.localPlayer.isAuthenticated) {
        NSError *error = MBCGameCenterError(1,
            MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                  @"Game Center is unavailable until you sign in."));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordError:error];
            if (completion) completion(@[], error);
        });
        return;
    }
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [GKTurnBasedMatch loadMatchesWithCompletionHandler:^(NSArray<GKTurnBasedMatch *> *matches,
                                                         NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSError *reportedError = error;
            if (!strongSelf.localPlayer.isAuthenticated) {
                reportedError = MBCGameCenterError(1,
                    MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                          @"Game Center is unavailable until you sign in."));
            }
            NSArray<GKTurnBasedMatch *> *snapshot = [matches copy] ?: @[];
            if (reportedError) {
                [strongSelf recordError:reportedError];
                if (completion) completion(snapshot, reportedError);
                return;
            }
            strongSelf.lastError = nil;
            strongSelf.existingMatches = snapshot;
            NSString *localID = strongSelf.localPlayer.playerID;
            NSUInteger localTurnCount = 0;
            for (GKTurnBasedMatch *match in snapshot) {
                if (match.status != GKTurnBasedMatchStatusEnded &&
                    MBCGameCenterPlayerIDMatches(match.currentParticipant, localID)) {
                    ++localTurnCount;
                }
            }
            strongSelf.existingMatchCount = localTurnCount;
            /* Follow macOS badge behavior without requesting notification
             * permission; iOS may ignore the badge under host policy. */
            UIApplication.sharedApplication.applicationIconBadgeNumber = localTurnCount;
            if (completion) completion(snapshot, nil);
        });
    }];
}

- (void)resumeMatchWithID:(NSString *)matchID
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self resumeMatchWithID:matchID]; });
        return;
    }
    if (!matchID.length) return;
    if (!self.authenticated || !self.localPlayer.isAuthenticated) {
        self.pendingResumeMatchID = [matchID copy];
        return;
    }
    self.pendingResumeMatchID = nil;
    [self resumeMatchWithID:matchID completion:nil];
}

- (void)resumeMatchWithID:(NSString *)matchID
              completion:(void (^)(GKTurnBasedMatch * _Nullable,
                                   NSError * _Nullable))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resumeMatchWithID:matchID completion:completion];
        });
        return;
    }
    if (!matchID.length) {
        NSError *error = MBCGameCenterError(11, @"The Game Center match ID is missing.");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordError:error];
            if (completion) completion(nil, error);
        });
        return;
    }
    if (!self.authenticated || !self.localPlayer.isAuthenticated) {
        NSError *error = MBCGameCenterError(1,
            MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                  @"Game Center is unavailable until you sign in."));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordError:error];
            if (completion) completion(nil, error);
        });
        return;
    }
    NSString *requestedID = [matchID copy];
    NSUInteger generation = ++self.resumeRequestGeneration;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [GKTurnBasedMatch loadMatchWithID:requestedID
               withCompletionHandler:^(GKTurnBasedMatch *match, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf.localPlayer.isAuthenticated) {
                NSError *signedOutError = MBCGameCenterError(1,
                    MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                          @"Game Center is unavailable until you sign in."));
                [strongSelf recordError:signedOutError];
                if (completion) completion(nil, signedOutError);
                return;
            }
            if (generation != strongSelf.resumeRequestGeneration) {
                if (completion) completion(nil, MBCGameCenterError(13,
                    @"A newer Game Center match selection replaced this request."));
                return;
            }
            NSError *reportedError = error;
            if (!reportedError && (!match || ![match.matchID isEqualToString:requestedID])) {
                reportedError = MBCGameCenterError(12,
                    @"The selected Game Center match is no longer available.");
            }
            if (reportedError) {
                [strongSelf recordError:reportedError];
                if (completion) completion(nil, reportedError);
                return;
            }
            [strongSelf activateMatch:match completion:^(NSError *activationError) {
                if (completion) completion(activationError ? nil : match, activationError);
            }];
        });
    }];
}

- (void)loadAchievements
{
    if (!self.processHub) {
        [[MBCIOSGameCenterManager sharedManager] loadAchievements];
        return;
    }
    if (!self.authenticated) return;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [GKAchievement loadAchievementsWithCompletionHandler:^(NSArray<GKAchievement *> *achievements,
                                                            NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf recordError:error];
            return;
        }
        [strongSelf.achievements removeAllObjects];
        for (GKAchievement *achievement in achievements ?: @[]) {
            if (achievement.identifier.length) {
                strongSelf.achievements[achievement.identifier] = achievement;
            }
        }
    }];
}

- (void)updateTurnState
{
    NSString *localID = self.localPlayer.playerID;
    self.localPlayerTurn = localID.length &&
        MBCGameCenterPlayerIDMatches(self.activeMatch.currentParticipant, localID);
}

- (GKTurnBasedParticipant *)opponentParticipant
{
    NSString *localID = self.localPlayer.playerID;
    GKTurnBasedParticipant *fallback = nil;
    for (GKTurnBasedParticipant *participant in self.activeMatch.participants) {
        if (!fallback) fallback = participant;
        if (!MBCGameCenterPlayerIDMatches(participant, localID)) return participant;
    }
    return fallback;
}

- (void)activateMatch:(GKTurnBasedMatch *)match
{
    [self activateMatch:match completion:nil];
}

+ (MBCIOSGameCenterManager *)ownerForMatchID:(NSString *)matchID
{
    if (!matchID.length) return nil;
    @synchronized([MBCIOSGameCenterManager class]) {
        return [MBCGameCenterMatchOwners() objectForKey:matchID];
    }
}

+ (MBCIOSGameCenterManager *)targetForUnownedMatch
{
    MBCIOSGameCenterManager *hub = [MBCIOSGameCenterManager sharedManager];
    @synchronized([MBCIOSGameCenterManager class]) {
        MBCIOSGameCenterManager *preferred = hub.preferredEventManager;
        if (preferred.delegate && !preferred.activeMatch &&
            !preferred.pendingActivationMatchID.length) return preferred;
    }
    return nil;
}

- (BOOL)reserveMatchID:(NSString *)matchID error:(NSError **)error
{
    if (!matchID.length) {
        if (error) *error = MBCGameCenterError(11, @"The Game Center match ID is missing.");
        return NO;
    }
    @synchronized([MBCIOSGameCenterManager class]) {
        NSMapTable *owners = MBCGameCenterMatchOwners();
        MBCIOSGameCenterManager *owner = [owners objectForKey:matchID];
        if (owner && owner != self) {
            if (error) *error = MBCGameCenterError(17, MBCIOSLocalizedString(
                @"ios_game_center_same_match_other_window",
                @"This Game Center match is already open in another window."));
            return NO;
        }
        NSString *oldPending = self.pendingActivationMatchID;
        if (oldPending.length && ![oldPending isEqualToString:matchID] &&
            ![oldPending isEqualToString:self.activeMatch.matchID] &&
            [owners objectForKey:oldPending] == self) {
            [owners removeObjectForKey:oldPending];
        }
        [owners setObject:self forKey:matchID];
        self.pendingActivationMatchID = matchID;
    }
    return YES;
}

- (void)abandonPendingMatchID:(NSString *)matchID
{
    if (![self.pendingActivationMatchID isEqualToString:matchID]) return;
    @synchronized([MBCIOSGameCenterManager class]) {
        if (![self.activeMatch.matchID isEqualToString:matchID] &&
            [MBCGameCenterMatchOwners() objectForKey:matchID] == self)
            [MBCGameCenterMatchOwners() removeObjectForKey:matchID];
        self.pendingActivationMatchID = nil;
    }
}

- (void)commitActiveMatch:(GKTurnBasedMatch *)match
{
    NSString *oldMatchID = self.activeMatch.matchID;
    NSString *newMatchID = match.matchID;
    @synchronized([MBCIOSGameCenterManager class]) {
        if (oldMatchID.length && ![oldMatchID isEqualToString:newMatchID] &&
            [MBCGameCenterMatchOwners() objectForKey:oldMatchID] == self)
            [MBCGameCenterMatchOwners() removeObjectForKey:oldMatchID];
        if (newMatchID.length) [MBCGameCenterMatchOwners() setObject:self forKey:newMatchID];
        self.pendingActivationMatchID = nil;
    }
    self.activeMatch = match;
    if (oldMatchID.length && ![oldMatchID isEqualToString:newMatchID]) {
        if ([self.pendingDrawOfferMatchID isEqualToString:oldMatchID])
            self.pendingDrawOfferMatchID = nil;
        [self.lastDrawPayloadByMatchID removeObjectForKey:oldMatchID];
        [self.declinedDrawPayloadByMatchID removeObjectForKey:oldMatchID];
    }
    [self updateTurnState];
}

- (BOOL)mayActivateMatch:(GKTurnBasedMatch *)match error:(NSError **)error
{
    MBCIOSGameCenterManager *owner =
        [MBCIOSGameCenterManager ownerForMatchID:match.matchID];
    if (owner && owner != self) {
        if (error) *error = MBCGameCenterError(17, MBCIOSLocalizedString(
            @"ios_game_center_same_match_other_window",
            @"This Game Center match is already open in another window."));
        return NO;
    }
    id<MBCIOSGameCenterManagerDelegate> delegate = self.delegate;
    if (!delegate || ![delegate respondsToSelector:
        @selector(gameCenterManager:shouldActivateMatch:)] ||
        [delegate gameCenterManager:self shouldActivateMatch:match]) return YES;
    if (error) *error = MBCGameCenterError(16, MBCIOSLocalizedString(
        @"ios_game_center_other_game_open",
        @"Another Game Center game is open. Select its window or close that game first."));
    return NO;
}

- (void)activateMatch:(GKTurnBasedMatch *)match
           completion:(void (^)(NSError * _Nullable))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self activateMatch:match completion:completion];
        });
        return;
    }
    NSError *gateError = nil;
    if (![self mayActivateMatch:match error:&gateError]) {
        [self recordError:gateError];
        if (completion) completion(gateError);
        return;
    }
    if (![self reserveMatchID:match.matchID error:&gateError]) {
        [self recordError:gateError];
        if (completion) completion(gateError);
        return;
    }
    NSUInteger generation = ++self.activationGeneration;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [match loadMatchDataWithCompletionHandler:^(NSData *data, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf.localPlayer.isAuthenticated) {
                NSError *signedOutError = MBCGameCenterError(1,
                    MBCIOSLocalizedString(@"ios_game_center_unavailable",
                                          @"Game Center is unavailable until you sign in."));
                [strongSelf abandonPendingMatchID:match.matchID];
                [strongSelf recordError:signedOutError];
                if (completion) completion(signedOutError);
                return;
            }
            if (generation != strongSelf.activationGeneration) {
                if (completion) completion(MBCGameCenterError(13,
                    @"A newer Game Center match selection replaced this request."));
                return;
            }
            NSError *reportedError = error;
            NSError *parseError = nil;
            NSDictionary *dictionary = (!reportedError && data.length)
                ? [MBCIOSGameCenterManager gameDictionaryForData:data error:&parseError] : nil;
            if (!reportedError) reportedError = parseError;
            if (reportedError) {
                [strongSelf abandonPendingMatchID:match.matchID];
                [strongSelf recordError:reportedError];
                if (completion) completion(reportedError);
                return;
            }

            BOOL initial = !dictionary || ![dictionary[@"Position"] isKindOfClass:[NSString class]];
            NSMutableDictionary *payload = [dictionary mutableCopy] ?: [NSMutableDictionary dictionary];
            NSString *localID = strongSelf.localPlayer.playerID;
            NSString *whiteID = [payload[@"WhitePlayerID"] isKindOfClass:[NSString class]]
                ? payload[@"WhitePlayerID"] : nil;
            NSString *blackID = [payload[@"BlackPlayerID"] isKindOfClass:[NSString class]]
                ? payload[@"BlackPlayerID"] : nil;
            BOOL localWhite = [whiteID isEqualToString:localID];
            BOOL localBlack = [blackID isEqualToString:localID];
            MBCSide localSide = kNeitherSide;
            if (localWhite) localSide = kWhiteSide;
            else if (localBlack) localSide = kBlackSide;
            else if (initial && !whiteID && !blackID) {
                BOOL chooseWhite = strongSelf.pendingSideCode == kPlayWhite ||
                    (strongSelf.pendingSideCode == kPlayEither && (arc4random_uniform(2) == 0));
                localSide = chooseWhite ? kWhiteSide : kBlackSide;
                payload[chooseWhite ? @"WhitePlayerID" : @"BlackPlayerID"] = localID ?: @"";
            } else if (!whiteID) {
                localSide = kWhiteSide;
                payload[@"WhitePlayerID"] = localID ?: @"";
            } else if (!blackID) {
                localSide = kBlackSide;
                payload[@"BlackPlayerID"] = localID ?: @"";
            }
            if (localSide == kNeitherSide) {
                reportedError = MBCGameCenterError(14,
                    @"This Game Center account is not a participant in the selected match.");
                [strongSelf abandonPendingMatchID:match.matchID];
                [strongSelf recordError:reportedError];
                if (completion) completion(reportedError);
                return;
            }
            if (!payload[@"Variant"]) {
                payload[@"Variant"] = MBCGameCenterVariantName(strongSelf.pendingVariant);
            }
            payload[@"Side"] = @(localSide);
            payload[@"WhiteType"] = @"human";
            payload[@"BlackType"] = @"human";
            if (match.matchID.length) {
                payload[@"MatchID"] = match.matchID;
                payload[@"GameCenterMatchID"] = match.matchID;
            }
            NSError *serializationError = nil;
            NSData *normalized = [MBCIOSGameCenterManager dataForGameDictionary:payload
                                                                            error:&serializationError];
            if (!normalized) {
                [strongSelf abandonPendingMatchID:match.matchID];
                [strongSelf recordError:serializationError];
                if (completion) completion(serializationError);
                return;
            }
            NSError *gateError = nil;
            if (![strongSelf mayActivateMatch:match error:&gateError]) {
                [strongSelf abandonPendingMatchID:match.matchID];
                [strongSelf recordError:gateError];
                if (completion) completion(gateError);
                return;
            }
            strongSelf.lastError = nil;
            [strongSelf commitActiveMatch:match];
            [strongSelf loadExistingMatches];
            MBCVariant variant = MBCGameCenterVariantFromDictionary(payload);
            id<MBCIOSGameCenterManagerDelegate> delegate = strongSelf.delegate;
            if (initial) {
                [delegate gameCenterManager:strongSelf
                           didActivateMatch:match
                                  matchData:normalized
                                 localSide:localSide
                                   variant:variant
                                isInitial:YES];
            } else {
                [delegate gameCenterManager:strongSelf didReceiveMatch:match matchData:normalized];
            }
            NSString *request = [payload[@"Request"] isKindOfClass:[NSString class]]
                ? payload[@"Request"] : nil;
            BOOL alreadyDeclinedDraw = [request isEqualToString:@"Draw"] &&
                [strongSelf.declinedDrawPayloadByMatchID[match.matchID]
                    isEqualToData:normalized];
            if (request.length && strongSelf.localPlayerTurn && !alreadyDeclinedDraw) {
                if ([request isEqualToString:@"Draw"] && match.matchID.length)
                    strongSelf.lastDrawPayloadByMatchID[match.matchID] = normalized;
                [delegate gameCenterManager:strongSelf didReceiveRequest:request matchData:normalized];
            } else if (!request.length && match.matchID.length) {
                [strongSelf.lastDrawPayloadByMatchID removeObjectForKey:match.matchID];
                [strongSelf.declinedDrawPayloadByMatchID removeObjectForKey:match.matchID];
            }
            if (completion) completion(nil);
        });
    }];
}

- (void)completeInitialMatchSetupWithData:(NSData *)data
                                localSide:(MBCSide)localSide
                                completion:(void (^)(NSError * _Nullable))completion
{
    if (!self.activeMatch || !data) {
        if (completion) completion(MBCGameCenterError(3, @"No Game Center match is active."));
        return;
    }
    [self updateTurnState];
    __weak MBCIOSGameCenterManager *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    };
    GKTurnBasedParticipant *opponent = [self opponentParticipant];
    if (!opponent || !self.localPlayerTurn) {
        finish(MBCGameCenterError(4, @"Game Center did not assign the local turn."));
        return;
    }
    if (localSide == kBlackSide) {
        [self.activeMatch endTurnWithNextParticipants:@[opponent]
                                           turnTimeout:kMBCIOSGameCenterTurnTimeout
                                             matchData:data
                                     completionHandler:^(NSError *error) {
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            if (strongSelf && error) [strongSelf recordError:error];
            finish(error);
        }];
    } else {
        [self.activeMatch saveCurrentTurnWithMatchData:data completionHandler:^(NSError *error) {
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            if (strongSelf && error) [strongSelf recordError:error];
            finish(error);
        }];
    }
}

- (void)sendCurrentTurnWithData:(NSData *)data
                      completion:(void (^)(NSError * _Nullable))completion
{
    if (!self.activeMatch || !data) {
        if (completion) completion(MBCGameCenterError(3, @"No Game Center match is active."));
        return;
    }
    [self updateTurnState];
    if (!self.localPlayerTurn) {
        NSError *error = MBCGameCenterError(5, @"It is not this player's Game Center turn.");
        [self recordError:error];
        if (completion) completion(error);
        return;
    }
    GKTurnBasedParticipant *opponent = [self opponentParticipant];
    if (!opponent) {
        NSError *error = MBCGameCenterError(6, @"The Game Center opponent is unavailable.");
        [self recordError:error];
        if (completion) completion(error);
        return;
    }
    NSString *submittedMatchID = self.activeMatch.matchID;
    BOOL stagedDrawOffer = submittedMatchID.length &&
        [self.pendingDrawOfferMatchID isEqualToString:submittedMatchID];
    NSData *submittedData = data;
    if (stagedDrawOffer) {
        NSError *payloadError = nil;
        NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data
                                                                            error:&payloadError];
        if (!dictionary) {
            if (completion) completion(payloadError);
            return;
        }
        NSMutableDictionary *payload = [dictionary mutableCopy];
        if (!payload[@"Request"]) payload[@"Request"] = @"Draw";
        submittedData = [MBCIOSGameCenterManager dataForGameDictionary:payload
                                                                 error:&payloadError];
        if (!submittedData) {
            if (completion) completion(payloadError);
            return;
        }
    }
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [self.activeMatch endTurnWithNextParticipants:@[opponent]
                                       turnTimeout:kMBCIOSGameCenterTurnTimeout
                                         matchData:submittedData
                                 completionHandler:^(NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (strongSelf && error) [strongSelf recordError:error];
        if (strongSelf && !error && stagedDrawOffer &&
            [strongSelf.pendingDrawOfferMatchID isEqualToString:submittedMatchID])
            strongSelf.pendingDrawOfferMatchID = nil;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}

- (void)requestTakebackWithData:(NSData *)data
                     completion:(void (^)(NSError * _Nullable))completion
{
    NSError *error = nil;
    NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data error:&error];
    if (!dictionary) { if (completion) completion(error); return; }
    NSMutableDictionary *payload = [dictionary mutableCopy];
    if (!payload[@"Request"]) payload[@"Request"] = @"Takeback";
    NSData *requestData = [MBCIOSGameCenterManager dataForGameDictionary:payload error:&error];
    if (!requestData) { if (completion) completion(error); return; }
    [self sendCurrentTurnWithData:requestData completion:completion];
}

- (void)requestDrawWithData:(NSData *)data
                 completion:(void (^)(NSError * _Nullable))completion
{
    NSError *error = nil;
    NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data error:&error];
    if (!dictionary) { if (completion) completion(error); return; }
    if (!self.activeMatch.matchID.length) {
        if (completion) completion(MBCGameCenterError(3, @"No Game Center match is active."));
        return;
    }
    [self updateTurnState];
    if (!self.localPlayerTurn) {
        if (completion) completion(MBCGameCenterError(5,
            @"It is not this player's Game Center turn."));
        return;
    }
    /* macOS Chess attaches the offer to the next move. This call only stages
     * that request; sendCurrentTurnWithData: carries it on the next turn. */
    self.pendingDrawOfferMatchID = self.activeMatch.matchID;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
}

- (void)respondToRequest:(NSString *)request
                    allow:(BOOL)allow
                     data:(NSData *)data
               completion:(void (^)(NSError * _Nullable))completion
{
    if ([request isEqualToString:@"Draw"]) {
        if (!self.activeMatch.matchID.length) {
            if (completion) completion(MBCGameCenterError(3,
                @"No Game Center match is active."));
            return;
        }
        [self updateTurnState];
        if (!self.localPlayerTurn) {
            if (completion) completion(MBCGameCenterError(5,
                @"It is not this player's Game Center turn."));
            return;
        }
        if (!allow) {
            NSString *matchID = self.activeMatch.matchID;
            NSData *offered = self.lastDrawPayloadByMatchID[matchID] ?:
                self.activeMatch.matchData ?: data;
            if (offered) self.declinedDrawPayloadByMatchID[matchID] = offered;
            /* The recipient keeps the turn. A refusal is recorded locally so
             * the same incoming payload does not repeatedly show the offer. */
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        NSError *payloadError = nil;
        NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data
                                                                            error:&payloadError];
        if (!dictionary) {
            if (completion) completion(payloadError);
            return;
        }
        NSMutableDictionary *payload = [dictionary mutableCopy];
        [payload removeObjectForKey:@"Request"];
        [payload removeObjectForKey:@"Response"];
        payload[@"Result"] = @"1/2-1/2";
        NSData *drawData = [MBCIOSGameCenterManager dataForGameDictionary:payload
                                                                   error:&payloadError];
        if (!drawData) {
            if (completion) completion(payloadError);
            return;
        }
        [self finishWithCommand:kCmdDraw data:drawData completion:completion];
        return;
    }
    NSError *error = nil;
    NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data error:&error];
    if (!dictionary) { if (completion) completion(error); return; }
    NSMutableDictionary *payload = [dictionary mutableCopy];
    [payload removeObjectForKey:@"Request"];
    if ([request isEqualToString:@"Takeback"]) {
        payload[@"Response"] = allow ? @"Takeback" : @"NoTakeback";
    } else if ([request isEqualToString:@"Draw"]) {
        payload[@"Response"] = allow ? @"Draw" : @"NoDraw";
    }
    NSData *responseData = [MBCIOSGameCenterManager dataForGameDictionary:payload error:&error];
    if (!responseData) { if (completion) completion(error); return; }
    [self sendCurrentTurnWithData:responseData completion:completion];
}

- (void)finishWithCommand:(MBCMoveCode)command
                     data:(NSData *)data
               completion:(void (^)(NSError * _Nullable))completion
{
    if (!self.activeMatch || !data) {
        if (completion) completion(MBCGameCenterError(3, @"No Game Center match is active."));
        return;
    }
    [self updateTurnState];
    if (!self.localPlayerTurn) {
        NSError *error = MBCGameCenterError(5, @"It is not this player's Game Center turn.");
        [self recordError:error];
        if (completion) completion(error);
        return;
    }
    NSError *parseError = nil;
    NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:data error:&parseError];
    if (!dictionary) { if (completion) completion(parseError); return; }
    NSString *whiteID = dictionary[@"WhitePlayerID"];
    GKTurnBasedMatchOutcome whiteOutcome = GKTurnBasedMatchOutcomeLost;
    GKTurnBasedMatchOutcome blackOutcome = GKTurnBasedMatchOutcomeLost;
    if (command == kCmdDraw) {
        whiteOutcome = blackOutcome = GKTurnBasedMatchOutcomeTied;
    } else if (command == kCmdWhiteWins) {
        whiteOutcome = GKTurnBasedMatchOutcomeWon;
        blackOutcome = GKTurnBasedMatchOutcomeLost;
    } else {
        whiteOutcome = GKTurnBasedMatchOutcomeLost;
        blackOutcome = GKTurnBasedMatchOutcomeWon;
    }
    for (GKTurnBasedParticipant *participant in self.activeMatch.participants) {
        participant.matchOutcome = MBCGameCenterPlayerIDMatches(participant, whiteID)
            ? whiteOutcome : blackOutcome;
    }
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [self.activeMatch endMatchInTurnWithMatchData:data completionHandler:^(NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (strongSelf && error) [strongSelf recordError:error];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}

- (void)resignWithData:(NSData *)data
            completion:(void (^)(NSError * _Nullable))completion
{
    if (!self.activeMatch) {
        if (completion) completion(MBCGameCenterError(3, @"No Game Center match is active."));
        return;
    }
    GKTurnBasedParticipant *local = nil;
    for (GKTurnBasedParticipant *participant in self.activeMatch.participants) {
        if (MBCGameCenterPlayerIDMatches(participant, self.localPlayer.playerID)) {
            local = participant;
            break;
        }
    }
    if (!local) {
        if (completion) completion(MBCGameCenterError(7, @"The local Game Center participant is unavailable."));
        return;
    }
    local.matchOutcome = GKTurnBasedMatchOutcomeLost;
    [self updateTurnState];
    GKTurnBasedParticipant *opponent = [self opponentParticipant];
    for (GKTurnBasedParticipant *participant in self.activeMatch.participants) {
        if (participant != local) participant.matchOutcome = GKTurnBasedMatchOutcomeWon;
    }
    __weak MBCIOSGameCenterManager *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (strongSelf && error) [strongSelf recordError:error];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    };
    if (self.localPlayerTurn && opponent) {
        [self.activeMatch participantQuitInTurnWithOutcome:GKTurnBasedMatchOutcomeLost
                                          nextParticipants:@[opponent]
                                               turnTimeout:kMBCIOSGameCenterTurnTimeout
                                                 matchData:data
                                         completionHandler:finish];
    } else {
        [self.activeMatch participantQuitOutOfTurnWithOutcome:GKTurnBasedMatchOutcomeLost
                                            withCompletionHandler:finish];
    }
}

- (void)reportAchievementIdentifier:(NSString *)identifier
                    percentComplete:(double)percentComplete
{
    if (!self.processHub) {
        [[MBCIOSGameCenterManager sharedManager]
            reportAchievementIdentifier:identifier percentComplete:percentComplete];
        return;
    }
    if (!identifier.length || !self.authenticated ||
        [self.reportedAchievements containsObject:identifier]) return;
    GKAchievement *existing = self.achievements[identifier];
    if (existing && existing.percentComplete >= percentComplete) return;
    [self.reportedAchievements addObject:identifier];
    GKAchievement *achievement = [[GKAchievement alloc] initWithIdentifier:identifier];
    achievement.percentComplete = MAX(existing.percentComplete,
                                      MAX(0.0, MIN(100.0, percentComplete)));
    achievement.showsCompletionBanner = YES;
    self.achievements[identifier] = achievement;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [GKAchievement reportAchievements:@[achievement] withCompletionHandler:^(NSError *error) {
        if (error) {
            MBCIOSGameCenterManager *strongSelf = weakSelf;
            [strongSelf.reportedAchievements removeObject:identifier];
            NSLog(@"Game Center achievement %@ failed: %@", identifier, error);
        }
    }];
}

+ (NSArray<NSString *> *)achievementIdentifiers
{
    return @[
        @"AppleChess_Luddite", @"AppleChess_King_of_the_Cloud",
        @"AppleChess_Battle_Royal", @"AppleChess_Lightning_Loser",
        @"AppleChess_Checker", @"AppleChess_Sidestepped",
        @"AppleChess_Promotional_Value", @"AppleChess_Promotional_Discount",
        @"AppleChess_One_Step_Beyond", @"AppleChess_Pawnbroker",
        @"AppleChess_Pikeman", @"AppleChess_Take_no_Prisoners",
        @"AppleChess_Blitz", @"AppleChess_Last_Ditch_Effort",
        @"AppleChess_Aerial_Attack", @"AppleChess_Duck_and_Cover",
        @"AppleChess_Merciful", @"AppleChess_Cry_me_a_River",
        @"AppleChess_Not_So_Fast"
    ];
}

+ (NSData *)dataForGameDictionary:(NSDictionary *)dictionary
                             error:(NSError **)error
{
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (error) *error = MBCGameCenterError(8, @"Game Center data is not a dictionary.");
        return nil;
    }
    return [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                       format:NSPropertyListXMLFormat_v1_0
                                                      options:0
                                                        error:error];
}

+ (NSDictionary *)gameDictionaryForData:(NSData *)data error:(NSError **)error
{
    if (!data.length) {
        if (error) *error = MBCGameCenterError(9, @"Game Center returned an empty match payload.");
        return nil;
    }
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil
                                                           error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) *error = MBCGameCenterError(10, @"Game Center returned an invalid match payload.");
        return nil;
    }
    return value;
}

#pragma mark - GKTurnBasedMatchmakerViewControllerDelegate

- (void)turnBasedMatchmakerViewControllerWasCancelled:(GKTurnBasedMatchmakerViewController *)viewController
{
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)turnBasedMatchmakerViewController:(GKTurnBasedMatchmakerViewController *)viewController
                          didFailWithError:(NSError *)error
{
    [viewController dismissViewControllerAnimated:YES completion:nil];
    [self recordError:error];
}

- (void)turnBasedMatchmakerViewController:(GKTurnBasedMatchmakerViewController *)viewController
                              didFindMatch:(GKTurnBasedMatch *)match
{
    [viewController dismissViewControllerAnimated:YES completion:^{
        [self activateMatch:match];
    }];
}

- (void)turnBasedMatchmakerViewController:(GKTurnBasedMatchmakerViewController *)viewController
                         playerQuitForMatch:(GKTurnBasedMatch *)match
{
    [viewController dismissViewControllerAnimated:YES completion:nil];
    [self activateMatch:match];
}

#pragma mark - GKLocalPlayerListener

- (void)player:(GKPlayer *)player
receivedTurnEventForMatch:(GKTurnBasedMatch *)match
didBecomeActive:(BOOL)didBecomeActive
{
    (void)player;
    (void)didBecomeActive;
    if (self.processHub) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self player:player receivedTurnEventForMatch:match didBecomeActive:didBecomeActive];
            });
            return;
        }
        MBCIOSGameCenterManager *target =
            [MBCIOSGameCenterManager ownerForMatchID:match.matchID] ?:
            [MBCIOSGameCenterManager targetForUnownedMatch];
        if (target && target != self) [target activateMatch:match];
        else [self loadExistingMatches];
        return;
    }
    [self activateMatch:match];
}

- (void)player:(GKPlayer *)player matchEnded:(GKTurnBasedMatch *)match
{
    (void)player;
    if (self.processHub) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self player:player matchEnded:match]; });
            return;
        }
        MBCIOSGameCenterManager *owner =
            [MBCIOSGameCenterManager ownerForMatchID:match.matchID];
        if (owner && owner != self) [owner player:player matchEnded:match];
        [self loadExistingMatches];
        return;
    }
    BOOL isSelectedMatch = !self.activeMatch ||
        [self.activeMatch.matchID isEqualToString:match.matchID];
    if (isSelectedMatch) self.activeMatch = match;
    __weak MBCIOSGameCenterManager *weakSelf = self;
    [match loadMatchDataWithCompletionHandler:^(NSData *data, NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf recordError:error];
            return;
        }
        if (isSelectedMatch) [strongSelf updateTurnState];
        GKTurnBasedMatchOutcome outcome = GKTurnBasedMatchOutcomeNone;
        for (GKTurnBasedParticipant *participant in match.participants) {
            if (MBCGameCenterPlayerIDMatches(participant, strongSelf.localPlayer.playerID)) {
                outcome = participant.matchOutcome;
                break;
            }
        }
        id<MBCIOSGameCenterManagerDelegate> delegate = strongSelf.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate gameCenterManager:strongSelf didEndMatch:match localOutcome:outcome];
        });
    }];
}

- (void)player:(GKPlayer *)player wantsToQuitMatch:(GKTurnBasedMatch *)match
{
    (void)player;
    if (self.processHub) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self player:player wantsToQuitMatch:match];
            });
            return;
        }
        MBCIOSGameCenterManager *owner =
            [MBCIOSGameCenterManager ownerForMatchID:match.matchID];
        if (owner && owner != self) [owner player:player wantsToQuitMatch:match];
        else [self quitUnownedMatch:match];
        return;
    }
    if (self.activeMatch && ![self.activeMatch.matchID isEqualToString:match.matchID]) {
        [self recordError:MBCGameCenterError(16, MBCIOSLocalizedString(
            @"ios_game_center_other_game_open",
            @"Another Game Center game is open. Select its window or close that game first."))];
        return;
    }
    self.activeMatch = match;
    [self resignWithData:match.matchData completion:nil];
}

- (void)quitUnownedMatch:(GKTurnBasedMatch *)match
{
    /* GameKit can ask the account to leave a match that is not open in any
     * window. Honor that request directly; selecting it in the foreground
     * controller would replace an unrelated game. */
    NSString *localID = self.localPlayer.playerID;
    GKTurnBasedParticipant *local = nil;
    GKTurnBasedParticipant *opponent = nil;
    for (GKTurnBasedParticipant *participant in match.participants) {
        if (MBCGameCenterPlayerIDMatches(participant, localID)) local = participant;
        else if (!opponent) opponent = participant;
    }
    if (!local) {
        [self recordError:MBCGameCenterError(7,
            @"The local Game Center participant is unavailable.")];
        return;
    }
    local.matchOutcome = GKTurnBasedMatchOutcomeLost;
    for (GKTurnBasedParticipant *participant in match.participants) {
        if (participant != local) participant.matchOutcome = GKTurnBasedMatchOutcomeWon;
    }
    BOOL localTurn = MBCGameCenterPlayerIDMatches(match.currentParticipant, localID);
    __weak MBCIOSGameCenterManager *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        MBCIOSGameCenterManager *strongSelf = weakSelf;
        if (error) [strongSelf recordError:error];
        [strongSelf loadExistingMatches];
    };
    if (localTurn && opponent) {
        [match participantQuitInTurnWithOutcome:GKTurnBasedMatchOutcomeLost
                              nextParticipants:@[opponent]
                                   turnTimeout:kMBCIOSGameCenterTurnTimeout
                                     matchData:match.matchData
                             completionHandler:finish];
    } else {
        [match participantQuitOutOfTurnWithOutcome:GKTurnBasedMatchOutcomeLost
                            withCompletionHandler:finish];
    }
}

- (void)player:(GKPlayer *)player
didRequestMatchWithOtherPlayers:(NSArray<GKPlayer *> *)playersToInvite
{
    (void)player;
    if (self.processHub) {
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self player:player didRequestMatchWithOtherPlayers:playersToInvite];
            });
            return;
        }
        MBCIOSGameCenterManager *target = self.preferredEventManager;
        if (target.delegate && target != self)
            [target player:player didRequestMatchWithOtherPlayers:playersToInvite];
        return;
    }
    if (!self.authenticated) return;
    GKMatchRequest *request = [[GKMatchRequest alloc] init];
    request.minPlayers = 2;
    request.maxPlayers = 2;
    request.recipients = playersToInvite;
    request.playerGroup = (uint32_t)self.pendingVariant;
    GKTurnBasedMatchmakerViewController *viewController =
        [[GKTurnBasedMatchmakerViewController alloc] initWithMatchRequest:request];
    viewController.showExistingMatches = YES;
    viewController.turnBasedMatchmakerDelegate = self;
    UIViewController *presenter = [self.delegate gameCenterPresentationViewControllerForManager:self];
    if (presenter) [[self topViewControllerFromPresenter:presenter]
        presentViewController:viewController animated:YES completion:nil];
}

- (void)player:(GKPlayer *)player
didRequestMatchWithRecipients:(NSArray<GKPlayer *> *)recipientPlayers
{
    [self player:player didRequestMatchWithOtherPlayers:recipientPlayers];
}

#pragma mark - GKGameCenterControllerDelegate

- (void)gameCenterViewControllerDidFinish:(GKGameCenterViewController *)gameCenterViewController
{
    [gameCenterViewController dismissViewControllerAnimated:YES completion:nil];
}

@end
