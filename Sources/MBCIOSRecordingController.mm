/* iOS ReplayKit/AVAssetWriter recording adapter. */

#import "MBCIOSRecordingController.h"

#import "MBCIOSGameStore.h"
#import "MBCIOSLocalization.h"

#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>

NSString *const MBCIOSRecordingErrorDomain = @"com.apple.Chess.iOSRecordingErrorDomain";
static NSString *const kMBCIOSLastRecordingPath = @"MBCIOSLastRecordingPath";
static NSString *const kMBCIOSLegacySupportSuffix =
    @"/Library/Application Support/com.apple.Chess";

static NSError *MBCIOSRecordingError(MBCIOSRecordingErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:MBCIOSRecordingErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSURL *MBCIOSValidatedRecordingURL(NSString *reference, NSURL *directory)
{
    if (!reference.length || !directory.isFileURL) return nil;
    NSString *fileName = reference.lastPathComponent;
    if (!fileName.length || [fileName isEqualToString:@"."] ||
        [fileName isEqualToString:@".."] ||
        ![fileName.pathExtension.lowercaseString isEqualToString:@"mp4"])
        return nil;
    if (reference.isAbsolutePath) {
        // A previous install's container UUID changes, but its app-support
        // tail does not. Never follow an arbitrary legacy absolute path.
        NSString *parent = reference.stringByStandardizingPath.stringByDeletingLastPathComponent;
        if (parent.length <= kMBCIOSLegacySupportSuffix.length ||
            ![parent hasSuffix:kMBCIOSLegacySupportSuffix]) return nil;
        NSString *container = [parent substringToIndex:
            parent.length - kMBCIOSLegacySupportSuffix.length];
        NSArray<NSString *> *parts = container.pathComponents;
        NSUInteger count = parts.count;
        if (count < 4 ||
            ![parts[count - 4] isEqualToString:@"Containers"] ||
            ![parts[count - 3] isEqualToString:@"Data"] ||
            ![parts[count - 2] isEqualToString:@"Application"] ||
            ![[NSUUID alloc] initWithUUIDString:parts[count - 1]]) return nil;
    } else if (![reference isEqualToString:fileName]) {
        return nil;
    }

    NSURL *candidate = [directory URLByAppendingPathComponent:fileName isDirectory:NO];
    NSURL *resolvedDirectory = directory.URLByResolvingSymlinksInPath;
    NSURL *resolvedCandidate = candidate.URLByResolvingSymlinksInPath;
    if (![resolvedCandidate.URLByDeletingLastPathComponent.path
            isEqualToString:resolvedDirectory.path]) return nil;
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:candidate.path error:nil];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [attributes fileSize] == 0) return nil;
    return candidate;
}

@interface MBCIOSRecordingController ()
@property (nonatomic, readwrite, copy, nullable) NSURL *outputURL;
@end

@implementation MBCIOSRecordingController {
    RPScreenRecorder *_recorder;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    dispatch_queue_t _writerQueue;
    BOOL _recording;
    BOOL _stopRequested;
    BOOL _sawVideo;
    MBCIOSRecordingCompletion _pendingStartCompletion;
    MBCIOSRecordingCompletion _pendingStopCompletion;
}

+ (BOOL)isAvailable
{
#if TARGET_OS_IOS
    return [RPScreenRecorder sharedRecorder].isAvailable;
#else
    return NO;
#endif
}

+ (NSURL *)defaultRecordingURLWithError:(NSError **)error
{
    NSURL *directory = [MBCIOSGameStore applicationSupportDirectoryWithError:error];
    if (!directory) return nil;
    return [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"Chess-%@.mp4", NSUUID.UUID.UUIDString]];
}

+ (BOOL)rememberCompletedRecordingAtURL:(NSURL *)url
{
    NSURL *directory = [MBCIOSGameStore applicationSupportDirectoryWithError:nil];
    if (!url.isFileURL || !directory) return NO;
    NSString *fileName = url.lastPathComponent;
    NSURL *validated = MBCIOSValidatedRecordingURL(fileName, directory);
    if (!validated || ![validated.URLByStandardizingPath.path
            isEqualToString:url.URLByStandardizingPath.path]) return NO;
    [[NSUserDefaults standardUserDefaults] setObject:fileName
                                              forKey:kMBCIOSLastRecordingPath];
    return YES;
}

