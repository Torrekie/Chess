/* iOS sandbox persistence and bundled-resource boundary for Chess games. */

#import "MBCIOSGameStore.h"
#import "MBCIOSLocalization.h"
#import "MBCMoveGenerator.h"
#import "MBCUserDefaults.h"

#include <stdio.h>
#include <limits.h>

NSString * const MBCIOSGameStoreErrorDomain = @"com.apple.Chess.iOSGameStore";

static NSError *MBCStoreError(MBCIOSGameStoreErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:MBCIOSGameStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *MBCVariantName(MBCVariant variant)
{
    if (variant < kVarNormal || variant > kVarLosers || !gVariantName[variant]) {
        return nil;
    }
    return gVariantName[variant];
}

static BOOL MBCParseVariant(NSString *name, MBCVariant *variant)
{
    for (NSInteger candidate = kVarNormal; candidate <= kVarLosers; ++candidate) {
        MBCVariant candidateVariant = (MBCVariant)candidate;
        if ([name isEqualToString:gVariantName[candidateVariant]]) {
            *variant = candidateVariant;
            return YES;
        }
    }
    return NO;
}

static NSString *MBCStandardFEN(void);
static BOOL MBCIOSHistoryIsLegal(NSString *moves, MBCVariant variant,
                                NSString *initialPosition, NSString *initialHolding);

static BOOL MBCBoardHasCustomOrigin(MBCBoard *board)
{
    return ![board.initialFen isEqualToString:MBCStandardFEN()] ||
           ![board.initialHolding isEqualToString:@"[] []"];
}

static BOOL MBCValidString(id value)
{
    return [value isKindOfClass:[NSString class]];
}

/* The shared board's FEN and engine-move readers use raw C pointers. Check
 * document text here before handing it to those readers, including the FEN
 * and MBCMoves extensions in imported PGN. Four/five-field FENs are expanded
 * to the six-field form that MBCBoard expects. */
static BOOL MBCIOSValidFENNumber(NSString *value, BOOL allowZero)
{
    if (!value.length || value.length > 10) return NO;
    unsigned long long number = 0;
    for (NSUInteger index = 0; index < value.length; ++index) {
        unichar digit = [value characterAtIndex:index];
        if (digit < '0' || digit > '9') return NO;
        number = number * 10 + digit - '0';
        if (number > (unsigned long long)INT_MAX - 10000) return NO;
    }
    return allowZero || number > 0;
}

static NSString *MBCIOSValidatedFEN(NSString *fen)
{
    if (!MBCValidString(fen) || !fen.length || fen.length > 1024) return nil;
    NSMutableArray<NSString *> *fields = [NSMutableArray arrayWithCapacity:6];
    for (NSString *part in [fen componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (part.length) [fields addObject:part];
    }
    if (fields.count < 4 || fields.count > 6) return nil;

    NSArray<NSString *> *ranks = [fields[0] componentsSeparatedByString:@"/"];
    if (ranks.count != 8) return nil;
    NSUInteger pieceCounts[2][7] = {};
    for (NSString *rank in ranks) {
        NSUInteger width = 0;
        for (NSUInteger index = 0; index < rank.length; ++index) {
            unichar token = [rank characterAtIndex:index];
            if (token >= '1' && token <= '8') width += token - '0';
            else if ([@"KQBNRPkqbnrp" rangeOfString:
                      [NSString stringWithCharacters:&token length:1]].location != NSNotFound) {
                NSUInteger color = token >= 'a' ? 1 : 0;
                NSString *pieceLetters = @"KQBNRP";
                NSUInteger piece = [pieceLetters rangeOfString:
                    [[NSString stringWithCharacters:&token length:1] uppercaseString]].location + 1;
                if (++pieceCounts[color][piece] > 16) return nil;
                ++width;
            }
            else return nil;
            if (width > 8) return nil;
        }
        if (width != 8) return nil;
    }
    if (![fields[1] isEqualToString:@"w"] && ![fields[1] isEqualToString:@"b"]) return nil;

    NSString *rights = fields[2];
    BOOL castling[4] = {NO, NO, NO, NO};
    if (![rights isEqualToString:@"-"]) {
        if (!rights.length || rights.length > 4) return nil;
        for (NSUInteger index = 0; index < rights.length; ++index) {
            unichar token = [rights characterAtIndex:index];
            NSUInteger slot = token == 'K' ? 0 : token == 'Q' ? 1 :
                              token == 'k' ? 2 : token == 'q' ? 3 : 4;
            if (slot == 4 || castling[slot]) return nil;
            castling[slot] = YES;
        }
        NSMutableString *canonical = [NSMutableString string];
        NSString *order = @"KQkq";
        for (NSUInteger index = 0; index < 4; ++index)
            if (castling[index]) [canonical appendFormat:@"%C", [order characterAtIndex:index]];
        rights = canonical;
    }

    NSString *enPassant = fields[3];
    if (![enPassant isEqualToString:@"-"] &&
        (enPassant.length != 2 || [enPassant characterAtIndex:0] < 'a' ||
         [enPassant characterAtIndex:0] > 'h' ||
         ([enPassant characterAtIndex:1] != '3' && [enPassant characterAtIndex:1] != '6'))) return nil;
    NSString *halfmove = fields.count >= 5 ? fields[4] : @"0";
    NSString *fullmove = fields.count >= 6 ? fields[5] : @"1";
    if (!MBCIOSValidFENNumber(halfmove, YES) ||
        !MBCIOSValidFENNumber(fullmove, NO)) return nil;
    return [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
            fields[0], fields[1], rights, enPassant, halfmove, fullmove];
}

static BOOL MBCIOSValidHolding(NSString *holding)
{
    if (!MBCValidString(holding) || holding.length < 4 || holding.length > 128) return NO;
    NSUInteger index = 0;
    NSUInteger pieceCount = 0;
    for (NSUInteger side = 0; side < 2; ++side) {
        if (index >= holding.length || [holding characterAtIndex:index++] != '[') return NO;
        while (index < holding.length && [holding characterAtIndex:index] != ']') {
            unichar piece = [holding characterAtIndex:index++];
            if ([@"QBNRP" rangeOfString:
                  [NSString stringWithCharacters:&piece length:1]].location == NSNotFound ||
                ++pieceCount > 64) return NO;
        }
        if (index >= holding.length || [holding characterAtIndex:index++] != ']') return NO;
        if (side == 0) {
            while (index < holding.length && [holding characterAtIndex:index] == ' ') ++index;
        }
    }
    return index == holding.length;
}

static BOOL MBCIOSIsMoveFile(unichar character)
{
    return character >= 'a' && character <= 'h';
}

static BOOL MBCIOSIsMoveRank(unichar character)
{
    return character >= '1' && character <= '8';
}

static NSString *MBCIOSValidatedMoves(NSString *moves, MBCVariant variant)
{
    if (!MBCValidString(moves) || moves.length > 60000) return nil;
    if (!moves.length) return @"";
    NSMutableString *canonical = [NSMutableString stringWithCapacity:moves.length + 1];
    NSUInteger count = 0;
    for (NSString *raw in [moves componentsSeparatedByString:@"\n"]) {
        NSString *part = [raw hasSuffix:@"\r"] ? [raw substringToIndex:raw.length - 1] : raw;
        if (!part.length) continue;
        if (++count > 10000) return nil;
        BOOL drop = part.length == 4 && [part characterAtIndex:1] == '@';
        if (drop) {
            unichar piece = [part characterAtIndex:0];
            if (variant != kVarCrazyhouse ||
                [@"QBNRPqbnrp" rangeOfString:
                  [NSString stringWithCharacters:&piece length:1]].location == NSNotFound ||
                !MBCIOSIsMoveFile([part characterAtIndex:2]) ||
                !MBCIOSIsMoveRank([part characterAtIndex:3])) return nil;
        } else {
            if ((part.length != 4 && part.length != 5) ||
                !MBCIOSIsMoveFile([part characterAtIndex:0]) ||
                !MBCIOSIsMoveRank([part characterAtIndex:1]) ||
                !MBCIOSIsMoveFile([part characterAtIndex:2]) ||
                !MBCIOSIsMoveRank([part characterAtIndex:3])) return nil;
            if (part.length == 5) {
                unichar promotion = [part characterAtIndex:4];
                NSString *choices = variant == kVarSuicide ? @"QBRNKqbrnk" : @"QBRNqbrn";
                if ([choices rangeOfString:
                      [NSString stringWithCharacters:&promotion length:1]].location == NSNotFound)
                    return nil;
            }
        }
        [canonical appendString:part];
        [canonical appendString:@"\n"];
    }
    return canonical;
}

static BOOL MBCPlayerTypeIsHuman(NSString *type)
{
    NSString *lower = type.lowercaseString;
    return [lower isEqualToString:@"human"] || [lower isEqualToString:@"user"];
}

static BOOL MBCPlayerTypeIsRecognized(id type)
{
    if (!MBCValidString(type)) return NO;
    NSString *lower = [type lowercaseString];
    return [lower isEqualToString:@"human"] || [lower isEqualToString:@"user"] ||
           [lower isEqualToString:@"program"] || [lower isEqualToString:@"computer"];
}

static NSString *MBCPlayerTypeForSide(BOOL human)
{
    /* MBCDocument compares these values to the lowercase macOS constants. */
    return human ? @"human" : @"program";
}

static NSString *MBCNormalizedPlayerType(id type, BOOL fallbackHuman)
{
    return MBCPlayerTypeForSide(MBCPlayerTypeIsRecognized(type)
                                ? MBCPlayerTypeIsHuman(type) : fallbackHuman);
}

static NSString *MBCMatchIDFromGameDictionary(NSDictionary *game)
{
    NSString *matchID = MBCValidString(game[@"MatchID"]) ? game[@"MatchID"] : nil;
    if (!matchID.length) {
        matchID = MBCValidString(game[@"GameCenterMatchID"]) ? game[@"GameCenterMatchID"] : nil;
    }
    return matchID.length ? matchID : nil;
}

static BOOL MBCIOSMatchIDFieldsConflict(NSDictionary *game)
{
    id canonical = game[@"MatchID"];
    id legacy = game[@"GameCenterMatchID"];
    if ((canonical && !MBCValidString(canonical)) ||
        (legacy && !MBCValidString(legacy))) return YES;
    return [canonical length] && [legacy length] &&
        ![canonical isEqualToString:legacy];
}

static BOOL MBCGameDictionaryIsMatch(NSDictionary *game)
{
    return MBCMatchIDFromGameDictionary(game) != nil ||
        MBCValidString(game[@"WhitePlayerID"]) || MBCValidString(game[@"BlackPlayerID"]);
}

static BOOL MBCSideForPlayerTypes(NSDictionary *game, MBCSide *side)
{
    NSString *whiteType = game[@"WhiteType"];
    NSString *blackType = game[@"BlackType"];
    if (!MBCPlayerTypeIsRecognized(whiteType) || !MBCPlayerTypeIsRecognized(blackType)) {
        return NO;
    }
    BOOL whiteHuman = MBCPlayerTypeIsHuman(whiteType);
    BOOL blackHuman = MBCPlayerTypeIsHuman(blackType);
    *side = whiteHuman ? (blackHuman ? kBothSides : kWhiteSide)
                       : (blackHuman ? kBlackSide : kNeitherSide);
    return YES;
}

static BOOL MBCLoadedSideForGameDictionary(NSDictionary *game, MBCSide *side)
{
    NSNumber *sideValue = game[@"Side"];
    MBCSide playerTypesSide;
    BOOL hasPlayerTypes = MBCSideForPlayerTypes(game, &playerTypesSide);
    BOOL isMatch = MBCGameDictionaryIsMatch(game);
    /* In a Game Center payload Side means the local participant, while both
     * player types are human. Ordinary documents use player types as the
     * macOS authority, even if an old iOS Side key has become stale. */
    if (sideValue && isMatch) {
        *side = (MBCSide)sideValue.integerValue;
        return YES;
    }
    if (hasPlayerTypes) {
        *side = playerTypesSide;
        return YES;
    }
    if (sideValue) {
        *side = (MBCSide)sideValue.integerValue;
        return YES;
    }
    return NO;
}

static NSArray<NSString *> *MBCIOSMetadataKeys(void)
{
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"White", @"Black", @"City", @"Country", @"Event",
                 @"StartDate", @"StartTime", @"Result"];
    });
    return keys;
}

