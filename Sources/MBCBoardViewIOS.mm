/* UIKit presentation for the retained OpenGL chess renderer. */

#import "MBCBoardView.h"
#import "MBCBoardViewDraw.h"
#import "MBCBoardViewTextures.h"
#import "MBCDrawStyle.h"
#include "../ThirdParty/GLU/include/GL/glu.h"
#include <cmath>

#if TARGET_OS_IOS
@implementation MBCBoardView (IOSPresentation)

- (void)setBoard:(MBCBoard *)board
{
    if (board == fBoard) return;
    [board retain];
    [fBoard release];
    fBoard = board;
    fLegalDropTargetsValid = NO;
    fPromotionSide = kNeitherSide;
    [self needsUpdate];
}
- (MBCBoard *)board { return fBoard; }
- (MBCVariant)variant { return fVariant; }
- (MBCSide)side { return fSide; }
- (BOOL)wantsMouse { return fWantMouse; }
- (BOOL)drawEdgeNotationLabels { return fDrawEdgeNotationLabels; }
- (void)setDrawEdgeNotationLabels:(BOOL)value
{
    fDrawEdgeNotationLabels = value;
    [self setNeedsDisplay];
}
- (void)setNeedsDisplay:(BOOL)flag { if (flag) [self setNeedsDisplay]; }
- (void)beginOrientationTransition { fOrientationTransitioning = YES; }
- (void)endOrientationTransition { fOrientationTransitioning = NO; [self needsUpdate]; }
- (BOOL)isOrientationTransitioning { return fOrientationTransitioning; }

