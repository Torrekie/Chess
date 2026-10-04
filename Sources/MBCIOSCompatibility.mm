/*
 * iOS compatibility symbols for the shared board model.
 *
 * The macOS application supplies these through MBCPlayer/MBCDocument. The
 * first iOS shell deliberately keeps the same notification names so the board
 * model does not need a second implementation.
 */

#import "MBCPlayer.h"

NSString * const MBCGameLoadNotification            = @"MBCGameLoad";
NSString * const MBCGameStartNotification           = @"MBCGameStart";
NSString * const MBCWhiteMoveNotification           = @"MBCWhiteMove";
NSString * const MBCBlackMoveNotification           = @"MBCBlackMove";
NSString * const MBCUncheckedWhiteMoveNotification  = @"MBCUncheckedWhiteMove";
NSString * const MBCUncheckedBlackMoveNotification  = @"MBCUncheckedBlackMove";
NSString * const MBCIllegalMoveNotification         = @"MBCIllegalMove";
NSString * const MBCEndMoveNotification             = @"MBCEndMove";
NSString * const MBCTakebackNotification            = @"MBCTakeback";
NSString * const MBCGameEndNotification             = @"MBCGameEnd";
NSString * const kMBCHumanPlayer                    = @"Human";
NSString * const kMBCEnginePlayer                   = @"Computer";

void MBCAbort(NSString *message, id document)
{
    (void)document;
    NSLog(@"Chess board invariant failure: %@", message);
}