static NSSet<NSString *> *MBCIOSCoreGameKeys(void)
{
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"Schema", @"Version", @"Variant", @"Side", @"BoardStyle",
            @"PieceStyle", @"MBCBoardStyle", @"MBCPieceStyle", @"WhiteType",
            @"BlackType", @"Position", @"Holding", @"Moves", @"IOSMoves",
            @"InitialPosition", @"InitialHolding"]];
    });
    return keys;
}

static NSDictionary *MBCIOSMetadataFromGameDictionary(NSDictionary *game, MBCSide side)
{
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    NSSet *coreKeys = MBCIOSCoreGameKeys();
    for (id key in game) {
        id value = game[key];
        if (![key isKindOfClass:[NSString class]] || [coreKeys containsObject:key] || !value) {
            continue;
        }
        /* Keep the original macOS document's property-list values intact so
         * fields that this iOS slice does not edit are not silently dropped. */
        if ([NSPropertyListSerialization propertyList:value
                                      isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
            metadata[key] = value;
        }
    }
    BOOL hasPlayerTypes = MBCPlayerTypeIsRecognized(game[@"WhiteType"]) &&
                          MBCPlayerTypeIsRecognized(game[@"BlackType"]);
    metadata[@"WhiteType"] = MBCNormalizedPlayerType(hasPlayerTypes ? game[@"WhiteType"] : nil,
                                                       SideIncludesWhite(side));
    metadata[@"BlackType"] = MBCNormalizedPlayerType(hasPlayerTypes ? game[@"BlackType"] : nil,
                                                       SideIncludesBlack(side));
    NSString *matchID = MBCMatchIDFromGameDictionary(game);
    if (matchID) {
        metadata[@"MatchID"] = matchID;
        metadata[@"GameCenterMatchID"] = matchID;
    }
    return [metadata copy];
}

static NSString *MBCIOSMetadataString(NSDictionary *metadata, NSString *key, NSString *fallback)
{
    NSString *value = [metadata[key] isKindOfClass:[NSString class]] ? metadata[key] : nil;
    return value.length ? value : fallback;
}

static NSString *MBCIOSDateString(NSString *format)
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = format;
    return [formatter stringFromDate:[NSDate date]];
}

