/* iOS recording adapter for the game window equivalent. */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MBCIOSRecordingErrorDomain;

typedef NS_ENUM(NSInteger, MBCIOSRecordingErrorCode) {
    MBCIOSRecordingErrorAlreadyRecording = -20101,
    MBCIOSRecordingErrorUnavailable      = -20102,
    MBCIOSRecordingErrorInvalidURL       = -20103,
    MBCIOSRecordingErrorWriterFailed     = -20104,
    MBCIOSRecordingErrorNoVideo          = -20105,
};

typedef void (^MBCIOSRecordingCompletion)(NSError * _Nullable error);
typedef void (^MBCIOSRecordingFailureHandler)(NSError *error);

/**
 * iOS equivalent of the macOS window recorder.
 *
 * ReplayKit captures the app's screen rather than an NSWindow.  The adapter
 * deliberately records video only, matching the macOS controller's
 * capturesAudio=NO configuration, and writes an H.264 MP4 in the caller's
 * sandbox URL.
 */
@interface MBCIOSRecordingController : NSObject

+ (BOOL)isAvailable;
+ (nullable NSURL *)defaultRecordingURLWithError:(NSError **)error;
/* Keep the last successful MP4 across application-container relocation. */
+ (BOOL)rememberCompletedRecordingAtURL:(NSURL *)url;
+ (nullable NSURL *)lastAvailableRecordingURL;
/* Resolve the saved recording using the supplied defaults and directory. */
+ (nullable NSURL *)lastAvailableRecordingURLWithDefaults:(NSUserDefaults *)defaults
                                             directory:(NSURL *)directory;

@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, copy, readonly, nullable) NSURL *outputURL;
/* Delivered on the main queue when capture or writing fails after start
 * completed, with no stop completion waiting for the same error. */
@property (nonatomic, copy, nullable) MBCIOSRecordingFailureHandler failureHandler;

- (void)startRecordingToURL:(NSURL *)url
          completionHandler:(MBCIOSRecordingCompletion)completionHandler;
- (void)stopRecordingWithCompletionHandler:(MBCIOSRecordingCompletion)completionHandler;

@end

NS_ASSUME_NONNULL_END
