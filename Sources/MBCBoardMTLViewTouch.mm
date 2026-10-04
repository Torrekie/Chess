/* Metal camera bridge for shared UIKit board interaction. */

#import "MBCBoardMTLView.h"
#import "MBCBoard.h"
#import "MBCPlayer.h"
#import "MBCMetalCamera.h"
#import "MBCMetalRenderer.h"
#import "MBCMoveGenerator.h"
#import "MBCIOSLocalization.h"

#import <TargetConditionals.h>
#if TARGET_OS_IOS

NSString * const MBCIOSBoardCameraChangedNotification = @"MBCIOSBoardCameraChangedNotification";
NSString * const MBCIOSBoardIdleTapNotification = @"MBCIOSBoardIdleTapNotification";
NSString * const MBCIOSBoardInteractionEndedNotification = @"MBCIOSBoardInteractionEndedNotification";

static vector_float2 MBCScreenPositionForTouch(MBCBoardMTLView *view, CGPoint point)
{
    CGSize bounds = view.bounds.size;
    CGSize drawable = view.drawableSize;
    CGFloat scaleX = bounds.width > 0.0 ? drawable.width / bounds.width : 1.0;
    CGFloat scaleY = bounds.height > 0.0 ? drawable.height / bounds.height : 1.0;

    // The camera uses a bottom-left viewport. UIKit touch coordinates are
    // top-left, so flip Y before unprojection.
    return simd_make_float2((float)(point.x * scaleX),
                            (float)((bounds.height - point.y) * scaleY));
}

static MBCPosition MBCPositionForTouch(MBCBoardMTLView *view, CGPoint point)
{
    vector_float2 screen = MBCScreenPositionForTouch(view, point);
    return [view.renderer.camera unProjectPositionFromScreenToModel:screen knownY:0.0f];
}

static vector_float2 MBCBoardPlaneDeltaForScreenDelta(MBCMetalCamera *camera,
                                                       CGPoint screenDelta)
{
    const float angle = camera.azimuth * kDegrees2Radians;
    // The two vectors are the screen-right and board-plane screen-up axes for
    // the current azimuth. Move the camera opposite the finger so the board
    // follows a two-finger drag, like a map or photo canvas.
    vector_float2 screenRight = simd_make_float2(-cosf(angle), -sinf(angle));
    vector_float2 screenUp = simd_make_float2(sinf(angle), -cosf(angle));
    const float scale = camera.distance * 0.003f;
    vector_float2 delta = screenRight * (float)screenDelta.x +
                          screenUp * (float)screenDelta.y;
    return -delta * scale;
}

static void MBCTranslateCameraByScreenDelta(MBCBoardMTLView *view, CGPoint delta)
{
    MBCMetalCamera *camera = view.renderer.camera;
    [camera translateOnBoardPlaneBy:MBCBoardPlaneDeltaForScreenDelta(camera, delta)];
}

static void MBCMultiplyCameraDistance(MBCBoardMTLView *view, float factor)
{
    view.renderer.camera.distance *= factor;
}

#define MBCIOSBoardTouchClass MBCBoardMTLView
#include "MBCBoardViewIOSTouch.inc"
#undef MBCIOSBoardTouchClass
#endif