@implementation MBCIOSGameStore

+ (NSURL *)applicationSupportDirectoryWithError:(NSError **)error
{
    NSURL *base = [[[NSFileManager defaultManager]
                    URLsForDirectory:NSApplicationSupportDirectory
                           inDomains:NSUserDomainMask] firstObject];
    if (!base) {
        if (error) {
            *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                   MBCIOSLocalizedString(@"ios_store_app_support_unavailable", @"The application support directory is unavailable."));
        }
        return nil;
    }

    NSURL *directory = [base URLByAppendingPathComponent:@"com.apple.Chess"
                                              isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:error]) {
        return nil;
    }
    return directory;
}

+ (NSURL *)defaultGameURLWithError:(NSError **)error
{
    NSURL *directory = [self applicationSupportDirectoryWithError:error];
    return [directory URLByAppendingPathComponent:@"Casual.game"];
}

+ (void)registerDefaults
{
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"Defaults" withExtension:@"plist"];
    NSDictionary *defaults = url ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
    if ([defaults isKindOfClass:[NSDictionary class]]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    }
    // Preserve the original turn-side rotation unless the user disables it.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{kMBCAutoRotateBoard: @YES}];
}

+ (NSDictionary *)gameDictionaryForBoard:(MBCBoard *)board
                                 variant:(MBCVariant)variant
                                    side:(MBCSide)side
                              boardStyle:(NSString *)boardStyle
                              pieceStyle:(NSString *)pieceStyle
{
    return [self gameDictionaryForBoard:board variant:variant side:side
                             boardStyle:boardStyle pieceStyle:pieceStyle metadata:nil];
}

+ (NSDictionary *)defaultMetadataForSide:(MBCSide)side
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *human = [defaults stringForKey:kMBCHumanName] ?:
        MBCIOSLocalizedString(@"ios_human_player", @"Human");
    NSString *human2 = [defaults stringForKey:kMBCHumanName2] ?: human;
    return @{
        @"White": SideIncludesWhite(side) ? human : NSLocalizedString(@"engine_player", @"Computer"),
        @"Black": SideIncludesBlack(side) ? human2 : NSLocalizedString(@"engine_player", @"Computer"),
        @"City": [defaults stringForKey:kMBCGameCity] ?: @"?",
        @"Country": [defaults stringForKey:kMBCGameCountry] ?: @"?",
        @"Event": [defaults stringForKey:kMBCGameEvent] ?: NSLocalizedString(@"casual_game", @"Casual Game"),
        @"StartDate": MBCIOSDateString(@"yyyy.MM.dd"),
        @"StartTime": MBCIOSDateString(@"HH:mm:ss"),
        @"Result": @"*"
    };
}

+ (NSDictionary *)gameDictionaryForBoard:(MBCBoard *)board
                                 variant:(MBCVariant)variant
                                    side:(MBCSide)side
                              boardStyle:(NSString *)boardStyle
                              pieceStyle:(NSString *)pieceStyle
                                metadata:(NSDictionary *)metadata
{
    NSMutableDictionary *game = [NSMutableDictionary dictionaryWithDictionary:metadata ?: @{}];
    game[@"Schema"] = @"com.apple.Chess.iOS.game";
    game[@"Version"] = @1;
    game[@"Variant"] = MBCVariantName(variant) ?: @"normal";
    game[@"Side"] = @(side);
    game[@"BoardStyle"] = boardStyle ?: @"Wood";
    game[@"PieceStyle"] = pieceStyle ?: @"Wood";
    game[@"MBCBoardStyle"] = boardStyle ?: @"Wood";
    game[@"MBCPieceStyle"] = pieceStyle ?: @"Wood";
    BOOL isMatch = MBCGameDictionaryIsMatch(metadata ?: @{});
    game[@"WhiteType"] = MBCPlayerTypeForSide(isMatch || SideIncludesWhite(side));
    game[@"BlackType"] = MBCPlayerTypeForSide(isMatch || SideIncludesBlack(side));
    NSString *matchID = MBCMatchIDFromGameDictionary(metadata ?: @{});
    if (matchID) {
        game[@"MatchID"] = matchID;
        game[@"GameCenterMatchID"] = matchID;
    }
    game[@"Position"] = [board fen] ?: @"";
    game[@"Holding"] = [board holding] ?: @"";
    NSString *recordedMoves = board.moves ?: @"";
    if (MBCBoardHasCustomOrigin(board)) {
        game[@"InitialPosition"] = board.initialFen;
        game[@"InitialHolding"] = board.initialHolding;
        if (recordedMoves.length) {
            /* macOS Chess replays Moves only from the standard position.
             * Keep its final-position path playable and carry the history
             * separately for custom starting positions. */
            game[@"Moves"] = @"";
            game[@"IOSMoves"] = recordedMoves;
        } else {
            game[@"Moves"] = @"";
            [game removeObjectForKey:@"IOSMoves"];
        }
    } else {
        game[@"Moves"] = recordedMoves;
        [game removeObjectsForKeys:@[@"IOSMoves", @"InitialPosition", @"InitialHolding"]];
    }
    return [game copy];
}

+ (BOOL)saveBoard:(MBCBoard *)board
          variant:(MBCVariant)variant
             side:(MBCSide)side
       boardStyle:(NSString *)boardStyle
       pieceStyle:(NSString *)pieceStyle
           toURL:(NSURL *)url
           error:(NSError **)error
{
    return [self saveBoard:board variant:variant side:side boardStyle:boardStyle
                 pieceStyle:pieceStyle metadata:nil toURL:url error:error];
}

+ (BOOL)saveBoard:(MBCBoard *)board
          variant:(MBCVariant)variant
             side:(MBCSide)side
       boardStyle:(NSString *)boardStyle
       pieceStyle:(NSString *)pieceStyle
         metadata:(NSDictionary *)metadata
            toURL:(NSURL *)url
            error:(NSError **)error
{
    if (!board || !url || !MBCVariantName(variant)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_invalid_game_save", @"Cannot save an invalid Chess game."));
        return NO;
    }

    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:
                    [self gameDictionaryForBoard:board variant:variant side:side
                                       boardStyle:boardStyle pieceStyle:pieceStyle
                                         metadata:metadata]
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&serializationError]) {
        if (error) *error = serializationError;
        return NO;
    }
    return YES;
}

+ (BOOL)writeBoard:(MBCBoard *)board
           variant:(MBCVariant)variant
              side:(MBCSide)side
        boardStyle:(NSString *)boardStyle
        pieceStyle:(NSString *)pieceStyle
             toURL:(NSURL *)url
             error:(NSError **)error
{
    return [self writeBoard:board variant:variant side:side boardStyle:boardStyle
                  pieceStyle:pieceStyle metadata:nil toURL:url error:error];
}

