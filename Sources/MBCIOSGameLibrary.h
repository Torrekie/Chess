/* Named, revisioned .game documents for the iOS Chess library. */

#import <Foundation/Foundation.h>

#import "MBCIOSGameStore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MBCIOSGameLibraryErrorDomain;
FOUNDATION_EXPORT NSString * const MBCIOSGameLibraryConflictingIdentifierKey;

typedef NS_ENUM(NSInteger, MBCIOSGameLibraryErrorCode) {
    MBCIOSGameLibraryErrorInvalidRequest = 1,
    MBCIOSGameLibraryErrorInvalidName,
    MBCIOSGameLibraryErrorNotFound,
    MBCIOSGameLibraryErrorConflict,
    MBCIOSGameLibraryErrorCorruptIndex,
    MBCIOSGameLibraryErrorCorruptGame,
};

/* A snapshot of one library entry. Pass the returned record back to saveGame:
 * to detect an intervening save or rename from another view of the library. */
@interface MBCIOSGameRecord : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *matchID;
@property (nonatomic, readonly) NSUInteger revision;
@property (nonatomic, copy, readonly) NSDate *createdAt;
@property (nonatomic, copy, readonly) NSDate *modifiedAt;
@property (nonatomic, copy, readonly, nullable) NSDate *openedAt;
@property (nonatomic, copy, readonly) NSURL *fileURL;

@end

@interface MBCIOSGameLibrary : NSObject

+ (nullable instancetype)sharedLibraryWithError:(NSError **)error;
+ (nullable instancetype)sharedLibrary;

/* Also supports an isolated directory for tests and future document moves. */
- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/* Entries are sorted by last open, then last modification. An absent match or
 * last-opened game returns nil with no error. */
- (nullable NSArray<MBCIOSGameRecord *> *)recentGamesWithError:(NSError **)error;
/* Clearing recents preserves saved games and the game restored on launch. */
- (nullable NSArray<MBCIOSGameRecord *> *)allGamesWithError:(NSError **)error;
- (BOOL)clearRecentGamesWithError:(NSError **)error;
/* The caller supplies every currently open game identifier across its scenes.
 * Revision validation prevents deletion after another window saves changes. */
- (BOOL)deleteGame:(MBCIOSGameRecord *)record
 excludingIdentifiers:(NSSet<NSString *> *)openIdentifiers error:(NSError **)error;
- (nullable MBCIOSGameRecord *)lastOpenedGameWithError:(NSError **)error;
- (nullable MBCIOSGameRecord *)recordForMatchID:(NSString *)matchID error:(NSError **)error;

- (nullable MBCIOSGameRecord *)createGameNamed:(NSString *)name
                                          board:(MBCBoard *)board
                                        variant:(MBCVariant)variant
                                           side:(MBCSide)side
                                     boardStyle:(NSString *)boardStyle
                                     pieceStyle:(NSString *)pieceStyle
                                       metadata:(NSDictionary * _Nullable)metadata
                                          error:(NSError **)error;

/* A stale record or a duplicate Game Center match ID returns Conflict. The
 * returned record has the new revision; retain it for the next autosave. */
- (nullable MBCIOSGameRecord *)saveGame:(MBCIOSGameRecord *)record
                                  board:(MBCBoard *)board
                                variant:(MBCVariant)variant
                                   side:(MBCSide)side
                             boardStyle:(NSString *)boardStyle
                             pieceStyle:(NSString *)pieceStyle
                               metadata:(NSDictionary * _Nullable)metadata
                                  error:(NSError **)error;

/* Save As creates an independent local copy. For a Game Center game, the copy
 * omits match identity and becomes a human-vs-human local game. */
- (nullable MBCIOSGameRecord *)duplicateGame:(MBCIOSGameRecord *)record
                                       asName:(NSString *)name
                                        error:(NSError **)error;

- (nullable MBCIOSGameRecord *)renameGame:(MBCIOSGameRecord *)record
                                    toName:(NSString *)name
                                     error:(NSError **)error;

/* Loads into a fresh board. On any failure, board and all output values stay
 * untouched, and the library's last-opened identifier is unchanged. */
- (nullable MBCIOSGameRecord *)openGameWithIdentifier:(NSString *)identifier
                                               board:(MBCBoard * _Nullable * _Nonnull)board
                                             variant:(MBCVariant *)variant
                                                side:(MBCSide *)side
                                          boardStyle:(NSString * _Nullable * _Nullable)boardStyle
                                          pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
                                            metadata:(NSDictionary * _Nullable * _Nullable)metadata
                                               error:(NSError **)error;

/* Copies Casual.game into the library once without deleting or rewriting it. */
- (BOOL)migrateLegacyAutosaveIfNeededWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
