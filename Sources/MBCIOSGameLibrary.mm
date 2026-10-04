/* Atomic named-game snapshots and a small recent-games index for iOS Chess. */

#import "MBCIOSGameLibrary.h"
#import "MBCIOSLocalization.h"

NSString * const MBCIOSGameLibraryErrorDomain = @"com.apple.Chess.iOSGameLibrary";
NSString * const MBCIOSGameLibraryConflictingIdentifierKey = @"ConflictingIdentifier";

static NSString * const MBCLibraryIndexName = @"LibraryIndex.plist";
static NSString * const MBCLibraryGamesName = @"Games";
static NSString * const MBCLegacyRecordIdentifier = @"00000000-0000-0000-0000-000000000001";

static NSError *MBCLibraryError(MBCIOSGameLibraryErrorCode code, NSString *description,
                                NSError *underlying, NSString *conflictingIdentifier)
{
    NSMutableDictionary *details = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (underlying) details[NSUnderlyingErrorKey] = underlying;
    if (conflictingIdentifier) {
        details[MBCIOSGameLibraryConflictingIdentifierKey] = conflictingIdentifier;
    }
    return [NSError errorWithDomain:MBCIOSGameLibraryErrorDomain code:code userInfo:details];
}

static NSString *MBCNormalizedGameName(id name)
{
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 && trimmed.length <= 120 ? trimmed : nil;
}

static NSString *MBCMetadataMatchID(NSDictionary *metadata, NSError **error)
{
    id canonical = metadata[@"MatchID"];
    id legacy = metadata[@"GameCenterMatchID"];
    if ((canonical && ![canonical isKindOfClass:[NSString class]]) ||
        (legacy && ![legacy isKindOfClass:[NSString class]])) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"Game Center match IDs must be strings.", nil, nil);
        return nil;
    }
    NSString *matchID = [canonical length] ? canonical : legacy;
    if ([canonical length] && [legacy length] && ![canonical isEqualToString:legacy]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"The two Game Center match IDs disagree.", nil, nil);
        return nil;
    }
    if (matchID && ![matchID stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"The Game Center match ID is empty.", nil, nil);
        return nil;
    }
    return matchID.length ? matchID : nil;
}

static BOOL MBCValidLibraryRow(NSDictionary *row)
{
    if (![row isKindOfClass:[NSDictionary class]]) return NO;
    NSString *identifier = row[@"Identifier"];
    NSString *fileName = row[@"FileName"];
    NSNumber *revision = row[@"Revision"];
    NSString *name = row[@"Name"];
    if (![identifier isKindOfClass:[NSString class]] ||
        ![[NSUUID alloc] initWithUUIDString:identifier] ||
        ![fileName isKindOfClass:[NSString class]] ||
        ![fileName hasPrefix:[identifier stringByAppendingString:@"-"]] ||
        ![fileName hasSuffix:@".game"] ||
        ![fileName.lastPathComponent isEqualToString:fileName] ||
        ![revision isKindOfClass:[NSNumber class]] || revision.integerValue < 1 ||
        ![name isKindOfClass:[NSString class]] || !MBCNormalizedGameName(name) ||
        ![row[@"CreatedAt"] isKindOfClass:[NSDate class]] ||
        ![row[@"ModifiedAt"] isKindOfClass:[NSDate class]]) return NO;
    NSString *generation = [fileName substringWithRange:
                            NSMakeRange(identifier.length + 1,
                                        fileName.length - identifier.length - 1 - @".game".length)];
    if (![[NSUUID alloc] initWithUUIDString:generation]) return NO;
    if (row[@"OpenedAt"] && ![row[@"OpenedAt"] isKindOfClass:[NSDate class]]) return NO;
    if (row[@"Recent"] && ![row[@"Recent"] isKindOfClass:[NSNumber class]]) return NO;
    if (row[@"MatchID"] && (![row[@"MatchID"] isKindOfClass:[NSString class]] ||
                             ![row[@"MatchID"] length])) return NO;
    return YES;
}