+ (BOOL)writeBoard:(MBCBoard *)board
           variant:(MBCVariant)variant
              side:(MBCSide)side
        boardStyle:(NSString *)boardStyle
        pieceStyle:(NSString *)pieceStyle
          metadata:(NSDictionary *)metadata
             toURL:(NSURL *)url
             error:(NSError **)error
{
    NSString *extension = url.pathExtension.lowercaseString;
    if (extension.length == 0 || [extension isEqualToString:@"game"]) {
        return [self saveBoard:board variant:variant side:side boardStyle:boardStyle
                     pieceStyle:pieceStyle metadata:metadata toURL:url error:error];
    }
    if (![extension isEqualToString:@"pgn"]) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorUnsupportedFormat,
                                          MBCIOSLocalizedString(@"ios_document_export_extension", @"Chess documents must use .game or .pgn."));
        return NO;
    }

    NSString *pgn = [self PGNForBoard:board variant:variant side:side
                           boardStyle:boardStyle pieceStyle:pieceStyle metadata:metadata error:error];
    NSData *data = [pgn dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    return YES;
}

+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString **)boardStyle
       pieceStyle:(NSString **)pieceStyle
          fromURL:(NSURL *)url
            error:(NSError **)error
{
    return [self loadBoard:board variant:variant side:side boardStyle:boardStyle
                 pieceStyle:pieceStyle metadata:nil fromURL:url error:error];
}

+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString **)boardStyle
       pieceStyle:(NSString **)pieceStyle
         metadata:(NSDictionary **)metadata
          fromURL:(NSURL *)url
            error:(NSError **)error
{
    if (!board || !variant || !side || !url) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_invalid_game_load", @"Cannot load an invalid Chess game request."));
        return NO;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    NSDictionary *game = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                              options:NSPropertyListImmutable
                                                                               format:nil
                                                                                error:&readError] : nil;
    if (![game isKindOfClass:[NSDictionary class]]) {
        if (error) *error = readError ?: MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                                        MBCIOSLocalizedString(@"ios_store_invalid_dictionary", @"The game file is not a property-list dictionary."));
        return NO;
    }
    NSString *variantName = game[@"Variant"];
    NSString *position = game[@"Position"];
    NSString *holding = game[@"Holding"];
    NSString *moves = game[@"Moves"];
    id iosMoves = game[@"IOSMoves"];
    id initialPosition = game[@"InitialPosition"];
    id initialHolding = game[@"InitialHolding"];
    NSNumber *sideValue = game[@"Side"];
    if (!MBCValidString(variantName) || !MBCValidString(position) ||
        !MBCValidString(holding) || !MBCValidString(moves) ||
        (sideValue && ![sideValue isKindOfClass:[NSNumber class]]) ||
        (iosMoves && (!MBCValidString(iosMoves) ||
                      !MBCValidString(initialPosition) || !MBCValidString(initialHolding))) ||
        (initialPosition && !MBCValidString(initialPosition)) ||
        (initialHolding && !MBCValidString(initialHolding))) {
        if (error) *error = readError ?: MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                                        MBCIOSLocalizedString(@"ios_store_missing_fields", @"The game file is missing required fields."));
        return NO;
    }
    if (MBCIOSMatchIDFieldsConflict(game)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_conflicting_match_ids",
                                  @"The game file has conflicting Game Center match IDs."));
        return NO;
    }

    MBCVariant loadedVariant;
    MBCSide loadedSide;
    if (!MBCLoadedSideForGameDictionary(game, &loadedSide)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_missing_players", @"The game file has no side or player-type fields."));
        return NO;
    }
    if (!MBCParseVariant(variantName, &loadedVariant) ||
        loadedSide < kWhiteSide || loadedSide > kNeitherSide) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorUnsupportedVariant,
                                          MBCIOSLocalizedString(@"ios_store_unsupported_variant", @"The game file contains an unsupported variant or side."));
        return NO;
    }

    NSString *safePosition = MBCIOSValidatedFEN(position);
    NSString *safeInitialPosition = initialPosition ? MBCIOSValidatedFEN(initialPosition) : nil;
    NSString *safeMoves = MBCIOSValidatedMoves(moves, loadedVariant);
    NSString *safeIOSMoves = iosMoves ? MBCIOSValidatedMoves(iosMoves, loadedVariant) : nil;
    if (!safePosition || !MBCIOSValidHolding(holding) || !safeMoves ||
        (iosMoves && !safeIOSMoves) ||
        ((initialPosition != nil) != (initialHolding != nil)) ||
        (initialPosition && (!safeInitialPosition || !MBCIOSValidHolding(initialHolding)))) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_invalid_position_history",
                                  @"The game file has an invalid position, holding, or move history."));
        return NO;
    }
    if (!MBCIOSHistoryIsLegal(safeIOSMoves ?: safeMoves, loadedVariant,
                             safeInitialPosition, initialHolding)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_invalid_move_history", @"The game file has an illegal move history."));
        return NO;
    }

    [board startGame:loadedVariant];
    [board setFen:safePosition holding:holding moves:safeIOSMoves ?: safeMoves
      initialFen:safeInitialPosition initialHolding:initialHolding];
    if (safeIOSMoves.length && ![board.moves isEqualToString:safeIOSMoves]) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_pgn_fen_mismatch", @"Game move replay did not produce its declared position."));
        return NO;
    }
    *variant = loadedVariant;
    *side = loadedSide;
    NSString *loadedBoardStyle = MBCValidString(game[@"BoardStyle"]) ? game[@"BoardStyle"] : game[@"MBCBoardStyle"];
    NSString *loadedPieceStyle = MBCValidString(game[@"PieceStyle"]) ? game[@"PieceStyle"] : game[@"MBCPieceStyle"];
    if (boardStyle) *boardStyle = loadedBoardStyle ?: @"Wood";
    if (pieceStyle) *pieceStyle = loadedPieceStyle ?: @"Wood";
    if (metadata) *metadata = MBCIOSMetadataFromGameDictionary(game, loadedSide);
    return YES;
}