+ (NSURL *)lastAvailableRecordingURL
{
    NSURL *directory = [MBCIOSGameStore applicationSupportDirectoryWithError:nil];
    return directory ? [self lastAvailableRecordingURLWithDefaults:
        [NSUserDefaults standardUserDefaults] directory:directory] : nil;
}

+ (NSURL *)lastAvailableRecordingURLWithDefaults:(NSUserDefaults *)defaults
                                        directory:(NSURL *)directory
{
    NSString *reference = [defaults stringForKey:kMBCIOSLastRecordingPath];
    NSURL *url = MBCIOSValidatedRecordingURL(reference, directory);
    if (url && reference.isAbsolutePath)
        [defaults setObject:url.lastPathComponent forKey:kMBCIOSLastRecordingPath];
    return url;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _recorder = [RPScreenRecorder sharedRecorder];
        _writerQueue = dispatch_queue_create("com.apple.Chess.iOSRecording", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRecording
{
    @synchronized (self) {
        return _recording;
    }
}

- (void)startRecordingToURL:(NSURL *)url
          completionHandler:(MBCIOSRecordingCompletion)completionHandler
{
    if (!url.isFileURL || url.path.length == 0) {
        if (completionHandler) completionHandler(MBCIOSRecordingError(MBCIOSRecordingErrorInvalidURL,
                                                                        MBCIOSLocalizedString(@"ios_recording_invalid_url", @"Recording output must be a file URL.")));
        return;
    }

    @synchronized (self) {
        if (_recording) {
            if (completionHandler) completionHandler(MBCIOSRecordingError(MBCIOSRecordingErrorAlreadyRecording,
                                                                            MBCIOSLocalizedString(@"ios_recording_already_active", @"A recording is already active.")));
            return;
        }
        if (!self.class.isAvailable) {
            if (completionHandler) completionHandler(MBCIOSRecordingError(MBCIOSRecordingErrorUnavailable,
                                                                            MBCIOSLocalizedString(@"ios_recording_unavailable", @"ReplayKit is unavailable in this runtime.")));
            return;
        }
        _recording = YES;
        _stopRequested = NO;
        _sawVideo = NO;
        _writer = nil;
        _videoInput = nil;
        _pendingStartCompletion = [completionHandler copy];
        self.outputURL = url;
    }

    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    __weak MBCIOSRecordingController *weakSelf = self;
    [_recorder startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer, RPSampleBufferType bufferType, NSError *error) {
        MBCIOSRecordingController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (sampleBuffer) CFRetain(sampleBuffer);
        dispatch_async(strongSelf->_writerQueue, ^{
            [strongSelf consumeSampleBuffer:sampleBuffer type:bufferType error:error];
            if (sampleBuffer) CFRelease(sampleBuffer);
        });
    } completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MBCIOSRecordingController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                [strongSelf failRecording:error];
                return;
            }
            MBCIOSRecordingCompletion startCompletion = nil;
            @synchronized (strongSelf) {
                if (strongSelf->_recording) {
                    startCompletion = strongSelf->_pendingStartCompletion;
                    strongSelf->_pendingStartCompletion = nil;
                }
            }
            if (startCompletion) startCompletion(nil);
        });
    }];
}

- (void)consumeSampleBuffer:(CMSampleBufferRef)sampleBuffer
                       type:(RPSampleBufferType)type
                      error:(NSError *)error
{
    if (error) {
        [self failRecording:error];
        return;
    }
    if (!sampleBuffer || type != RPSampleBufferTypeVideo || _stopRequested) return;
    if (!_writer) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        CMVideoDimensions dimensions = format ? CMVideoFormatDescriptionGetDimensions(format) : (CMVideoDimensions){0, 0};
        if (dimensions.width <= 0 || dimensions.height <= 0 || !self.outputURL) {
            [self failRecording:MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
                                                       MBCIOSLocalizedString(@"ios_recording_invalid_video_format", @"ReplayKit returned an invalid video format."))];
            return;
        }
        NSError *writerError = nil;
        _writer = [[AVAssetWriter alloc] initWithURL:self.outputURL
                                             fileType:AVFileTypeMPEG4
                                                error:&writerError];
        if (!_writer || writerError) {
            [self failRecording:writerError ?: MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
                                                                      MBCIOSLocalizedString(@"ios_recording_create_writer", @"Unable to create the MP4 writer."))];
            return;
        }
        NSDictionary *settings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(dimensions.width),
            AVVideoHeightKey: @(dimensions.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(MAX(1200000, dimensions.width * dimensions.height * 4)),
                AVVideoMaxKeyFrameIntervalKey: @60
            }
        };
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                           outputSettings:settings];
        _videoInput.expectsMediaDataInRealTime = YES;
        if (![_writer canAddInput:_videoInput]) {
            [self failRecording:MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
                                                       MBCIOSLocalizedString(@"ios_recording_attach_writer", @"Unable to attach the video writer input."))];
            return;
        }
        [_writer addInput:_videoInput];
        if (![_writer startWriting]) {
            [self failRecording:_writer.error ?: MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
                                                                        MBCIOSLocalizedString(@"ios_recording_start_writer", @"Unable to start the MP4 writer."))];
            return;
        }
        [_writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
    }

    if (_videoInput.readyForMoreMediaData && [_videoInput appendSampleBuffer:sampleBuffer]) {
        _sawVideo = YES;
    } else if (_writer.status == AVAssetWriterStatusFailed) {
        [self failRecording:_writer.error ?: MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
                                                                    MBCIOSLocalizedString(@"ios_recording_reject_sample", @"The MP4 writer rejected a video sample."))];
    }
}

