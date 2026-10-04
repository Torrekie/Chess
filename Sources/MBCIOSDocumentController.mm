/* UIKit document-provider bridge for Chess .game and .pgn files. */

#import "MBCIOSDocumentController.h"
#import "MBCIOSLocalization.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <TargetConditionals.h>
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

static NSString *MBCIOSDecodePGN(NSData *data)
{
    if (!data) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // macOS Chess exports PGN using ISO Latin-1, including player names.
    return text ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

NSString *const MBCIOSDocumentErrorDomain = @"com.apple.Chess.iOSDocument";

@interface MBCIOSDocumentController ()
@property (nonatomic, weak, readwrite) UIViewController *presenter;
@property (nonatomic, strong, readwrite, nullable) NSURL *lastImportedURL;
@property (nonatomic, copy, readwrite, nullable) NSDictionary *lastImportedMetadata;
@property (nonatomic, copy) MBCIOSDocumentImportCompletion importCompletion;
@property (nonatomic, copy) MBCIOSDocumentExportCompletion exportCompletion;
@property (nonatomic, strong) NSURL *stagedExportURL;
@property (nonatomic, strong) NSURL *exportDirectoryURL;
@property (nonatomic, assign) BOOL exportDirectoryScoped;
@end

static NSError *MBCDocumentError(MBCIOSDocumentErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:MBCIOSDocumentErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *MBCSafeExportName(NSString *suggestedName)
{
    NSString *name = [suggestedName stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lowerExtension = name.pathExtension.lowercaseString;
    if ([lowerExtension isEqualToString:@"game"] || [lowerExtension isEqualToString:@"pgn"]) {
        name = name.stringByDeletingPathExtension;
    }
    NSMutableCharacterSet *unsafe = [NSCharacterSet.controlCharacterSet mutableCopy];
    [unsafe addCharactersInString:@"/\\:"];
    name = [[name componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"-"];
    name = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@" .-\t\r\n"]];
    if (!name.length) return @"Chess Game";
    if (name.length > 100) {
        NSRange range = [name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 100)];
        name = [name substringWithRange:range];
    }
    return name;
}

static void MBCRemoveStagedExport(NSURL *url)
{
    if (!url) return;
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtURL:url error:nil];
    NSURL *parent = url.URLByDeletingLastPathComponent;
    if ([parent.lastPathComponent hasPrefix:@"Export-"] &&
        [parent.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"Export Staging"]) {
        [files removeItemAtURL:parent error:nil];
    }
}

@implementation MBCIOSDocumentController

- (instancetype)initWithPresenter:(UIViewController * _Nullable)presenter
{
    self = [super init];
    if (self) _presenter = presenter;
    return self;
}

+ (NSArray<NSString *> *)supportedDocumentTypes
{
    /* Keep the UTI strings available on iOS 13; the modern UniformType
     * Identifiers API can be layered on later without changing the picker
     * lifecycle. */
    return @[@"com.apple.chess.game", @"com.apple.chess.pgn", @"public.chess-pgn", @"public.data"];
}

+ (NSURL *)stageExportForBoard:(MBCBoard *)board
                        variant:(MBCVariant)variant
                           side:(MBCSide)side
                     boardStyle:(NSString *)boardStyle
                     pieceStyle:(NSString *)pieceStyle
                          extension:(NSString *)extension
                              error:(NSError **)error
{
    return [self stageExportForBoard:board variant:variant side:side boardStyle:boardStyle
                           pieceStyle:pieceStyle metadata:nil suggestedName:nil extension:extension error:error];
}

+ (NSURL *)stageExportForBoard:(MBCBoard *)board
                        variant:(MBCVariant)variant
                           side:(MBCSide)side
                     boardStyle:(NSString *)boardStyle
                     pieceStyle:(NSString *)pieceStyle
                       metadata:(NSDictionary *)metadata
                      extension:(NSString *)extension
                          error:(NSError **)error
{
    return [self stageExportForBoard:board variant:variant side:side boardStyle:boardStyle
                           pieceStyle:pieceStyle metadata:metadata suggestedName:nil
                            extension:extension error:error];
}