@interface MBCIOSGameRecord ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite, nullable) NSString *matchID;
@property (nonatomic, readwrite) NSUInteger revision;
@property (nonatomic, copy, readwrite) NSDate *createdAt;
@property (nonatomic, copy, readwrite) NSDate *modifiedAt;
@property (nonatomic, copy, readwrite, nullable) NSDate *openedAt;
@property (nonatomic, copy, readwrite) NSURL *fileURL;
@end

@implementation MBCIOSGameRecord
@end

@interface MBCIOSGameLibrary ()
@property (nonatomic, copy) NSURL *directoryURL;
@property (nonatomic, copy) NSURL *gamesURL;
@property (nonatomic, copy) NSURL *indexURL;
@end

@implementation MBCIOSGameLibrary

+ (instancetype)sharedLibrary
{
    return [self sharedLibraryWithError:nil];
}

+ (instancetype)sharedLibraryWithError:(NSError **)error
{
    static MBCIOSGameLibrary *library;
    @synchronized(self) {
        if (!library) {
            NSURL *directory = [MBCIOSGameStore applicationSupportDirectoryWithError:error];
            if (!directory) return nil;
            library = [[self alloc] initWithDirectoryURL:directory];
        }
        return library;
    }
}

- (instancetype)initWithDirectoryURL:(NSURL *)directoryURL
{
    NSParameterAssert(directoryURL.isFileURL);
    self = [super init];
    if (self) {
        _directoryURL = [directoryURL copy];
        _gamesURL = [_directoryURL URLByAppendingPathComponent:MBCLibraryGamesName isDirectory:YES];
        _indexURL = [_directoryURL URLByAppendingPathComponent:MBCLibraryIndexName];
    }
    return self;
}

- (BOOL)ensureDirectoriesWithError:(NSError **)error
{
    return [[NSFileManager defaultManager] createDirectoryAtURL:self.gamesURL
                                     withIntermediateDirectories:YES
                                                      attributes:nil error:error];
}

- (NSMutableDictionary *)readIndexWithError:(NSError **)error
{
    if (![self ensureDirectoriesWithError:error]) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.indexURL.path]) {
        return [@{@"Version": @1, @"Records": @[], @"LegacyMigrated": @NO} mutableCopy];
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:self.indexURL options:0 error:&readError];
    NSDictionary *index = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                             options:NSPropertyListImmutable
                                                                              format:nil error:&readError] : nil;
    if (![index isKindOfClass:[NSDictionary class]] ||
        ![index[@"Version"] isKindOfClass:[NSNumber class]] ||
        [index[@"Version"] integerValue] != 1 ||
        ![index[@"Records"] isKindOfClass:[NSArray class]] ||
        (index[@"LegacyMigrated"] && ![index[@"LegacyMigrated"] isKindOfClass:[NSNumber class]]) ||
        (index[@"LastOpenedIdentifier"] &&
         ![index[@"LastOpenedIdentifier"] isKindOfClass:[NSString class]])) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptIndex,
                                            @"The Chess game library index is damaged.",
                                            readError, nil);
        return nil;
    }
    NSMutableSet *identifiers = [NSMutableSet set];
    NSMutableSet *matchIDs = [NSMutableSet set];
    for (id row in index[@"Records"]) {
        if (!MBCValidLibraryRow(row) || [identifiers containsObject:row[@"Identifier"]] ||
            (row[@"MatchID"] && [matchIDs containsObject:row[@"MatchID"]])) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptIndex,
                                                @"The Chess game library has invalid or duplicate entries.",
                                                nil, nil);
            return nil;
        }
        [identifiers addObject:row[@"Identifier"]];
        if (row[@"MatchID"]) [matchIDs addObject:row[@"MatchID"]];
    }
    NSString *last = index[@"LastOpenedIdentifier"];
    if (last && ![identifiers containsObject:last]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptIndex,
                                            @"The Chess library's last-opened game is missing from its index.",
                                            nil, nil);
        return nil;
    }
    return [index mutableCopy];
}

