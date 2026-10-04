#import <UIKit/UIKit.h>
#import "MBCIOSBoardPresentation.h"

#import "MBCIOSDocumentController.h"
#import "MBCIOSRecordingController.h"
#import "MBCIOSGameCenterManager.h"

@class MBCBoard;

typedef void (^MBCIOSStyleSelectionCompletion)(BOOL confirmed,
                                               NSString * _Nullable styleName,
                                               BOOL autoRotateBoard);
typedef void (^MBCIOSStylePairSelectionCompletion)(BOOL confirmed,
    NSString * _Nullable boardStyle, NSString * _Nullable pieceStyle,
    BOOL autoRotateBoard);

@interface MBCIOSPreferencesViewController : UITableViewController
@property (nonatomic, copy) NSDictionary *gameSettings;
@property (nonatomic) BOOL showsComputerStrength;
@property (nonatomic, copy) void (^settingsCompletion)(NSDictionary *settings);
@property (nonatomic, strong, readonly) UISegmentedControl *boardStyleControl;
@property (nonatomic, strong, readonly) UISegmentedControl *pieceStyleControl;
@property (nonatomic, strong, readonly) UISegmentedControl *rendererControl;
@property (nonatomic) MBCIOSRendererKind rendererKind;
@property (nonatomic, copy) BOOL (^rendererCompletion)(MBCIOSRendererKind kind);
@property (nonatomic, strong, readonly) UISwitch *autoRotateSwitch;
@property (nonatomic, strong, readonly) UISwitch *speakMovesSwitch;
@property (nonatomic, strong, readonly) UISwitch *speakHumanMovesSwitch;
@property (nonatomic, strong, readonly) UIButton *primaryVoiceButton;
@property (nonatomic, strong, readonly) UIButton *alternateVoiceButton;

- (instancetype)initWithStyleName:(NSString *)styleName
                   autoRotateBoard:(BOOL)autoRotateBoard
                        completion:(MBCIOSStyleSelectionCompletion)completion;
- (instancetype)initWithBoardStyle:(NSString *)boardStyle
                       pieceStyle:(NSString *)pieceStyle
                  autoRotateBoard:(BOOL)autoRotateBoard
                       completion:(MBCIOSStylePairSelectionCompletion)completion;
- (void)commitSelection;
- (void)cancelSelection;
@end

@interface ChessIOSViewController : UIViewController <MBCIOSGameCenterManagerDelegate>
@property (nonatomic, strong) MBCBoard *board;
@property (nonatomic, strong) UIView<MBCIOSBoardPresentation> *boardView;
@property (nonatomic, strong) MBCIOSDocumentController *documentController;
@property (nonatomic, strong) MBCIOSRecordingController *recordingController;
@property (nonatomic, strong, readonly) MBCIOSGameCenterManager *gameCenterManager;
@property (nonatomic) MBCVariant variant;
@property (nonatomic) MBCSide side;
@property (nonatomic, copy) NSString *boardStyle;
@property (nonatomic, copy) NSString *pieceStyle;
/* Set one of these before loading the view for scene-specific restoration. */
@property (nonatomic, copy, nullable) NSString *preferredInitialGameIdentifier;
@property (nonatomic) BOOL startsWithNewLibraryGame;
/* Set before loading a scene opened for document import. Its untouched
 * placeholder board stays temporary until the import finishes. */
@property (nonatomic) BOOL defersInitialLibrarySaveForImport;
@property (nonatomic, copy, readonly, nullable) NSString *activeGameIdentifier;

/* Ends launch-import deferral, saving the placeholder only if no document
 * became this scene's library record. */
- (BOOL)finishInitialSceneImportWithError:(NSError **)error;

/* Opens a named game after saving the current board when requested. */
- (void)openLibraryGameWithIdentifier:(NSString *)identifier saveCurrent:(BOOL)saveCurrent;

- (void)applyImportedBoard:(MBCBoard *)board
                   variant:(MBCVariant)variant
                      side:(MBCSide)side
                boardStyle:(NSString *)boardStyle
                pieceStyle:(NSString *)pieceStyle;
/* Reports whether an import was installed; useful for multi-file scene handoff. */
- (BOOL)tryApplyImportedBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                        error:(NSError **)error;

/* Applies a matching style to both components for older callers. */
- (void)applyStylePreference:(NSString *)styleName;
- (void)applyBoardStylePreference:(NSString *)styleName;
- (void)applyPieceStylePreference:(NSString *)styleName;
- (void)applyAutoRotatePreference:(BOOL)enabled;

/* Saves the active board to its named library document. */
- (BOOL)saveCurrentGame:(NSError **)error;
/* Preserve the live board under a new library ID after a revision conflict.
 * Safe to call while the scene is entering the background or disconnecting. */
- (BOOL)saveCurrentBoardAsRecoveredCopy:(NSError **)error;
@end
