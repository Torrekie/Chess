/* iOS sandbox persistence and bundled-resource boundary for Chess games. */

#import <Foundation/Foundation.h>

#import "MBCBoard.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MBCIOSGameStoreErrorDomain;

typedef NS_ENUM(NSInteger, MBCIOSGameStoreErrorCode) {
    MBCIOSGameStoreErrorInvalidGame = 1,
    MBCIOSGameStoreErrorUnsupportedVariant,
    MBCIOSGameStoreErrorMissingResource,
    MBCIOSGameStoreErrorUnsupportedFormat,
    MBCIOSGameStoreErrorInvalidPGN,
};

@interface MBCIOSGameStore : NSObject

+ (nullable NSURL *)applicationSupportDirectoryWithError:(NSError **)error;
+ (nullable NSURL *)defaultGameURLWithError:(NSError **)error;

+ (void)registerDefaults;

+ (NSDictionary *)gameDictionaryForBoard:(MBCBoard *)board
                                 variant:(MBCVariant)variant
                                    side:(MBCSide)side
                              boardStyle:(NSString *)boardStyle
                              pieceStyle:(NSString *)pieceStyle;

/* The editable document properties mirror MBCGameInfo/MBCDocument on macOS:
 * White, Black, City, Country, Event, StartDate, StartTime, and Result. */
+ (NSDictionary *)defaultMetadataForSide:(MBCSide)side;

+ (NSDictionary *)gameDictionaryForBoard:(MBCBoard *)board
                                 variant:(MBCVariant)variant
                                    side:(MBCSide)side
                              boardStyle:(NSString *)boardStyle
                              pieceStyle:(NSString *)pieceStyle
                                metadata:(NSDictionary * _Nullable)metadata;

+ (BOOL)saveBoard:(MBCBoard *)board
          variant:(MBCVariant)variant
             side:(MBCSide)side
       boardStyle:(NSString *)boardStyle
       pieceStyle:(NSString *)pieceStyle
           toURL:(NSURL *)url
           error:(NSError **)error;

+ (BOOL)saveBoard:(MBCBoard *)board
          variant:(MBCVariant)variant
             side:(MBCSide)side
       boardStyle:(NSString *)boardStyle
       pieceStyle:(NSString *)pieceStyle
         metadata:(NSDictionary * _Nullable)metadata
            toURL:(NSURL *)url
            error:(NSError **)error;

+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString * _Nullable * _Nullable)boardStyle
       pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
          fromURL:(NSURL *)url
            error:(NSError **)error;

/* Game Center uses the same top-level property-list dictionary as a .game
 * document, but transports it as NSData instead of a file URL. Returned
 * metadata includes normalized lowercase WhiteType/BlackType and both
 * MatchID/GameCenterMatchID when either match key exists in the source.
 * Player types determine local-game side; for a match, Side is the local
 * participant and both player types are human. */
+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString * _Nullable * _Nullable)boardStyle
       pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
          metadata:(NSDictionary * _Nullable * _Nullable)metadata
 fromGameDictionary:(NSDictionary *)game
            error:(NSError **)error;

+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString * _Nullable * _Nullable)boardStyle
       pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
         metadata:(NSDictionary * _Nullable * _Nullable)metadata
          fromURL:(NSURL *)url
            error:(NSError **)error;

/* Document bridge. .game is the property list used by the macOS document.
 * For a nonstandard starting position, Moves is empty for macOS and IOSMoves
 * plus InitialPosition/InitialHolding preserve iOS history. PGN carries
 * standard starting-position headers plus MBCMoves and MBCFinalFEN tags for
 * lossless round trips and also accepts ordinary SAN-only external PGN. */
+ (BOOL)writeBoard:(MBCBoard *)board
           variant:(MBCVariant)variant
              side:(MBCSide)side
        boardStyle:(NSString *)boardStyle
        pieceStyle:(NSString *)pieceStyle
             toURL:(NSURL *)url
             error:(NSError **)error;

+ (BOOL)writeBoard:(MBCBoard *)board
           variant:(MBCVariant)variant
              side:(MBCSide)side
        boardStyle:(NSString *)boardStyle
        pieceStyle:(NSString *)pieceStyle
          metadata:(NSDictionary * _Nullable)metadata
             toURL:(NSURL *)url
             error:(NSError **)error;

+ (nullable NSString *)PGNForBoard:(MBCBoard *)board
                           variant:(MBCVariant)variant
                              side:(MBCSide)side
                        boardStyle:(NSString *)boardStyle
                        pieceStyle:(NSString *)pieceStyle
                             error:(NSError **)error;

+ (nullable NSString *)PGNForBoard:(MBCBoard *)board
                           variant:(MBCVariant)variant
                              side:(MBCSide)side
                        boardStyle:(NSString *)boardStyle
                        pieceStyle:(NSString *)pieceStyle
                          metadata:(NSDictionary * _Nullable)metadata
                             error:(NSError **)error;

+ (BOOL)importPGN:(NSString *)pgn
         intoBoard:(MBCBoard *)board
           variant:(MBCVariant *)variant
              side:(MBCSide *)side
        boardStyle:(NSString * _Nullable * _Nullable)boardStyle
        pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
             error:(NSError **)error;

+ (BOOL)importPGN:(NSString *)pgn
         intoBoard:(MBCBoard *)board
           variant:(MBCVariant *)variant
              side:(MBCSide *)side
        boardStyle:(NSString * _Nullable * _Nullable)boardStyle
        pieceStyle:(NSString * _Nullable * _Nullable)pieceStyle
          metadata:(NSDictionary * _Nullable * _Nullable)metadata
             error:(NSError **)error;

+ (nullable NSURL *)openingBookURLForVariant:(MBCVariant)variant
                                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