- (BOOL)writeIndex:(NSDictionary *)index error:(NSError **)error
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:index
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:error];
    return data && [data writeToURL:self.indexURL options:NSDataWritingAtomic error:error];
}

- (NSURL *)URLForRow:(NSDictionary *)row
{
    return [self.gamesURL URLByAppendingPathComponent:row[@"FileName"]];
}

- (MBCIOSGameRecord *)recordForRow:(NSDictionary *)row
{
    MBCIOSGameRecord *record = [[MBCIOSGameRecord alloc] init];
    record.identifier = row[@"Identifier"];
    record.name = row[@"Name"];
    record.matchID = row[@"MatchID"];
    record.revision = [row[@"Revision"] unsignedIntegerValue];
    record.createdAt = row[@"CreatedAt"];
    record.modifiedAt = row[@"ModifiedAt"];
    record.openedAt = row[@"OpenedAt"];
    record.fileURL = [self URLForRow:row];
    return record;
}

- (NSDictionary *)rowForIdentifier:(NSString *)identifier inIndex:(NSDictionary *)index
{
    for (NSDictionary *row in index[@"Records"]) {
        if ([row[@"Identifier"] isEqualToString:identifier]) return row;
    }
    return nil;
}

- (NSDictionary *)currentRowForRecord:(MBCIOSGameRecord *)record
                              inIndex:(NSDictionary *)index error:(NSError **)error
{
    if (![record isKindOfClass:[MBCIOSGameRecord class]]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"A Chess library record is required.", nil, nil);
        return nil;
    }
    NSDictionary *row = [self rowForIdentifier:record.identifier inIndex:index];
    if (!row) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorNotFound,
                                            @"The Chess game is no longer in the library.", nil, nil);
        return nil;
    }
    if (record.revision != [row[@"Revision"] unsignedIntegerValue] ||
        ![record.fileURL isEqual:[self URLForRow:row]]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                            @"This game changed elsewhere. Reopen it before saving.",
                                            nil, record.identifier);
        return nil;
    }
    return row;
}

- (NSString *)newFileNameForIdentifier:(NSString *)identifier
{
    return [NSString stringWithFormat:@"%@-%@.game", identifier, NSUUID.UUID.UUIDString];
}

- (BOOL)validateBoard:(MBCBoard *)board variant:(MBCVariant)variant
                  side:(MBCSide)side error:(NSError **)error
{
    if (!board || variant < kVarNormal || variant > kVarLosers ||
        side < kWhiteSide || side > kNeitherSide) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"The Chess game settings are invalid.", nil, nil);
        return NO;
    }
    return YES;
}

- (NSArray<MBCIOSGameRecord *> *)recentGamesWithError:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSMutableSet *recentIdentifiers = [NSMutableSet set];
        for (NSDictionary *row in index[@"Records"])
            if (!row[@"Recent"] || [row[@"Recent"] boolValue])
                [recentIdentifiers addObject:row[@"Identifier"]];
        NSArray *all = [self allGamesWithError:error];
        if (!all) return nil;
        return [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(MBCIOSGameRecord *record, NSDictionary *bindings) {
                (void)bindings;
                return [recentIdentifiers containsObject:record.identifier];
            }]];
    }
}

- (NSArray<MBCIOSGameRecord *> *)allGamesWithError:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSMutableArray<MBCIOSGameRecord *> *records = [NSMutableArray array];
        for (NSDictionary *row in index[@"Records"]) [records addObject:[self recordForRow:row]];
        [records sortUsingComparator:^NSComparisonResult(MBCIOSGameRecord *left,
                                                         MBCIOSGameRecord *right) {
            NSDate *leftDate = left.openedAt &&
                [left.openedAt compare:left.modifiedAt] == NSOrderedDescending
                ? left.openedAt : left.modifiedAt;
            NSDate *rightDate = right.openedAt &&
                [right.openedAt compare:right.modifiedAt] == NSOrderedDescending
                ? right.openedAt : right.modifiedAt;
            NSComparisonResult order = [rightDate compare:leftDate];
            if (order == NSOrderedSame) order = [right.modifiedAt compare:left.modifiedAt];
            return order == NSOrderedSame ? [left.identifier compare:right.identifier] : order;
        }];
        return [records copy];
    }
}