+ (BOOL)loadBoard:(MBCBoard *)board
          variant:(MBCVariant *)variant
             side:(MBCSide *)side
       boardStyle:(NSString **)boardStyle
       pieceStyle:(NSString **)pieceStyle
          metadata:(NSDictionary **)metadata
 fromGameDictionary:(NSDictionary *)game
            error:(NSError **)error
{
    if (!board || !variant || !side || ![game isKindOfClass:[NSDictionary class]]) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_invalid_game_load", @"Cannot load an invalid Chess game request."));
        return NO;
    }
    NSString *variantName = game[@"Variant"];
    NSString *position = game[@"Position"];
    NSString *holding = game[@"Holding"];
    NSString *moves = game[@"Moves"];
    id iosMoves = game[@"IOSMoves"];
    id initialPosition = game[@"InitialPosition"];
    id initialHolding = game[@"InitialHolding"];
    NSNumber *sideValue = game[@"Side"];
    if (!MBCValidString(variantName) || !MBCValidString(position) ||
        !MBCValidString(holding) || !MBCValidString(moves) ||
        (sideValue && ![sideValue isKindOfClass:[NSNumber class]]) ||
        (iosMoves && (!MBCValidString(iosMoves) ||
                      !MBCValidString(initialPosition) || !MBCValidString(initialHolding))) ||
        (initialPosition && !MBCValidString(initialPosition)) ||
        (initialHolding && !MBCValidString(initialHolding))) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_missing_fields", @"The game file is missing required fields."));
        return NO;
    }
    if (MBCIOSMatchIDFieldsConflict(game)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_conflicting_match_ids",
                                  @"The game file has conflicting Game Center match IDs."));
        return NO;
    }
    MBCVariant loadedVariant;
    MBCSide loadedSide;
    if (!MBCLoadedSideForGameDictionary(game, &loadedSide)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_missing_players", @"The game file has no side or player-type fields."));
        return NO;
    }
    if (!MBCParseVariant(variantName, &loadedVariant) ||
        loadedSide < kWhiteSide || loadedSide > kNeitherSide) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorUnsupportedVariant,
                                          MBCIOSLocalizedString(@"ios_store_unsupported_variant", @"The game file contains an unsupported variant or side."));
        return NO;
    }

    NSString *safePosition = MBCIOSValidatedFEN(position);
    NSString *safeInitialPosition = initialPosition ? MBCIOSValidatedFEN(initialPosition) : nil;
    NSString *safeMoves = MBCIOSValidatedMoves(moves, loadedVariant);
    NSString *safeIOSMoves = iosMoves ? MBCIOSValidatedMoves(iosMoves, loadedVariant) : nil;
    if (!safePosition || !MBCIOSValidHolding(holding) || !safeMoves ||
        (iosMoves && !safeIOSMoves) ||
        ((initialPosition != nil) != (initialHolding != nil)) ||
        (initialPosition && (!safeInitialPosition || !MBCIOSValidHolding(initialHolding)))) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_invalid_position_history",
                                  @"The game file has an invalid position, holding, or move history."));
        return NO;
    }
    if (!MBCIOSHistoryIsLegal(safeIOSMoves ?: safeMoves, loadedVariant,
                             safeInitialPosition, initialHolding)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
            MBCIOSLocalizedString(@"ios_store_invalid_move_history", @"The game file has an illegal move history."));
        return NO;
    }
    [board startGame:loadedVariant];
    [board setFen:safePosition holding:holding moves:safeIOSMoves ?: safeMoves
      initialFen:safeInitialPosition initialHolding:initialHolding];
    if (safeIOSMoves.length && ![board.moves isEqualToString:safeIOSMoves]) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_pgn_fen_mismatch", @"Game move replay did not produce its declared position."));
        return NO;
    }
    *variant = loadedVariant;
    *side = loadedSide;
    NSString *loadedBoardStyle = MBCValidString(game[@"BoardStyle"])
        ? game[@"BoardStyle"] : game[@"MBCBoardStyle"];
    NSString *loadedPieceStyle = MBCValidString(game[@"PieceStyle"])
        ? game[@"PieceStyle"] : game[@"MBCPieceStyle"];
    if (boardStyle) *boardStyle = loadedBoardStyle ?: @"Wood";
    if (pieceStyle) *pieceStyle = loadedPieceStyle ?: @"Wood";
    if (metadata) *metadata = MBCIOSMetadataFromGameDictionary(game, loadedSide);
    return YES;
}

static NSString *MBCPGNTag(NSString *pgn, NSString *tag)
{
    if (!pgn || !tag) return nil;
    NSString *pattern = [NSString stringWithFormat:@"(?m)^\\[%@\\s+\\\"([^\\\"]*)\\\"\\]", tag];
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                   options:0
                                                                                     error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:pgn options:0
                                                            range:NSMakeRange(0, pgn.length)];
    return match ? [pgn substringWithRange:[match rangeAtIndex:1]] : nil;
}

static NSString *MBCPGNEscapedValue(NSString *value)
{
    return [[value ?: @"" stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

static NSString *MBCSpaceSeparatedMoves(NSString *moves)
{
    NSArray *parts = [moves componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *nonempty = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) [nonempty addObject:part];
    }
    return [nonempty componentsJoinedByString:@" "];
}

static NSDictionary *MBCIOSMetadataForPGN(NSString *pgn)
{
    NSString *site = MBCPGNTag(pgn, @"Site");
    NSString *city = site;
    NSString *country = @"";
    NSRange separator = [site rangeOfString:@", "];
    if (separator.location != NSNotFound) {
        city = [site substringToIndex:separator.location];
        country = [site substringFromIndex:separator.location + separator.length];
    }
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    NSDictionary *tags = @{
        @"City": city ?: @"",
        @"Country": country ?: @""
    };
    NSMutableDictionary *allTags = [tags mutableCopy];
    NSDictionary *standardTags = @{
        @"White": @"White", @"Black": @"Black", @"Event": @"Event",
        @"StartDate": @"Date", @"StartTime": @"Time", @"Result": @"Result"
    };
    [standardTags enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *tag, BOOL *stop) {
        (void)stop;
        NSString *value = MBCPGNTag(pgn, tag);
        if (value) allTags[key] = value;
    }];
    for (NSString *key in MBCIOSMetadataKeys()) {
        NSString *value = allTags[key];
        if ([value isKindOfClass:[NSString class]]) metadata[key] = value;
    }
    return metadata;
}

static NSString *MBCStandardFEN(void)
{
    return @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
}

static NSString *MBCFENWithWhiteTurn(NSString *fen)
{
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 2) return fen;
    NSMutableArray *mutableParts = [parts mutableCopy];
    mutableParts[1] = @"w";
    return [mutableParts componentsJoinedByString:@" "];
}

static MBCMove *MBCCopyMove(MBCMove *move)
{
    MBCMove *copy = [MBCMove moveWithCommand:move->fCommand];
    copy->fFromSquare = move->fFromSquare;
    copy->fToSquare = move->fToSquare;
    copy->fPiece = move->fPiece;
    copy->fPromotion = move->fPromotion;
    copy->fVictim = move->fVictim;
    copy->fCastling = move->fCastling;
    copy->fEnPassant = move->fEnPassant;
    copy->fCheck = move->fCheck;
    copy->fCheckMate = move->fCheckMate;
    copy->fAnimate = NO;
    return copy;
}

static void MBCAppendPromotionCandidates(NSMutableArray *candidates, MBCMove *base,
                                         MBCVariant variant)
{
    if (Piece(base->fPiece) != PAWN || (Row(base->fToSquare) != 1 && Row(base->fToSquare) != 8)) {
        [candidates addObject:base];
        return;
    }
    /* Suicide chess permits promotion to a king. The other variants use the
     * usual four choices; all need rook even though its code follows knight. */
    const MBCPiece promotionTypes[] = {QUEEN, ROOK, BISHOP, KNIGHT, KING};
    NSUInteger count = variant == kVarSuicide ? 5 : 4;
    for (NSUInteger index = 0; index < count; ++index) {
        MBCMove *promotion = MBCCopyMove(base);
        promotion->fPromotion = promotionTypes[index];
        [candidates addObject:promotion];
    }
}

