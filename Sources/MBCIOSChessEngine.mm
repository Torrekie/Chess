/*
 * iOS transport for the shared Sjeng chess engine.
 *
 * MBCEngine on macOS launches Sjeng with NSTask/NSPipe and decodes its
 * xboard stream through NSPort.  iOS exposes the POSIX pipe primitives but
 * rejects executing a nested application binary from an app sandbox.  The
 * iOS target therefore compiles the same Sjeng sources into the app and runs
 * its unchanged xboard loop on an 8 MiB pthread.  Only stdin/stdout are
 * redirected to private pipes; the command protocol and move notifications
 * remain shared with the macOS implementation.
 */

#import "MBCIOSChessEngine.h"
#import "MBCIOSjeng.h"

NSNotificationName const MBCIOSChessEngineDidStopNotification = @"MBCIOSChessEngineDidStopNotification";

#import "MBCPlayer.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int MBCIOSMovesForSearchTime(NSInteger time)
{
    if (time <= 10) return MAX(1, (int)time);
    if (time == 11) return 20;
    if (time == 12) return 30;
    return 1;
}

static const NSTimeInterval kMBCIOSAutomaticDelay = 4.0;

static NSString *MBCIOSNotificationForSide(MBCSide side)
{
    return side == kWhiteSide ? MBCWhiteMoveNotification : MBCBlackMoveNotification;
}

static MBCMoveCode MBCIOSGameResultForEngineLine(NSString *line)
{
    /* Sjeng emits xboard result tokens after the final move.  Checkmate and
     * stalemate are also derivable from MBCBoard, but repetition and the
     * fifty-move rule are engine-owned terminal states, so preserve the
     * protocol result instead of waiting for another `go`. */
    if ([line hasPrefix:@"1-0"]) return kCmdWhiteWins;
    if ([line hasPrefix:@"0-1"]) return kCmdBlackWins;
    if ([line hasPrefix:@"1/2-1/2"]) return kCmdDraw;
    return kCmdNull;
}

static void *MBCIOSjengThreadMain(void *opaque)
{
    MBCIOSjengRun((MBCIOSjengSession *)opaque);
    return NULL;
}

@interface MBCIOSChessEngine ()
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic) int inputFD;
@property (nonatomic) int outputFD;
@property (nonatomic) int sjengInputFD;
@property (nonatomic) int sjengOutputFD;
@property (nonatomic) pthread_t sjengThread;
@property (nonatomic) BOOL threadStarted;
@property (nonatomic) dispatch_queue_t readerQueue;
@property (nonatomic) dispatch_source_t readerSource;
@property (nonatomic, strong) NSMutableData *inputBuffer;
@property (nonatomic, strong) MBCMove *pendingHumanMove;
@property (nonatomic, strong) MBCMove *lastEngineMove;
@property (nonatomic, strong, readwrite) MBCMove *lastPonder;
@property (nonatomic) MBCVariant variant;
@property (nonatomic) MBCSide engineSide;
@property (nonatomic) MBCSide nextSide;
@property (nonatomic) MBCSide pendingHumanSide;
@property (nonatomic) BOOL observingMoves;
@property (nonatomic) BOOL waitingForMovePresentation;
@property (nonatomic) BOOL awaitingStartupAcknowledgement;
@property (nonatomic) MBCIOSjengSession *session;
@property (nonatomic) NSUInteger generation;
@end

@implementation MBCIOSChessEngine

