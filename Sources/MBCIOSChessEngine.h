/*
 * iOS transport for the shared Sjeng chess engine.
 *
 * The macOS target uses MBCEngine's NSTask/NSPipe/NSPort transport.  The iOS
 * target keeps the same xboard protocol and notification contract while
 * running the shared Sjeng sources in-process on a private pthread.  This
 * avoids trying to execute a nested helper from the iOS application sandbox.
 */

#import <Foundation/Foundation.h>

#import "MBCBoard.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MBCIOSChessEngineDidStopNotification;

@interface MBCIOSChessEngine : NSObject

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, strong, readonly, nullable) MBCMove *lastPonder;
/* The board view whose unchecked local moves belong to this engine. Set
 * before startGame: so concurrent iPad scenes cannot feed each other. */
@property (nonatomic, weak, nullable) id moveSource;
/* Stable game identifier for independent persistent learning files. */
@property (nonatomic, copy) NSString *sessionIdentifier;

- (void)startGame:(MBCVariant)variant
          playing:(MBCSide)engineSide
       searchTime:(NSInteger)searchTime;

/* Starts the same xboard session from the supplied board position.  This is
 * used by local takeback so the in-process engine and the shared board model
 * continue from the same position after the old session is stopped. */
- (void)startGame:(MBCVariant)variant
          playing:(MBCSide)engineSide
       searchTime:(NSInteger)searchTime
        fromBoard:(nullable MBCBoard *)board;

- (void)setSearchTime:(NSInteger)searchTime;

/*
 * Computer-vs-computer games wait for the board view to finish presenting
 * the current move before asking Sjeng for the next one.  This preserves the
 * macOS turn/animation boundary instead of allowing engine output to run
 * ahead of the visible board.
 */
- (void)movePresentationDidFinish;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