static NSArray *MBCLegalMoveCandidates(MBCBoard *board, MBCVariant variant)
{
    MBCMoveCollector *collector = [[MBCMoveCollector alloc] init];
    BOOL white = (([board numMoves] & 1) == 0);
    MBCMoveGenerator generator(collector, variant, 0);
    generator.Generate(white, *[board curPos]);
    MBCMoveCollection *collection = [collector collection];
    NSMutableArray *candidates = [NSMutableArray array];

    for (int type = KING; type <= PAWN; ++type) {
        MBCPieceMoves &moves = collection->fMoves[type];
        for (int instance = 0; instance < moves.fNumInstances; ++instance) {
            MBCSquare from = moves.fFrom[instance];
            MBCPiece piece = [board curContents:from];
            uint64_t targets = moves.fTo[instance];
            for (int target = 0; target < kBoardSquares; ++target) {
                if (!(targets & (1ULL << target))) continue;
                MBCMove *move = [MBCMove moveWithCommand:kCmdMove];
                move->fFromSquare = from;
                move->fToSquare = (MBCSquare)target;
                move->fPiece = piece;
                MBCAppendPromotionCandidates(candidates, move, variant);
            }
        }
    }

    MBCSquare kingSquare = Square('e', white ? 1 : 8);
    MBCPiece king = [board curContents:kingSquare];
    if (king && collection->fCastleKingside) {
        MBCMove *move = [MBCMove moveWithCommand:kCmdMove];
        move->fFromSquare = kingSquare;
        move->fToSquare = Square('g', white ? 1 : 8);
        move->fPiece = king;
        [candidates addObject:move];
    }
    if (king && collection->fCastleQueenside) {
        MBCMove *move = [MBCMove moveWithCommand:kCmdMove];
        move->fFromSquare = kingSquare;
        move->fToSquare = Square('c', white ? 1 : 8);
        move->fPiece = king;
        [candidates addObject:move];
    }

    if (variant == kVarCrazyhouse) {
        uint64_t targets = collection->fPawnDrops;
        for (int target = 0; target < kBoardSquares; ++target) {
            if (!(targets & (1ULL << target))) continue;
            MBCMove *move = [MBCMove moveWithCommand:kCmdDrop];
            move->fToSquare = (MBCSquare)target;
            move->fPiece = white ? White(PAWN) : Black(PAWN);
            [candidates addObject:move];
        }
        targets = collection->fPieceDrops;
        for (int type = QUEEN; type <= ROOK; ++type) {
            if (!(collection->fDroppablePieces & (1 << type))) continue;
            for (int target = 0; target < kBoardSquares; ++target) {
                if (!(targets & (1ULL << target))) continue;
                MBCMove *move = [MBCMove moveWithCommand:kCmdDrop];
                move->fToSquare = (MBCSquare)target;
                move->fPiece = white ? White((MBCPieceCode)type) : Black((MBCPieceCode)type);
                [candidates addObject:move];
            }
        }
    }
    return candidates;
}

static BOOL MBCIOSBoardSafeForMoveGeneration(MBCBoard *board)
{
    /* MBCMoveCollection reserves 16 source squares per color and piece type.
     * A malformed FEN must not overflow that fixed array during validation. */
    NSUInteger pieceCounts[2][7] = {};
    for (MBCSquare square = Square('a', 1); square <= Square('h', 8); ++square) {
        MBCPiece piece = [board curContents:square];
        if (!piece) continue;
        NSUInteger color = Color(piece) == kBlackPiece ? 1 : 0;
        if (++pieceCounts[color][Piece(piece)] > 16) return NO;
    }
    return YES;
}

static BOOL MBCIOSHistoryIsLegal(NSString *moves, MBCVariant variant,
                                NSString *initialPosition, NSString *initialHolding)
{
    if (!moves.length) return YES;
    MBCBoard *replay = [[MBCBoard alloc] init];
    [replay startGame:variant];
    [replay setFen:initialPosition ?: MBCStandardFEN()
          holding:initialHolding ?: @"[] []" moves:@""];
    for (NSString *part in [moves componentsSeparatedByString:@"\n"]) {
        if (!part.length) continue;
        if (!MBCIOSBoardSafeForMoveGeneration(replay)) return NO;
        MBCMove *selected = nil;
        for (MBCMove *candidate in MBCLegalMoveCandidates(replay, variant)) {
            NSString *engineMove = [[candidate engineMove] stringByTrimmingCharactersInSet:
                                    [NSCharacterSet newlineCharacterSet]];
            if ([engineMove isEqualToString:part]) {
                selected = candidate;
                break;
            }
        }
        if (!selected) return NO;
        [replay makeMove:MBCCopyMove(selected)];
    }
    return MBCIOSBoardSafeForMoveGeneration(replay);
}

static NSString *MBCSANForMove(MBCBoard *board, MBCVariant variant, MBCMove *move)
{
    MBCBoard *clone = [[MBCBoard alloc] init];
    [clone startGame:variant];
    [clone setFen:MBCFENWithWhiteTurn(board.fen) holding:board.holding moves:@""];
    [clone makeMove:MBCCopyMove(move)];

    FILE *file = tmpfile();
    if (!file) return nil;
    BOOL saved = [clone saveMovesTo:file];
    fflush(file);
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    NSMutableData *data = [NSMutableData dataWithLength:length > 0 ? (NSUInteger)length : 0];
    if (length > 0) fread(data.mutableBytes, 1, (size_t)length, file);
    fclose(file);
    if (!saved || data.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *tokens = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *token in tokens) {
        if (token.length && ![token hasSuffix:@"."]) return token;
    }
    return nil;
}

static NSString *MBCNormalizedSAN(NSString *token)
{
    NSString *normalized = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"0-0-0" withString:@"O-O-O"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"0-0" withString:@"O-O"];
    /* NAGs are commonly emitted either as a separate token or attached to
     * the SAN move (for example, e4$1).  The tokenizer drops the former;
     * normalize the latter here so both forms have the same semantics. */
    NSRegularExpression *nag = [NSRegularExpression regularExpressionWithPattern:@"\\$[0-9]+$"
                                                                             options:0 error:nil];
    normalized = [nag stringByReplacingMatchesInString:normalized options:0
                                                  range:NSMakeRange(0, normalized.length)
                                             withTemplate:@""];
    while (normalized.length && ([normalized hasSuffix:@"!"] || [normalized hasSuffix:@"?"] ||
                                 [normalized hasSuffix:@"+"] || [normalized hasSuffix:@"#"])) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }
    if ([normalized hasSuffix:@"e.p."]) {
        normalized = [normalized substringToIndex:normalized.length - 4];
    }
    return normalized;
}