- (instancetype)init
{
    self = [super init];
    if (self) {
        _inputFD = -1;
        _outputFD = -1;
        _sjengInputFD = -1;
        _sjengOutputFD = -1;
        _sessionIdentifier = NSUUID.UUID.UUIDString;
        _inputBuffer = [[NSMutableData alloc] init];
        _readerQueue = dispatch_queue_create("com.apple.chess.ios-sjeng-reader",
                                             DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (void)removeMoveObservers
{
    if (!self.observingMoves) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:MBCUncheckedWhiteMoveNotification object:nil];
    [center removeObserver:self name:MBCUncheckedBlackMoveNotification object:nil];
    self.observingMoves = NO;
}

- (void)installMoveObservers
{
    [self removeMoveObservers];
    if (!self.moveSource) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (self.engineSide == kWhiteSide) {
        [center addObserver:self selector:@selector(opponentMoved:)
                       name:MBCUncheckedBlackMoveNotification object:self.moveSource];
    } else if (self.engineSide == kBlackSide) {
        [center addObserver:self selector:@selector(opponentMoved:)
                       name:MBCUncheckedWhiteMoveNotification object:self.moveSource];
    }
    self.observingMoves = YES;
}

- (NSString *)workingDirectory
{
    NSArray<NSURL *> *directories = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *directory = directories.firstObject;
    if (!directory) return nil;
    directory = [directory URLByAppendingPathComponent:@"Chess/Sjeng" isDirectory:YES];
    NSString *identifier = [[self.sessionIdentifier componentsSeparatedByCharactersInSet:
        NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    if (!identifier.length) identifier = NSUUID.UUID.UUIDString;
    directory = [directory URLByAppendingPathComponent:identifier isDirectory:YES];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        NSLog(@"Chess Sjeng working directory unavailable: %@", error);
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *names = @[
        @"sjeng.rc", @"normal.opn", @"suicide.opn", @"losers.opn", @"bug.opn",
        @"nbook.db", @"zbook.db"
    ];
    for (NSString *name in names) {
        NSURL *source = [NSBundle.mainBundle URLForResource:name withExtension:nil];
        if (!source) source = [NSBundle.mainBundle URLForResource:name
            withExtension:nil subdirectory:@"books"];
        NSURL *booksDirectory = [NSBundle.mainBundle URLForResource:@"Opening Books"
                                                        withExtension:nil];
        if (!source && booksDirectory) source = [booksDirectory URLByAppendingPathComponent:name];
        NSURL *destination = [directory URLByAppendingPathComponent:name];
        if (source && ![fileManager fileExistsAtPath:destination.path]) {
            [fileManager copyItemAtURL:source toURL:destination error:nil];
        }
    }
    return directory.path;
}

- (BOOL)startInProcessEngine
{
    int toEngine[2] = {-1, -1};
    int fromEngine[2] = {-1, -1};
    if (pipe(toEngine) != 0 || pipe(fromEngine) != 0) {
        if (toEngine[0] >= 0) close(toEngine[0]);
        if (toEngine[1] >= 0) close(toEngine[1]);
        if (fromEngine[0] >= 0) close(fromEngine[0]);
        if (fromEngine[1] >= 0) close(fromEngine[1]);
        NSLog(@"Chess Sjeng pipe setup failed: %s", strerror(errno));
        return NO;
    }

    /* Configure both writers before the Sjeng thread can run or either
     * reader can be closed by a scene handoff. */
    if (fcntl(toEngine[1], F_SETNOSIGPIPE, 1) == -1 ||
        fcntl(fromEngine[1], F_SETNOSIGPIPE, 1) == -1) {
        int savedError = errno;
        close(toEngine[0]); close(toEngine[1]);
        close(fromEngine[0]); close(fromEngine[1]);
        NSLog(@"Chess Sjeng pipe configuration failed: %s", strerror(savedError));
        return NO;
    }

    NSString *workingDirectory = [self workingDirectory];
    if (!workingDirectory.length) {
        close(toEngine[0]); close(toEngine[1]);
        close(fromEngine[0]); close(fromEngine[1]);
        return NO;
    }

    self.session = MBCIOSjengCreate(toEngine[0], fromEngine[1],
                                    workingDirectory.fileSystemRepresentation);
    if (!self.session) {
        close(toEngine[0]); close(toEngine[1]);
        close(fromEngine[0]); close(fromEngine[1]);
        return NO;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    int result = pthread_create(&_sjengThread, &attributes, MBCIOSjengThreadMain, self.session);
    pthread_attr_destroy(&attributes);
    if (result != 0) {
        MBCIOSjengDestroy(self.session);
        self.session = NULL;
        close(toEngine[0]); close(toEngine[1]);
        close(fromEngine[0]); close(fromEngine[1]);
        NSLog(@"Chess Sjeng thread creation failed: %s", strerror(result));
        return NO;
    }

    self.sjengInputFD = toEngine[0];
    self.inputFD = toEngine[1];
    self.sjengOutputFD = fromEngine[1];
    self.outputFD = fromEngine[0];
    fcntl(self.outputFD, F_SETFL, fcntl(self.outputFD, F_GETFL) | O_NONBLOCK);
    self.threadStarted = YES;
    self.running = YES;
    return YES;
}

- (void)startReader
{
    if (self.readerSource) dispatch_source_cancel(self.readerSource);
    int fd = self.outputFD;
    NSUInteger generation = self.generation;
    self.readerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd,
                                                0, self.readerQueue);
    __weak MBCIOSChessEngine *weakSelf = self;
    dispatch_source_set_event_handler(self.readerSource, ^{
        MBCIOSChessEngine *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRunning) return;
        char bytes[4096];
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count > 0) {
            [strongSelf.inputBuffer appendBytes:bytes length:(NSUInteger)count];
            [strongSelf consumeInputLinesForGeneration:generation];
        } else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MBCIOSChessEngine *current = weakSelf;
                if (current && current.generation == generation) [current stop];
            });
        }
    });
    dispatch_source_set_cancel_handler(self.readerSource, ^{
        close(fd);
    });
    dispatch_resume(self.readerSource);
}

