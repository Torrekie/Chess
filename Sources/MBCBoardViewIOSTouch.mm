/* OpenGL camera bridge for shared UIKit board interaction. */
#import "MBCBoardView.h"
#import "MBCPlayer.h"
#import "MBCMoveGenerator.h"
#import "MBCIOSLocalization.h"
#if TARGET_OS_IOS
static MBCPosition MBCPositionForTouch(MBCBoardView *view, CGPoint point)
{
    return [view iosUnprojectPoint:point];
}
static void MBCTranslateCameraByScreenDelta(MBCBoardView *view, CGPoint delta)
{
    [view iosTranslateCameraByScreenDelta:delta];
}
static void MBCMultiplyCameraDistance(MBCBoardView *view, float factor)
{
    [view iosMultiplyCameraDistance:factor];
}
#define MBCIOSBoardTouchClass MBCBoardView
#define _board fBoard
#define _variant fVariant
#define _side fSide
#define _wantMouse fWantMouse
#define _inAnimation fInAnimation
#define _awaitingPromotionChoice fAwaitingPromotionChoice
#define _inTwoFingerManipulation fInTwoFingerManipulation
#define _inBoardManipulation fInBoardManipulation
#define _boardManipulationDidMove fBoardManipulationDidMove
#define _previousGestureCenter fPreviousGestureCenter
#define _previousGestureSpan fPreviousGestureSpan
#define _pickedSquare fPickedSquare
#define _selectedDestination fSelectedDest
#define _boardManipulationStartPoint fBoardManipulationStartPoint
#define _previousMousePosition fOrigMouse
#define _currentMousePosition fCurMouse
#define _rawAzimuth fRawAzimuth
#define _selectedPiece fSelectedPiece
#define _selectedPosition fSelectedPos
#define _selectedSquare fSelectedSquare
#define _legalDropTargetsValid fLegalDropTargetsValid
#define _legalDropOrigin fLegalDropOrigin
#define _legalDropMoveCount fLegalDropMoveCount
#define _legalDropTargetsMask fLegalDropTargetsMask
#include "MBCBoardViewIOSTouch.inc"
#undef _board
#undef _variant
#undef _side
#undef _wantMouse
#undef _inAnimation
#undef _awaitingPromotionChoice
#undef _inTwoFingerManipulation
#undef _inBoardManipulation
#undef _boardManipulationDidMove
#undef _previousGestureCenter
#undef _previousGestureSpan
#undef _pickedSquare
#undef _selectedDestination
#undef _boardManipulationStartPoint
#undef _previousMousePosition
#undef _currentMousePosition
#undef _rawAzimuth
#undef _selectedPiece
#undef _selectedPosition
#undef _selectedSquare
#undef _legalDropTargetsValid
#undef _legalDropOrigin
#undef _legalDropMoveCount
#undef _legalDropTargetsMask
#undef MBCIOSBoardTouchClass
#endif
