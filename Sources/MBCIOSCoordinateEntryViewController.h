/* Hardware-keyboard friendly coordinate move entry for iOS Chess. */

#import <UIKit/UIKit.h>

#import "MBCBoard.h"

NS_ASSUME_NONNULL_BEGIN

/* Return NO and optionally fill rejectionMessage to keep the sheet open. The
 * caller can reject input when a Game Center turn or engine state changed. */
typedef BOOL (^MBCIOSCoordinateMoveSubmissionHandler)(
    MBCMove *move, NSString * _Nullable * _Nullable rejectionMessage);

@interface MBCIOSCoordinateEntryViewController : UIViewController

@property (nonatomic, weak, readonly, nullable) MBCBoard *board;
@property (nonatomic, readonly) MBCVariant variant;
@property (nonatomic, readonly) MBCSide allowedSide;
@property (nonatomic, strong, readonly) UITextField *coordinateField;
@property (nonatomic, strong, readonly) UILabel *feedbackLabel;
/* Redraw any on-board promotion marker after =Q or an explicit promotion. */
@property (nonatomic, copy, nullable) void (^promotionChangedHandler)(MBCPieceCode choice);

- (instancetype)initWithBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                  allowedSide:(MBCSide)allowedSide
            submissionHandler:(MBCIOSCoordinateMoveSubmissionHandler)submissionHandler;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/* Parse and validate against the current board, including king safety.
 * Accepted formats: e2e4, e2-e4, e7e8q, e7e8=Q, and Crazyhouse N@f3.
 * A missing promotion suffix uses the board's current default choice. */
+ (nullable MBCMove *)moveForInput:(NSString *)input
                             board:(MBCBoard *)board
                           variant:(MBCVariant)variant
                       allowedSide:(MBCSide)allowedSide
                          feedback:(NSString * _Nullable * _Nullable)feedback;

/* =q, =r, =b, =n, and =k (Suicide only) set both default promotions. */
+ (BOOL)applyPromotionShortcut:(NSString *)input
                         board:(MBCBoard *)board
                       variant:(MBCVariant)variant
                      feedback:(NSString * _Nullable * _Nullable)feedback;

@end

NS_ASSUME_NONNULL_END
