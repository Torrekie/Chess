/* UIKit document-provider bridge for Chess .game and .pgn files. */

#import <UIKit/UIKit.h>

#import "MBCIOSGameStore.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MBCIOSDocumentErrorDomain;

typedef NS_ENUM(NSInteger, MBCIOSDocumentErrorCode) {
    MBCIOSDocumentErrorNoPresenter = -20201,
    MBCIOSDocumentErrorCancelled = -20202,
    MBCIOSDocumentErrorUnsupportedFile = -20203,
};

typedef void (^MBCIOSDocumentImportCompletion)(MBCBoard * _Nullable board,
                                                MBCVariant variant,
                                                MBCSide side,
                                                NSString * _Nullable boardStyle,
                                                NSString * _Nullable pieceStyle,
                                                NSError * _Nullable error);
typedef void (^MBCIOSDocumentExportCompletion)(NSURL * _Nullable destinationURL,
                                                NSError * _Nullable error);

@interface MBCIOSDocumentController : NSObject <UIDocumentPickerDelegate>

@property (nonatomic, weak, readonly, nullable) UIViewController *presenter;
/* The most recent URL returned by UIDocumentPicker/Launch Services. */
@property (nonatomic, strong, readonly, nullable) NSURL *lastImportedURL;
/* macOS MBCDocument properties recovered from the most recent import. */
@property (nonatomic, copy, readonly, nullable) NSDictionary *lastImportedMetadata;

- (instancetype)initWithPresenter:(UIViewController * _Nullable)presenter;

+ (NSArray<NSString *> *)supportedDocumentTypes;

/* Stages an export in Application Support before UIDocumentPicker presents it
 * to a Files/provider destination.  The returned file is caller-owned and may
 * be removed after the provider completion callback. */
+ (nullable NSURL *)stageExportForBoard:(MBCBoard *)board
                               variant:(MBCVariant)variant
                                  side:(MBCSide)side
                            boardStyle:(NSString *)boardStyle
                            pieceStyle:(NSString *)pieceStyle
                             extension:(NSString *)extension
                                 error:(NSError **)error;

+ (nullable NSURL *)stageExportForBoard:(MBCBoard *)board
                               variant:(MBCVariant)variant
                                  side:(MBCSide)side
                            boardStyle:(NSString *)boardStyle
                            pieceStyle:(NSString *)pieceStyle
                              metadata:(NSDictionary * _Nullable)metadata
                             extension:(NSString *)extension
                                 error:(NSError **)error;

/* A named export keeps the game title as the Files suggested filename. */
+ (nullable NSURL *)stageExportForBoard:(MBCBoard *)board
                               variant:(MBCVariant)variant
                                  side:(MBCSide)side
                            boardStyle:(NSString *)boardStyle
                            pieceStyle:(NSString *)pieceStyle
                              metadata:(NSDictionary * _Nullable)metadata
                         suggestedName:(NSString * _Nullable)suggestedName
                             extension:(NSString *)extension
                                 error:(NSError **)error;

- (void)presentOpenDocumentPickerWithCompletion:(MBCIOSDocumentImportCompletion)completion;

/* Handles a URL delivered by Files/Launch Services as well as URLs selected
 * through UIDocumentPickerViewController. */
- (void)importDocumentAtURL:(NSURL *)url
                  completion:(MBCIOSDocumentImportCompletion)completion;

- (void)presentExportForBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                    extension:(NSString *)extension
                    completion:(MBCIOSDocumentExportCompletion)completion;

- (void)presentExportForBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                     metadata:(NSDictionary * _Nullable)metadata
                    extension:(NSString *)extension
                    completion:(MBCIOSDocumentExportCompletion)completion;

- (void)presentExportForBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                     metadata:(NSDictionary * _Nullable)metadata
                suggestedName:(NSString * _Nullable)suggestedName
                    extension:(NSString *)extension
                    completion:(MBCIOSDocumentExportCompletion)completion;

@end

NS_ASSUME_NONNULL_END