- (void)stopRecordingWithCompletionHandler:(MBCIOSRecordingCompletion)completionHandler
{
    @synchronized (self) {
        if (!_recording) {
            if (completionHandler) completionHandler(MBCIOSRecordingError(MBCIOSRecordingErrorInvalidURL,
                                                                            MBCIOSLocalizedString(@"ios_recording_not_active", @"No recording is active.")));
            return;
        }
        _stopRequested = YES;
        _pendingStopCompletion = [completionHandler copy];
    }

    __weak MBCIOSRecordingController *weakSelf = self;
    [_recorder stopCaptureWithHandler:^(NSError *error) {
        MBCIOSRecordingController *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_writerQueue, ^{
            [strongSelf finishAfterStop:error];
        });
    }];
}

- (void)finishAfterStop:(NSError *)captureError
{
    @synchronized (self) {
        if (!_recording) {
            _writer = nil;
            _videoInput = nil;
            return;
        }
    }
    NSError *finalError = captureError;
    if (!finalError && !_sawVideo) {
        finalError = MBCIOSRecordingError(MBCIOSRecordingErrorNoVideo,
                                           MBCIOSLocalizedString(@"ios_recording_no_video", @"ReplayKit stopped without delivering a video frame."));
    }
    if (!finalError && _writer.status == AVAssetWriterStatusFailed)
        finalError = _writer.error ?: MBCIOSRecordingError(MBCIOSRecordingErrorWriterFailed,
            MBCIOSLocalizedString(@"ios_recording_reject_sample", @"The MP4 writer rejected a video sample."));
    if (!finalError && _writer) {
        [_videoInput markAsFinished];
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [_writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(semaphore); }];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        if (_writer.status == AVAssetWriterStatusFailed) finalError = _writer.error;
    }

    _writer = nil;
    _videoInput = nil;

    MBCIOSRecordingCompletion startCompletion = nil;
    MBCIOSRecordingCompletion stopCompletion = nil;
    @synchronized (self) {
        if (_recording) {
            startCompletion = _pendingStartCompletion;
            _pendingStartCompletion = nil;
            stopCompletion = _pendingStopCompletion;
            _pendingStopCompletion = nil;
            _recording = NO;
            _stopRequested = NO;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (startCompletion) startCompletion(finalError);
        if (stopCompletion) stopCompletion(finalError);
    });
}

- (void)failRecording:(NSError *)error
{
    MBCIOSRecordingCompletion startCompletion = nil;
    MBCIOSRecordingCompletion stopCompletion = nil;
    MBCIOSRecordingFailureHandler failureHandler = nil;
    BOOL shouldStopCapture = NO;
    @synchronized (self) {
        if (!_recording) return;
        shouldStopCapture = !_stopRequested;
        _recording = NO;
        _stopRequested = YES;
        startCompletion = _pendingStartCompletion;
        _pendingStartCompletion = nil;
        stopCompletion = _pendingStopCompletion;
        _pendingStopCompletion = nil;
        if (!startCompletion && !stopCompletion)
            failureHandler = self.failureHandler;
    }
    if (shouldStopCapture) [_recorder stopCaptureWithHandler:nil];
    NSLog(@"Chess recording failed: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (startCompletion) startCompletion(error);
        if (stopCompletion) stopCompletion(error);
        if (failureHandler) failureHandler(error);
    });
}

@end
