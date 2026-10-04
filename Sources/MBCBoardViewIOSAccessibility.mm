/* UIKit accessibility for the retained OpenGL chess board. */
#import "MBCBoardView.h"
#import "MBCIOSChessSquareElement.h"
#import "MBCIOSLocalization.h"
#include <cmath>
#if TARGET_OS_IOS
#define MBCIOSBoardAccessibilityClass MBCBoardView
#define _board fBoard
#define _variant fVariant
#define _side fSide
#define _iosAccessibilitySquareElements fIOSAccessibilitySquareElements
#define _iosVisibleAccessibilityElements fIOSVisibleAccessibilityElements
#include "MBCBoardViewIOSAccessibility.inc"
#undef _board
#undef _variant
#undef _side
#undef _iosAccessibilitySquareElements
#undef _iosVisibleAccessibilityElements
#undef MBCIOSBoardAccessibilityClass
#endif