- (BOOL)clearRecentGamesWithError:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return NO;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *row in index[@"Records"]) {
            NSMutableDictionary *updated = [row mutableCopy];
            updated[@"Recent"] = @NO;
            [rows addObject:updated];
        }
        index[@"Records"] = rows;
        return [self writeIndex:index error:error];
    }
}

- (BOOL)deleteGame:(MBCIOSGameRecord *)record
 excludingIdentifiers:(NSSet<NSString *> *)openIdentifiers error:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return NO;
        NSDictionary *current = [self currentRowForRecord:record inIndex:index error:error];
        if (!current) return NO;
        if (![openIdentifiers isKindOfClass:[NSSet class]] ||
            [openIdentifiers containsObject:record.identifier]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                MBCIOSLocalizedString(@"ios_close_game_before_delete", @"Close this game before deleting it."),
                nil, record.identifier);
            return NO;
        }
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        [rows removeObject:current];
        index[@"Records"] = rows;
        if ([index[@"LastOpenedIdentifier"] isEqual:record.identifier])
            [index removeObjectForKey:@"LastOpenedIdentifier"];
        // Commit the index first so a failed write never removes a saved game.
        if (![self writeIndex:index error:error]) return NO;
        [[NSFileManager defaultManager] removeItemAtURL:[self URLForRow:current] error:nil];
        return YES;
    }
}

- (MBCIOSGameRecord *)lastOpenedGameWithError:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSDictionary *row = [self rowForIdentifier:index[@"LastOpenedIdentifier"] inIndex:index];
        return row ? [self recordForRow:row] : nil;
    }
}

- (MBCIOSGameRecord *)recordForMatchID:(NSString *)matchID error:(NSError **)error
{
    if (![matchID isKindOfClass:[NSString class]] || !matchID.length) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"A Game Center match ID is required.", nil, nil);
        return nil;
    }
    @synchronized([MBCIOSGameLibrary class]) {
        NSDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        for (NSDictionary *row in index[@"Records"]) {
            if ([row[@"MatchID"] isEqualToString:matchID]) return [self recordForRow:row];
        }
        return nil;
    }
}

- (MBCIOSGameRecord *)createGameNamed:(NSString *)name board:(MBCBoard *)board
                               variant:(MBCVariant)variant side:(MBCSide)side
                            boardStyle:(NSString *)boardStyle pieceStyle:(NSString *)pieceStyle
                              metadata:(NSDictionary *)metadata error:(NSError **)error
{
    NSString *normalizedName = MBCNormalizedGameName(name);
    if (!normalizedName) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidName,
                                            @"Enter a game name of 1 to 120 characters.", nil, nil);
        return nil;
    }
    if (![self validateBoard:board variant:variant side:side error:error]) return nil;
    if (metadata && ![metadata isKindOfClass:[NSDictionary class]]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"Game metadata must be a dictionary.", nil, nil);
        return nil;
    }
    NSError *matchError = nil;
    NSString *matchID = MBCMetadataMatchID(metadata ?: @{}, &matchError);
    if (matchError) {
        if (error) *error = matchError;
        return nil;
    }
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        for (NSDictionary *row in index[@"Records"]) {
            if (matchID && [row[@"MatchID"] isEqualToString:matchID]) {
                if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                                    @"This Game Center match is already in the library.",
                                                    nil, row[@"Identifier"]);
                return nil;
            }
        }
        NSString *identifier = NSUUID.UUID.UUIDString;
        NSString *fileName = [self newFileNameForIdentifier:identifier];
        NSURL *fileURL = [self.gamesURL URLByAppendingPathComponent:fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                                @"The new game file already exists.", nil, identifier);
            return nil;
        }
        if (![MBCIOSGameStore saveBoard:board variant:variant side:side
                             boardStyle:boardStyle pieceStyle:pieceStyle
                               metadata:metadata toURL:fileURL error:error]) return nil;

        NSDate *now = [NSDate date];
        NSMutableDictionary *row = [@{@"Identifier": identifier, @"Name": normalizedName,
                                      @"Revision": @1, @"CreatedAt": now,
                                      @"ModifiedAt": now, @"OpenedAt": now,
                                      @"FileName": fileName} mutableCopy];
        if (matchID) row[@"MatchID"] = matchID;
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        [rows addObject:row];
        index[@"Records"] = rows;
        index[@"LastOpenedIdentifier"] = identifier;
        if (![self writeIndex:index error:error]) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            return nil;
        }
        return [self recordForRow:row];
    }
}

