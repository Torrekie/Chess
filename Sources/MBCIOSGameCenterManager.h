/*
 * UIKit/GameKit bridge for the turn based service used by Apple Chess.
 *
 * The macOS target keeps this work in MBCController/MBCDocument.  Those
 * classes are AppKit documents and are intentionally not part of the iOS
 * target, so this small coordinator preserves the same match payload and
 * turn boundaries without pulling AppKit or the macOS document controller
 * into the mobile build.
 */

#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>

#import "MBCBoardEnums.h"

NS_ASSUME_NONNULL_BEGIN

@class MBCIOSGameCenterManager;

@protocol MBCIOSGameCenterManagerDelegate <NSObject>
- (UIViewController *)gameCenterPresentationViewControllerForManager:(MBCIOSGameCenterManager *)manager;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
         didActivateMatch:(GKTurnBasedMatch *)match
                matchData:(NSData *)matchData
               localSide:(MBCSide)localSide
                 variant:(MBCVariant)variant
              isInitial:(BOOL)isInitial;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
         didReceiveMatch:(GKTurnBasedMatch *)match
                matchData:(NSData *)matchData;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
             didEndMatch:(GKTurnBasedMatch *)match
            localOutcome:(GKTurnBasedMatchOutcome)outcome;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
        didReceiveRequest:(NSString *)request
                matchData:(NSData *)matchData;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
  didChangeAuthentication:(BOOL)authenticated;
- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
       didFailWithError:(NSError *)error;
@optional
/* Called before this window selects a match. */
- (BOOL)gameCenterManager:(MBCIOSGameCenterManager *)manager
 shouldActivateMatch:(GKTurnBasedMatch *)match;
@end

@interface MBCIOSGameCenterManager : NSObject <GKLocalPlayerListener,
                                               GKTurnBasedMatchmakerViewControllerDelegate,
                                               GKGameCenterControllerDelegate>

@property (nonatomic, weak, nullable) id<MBCIOSGameCenterManagerDelegate> delegate;
@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;
@property (nonatomic, readonly) GKLocalPlayer *localPlayer;
@property (nonatomic, readonly, nullable) NSError *lastError;
@property (nonatomic, readonly, nullable) GKTurnBasedMatch *activeMatch;
@property (nonatomic, readonly) NSUInteger existingMatchCount;
@property (nonatomic, readonly, getter=isLocalPlayerTurn) BOOL localPlayerTurn;

/* Shared account/authentication and GameKit event hub. Game windows should
 * own separate manager instances so each keeps its own selected match. */
+ (instancetype)sharedManager;

/* Mark this window as the destination for unowned incoming matches when it
 * takes focus. Match events for a match already open elsewhere always go to
 * that match's owner. Release the selected match when leaving its document. */
- (void)becomePreferredEventTarget;
- (void)releaseActiveMatch;

/* Authentication starts from the app shell and presents GameKit's account UI. */
- (void)authenticateFromPresenter:(UIViewController *)presenter;
- (void)presentDashboardFromPresenter:(UIViewController *)presenter;
- (void)presentAchievementsFromPresenter:(UIViewController *)presenter;
- (void)presentMatchmakerForVariant:(MBCVariant)variant
                           sideCode:(MBCSideCode)sideCode
                          presenter:(UIViewController *)presenter;
- (void)loadExistingMatches;
- (void)resumeMatchWithID:(NSString *)matchID;

/* Completions run on the main queue. Enumeration can return a partial list
 * with an error, as GameKit permits; only a complete result updates the
 * manager's cached count. A successful resume has delivered its match to the
 * existing delegate by the time its completion runs. */
- (void)fetchExistingMatchesWithCompletion:
    (void (^ _Nullable)(NSArray<GKTurnBasedMatch *> *matches,
                       NSError * _Nullable error))completion;
- (void)resumeMatchWithID:(NSString *)matchID
              completion:(void (^ _Nullable)(GKTurnBasedMatch * _Nullable match,
                                             NSError * _Nullable error))completion;

/* The controller supplies the fully serialized board after a newly matched
 * game has selected its side. */
- (void)completeInitialMatchSetupWithData:(NSData *)data
                                localSide:(MBCSide)localSide
                                completion:(void (^ _Nullable)(NSError * _Nullable error))completion;

/* Turn data is the same property-list envelope used by the macOS document.
 * These methods are used for moves, draw/takeback requests and responses. */
- (void)sendCurrentTurnWithData:(NSData *)data
                      completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)requestTakebackWithData:(NSData *)data
                     completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)requestDrawWithData:(NSData *)data
                 completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)respondToRequest:(NSString *)request
                    allow:(BOOL)allow
                     data:(NSData *)data
               completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)finishWithCommand:(MBCMoveCode)command
                     data:(NSData *)data
               completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)resignWithData:(NSData *)data
            completion:(void (^ _Nullable)(NSError * _Nullable error))completion;

- (void)reportAchievementIdentifier:(NSString *)identifier
                    percentComplete:(double)percentComplete;

+ (NSArray<NSString *> *)achievementIdentifiers;
+ (nullable NSData *)dataForGameDictionary:(NSDictionary *)dictionary
                                     error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)gameDictionaryForData:(NSData *)data
                                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