+ (NSURL *)stageExportForBoard:(MBCBoard *)board
                       variant:(MBCVariant)variant
                          side:(MBCSide)side
                    boardStyle:(NSString *)boardStyle
                    pieceStyle:(NSString *)pieceStyle
                      metadata:(NSDictionary *)metadata
                 suggestedName:(NSString *)suggestedName
                     extension:(NSString *)extension
                         error:(NSError **)error
{
    NSString *lowerExtension = extension.lowercaseString;
    if (![lowerExtension isEqualToString:@"game"] && ![lowerExtension isEqualToString:@"pgn"]) {
        if (error) *error = MBCDocumentError(MBCIOSDocumentErrorUnsupportedFile,
                                              MBCIOSLocalizedString(@"ios_document_export_extension", @"Chess exports must use .game or .pgn."));
        return nil;
    }
    NSURL *directory = [MBCIOSGameStore applicationSupportDirectoryWithError:error];
    if (!directory) return nil;
    NSURL *stagedURL = nil;
    if (suggestedName.length) {
        NSURL *stagingRoot = [directory URLByAppendingPathComponent:@"Export Staging" isDirectory:YES];
        NSURL *instance = [stagingRoot URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"Export-%@", NSUUID.UUID.UUIDString]
                                                 isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:instance
                                     withIntermediateDirectories:YES attributes:nil error:error]) return nil;
        stagedURL = [instance URLByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@.%@", MBCSafeExportName(suggestedName), lowerExtension]];
    } else {
        stagedURL = [directory URLByAppendingPathComponent:
                     [NSString stringWithFormat:@"Export-%@.%@", NSUUID.UUID.UUIDString, lowerExtension]];
    }
    NSError *writeError = nil;
    if (![MBCIOSGameStore writeBoard:board variant:variant side:side
                          boardStyle:boardStyle pieceStyle:pieceStyle metadata:metadata
                               toURL:stagedURL error:&writeError]) {
        if (error) *error = writeError ?: MBCDocumentError(MBCIOSDocumentErrorUnsupportedFile,
                                                            MBCIOSLocalizedString(@"ios_document_stage_export", @"Chess could not stage the export file."));
        MBCRemoveStagedExport(stagedURL);
        return nil;
    }
    return stagedURL;
}

- (void)presentOpenDocumentPickerWithCompletion:(MBCIOSDocumentImportCompletion)completion
{
    if (!self.presenter) {
        if (completion) completion(nil, kVarNormal, kNeitherSide, nil, nil,
                                   MBCDocumentError(MBCIOSDocumentErrorNoPresenter,
                                                    MBCIOSLocalizedString(@"ios_document_no_presenter", @"Chess has no view controller to present the document picker.")));
        return;
    }
    self.importCompletion = completion;
    UIDocumentPickerViewController *picker = nil;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
        for (NSString *identifier in self.class.supportedDocumentTypes) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) [contentTypes addObject:type];
        }
        /* Import a copy so document providers deliver the callback reliably.
         * When a provider returns an original URL through another path, the
         * export code below can still reuse its parent directory. */
        if (contentTypes.count) {
            picker = [[UIDocumentPickerViewController alloc]
                      initForOpeningContentTypes:contentTypes asCopy:YES];
        }
    }
#endif
    if (!picker) {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:self.class.supportedDocumentTypes
                                  inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

- (void)presentExportForBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                    extension:(NSString *)extension
                    completion:(MBCIOSDocumentExportCompletion)completion
{
    [self presentExportForBoard:board variant:variant side:side boardStyle:boardStyle
                      pieceStyle:pieceStyle metadata:nil suggestedName:nil extension:extension
                       completion:completion];
}

- (void)presentExportForBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                     metadata:(NSDictionary *)metadata
                    extension:(NSString *)extension
                    completion:(MBCIOSDocumentExportCompletion)completion
{
    [self presentExportForBoard:board variant:variant side:side boardStyle:boardStyle
                      pieceStyle:pieceStyle metadata:metadata suggestedName:nil extension:extension
                       completion:completion];
}

- (void)presentExportForBoard:(MBCBoard *)board
                     variant:(MBCVariant)variant
                        side:(MBCSide)side
                  boardStyle:(NSString *)boardStyle
                  pieceStyle:(NSString *)pieceStyle
                    metadata:(NSDictionary *)metadata
               suggestedName:(NSString *)suggestedName
                   extension:(NSString *)extension
                  completion:(MBCIOSDocumentExportCompletion)completion
{
    if (!self.presenter) {
        if (completion) completion(nil, MBCDocumentError(MBCIOSDocumentErrorNoPresenter,
                                                         MBCIOSLocalizedString(@"ios_document_no_presenter", @"Chess has no view controller to present the document picker.")));
        return;
    }
    NSError *writeError = nil;
    NSURL *stagedURL = [self.class stageExportForBoard:board variant:variant side:side
                                            boardStyle:boardStyle pieceStyle:pieceStyle metadata:metadata
                                        suggestedName:suggestedName extension:extension error:&writeError];
    if (!stagedURL) {
        if (completion) completion(nil, writeError);
        return;
    }

    self.stagedExportURL = stagedURL;
    self.exportCompletion = completion;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        /* Export the disposable staged file as a copy. Some providers can
         * dismiss a move operation without completing the transaction. */
        picker = [[UIDocumentPickerViewController alloc]
                     initForExportingURLs:@[stagedURL] asCopy:YES];
        NSURL *directoryURL = [self.lastImportedURL URLByDeletingLastPathComponent];
        NSString *homePath = NSHomeDirectory();
        BOOL isAppContainerCopy = directoryURL.isFileURL &&
            homePath.length && [directoryURL.path hasPrefix:homePath];
        if (directoryURL && !isAppContainerCopy) {
            self.exportDirectoryURL = directoryURL;
            self.exportDirectoryScoped = [directoryURL startAccessingSecurityScopedResource];
            picker.directoryURL = directoryURL;
        }
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                     initWithURL:stagedURL
                           inMode:UIDocumentPickerModeExportToService];
    }
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    NSURL *url = urls.firstObject;
    if (self.exportCompletion) {
        MBCIOSDocumentExportCompletion completion = self.exportCompletion;
        self.exportCompletion = nil;
        NSURL *stagedURL = self.stagedExportURL;
        self.stagedExportURL = nil;
        NSURL *directoryURL = self.exportDirectoryURL;
        BOOL directoryScoped = self.exportDirectoryScoped;
        self.exportDirectoryURL = nil;
        self.exportDirectoryScoped = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(url, nil);
            MBCRemoveStagedExport(stagedURL);
            if (directoryScoped) [directoryURL stopAccessingSecurityScopedResource];
        });
        return;
    }

    MBCIOSDocumentImportCompletion completion = self.importCompletion;
    self.importCompletion = nil;
    if (!completion) return;
    if (!url) {
        completion(nil, kVarNormal, kNeitherSide, nil, nil,
                   MBCDocumentError(MBCIOSDocumentErrorUnsupportedFile,
                                    MBCIOSLocalizedString(@"ios_document_provider_no_url", @"The document provider returned no URL.")));
        return;
    }

    self.lastImportedURL = url;
    self.lastImportedMetadata = nil;
    [self importDocumentAtURL:url completion:completion];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentAtURL:(NSURL *)url
{
    /* Providers may use the singular callback with a modern initializer.
     * Normalize it into the plural path to share export staging and cleanup. */
    [self documentPicker:controller
  didPickDocumentsAtURLs:url ? @[url] : @[]];
}