- (MBCIOSGameRecord *)saveGame:(MBCIOSGameRecord *)record board:(MBCBoard *)board
                        variant:(MBCVariant)variant side:(MBCSide)side
                     boardStyle:(NSString *)boardStyle pieceStyle:(NSString *)pieceStyle
                       metadata:(NSDictionary *)metadata error:(NSError **)error
{
    if (![self validateBoard:board variant:variant side:side error:error]) return nil;
    if (metadata && ![metadata isKindOfClass:[NSDictionary class]]) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"Game metadata must be a dictionary.", nil, nil);
        return nil;
    }
    NSError *matchError = nil;
    NSString *incomingMatchID = MBCMetadataMatchID(metadata ?: @{}, &matchError);
    if (matchError) {
        if (error) *error = matchError;
        return nil;
    }
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSDictionary *current = [self currentRowForRecord:record inIndex:index error:error];
        if (!current) return nil;
        NSString *storedMatchID = current[@"MatchID"];
        if ((incomingMatchID && ![incomingMatchID isEqualToString:storedMatchID]) ||
            (!storedMatchID && incomingMatchID)) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                                @"A saved game's Game Center match cannot be changed.",
                                                nil, record.identifier);
            return nil;
        }
        NSError *readError = nil;
        NSData *oldData = [NSData dataWithContentsOfURL:[self URLForRow:current]
                                               options:0 error:&readError];
        NSDictionary *oldGame = oldData ? [NSPropertyListSerialization propertyListWithData:oldData
                                                                                     options:NSPropertyListImmutable
                                                                                      format:nil error:&readError] : nil;
        if (![oldGame isKindOfClass:[NSDictionary class]]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptGame,
                                                @"The saved Chess game cannot be read.", readError, nil);
            return nil;
        }
        NSMutableDictionary *effectiveMetadata = [oldGame mutableCopy];
        if (metadata) [effectiveMetadata addEntriesFromDictionary:metadata];
        if (storedMatchID) {
            effectiveMetadata[@"MatchID"] = storedMatchID;
            effectiveMetadata[@"GameCenterMatchID"] = storedMatchID;
        } else {
            [effectiveMetadata removeObjectsForKeys:@[@"MatchID", @"GameCenterMatchID",
                                                      @"WhitePlayerID", @"BlackPlayerID"]];
        }

        NSString *fileName = [self newFileNameForIdentifier:record.identifier];
        NSURL *newURL = [self.gamesURL URLByAppendingPathComponent:fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:newURL.path]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                                @"The next game file already exists.", nil,
                                                record.identifier);
            return nil;
        }
        if (![MBCIOSGameStore saveBoard:board variant:variant side:side
                             boardStyle:boardStyle pieceStyle:pieceStyle
                               metadata:effectiveMetadata toURL:newURL error:error]) return nil;
        NSMutableDictionary *updated = [current mutableCopy];
        updated[@"Revision"] = @([current[@"Revision"] unsignedIntegerValue] + 1);
        updated[@"ModifiedAt"] = [NSDate date];
        updated[@"FileName"] = fileName;
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        NSUInteger position = [rows indexOfObject:current];
        rows[position] = updated;
        index[@"Records"] = rows;
        if (![self writeIndex:index error:error]) {
            [[NSFileManager defaultManager] removeItemAtURL:newURL error:nil];
            return nil;
        }
        [[NSFileManager defaultManager] removeItemAtURL:[self URLForRow:current] error:nil];
        return [self recordForRow:updated];
    }
}

