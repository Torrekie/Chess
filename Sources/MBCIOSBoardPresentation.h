#import <UIKit/UIKit.h>
#import "MBCBoardViewInterface.h"
#import "MBCBoardCommon.h"

@class MBCBoard;
@class MBCMove;

typedef NS_ENUM(NSInteger, MBCIOSRendererKind) {
    MBCIOSRendererMetal = 0,
    MBCIOSRendererOpenGL = 1,
};

FOUNDATION_EXPORT NSString * const MBCIOSBoardIdleTapNotification;
FOUNDATION_EXPORT NSString * const MBCIOSBoardCameraChangedNotification;
FOUNDATION_EXPORT NSString * const MBCIOSBoardInteractionEndedNotification;

/* UIKit presentation shared by the two board renderers. Camera coordinates
 * are view points, with the origin at the upper left. State dictionaries are
 * transient and are never part of saved games. */
@protocol MBCIOSBoardPresentation <MBCBoardViewInterface>
@property (nonatomic) BOOL drawEdgeNotationLabels;
- (void)setBoard:(MBCBoard *)board;
- (MBCBoard *)board;
- (MBCVariant)variant;
- (MBCSide)side;
- (void)iosSubmitMove:(MBCMove *)move;
- (void)iosSelectSquare:(MBCSquare)square;
- (uint64_t)iosLegalDropTargets;
- (void)beginOrientationTransition;
- (void)endOrientationTransition;
- (BOOL)isOrientationTransitioning;
- (void)resetCamera;
- (CGPoint)iosProjectPosition:(MBCPosition)position;
- (MBCPosition)iosUnprojectPoint:(CGPoint)point;
/* Camera keys: azimuth, elevation, zoomScale, panX, panZ. Selection keys:
 * pickedSquare, hintMove, lastMove. Both backends use the same board units. */
- (NSDictionary *)iosCapturePresentationState;
- (void)iosRestorePresentationState:(NSDictionary *)state;
- (BOOL)iosHasActiveInteraction;
- (BOOL)iosPrepareRendererWithError:(NSError **)error;
- (void)iosSetRenderingActive:(BOOL)active;
- (void)iosRetireRendererWithCompletion:(void (^)(void))completion;
@end