static NSArray *MBCPGNMovetextTokens(NSString *pgn)
{
    NSMutableString *text = [pgn mutableCopy];
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*\\[[^\\n]*\\]\\s*$"
                                                                              options:0 error:nil];
    [tags replaceMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    NSMutableString *clean = [NSMutableString stringWithCapacity:text.length];
    NSInteger braceDepth = 0;
    NSInteger variationDepth = 0;
    BOOL lineComment = NO;
    for (NSUInteger index = 0; index < text.length; ++index) {
        unichar character = [text characterAtIndex:index];
        if (lineComment) {
            if (character == '\n') lineComment = NO;
            continue;
        }
        if (braceDepth) {
            if (character == '}') --braceDepth;
            continue;
        }
        if (character == '{') { braceDepth = 1; continue; }
        if (character == ';') { lineComment = YES; continue; }
        if (character == '(') { ++variationDepth; continue; }
        if (character == ')') { if (variationDepth) --variationDepth; continue; }
        if (!variationDepth) [clean appendFormat:@"%C", character];
    }

    NSMutableArray *tokens = [NSMutableArray array];
    NSRegularExpression *moveNumber = [NSRegularExpression regularExpressionWithPattern:@"^\\d+\\.(?:\\.\\.)?"
                                                                                     options:0 error:nil];
    for (NSString *raw in [clean componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (!raw.length || [raw hasPrefix:@"$"]) continue;
        NSString *token = [moveNumber stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
        if (!token.length || [token isEqualToString:@"..."] || [token isEqualToString:@"*"] ||
            [token isEqualToString:@"1-0"] || [token isEqualToString:@"0-1"] || [token isEqualToString:@"1/2-1/2"] ||
            [[token lowercaseString] isEqualToString:@"e.p."] || [[token lowercaseString] isEqualToString:@"e.p"]) continue;
        [tokens addObject:token];
    }
    return tokens;
}

static BOOL MBCReplaySANMovetext(MBCBoard *board, MBCVariant variant, NSString *pgn, NSError **error)
{
    for (NSString *token in MBCPGNMovetextTokens(pgn)) {
        NSString *wanted = MBCNormalizedSAN(token);
        NSArray *candidates = MBCLegalMoveCandidates(board, variant);
        MBCMove *selected = nil;
        for (MBCMove *candidate in candidates) {
            NSString *generated = MBCSANForMove(board, variant, candidate);
            if ([MBCNormalizedSAN(generated) isEqualToString:wanted]) {
                if (selected) {
                    if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                                       [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_store_pgn_ambiguous", @"PGN move %@ is ambiguous."), token]);
                    return NO;
                }
                selected = candidate;
            }
        }
        if (!selected) {
            if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                               [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_store_pgn_illegal", @"PGN move %@ is illegal or unsupported."), token]);
            return NO;
        }
        [board makeMove:selected];
    }
    return YES;
}

+ (NSString *)PGNForBoard:(MBCBoard *)board
                   variant:(MBCVariant)variant
                      side:(MBCSide)side
                boardStyle:(NSString *)boardStyle
                      pieceStyle:(NSString *)pieceStyle
                             error:(NSError **)error
{
    return [self PGNForBoard:board variant:variant side:side boardStyle:boardStyle
                  pieceStyle:pieceStyle metadata:nil error:error];
}

+ (NSString *)PGNForBoard:(MBCBoard *)board
                   variant:(MBCVariant)variant
                      side:(MBCSide)side
                boardStyle:(NSString *)boardStyle
                pieceStyle:(NSString *)pieceStyle
                  metadata:(NSDictionary *)metadata
                     error:(NSError **)error
{
    if (!board || !MBCVariantName(variant)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_invalid_export", @"Cannot export an invalid Chess game."));
        return nil;
    }

    NSURL *directory = [self applicationSupportDirectoryWithError:error];
    NSURL *temporaryURL = [directory URLByAppendingPathComponent:
                           [NSString stringWithFormat:@"PGN-%@.tmp", NSUUID.UUID.UUIDString]];
    FILE *file = fopen(temporaryURL.fileSystemRepresentation, "w");
    if (!file) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidGame,
                                          MBCIOSLocalizedString(@"ios_store_export_open", @"The sandbox export file could not be opened."));
        return nil;
    }
    BOOL saved = [board saveMovesTo:file];
    fclose(file);
    NSString *movesText = saved ? [NSString stringWithContentsOfURL:temporaryURL
                                                            encoding:NSUTF8StringEncoding
                                                               error:error] : nil;
    [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
    if (!movesText) return nil;

    NSString *engineMoves = MBCSpaceSeparatedMoves(board.moves);
    NSString *escapedPosition = MBCPGNEscapedValue(board.initialFen);
    NSString *escapedHolding = MBCPGNEscapedValue(board.initialHolding);
    NSString *escapedFinalPosition = MBCPGNEscapedValue(board.fen);
    NSString *escapedFinalHolding = MBCPGNEscapedValue(board.holding);
    NSString *escapedMoves = MBCPGNEscapedValue(engineMoves);
    NSString *setupTag = MBCBoardHasCustomOrigin(board) ? @"[SetUp \"1\"]\n" : @"";
    NSString *event = MBCIOSMetadataString(metadata, @"Event", @"Apple Chess");
    NSString *city = MBCIOSMetadataString(metadata, @"City", @"?");
    NSString *country = MBCIOSMetadataString(metadata, @"Country", @"?");
    NSString *site = [NSString stringWithFormat:@"%@, %@", city, country];
    NSString *date = MBCIOSMetadataString(metadata, @"StartDate", MBCIOSDateString(@"yyyy.MM.dd"));
    NSString *time = MBCIOSMetadataString(metadata, @"StartTime", MBCIOSDateString(@"HH:mm:ss"));
    NSString *white = MBCIOSMetadataString(metadata, @"White",
                                            SideIncludesWhite(side) ? @"Human" : @"Computer");
    NSString *black = MBCIOSMetadataString(metadata, @"Black",
                                            SideIncludesBlack(side) ? @"Human" : @"Computer");
    NSString *result = MBCIOSMetadataString(metadata, @"Result", @"*");
    if (![@[@"*", @"1-0", @"0-1", @"1/2-1/2"] containsObject:result]) result = @"*";
    NSString *movetext = [movesText stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [NSString stringWithFormat:
            @"[Event \"%@\"]\n"
             "[Site \"%@\"]\n"
             "[Date \"%@\"]\n"
             "[Round \"-\"]\n"
             "[White \"%@\"]\n"
             "[Black \"%@\"]\n"
             "[Result \"%@\"]\n"
             "[Time \"%@\"]\n"
             "%@"
             "[Variant \"%@\"]\n"
             "[FEN \"%@\"]\n"
             "[Holding \"%@\"]\n"
             "[MBCInitialPosition \"%@\"]\n"
             "[MBCInitialHolding \"%@\"]\n"
             "[MBCFinalFEN \"%@\"]\n"
             "[MBCFinalHolding \"%@\"]\n"
             "[MBCSide \"%ld\"]\n"
             "[MBCBoardStyle \"%@\"]\n"
             "[MBCPieceStyle \"%@\"]\n"
             "[MBCMoves \"%@\"]\n\n%@ %@\n",
            MBCPGNEscapedValue(event), MBCPGNEscapedValue(site), MBCPGNEscapedValue(date),
            MBCPGNEscapedValue(white), MBCPGNEscapedValue(black), MBCPGNEscapedValue(result),
            MBCPGNEscapedValue(time), setupTag, MBCVariantName(variant), escapedPosition, escapedHolding,
            escapedPosition, escapedHolding, escapedFinalPosition, escapedFinalHolding, (long)side,
            boardStyle ?: @"Wood", pieceStyle ?: @"Wood", escapedMoves, movetext, result];
}

+ (BOOL)importPGN:(NSString *)pgn
         intoBoard:(MBCBoard *)board
           variant:(MBCVariant *)variant
              side:(MBCSide *)side
        boardStyle:(NSString **)boardStyle
        pieceStyle:(NSString **)pieceStyle
             error:(NSError **)error
{
    return [self importPGN:pgn intoBoard:board variant:variant side:side
                boardStyle:boardStyle pieceStyle:pieceStyle metadata:nil error:error];
}

+ (BOOL)importPGN:(NSString *)pgn
         intoBoard:(MBCBoard *)board
           variant:(MBCVariant *)variant
              side:(MBCSide *)side
        boardStyle:(NSString **)boardStyle
        pieceStyle:(NSString **)pieceStyle
          metadata:(NSDictionary **)metadata
             error:(NSError **)error
{
    if (!pgn || !board || !variant || !side) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                          MBCIOSLocalizedString(@"ios_store_pgn_import_incomplete", @"The PGN import request is incomplete."));
        return NO;
    }

    MBCVariant loadedVariant = kVarNormal;
    NSString *variantName = MBCPGNTag(pgn, @"Variant");
    if (variantName.length && !MBCParseVariant(variantName, &loadedVariant)) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorUnsupportedVariant,
                                          MBCIOSLocalizedString(@"ios_store_pgn_variant_unsupported", @"The PGN variant is not supported by Chess."));
        return NO;
    }
    NSString *sideText = MBCPGNTag(pgn, @"MBCSide");
    NSInteger sideValue = sideText.integerValue;
    if (sideText.length == 0) sideValue = kBothSides;
    if (sideValue < kWhiteSide || sideValue > kNeitherSide) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                          MBCIOSLocalizedString(@"ios_store_pgn_invalid_side", @"The PGN contains an invalid side value."));
        return NO;
    }

    NSString *fenTag = MBCPGNTag(pgn, @"FEN");
    NSString *positionTag = MBCPGNTag(pgn, @"Position");
    NSString *holdingTag = MBCPGNTag(pgn, @"Holding");
    NSString *initialPositionTag = MBCPGNTag(pgn, @"MBCInitialPosition");
    NSString *initialHolding = MBCPGNTag(pgn, @"MBCInitialHolding");
    NSString *finalPositionTag = MBCPGNTag(pgn, @"MBCFinalFEN");
    NSString *finalHolding = MBCPGNTag(pgn, @"MBCFinalHolding");
    NSString *safeFEN = fenTag ? MBCIOSValidatedFEN(fenTag) : nil;
    NSString *safePositionTag = positionTag ? MBCIOSValidatedFEN(positionTag) : nil;
    NSString *position = fenTag ? safeFEN : safePositionTag;
    NSString *holding = holdingTag ?: @"[] []";
    NSString *initialPosition = initialPositionTag ? MBCIOSValidatedFEN(initialPositionTag) : nil;
    NSString *finalPosition = finalPositionTag ? MBCIOSValidatedFEN(finalPositionTag) : nil;
    NSString *engineMoves = MBCPGNTag(pgn, @"MBCMoves");
    NSString *moves = engineMoves ? MBCIOSValidatedMoves(
        [engineMoves stringByReplacingOccurrencesOfString:@" " withString:@"\n"],
        loadedVariant) : nil;

    if ((fenTag && !safeFEN) ||
        (positionTag && !safePositionTag) ||
        (initialPositionTag && !initialPosition) ||
        (finalPositionTag && !finalPosition) ||
        !MBCIOSValidHolding(holding) ||
        (initialHolding && !MBCIOSValidHolding(initialHolding)) ||
        (finalHolding && !MBCIOSValidHolding(finalHolding)) ||
        (engineMoves && !moves) ||
        ((initialPositionTag != nil) != (initialHolding != nil))) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
            MBCIOSLocalizedString(@"ios_store_invalid_pgn_position_history",
                                  @"The PGN has an invalid position, holding, or move history."));
        return NO;
    }

    if (moves.length && !MBCIOSHistoryIsLegal(moves, loadedVariant,
        initialPosition.length ? initialPosition : (finalPosition.length ? position : nil),
        initialHolding.length ? initialHolding : (finalPosition.length ? holding : nil))) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
            MBCIOSLocalizedString(@"ios_store_invalid_pgn_move_history", @"The PGN has an illegal move history."));
        return NO;
    }

    [board startGame:loadedVariant];
    if (moves.length) {
        /* New exports use FEN/Holding as the starting position and
         * MBCFinalFEN/MBCFinalHolding as the final state. Older iOS PGN files
         * used FEN/Holding for the final state; absent final tags preserve
         * that interpretation. */
        NSString *expectedPosition = finalPosition.length ? finalPosition : position;
        NSString *expectedHolding = finalHolding.length ? finalHolding : holding;
        NSString *origin = initialPosition.length ? initialPosition
            : (finalPosition.length ? position : nil);
        NSString *originHolding = initialHolding.length ? initialHolding
            : (finalPosition.length ? holding : nil);
        [board setFen:expectedPosition ?: MBCStandardFEN()
              holding:expectedHolding moves:moves
           initialFen:origin initialHolding:originHolding];
        if (finalPosition.length && ![MBCSpaceSeparatedMoves(board.moves) isEqualToString:engineMoves]) {
            if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                              MBCIOSLocalizedString(@"ios_store_pgn_fen_mismatch", @"PGN move replay did not produce its declared FEN."));
            return NO;
        }
    } else {
        /* Standard PGN uses SAN movetext.  Seed from its FEN when present,
         * otherwise use the normal initial position, then resolve each SAN
         * token against the shared legal-move generator. */
        [board setFen:position.length ? position : MBCStandardFEN()
                holding:holding moves:@""];
        if (!MBCReplaySANMovetext(board, loadedVariant, pgn, error)) return NO;
    }

    NSString *declaredFinal = finalPosition.length ? finalPosition : position;
    NSString *declaredHolding = finalHolding.length ? finalHolding : holding;
    if (moves.length && declaredFinal.length &&
        (![declaredFinal isEqualToString:board.fen] ||
         ![declaredHolding isEqualToString:board.holding])) {
        if (error) *error = MBCStoreError(MBCIOSGameStoreErrorInvalidPGN,
                                          MBCIOSLocalizedString(@"ios_store_pgn_fen_mismatch", @"PGN move replay did not produce its declared FEN."));
        return NO;
    }
    *variant = loadedVariant;
    *side = (MBCSide)sideValue;
    if (boardStyle) *boardStyle = MBCPGNTag(pgn, @"MBCBoardStyle") ?: @"Wood";
    if (pieceStyle) *pieceStyle = MBCPGNTag(pgn, @"MBCPieceStyle") ?: @"Wood";
    if (metadata) *metadata = MBCIOSMetadataForPGN(pgn);
    return YES;
}

+ (NSURL *)openingBookURLForVariant:(MBCVariant)variant error:(NSError **)error
{
    NSString *fileName = nil;
    switch (variant) {
        case kVarNormal: fileName = @"normal.opn"; break;
        case kVarCrazyhouse: fileName = @"zhbook.pgn"; break;
        case kVarSuicide: fileName = @"suicide.opn"; break;
        case kVarLosers: fileName = @"losers.opn"; break;
    }
    NSURL *url = [[NSBundle mainBundle] URLForResource:[fileName stringByDeletingPathExtension]
                                         withExtension:[fileName pathExtension]
                                          subdirectory:@"Opening Books"];
    // Xcode folder references preserve the source folder's final component in
    // the bundle.  The project currently copies sjeng/books as "books"; keep
    // the semantic resource name above while accepting that on-device layout.
    if (!url) {
        url = [[NSBundle mainBundle] URLForResource:[fileName stringByDeletingPathExtension]
                                     withExtension:[fileName pathExtension]
                                      subdirectory:@"books"];
    }
    if (!url && error) {
        *error = MBCStoreError(MBCIOSGameStoreErrorMissingResource,
                               [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_store_opening_book_missing", @"Opening book %@ is not bundled."), fileName]);
    }
    return url;
}

@end