- (void)consumeInputLinesForGeneration:(NSUInteger)generation
{
    const uint8_t *bytes = (const uint8_t *)self.inputBuffer.bytes;
    NSUInteger length = self.inputBuffer.length;
    NSUInteger start = 0;
    for (NSUInteger index = 0; index < length; ++index) {
        if (bytes[index] != '\n') continue;
        NSData *lineData = [self.inputBuffer subdataWithRange:NSMakeRange(start, index - start)];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) dispatch_async(dispatch_get_main_queue(), ^{
            if (self.generation == generation) [self handleEngineLine:line];
        });
        start = index + 1;
    }
    if (start) [self.inputBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

- (void)writeString:(NSString *)string
{
    if (!self.isRunning || self.inputFD < 0) return;
    NSData *data = [string dataUsingEncoding:NSASCIIStringEncoding];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    ssize_t remaining = (ssize_t)data.length;
    while (remaining > 0) {
        ssize_t written = write(self.inputFD, bytes, (size_t)remaining);
        if (written > 0) {
            bytes += written;
            remaining -= written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

- (void)startGame:(MBCVariant)variant playing:(MBCSide)engineSide searchTime:(NSInteger)searchTime
{
    [self startGame:variant playing:engineSide searchTime:searchTime fromBoard:nil];
}

- (void)startGame:(MBCVariant)variant
          playing:(MBCSide)engineSide
       searchTime:(NSInteger)searchTime
        fromBoard:(MBCBoard *)board
{
    [self stop];
    [self.inputBuffer setLength:0];
    self.variant = variant;
    self.engineSide = engineSide;
    self.nextSide = board && ([board numMoves] & 1) ? kBlackSide : kWhiteSide;
    self.pendingHumanSide = kNeitherSide;
    self.pendingHumanMove = nil;
    self.lastEngineMove = nil;
    self.lastPonder = nil;
    self.waitingForMovePresentation = NO;
    self.awaitingStartupAcknowledgement = YES;
    if (![self startInProcessEngine]) return;

    [self installMoveObservers];
    [self startReader];
    [self writeString:@"xboard\nconfirm_moves\n?new\npost\n"];
    switch (variant) {
        case kVarCrazyhouse: [self writeString:@"variant crazyhouse\n"]; break;
        case kVarSuicide: [self writeString:@"variant suicide\n"]; break;
        case kVarLosers: [self writeString:@"variant losers\n"]; break;
        default: break;
    }
    [self setSearchTime:searchTime];
    if (board) {
        /* Replaying the game preserves opening-book choices, repetition
         * hashes and the fifty-move clock. setboard disables Sjeng's books,
         * so use it only for a nonstandard initial position. */
        [self writeString:@"force\n"];
        NSString *initialFen = board.initialFen;
        NSString *holding = board.initialHolding;
        NSString *standardFen = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        if (![initialFen isEqualToString:standardFen] || ![holding isEqualToString:@"[] []"]) {
            [self writeString:[NSString stringWithFormat:@"setboard %@\n", initialFen ?: board.fen]];
            if (variant == kVarCrazyhouse && holding.length) {
                [self writeString:[NSString stringWithFormat:@"holding %@\n", holding]];
            }
        }
        NSString *moves = board.moves;
        if (moves.length) [self writeString:moves];
    }
    /* User input can arrive before the reader drains replay confirmations.
     * xboard processes this marker before subsequently queued user moves. */
    [self writeString:@"ping 1\n"];

    BOOL engineMovesNow = engineSide == kBothSides || engineSide == self.nextSide;
    if (engineMovesNow) [self writeString:@"go\n"];
    else [self writeString:@"force\n"];
}

- (void)setSearchTime:(NSInteger)searchTime
{
    [self writeString:[NSString stringWithFormat:@"sd %d\n", MBCIOSMovesForSearchTime(searchTime)]];
}

- (void)opponentMoved:(NSNotification *)notification
{
    MBCMove *move = (MBCMove *)notification.userInfo;
    if (!self.isRunning || !move) return;
    self.lastPonder = nil;
    self.pendingHumanMove = move;
    self.pendingHumanSide = self.nextSide;
    NSString *engineMove = [move engineMove];
    if (engineMove.length) [self writeString:engineMove];
}

- (void)postMove:(MBCMove *)move side:(MBCSide)side
{
    if (!move || side == kNeitherSide) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:MBCIOSNotificationForSide(side)
                                                          object:self
                                                        userInfo:(NSDictionary *)move];
}

- (void)handleEngineLine:(NSString *)rawLine
{
    if (!self.isRunning) return;
    NSString *line = [rawLine stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!line.length) return;
    if (self.awaitingStartupAcknowledgement) {
        if ([line isEqualToString:@"pong 1"]) self.awaitingStartupAcknowledgement = NO;
        return;
    }

    MBCMoveCode resultCommand = MBCIOSGameResultForEngineLine(line);
    if (resultCommand != kCmdNull) {
        self.waitingForMovePresentation = NO;
        MBCMove *result = [MBCMove moveWithCommand:resultCommand];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCGameEndNotification object:self userInfo:(id)result];
        return;
    }

    if ([line hasPrefix:@"Legal move:"]) {
        if (!self.pendingHumanMove) return;
        MBCMove *move = self.pendingHumanMove;
        MBCSide side = self.pendingHumanSide;
        self.pendingHumanMove = nil;
        self.pendingHumanSide = kNeitherSide;
        [self postMove:move side:side];
        self.nextSide = side == kWhiteSide ? kBlackSide : kWhiteSide;
        if (self.engineSide == self.nextSide) [self writeString:@"go\n"];
        return;
    }
    if ([line hasPrefix:@"Illegal move:"]) {
        MBCMove *move = self.pendingHumanMove;
        self.pendingHumanMove = nil;
        self.pendingHumanSide = kNeitherSide;
        [[NSNotificationCenter defaultCenter] postNotificationName:MBCIllegalMoveNotification
                                                              object:self
                                                            userInfo:(NSDictionary *)move];
        return;
    }
    if ([line hasPrefix:@"ponder "]) {
        NSString *coordinate = [[line substringFromIndex:7]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (coordinate.length < 4) return;
        MBCMove *move = [MBCMove newFromEngineMove:coordinate];
        if (move->fCommand != kCmdNull) self.lastPonder = move;
        return;
    }
    if ([line hasPrefix:@"move "]) {
        NSString *coordinate = [[line substringFromIndex:5]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (coordinate.length < 4) return;
        MBCMove *move = [MBCMove newFromEngineMove:coordinate];
        if (move->fCommand == kCmdNull) return;
        self.lastEngineMove = move;
        self.lastPonder = nil;
        MBCSide side = self.nextSide;
        [self postMove:move side:side];
        self.nextSide = side == kWhiteSide ? kBlackSide : kWhiteSide;
        if (self.engineSide == kBothSides) {
            /* The controller owns the visible move animation.  Do not let
             * the engine advance the protocol until that animation ends. */
            self.waitingForMovePresentation = YES;
        }
    }
}

- (void)sendNextComputerMove
{
    if (!self.isRunning || self.engineSide != kBothSides || self.waitingForMovePresentation) {
        return;
    }
    [self writeString:@"go\n"];
}

- (void)movePresentationDidFinish
{
    if (!self.isRunning || self.engineSide != kBothSides || !self.waitingForMovePresentation) {
        return;
    }

    self.waitingForMovePresentation = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                               selector:@selector(sendNextComputerMove)
                                                 object:nil];
    /* Match MBCEngine's kAutomaticDelay between visible computer moves. */
    [self performSelector:@selector(sendNextComputerMove)
               withObject:nil
               afterDelay:kMBCIOSAutomaticDelay];
}

- (void)stop
{
    BOOL wasRunning = self.isRunning;
    ++self.generation;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                               selector:@selector(sendNextComputerMove)
                                                 object:nil];
    self.waitingForMovePresentation = NO;
    [self removeMoveObservers];
    self.awaitingStartupAcknowledgement = NO;
    if (self.threadStarted) MBCIOSjengRequestStop(self.session);
    if (self.isRunning && self.inputFD >= 0) [self writeString:@"quit\n"];
    dispatch_source_t source = self.readerSource;
    self.readerSource = nil;
    if (source) {
        dispatch_source_cancel(source);
        /* The cancellation handler owns outputFD.  Drain the serial reader
         * queue before a later game can reuse that descriptor number. */
        dispatch_sync(self.readerQueue, ^{});
    }

    int inputFD = self.inputFD;
    int outputFD = self.outputFD;
    self.inputFD = -1;
    self.outputFD = -1;
    if (inputFD >= 0) close(inputFD);
    if (!source && outputFD >= 0) close(outputFD);
    if (self.threadStarted) {
        pthread_join(self.sjengThread, NULL);
        self.threadStarted = NO;
    }
    MBCIOSjengDestroy(self.session);
    self.session = NULL;
    self.sjengInputFD = -1;
    self.sjengOutputFD = -1;
    self.running = NO;
    self.pendingHumanMove = nil;
    self.lastEngineMove = nil;
    self.lastPonder = nil;
    if (wasRunning) {
        __weak MBCIOSChessEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            MBCIOSChessEngine *engine = weakSelf;
            if (engine && !engine.isRunning) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:MBCIOSChessEngineDidStopNotification object:engine];
            }
        });
    }
}

@end
