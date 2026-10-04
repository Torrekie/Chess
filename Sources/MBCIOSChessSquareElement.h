#import "MBCIOSBoardPresentation.h"

@interface MBCIOSChessSquareElement : UIAccessibilityElement
@property (nonatomic) MBCSquare square;
@property (nonatomic) BOOL canActivate;
@property (nonatomic, weak) UIView<MBCIOSBoardPresentation> *boardView;
@end
