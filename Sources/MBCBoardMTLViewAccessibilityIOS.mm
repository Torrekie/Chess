/* UIKit accessibility for the Metal chess board. */
#import "MBCBoardMTLView.h"
#import "MBCBoard.h"
#import "MBCIOSChessSquareElement.h"
#import "MBCIOSLocalization.h"
#include <cmath>
#if TARGET_OS_IOS
@implementation MBCIOSChessSquareElement
- (BOOL)isAccessibilityElement
{
    return YES;
}

- (BOOL)accessibilityActivate
{
    if (!self.canActivate) return NO;
    [self.boardView iosSelectSquare:self.square];
    return YES;
}
@end

#define MBCIOSBoardAccessibilityClass MBCBoardMTLView
#include "MBCBoardViewIOSAccessibility.inc"
#undef MBCIOSBoardAccessibilityClass
#endif