- (MBCIOSGameRecord *)duplicateGame:(MBCIOSGameRecord *)record
                              asName:(NSString *)name error:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSDictionary *current = [self currentRowForRecord:record inIndex:index error:error];
        if (!current) return nil;
        MBCBoard *board = [[MBCBoard alloc] init];
        MBCVariant variant;
        MBCSide side;
        NSString *boardStyle = nil;
        NSString *pieceStyle = nil;
        NSDictionary *metadata = nil;
        if (![MBCIOSGameStore loadBoard:board variant:&variant side:&side
                            boardStyle:&boardStyle pieceStyle:&pieceStyle
                              metadata:&metadata fromURL:[self URLForRow:current] error:error]) return nil;
        NSMutableDictionary *copyMetadata = [metadata mutableCopy];
        [copyMetadata removeObjectsForKeys:@[@"MatchID", @"GameCenterMatchID",
                                            @"WhitePlayerID", @"BlackPlayerID"]];
        if (current[@"MatchID"]) {
            side = kBothSides;
            [copyMetadata removeObjectForKey:@"IOSPlayers"];
        }
        return [self createGameNamed:name board:board variant:variant side:side
                         boardStyle:boardStyle pieceStyle:pieceStyle
                           metadata:copyMetadata error:error];
    }
}

- (MBCIOSGameRecord *)renameGame:(MBCIOSGameRecord *)record
                           toName:(NSString *)name error:(NSError **)error
{
    NSString *normalizedName = MBCNormalizedGameName(name);
    if (!normalizedName) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidName,
                                            @"Enter a game name of 1 to 120 characters.", nil, nil);
        return nil;
    }
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSDictionary *current = [self currentRowForRecord:record inIndex:index error:error];
        if (!current) return nil;
        if ([current[@"Name"] isEqualToString:normalizedName]) return [self recordForRow:current];
        NSMutableDictionary *updated = [current mutableCopy];
        updated[@"Name"] = normalizedName;
        updated[@"Revision"] = @([current[@"Revision"] unsignedIntegerValue] + 1);
        updated[@"ModifiedAt"] = [NSDate date];
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        rows[[rows indexOfObject:current]] = updated;
        index[@"Records"] = rows;
        if (![self writeIndex:index error:error]) return nil;
        return [self recordForRow:updated];
    }
}

- (MBCIOSGameRecord *)openGameWithIdentifier:(NSString *)identifier
                                      board:(MBCBoard **)board variant:(MBCVariant *)variant
                                       side:(MBCSide *)side boardStyle:(NSString **)boardStyle
                                 pieceStyle:(NSString **)pieceStyle metadata:(NSDictionary **)metadata
                                      error:(NSError **)error
{
    if (![identifier isKindOfClass:[NSString class]] || !identifier.length ||
        !board || !variant || !side) {
        if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorInvalidRequest,
                                            @"A game identifier and output board are required.", nil, nil);
        return nil;
    }
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return nil;
        NSDictionary *current = [self rowForIdentifier:identifier inIndex:index];
        if (!current) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorNotFound,
                                                @"The Chess game is no longer in the library.", nil, nil);
            return nil;
        }
        MBCBoard *loadedBoard = [[MBCBoard alloc] init];
        MBCVariant loadedVariant;
        MBCSide loadedSide;
        NSString *loadedBoardStyle = nil;
        NSString *loadedPieceStyle = nil;
        NSDictionary *loadedMetadata = nil;
        NSError *loadError = nil;
        if (![MBCIOSGameStore loadBoard:loadedBoard variant:&loadedVariant side:&loadedSide
                            boardStyle:&loadedBoardStyle pieceStyle:&loadedPieceStyle
                              metadata:&loadedMetadata fromURL:[self URLForRow:current]
                                 error:&loadError]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptGame,
                                                @"The Chess game could not be opened.", loadError, nil);
            return nil;
        }
        NSString *loadedMatchID = MBCMetadataMatchID(loadedMetadata, nil);
        if ((current[@"MatchID"] || loadedMatchID) &&
            ![current[@"MatchID"] isEqualToString:loadedMatchID]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptGame,
                                                @"The game's match identity differs from the library entry.",
                                                nil, nil);
            return nil;
        }
        NSMutableDictionary *updated = [current mutableCopy];
        updated[@"OpenedAt"] = [NSDate date];
        updated[@"Recent"] = @YES;
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        rows[[rows indexOfObject:current]] = updated;
        index[@"Records"] = rows;
        index[@"LastOpenedIdentifier"] = identifier;
        if (![self writeIndex:index error:error]) return nil;
        *board = loadedBoard;
        *variant = loadedVariant;
        *side = loadedSide;
        if (boardStyle) *boardStyle = loadedBoardStyle;
        if (pieceStyle) *pieceStyle = loadedPieceStyle;
        if (metadata) *metadata = loadedMetadata;
        return [self recordForRow:updated];
    }
}