- (void)drawBoardFrame
{
    if (!fBoard || fOrientationTransitioning ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    if (!fStylesLoaded) { [self loadStyles]; fStylesLoaded = YES; }
    /* UIKit drawable resizing can occur without a legacy reshape callback. */
    fNeedPerspective = true;
    [self drawPosition];
}

- (BOOL)iosPrepareRendererWithError:(NSError **)error
{
    if (![super iosPrepareRendererWithError:error]) return NO;
    __block BOOL valid = NO;
    [self performWithGLContext:^{
        const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
        if (extensions && strstr(extensions, "GL_EXT_texture_filter_anisotropic")) {
            glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, &fAnisotropy);
            fAnisotropy = fminf(fAnisotropy, 4.0f);
        }
        [self loadStyles];
        fStylesLoaded = YES;
        valid = fBoardAttr && fPieceAttr && [fBoardDrawStyle[0] hasOpenGLTexture] &&
            [fBoardDrawStyle[1] hasOpenGLTexture] && [fPieceDrawStyle[0] hasOpenGLTexture] &&
            [fPieceDrawStyle[1] hasOpenGLTexture] && [fBorderDrawStyle hasOpenGLTexture];
        /* The retained first-draw path creates models and static textures.
         * Validate those textures after that initialization has run. */
        if (valid) [self drawBoardFrame];
        valid = valid && [fSelectedPieceDrawStyle hasOpenGLTexture];
        for (int index = 0; index < 8; ++index)
            valid = valid && fNumberTextures[index] && fLetterTextures[index];
    }];
    if (!valid && error) {
        *error = [NSError errorWithDomain:@"ChessOpenGL" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The OpenGL board materials could not be loaded."}];
    }
    return valid;
}

- (void)releaseGLResources
{
    glDeleteLists(KING, 6);
    glDeleteTextures(8, fNumberTextures);
    glDeleteTextures(8, fLetterTextures);
    memset(fNumberTextures, 0, sizeof(fNumberTextures));
    memset(fLetterTextures, 0, sizeof(fLetterTextures));
    for (int color = 0; color < 2; ++color) {
        [fBoardDrawStyle[color] unloadTexture];
        [fPieceDrawStyle[color] unloadTexture];
    }
    [fBorderDrawStyle unloadTexture];
    [fSelectedPieceDrawStyle unloadTexture];
    fStylesLoaded = NO;
    fNeedStaticModels = true;
}

- (void)resetCamera
{
    fAzimuth = 180.0f;
    fElevation = 60.0f;
    fCameraZoomScale = 1.0f;
    fCameraPanX = fCameraPanZ = 0.0f;
    [self needsUpdate];
    [self drawNow];
}
- (void)iosTranslateCameraByScreenDelta:(CGPoint)delta
{
    float angle = fAzimuth * (float)M_PI / 180.0f;
    /* Match the shared gesture's board-plane axes and Metal's default speed. */
    float scale = 185.0f * fCameraZoomScale * 0.003f;
    fCameraPanX -= (-cosf(angle) * delta.x + sinf(angle) * delta.y) * scale;
    fCameraPanZ -= (-sinf(angle) * delta.x - cosf(angle) * delta.y) * scale;
    fNeedPerspective = true;
}
- (void)iosMultiplyCameraDistance:(float)factor
{
    if (!std::isfinite(factor) || factor <= 0.0f) return;
    fCameraZoomScale = fmaxf(110.0f / 185.0f,
                           fminf(300.0f / 185.0f, fCameraZoomScale * factor));
    fNeedPerspective = true;
}

- (BOOL)iosReadProjectionModel:(GLdouble *)model projection:(GLdouble *)projection viewport:(GLint *)viewport
{
    if (!self.drawablePrepared || self.rendererRetired ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground ||
        self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return NO;
    __block BOOL available = NO;
    [self performWithGLContext:^{
        [self setupPerspective];
        GLfloat values[16];
        glGetFloatv(GL_MODELVIEW_MATRIX, values);
        for (int index = 0; index < 16; ++index) model[index] = values[index];
        glGetFloatv(GL_PROJECTION_MATRIX, values);
        for (int index = 0; index < 16; ++index) projection[index] = values[index];
        glGetIntegerv(GL_VIEWPORT, viewport);
        available = viewport[2] > 0 && viewport[3] > 0;
    }];
    return available;
}
- (CGPoint)iosProjectPosition:(MBCPosition)position
{
    GLdouble model[16], projection[16], x, y, z;
    GLint viewport[4];
    if (![self iosReadProjectionModel:model projection:projection viewport:viewport] ||
        !gluProject(position[0], position[1], position[2], model, projection,
                    viewport, &x, &y, &z)) return CGPointMake(NAN, NAN);
    return CGPointMake(x * self.bounds.size.width / viewport[2],
                       self.bounds.size.height - y * self.bounds.size.height / viewport[3]);
}
- (MBCPosition)iosUnprojectPoint:(CGPoint)point
{
    MBCPosition result = {{NAN, 0.0f, NAN}};
    GLdouble model[16], projection[16], nearX, nearY, nearZ, farX, farY, farZ;
    GLint viewport[4];
    if (![self iosReadProjectionModel:model projection:projection viewport:viewport]) return result;
    double x = point.x * viewport[2] / self.bounds.size.width;
    double y = (self.bounds.size.height - point.y) * viewport[3] / self.bounds.size.height;
    if (!gluUnProject(x, y, 0.0, model, projection, viewport, &nearX, &nearY, &nearZ) ||
        !gluUnProject(x, y, 1.0, model, projection, viewport, &farX, &farY, &farZ) ||
        fabs(farY - nearY) < 1e-9) return result;
    double t = -nearY / (farY - nearY);
    result[0] = (float)(nearX + t * (farX - nearX));
    result[2] = (float)(nearZ + t * (farZ - nearZ));
    return result;
}

- (NSDictionary *)iosCapturePresentationState
{
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:@{
        @"azimuth": @(fAzimuth), @"elevation": @(fElevation),
        @"zoomScale": @(fCameraZoomScale), @"panX": @(fCameraPanX),
        @"panZ": @(fCameraPanZ), @"pickedSquare": @(fPickedSquare),
        @"edgeLabels": @(fDrawEdgeNotationLabels)}];
    if (fHintMove) state[@"hintMove"] = fHintMove;
    if (fLastMove) state[@"lastMove"] = fLastMove;
    return state;
}
- (void)iosRestorePresentationState:(NSDictionary *)state
{
    if ([state[@"azimuth"] isKindOfClass:[NSNumber class]]) fAzimuth = [state[@"azimuth"] floatValue];
    if ([state[@"elevation"] isKindOfClass:[NSNumber class]]) fElevation = [state[@"elevation"] floatValue];
    if ([state[@"zoomScale"] isKindOfClass:[NSNumber class]]) fCameraZoomScale = [state[@"zoomScale"] floatValue];
    if ([state[@"panX"] isKindOfClass:[NSNumber class]]) fCameraPanX = [state[@"panX"] floatValue];
    if ([state[@"panZ"] isKindOfClass:[NSNumber class]]) fCameraPanZ = [state[@"panZ"] floatValue];
    if ([state[@"pickedSquare"] isKindOfClass:[NSNumber class]]) {
        MBCSquare square = [state[@"pickedSquare"] unsignedCharValue];
        fPickedSquare = square < kBoardSquares ||
            (square > kInHandSquare && square <= kInHandSquare + Black(PAWN))
            ? square : kInvalidSquare;
    }
    if ([state[@"edgeLabels"] isKindOfClass:[NSNumber class]])
        fDrawEdgeNotationLabels = [state[@"edgeLabels"] boolValue];
    if ([state[@"hintMove"] isKindOfClass:[MBCMove class]]) [self showMoveAsHint:state[@"hintMove"]];
    if ([state[@"lastMove"] isKindOfClass:[MBCMove class]]) [self showMoveAsLast:state[@"lastMove"]];
    [self needsUpdate];
}
- (BOOL)iosHasActiveInteraction
{
    return fInAnimation || fInBoardManipulation || fInTwoFingerManipulation ||
           fAwaitingPromotionChoice || fSelectedPiece != EMPTY || fOrientationTransitioning;
}

- (void)drawIOSLegalDropTargets
{
    uint64_t targets = [self iosLegalDropTargets];
    if (!targets) return;
    glPushAttrib(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT |
                 GL_CURRENT_BIT | GL_LIGHTING_BIT | GL_TEXTURE_BIT);
    glDisable(GL_LIGHTING);
    glDisable(GL_TEXTURE_2D);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDepthMask(GL_FALSE);
    glColor4f(0.36f, 0.90f, 0.56f, 0.72f);
    for (MBCSquare square = 0; square < 64; ++square) {
        if (!(targets & (1ULL << square))) continue;
        MBCPosition position = [self squareToPosition:square];
        glBegin(GL_TRIANGLE_FAN);
        glVertex3f(position[0], MBC_POSITION_Y_PIECE_SELECTION, position[2]);
        for (int segment = 0; segment <= 24; ++segment) {
            float angle = segment * (float)(2.0 * M_PI / 24.0);
            glVertex3f(position[0] + cosf(angle) * 1.15f,
                       MBC_POSITION_Y_PIECE_SELECTION, position[2] + sinf(angle) * 1.15f);
        }
        glEnd();
    }
    glPopAttrib();
}
@end
#endif