- (void)importDocumentAtURL:(NSURL *)url
                  completion:(MBCIOSDocumentImportCompletion)completion
{
    if (!url || !completion) return;

    self.lastImportedURL = url;
    self.lastImportedMetadata = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    MBCBoard *board = [[MBCBoard alloc] init];
    MBCVariant variant = kVarNormal;
    MBCSide side = kBothSides;
    NSString *boardStyle = nil;
    NSString *pieceStyle = nil;
    NSDictionary *metadata = nil;
    NSString *extension = url.pathExtension.lowercaseString;
    BOOL loaded = NO;
    if ([extension isEqualToString:@"game"]) {
        loaded = [MBCIOSGameStore loadBoard:board variant:&variant side:&side
                                  boardStyle:&boardStyle pieceStyle:&pieceStyle metadata:&metadata
                                     fromURL:url error:&error];
    } else if ([extension isEqualToString:@"pgn"]) {
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        NSString *pgn = MBCIOSDecodePGN(data);
        loaded = pgn && [MBCIOSGameStore importPGN:pgn intoBoard:board variant:&variant side:&side
                                         boardStyle:&boardStyle pieceStyle:&pieceStyle metadata:&metadata error:&error];
    } else {
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data) {
            NSDictionary *probe = [NSPropertyListSerialization propertyListWithData:data
                                                                                options:NSPropertyListImmutable
                                                                                 format:nil
                                                                                  error:nil];
            if ([probe isKindOfClass:[NSDictionary class]]) {
                loaded = [MBCIOSGameStore loadBoard:board variant:&variant side:&side
                                          boardStyle:&boardStyle pieceStyle:&pieceStyle metadata:&metadata
                                             fromURL:url error:&error];
            } else {
                NSString *pgn = MBCIOSDecodePGN(data);
                loaded = pgn && [MBCIOSGameStore importPGN:pgn intoBoard:board variant:&variant side:&side
                                                 boardStyle:&boardStyle pieceStyle:&pieceStyle metadata:&metadata error:&error];
            }
        }
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!loaded && !error) {
        error = MBCDocumentError(MBCIOSDocumentErrorUnsupportedFile,
                                 MBCIOSLocalizedString(@"ios_document_unsupported_file", @"The selected file is not a supported Chess document."));
    }
    self.lastImportedMetadata = loaded ? metadata : nil;
    completion(loaded ? board : nil, variant, side, boardStyle, pieceStyle, error);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    (void)controller;
    if (self.exportCompletion) {
        MBCIOSDocumentExportCompletion completion = self.exportCompletion;
        self.exportCompletion = nil;
        NSURL *stagedURL = self.stagedExportURL;
        self.stagedExportURL = nil;
        NSURL *directoryURL = self.exportDirectoryURL;
        BOOL directoryScoped = self.exportDirectoryScoped;
        self.exportDirectoryURL = nil;
        self.exportDirectoryScoped = NO;
        MBCRemoveStagedExport(stagedURL);
        if (directoryScoped) [directoryURL stopAccessingSecurityScopedResource];
        if (completion) completion(nil, MBCDocumentError(MBCIOSDocumentErrorCancelled,
                                                          MBCIOSLocalizedString(@"ios_document_export_cancelled", @"The document export was cancelled.")));
    } else if (self.importCompletion) {
        MBCIOSDocumentImportCompletion completion = self.importCompletion;
        self.importCompletion = nil;
        if (completion) completion(nil, kVarNormal, kNeitherSide, nil, nil,
                                   MBCDocumentError(MBCIOSDocumentErrorCancelled,
                                                    MBCIOSLocalizedString(@"ios_document_import_cancelled", @"The document import was cancelled.")));
    }
}

@end