- (BOOL)migrateLegacyAutosaveIfNeededWithError:(NSError **)error
{
    @synchronized([MBCIOSGameLibrary class]) {
        NSMutableDictionary *index = [self readIndexWithError:error];
        if (!index) return NO;
        if ([index[@"LegacyMigrated"] boolValue]) return YES;
        NSURL *legacyURL = [self.directoryURL URLByAppendingPathComponent:@"Casual.game"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:legacyURL.path]) return YES;
        if ([self rowForIdentifier:MBCLegacyRecordIdentifier inIndex:index]) {
            index[@"LegacyMigrated"] = @YES;
            return [self writeIndex:index error:error];
        }
        MBCBoard *board = [[MBCBoard alloc] init];
        MBCVariant variant;
        MBCSide side;
        NSDictionary *metadata = nil;
        NSError *loadError = nil;
        if (![MBCIOSGameStore loadBoard:board variant:&variant side:&side
                            boardStyle:nil pieceStyle:nil metadata:&metadata
                               fromURL:legacyURL error:&loadError]) {
            if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorCorruptGame,
                                                @"The older autosave could not be migrated.",
                                                loadError, nil);
            return NO;
        }
        NSString *matchID = MBCMetadataMatchID(metadata, nil);
        for (NSDictionary *row in index[@"Records"]) {
            if (matchID && [row[@"MatchID"] isEqualToString:matchID]) {
                if (error) *error = MBCLibraryError(MBCIOSGameLibraryErrorConflict,
                                                    @"The older autosave's Game Center match is already in the library.",
                                                    nil, row[@"Identifier"]);
                return NO;
            }
        }
        NSData *legacyData = [NSData dataWithContentsOfURL:legacyURL options:0 error:error];
        if (!legacyData) return NO;
        NSString *fileName = [self newFileNameForIdentifier:MBCLegacyRecordIdentifier];
        NSURL *destination = [self.gamesURL URLByAppendingPathComponent:fileName];
        if (![legacyData writeToURL:destination options:NSDataWritingAtomic error:error]) return NO;
        NSDate *now = [NSDate date];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:legacyURL.path
                                                                                    error:nil];
        NSDate *createdAt = attributes[NSFileCreationDate] ?: now;
        NSDate *modifiedAt = attributes[NSFileModificationDate] ?: now;
        NSMutableDictionary *row = [@{@"Identifier": MBCLegacyRecordIdentifier,
                                      @"Name": @"Recovered Casual Game",
                                      @"Revision": @1, @"CreatedAt": createdAt,
                                      @"ModifiedAt": modifiedAt,
                                      @"FileName": fileName} mutableCopy];
        if (matchID) row[@"MatchID"] = matchID;
        NSMutableArray *rows = [index[@"Records"] mutableCopy];
        [rows addObject:row];
        index[@"Records"] = rows;
        index[@"LegacyMigrated"] = @YES;
        if (!index[@"LastOpenedIdentifier"]) {
            row[@"OpenedAt"] = now;
            index[@"LastOpenedIdentifier"] = MBCLegacyRecordIdentifier;
        }
        if (![self writeIndex:index error:error]) {
            [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
            return NO;
        }
        return YES;
    }
}

@end
