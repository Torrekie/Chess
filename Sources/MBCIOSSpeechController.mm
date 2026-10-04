/*
 * iOS speech adapter for Apple Chess's move announcements.
 *
 * The macOS target uses NSSpeechSynthesizer and Spoken.strings selected by
 * the voice locale. iOS keeps the same move-format strings and preference
 * keys while using AVSpeechSynthesizer and the voices installed on the
 * target. Invalid or unavailable stored voice identifiers fall back to the
 * system voice rather than disabling announcements.
 */

#import "MBCIOSSpeechController.h"

#import <AVFoundation/AVFoundation.h>

#import "MBCIOSLocalization.h"
#import "MBCUserDefaults.h"

NSString * const MBCIOSSpeechVoiceIdentifierKey = @"identifier";
NSString * const MBCIOSSpeechVoiceNameKey       = @"name";
NSString * const MBCIOSSpeechVoiceLanguageKey   = @"language";

static NSString *MBCIOSSpeechCleanDirectives(NSString *text)
{
    if (!text.length) return @"";
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"\\[\\[.*?\\]\\]"
                                                                    options:0
                                                                      error:nil];
    });
    return [expression stringByReplacingMatchesInString:text
                                                options:0
                                                  range:NSMakeRange(0, text.length)
                                           withTemplate:@""];
}

static NSArray<NSString *> *MBCIOSSpeechLocalizationCandidates(NSString *language)
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^appendExact)(NSString *) = ^(NSString *value) {
        if (!value.length || [candidates containsObject:value]) return;
        [candidates addObject:value];
    };
    void (^appendLanguage)(NSString *) = ^(NSString *value) {
        if (!value.length) return;
        NSString *normalized = [value stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        appendExact(value);
        appendExact(normalized);
        if ([normalized hasPrefix:@"zh_Hans"]) appendExact(@"zh_CN");
        if ([normalized hasPrefix:@"zh_Hant_HK"]) appendExact(@"zh_HK");
        else if ([normalized hasPrefix:@"zh_Hant"]) appendExact(@"zh_TW");
        NSString *base = [[normalized componentsSeparatedByString:@"_"] firstObject];
        if ([base isEqualToString:@"es"] && [normalized containsString:@"_"] &&
            ![normalized isEqualToString:@"es_ES"])
            appendExact(@"es_419");
        if ([base isEqualToString:@"pt"] && [normalized isEqualToString:@"pt"])
            appendExact(@"pt_PT");
        appendExact(base);
    };

    appendLanguage(language);
    appendLanguage([NSLocale preferredLanguages].firstObject);
    appendExact(@"en");
    return candidates;
}

static AVSpeechSynthesisVoice *MBCIOSSpeechVoiceForIdentifier(NSString *identifier)
{
    if (!identifier.length) return nil;

    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:identifier];
    if (voice) return voice;

    /* The shipped macOS defaults can contain Victoria/Vicky identifiers that
     * do not exist on iOS. Prefer an English iOS voice before falling back to
     * AVSpeechSynthesizer's system default. */
    if ([identifier rangeOfString:@"Victoria" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [identifier rangeOfString:@"Vicky" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    }
    return voice;
}

@interface MBCIOSSpeechController ()
@property (nonatomic, strong) MBCBoard *board;
@property (nonatomic, strong) AVSpeechSynthesizer *synthesizer;
@end

@implementation MBCIOSSpeechController

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableVoiceChoices
{
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *choices = [NSMutableArray array];
    [choices addObject:@{
        MBCIOSSpeechVoiceIdentifierKey: @"",
        MBCIOSSpeechVoiceNameKey: MBCIOSLocalizedString(@"ios_system_default_voice", @"System Default"),
        MBCIOSSpeechVoiceLanguageKey: @""
    }];

    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
    voices = [voices sortedArrayUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a,
                                                                    AVSpeechSynthesisVoice *b) {
        NSString *aLanguage = a.language ?: @"";
        NSString *bLanguage = b.language ?: @"";
        NSComparisonResult languageResult = [aLanguage localizedStandardCompare:bLanguage];
        if (languageResult != NSOrderedSame) return languageResult;
        return [a.name localizedStandardCompare:b.name];
    }];

    for (AVSpeechSynthesisVoice *voice in voices) {
        if (!voice.identifier.length) continue;
        NSString *name = voice.name.length ? voice.name : voice.identifier;
        if (voice.language.length) {
            name = [NSString stringWithFormat:@"%@ (%@)", name, voice.language];
        }
        [choices addObject:@{
            MBCIOSSpeechVoiceIdentifierKey: voice.identifier,
            MBCIOSSpeechVoiceNameKey: name,
            MBCIOSSpeechVoiceLanguageKey: voice.language ?: @""
        }];
    }
    return choices;
}

+ (NSString *)displayNameForVoiceIdentifier:(NSString *)identifier
{
    for (NSDictionary<NSString *, NSString *> *choice in [self availableVoiceChoices]) {
        if ([choice[MBCIOSSpeechVoiceIdentifierKey] isEqualToString:identifier ?: @""]) {
            return choice[MBCIOSSpeechVoiceNameKey];
        }
    }
    return MBCIOSLocalizedString(@"ios_system_default_voice", @"System Default");
}

- (instancetype)initWithBoard:(MBCBoard *)board
{
    self = [super init];
    if (self) {
        _board = board;
        _synthesizer = [[AVSpeechSynthesizer alloc] init];
    }
    return self;
}

- (void)setBoard:(MBCBoard *)board
{
    _board = board;
}

- (id)settingForKey:(NSString *)key
{
    return self.gameSettings[key] ?: [[NSUserDefaults standardUserDefaults] objectForKey:key];
}

- (void)previewVoiceIdentifier:(NSString *)identifier
{
    [self stop];
    AVSpeechSynthesisVoice *voice = MBCIOSSpeechVoiceForIdentifier(identifier);
    NSDictionary *localization = [self.class localizationForVoiceLanguage:voice.language];
    MBCMove *move = [MBCMove moveWithCommand:kCmdMove];
    move->fPiece = PAWN;
    move->fFromSquare = 12;
    move->fToSquare = 28;
    NSString *text = [self.board extStringFromMove:move withLocalization:localization];
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:
        MBCIOSSpeechCleanDirectives(text.length ? text : @"e2 e4")];
    utterance.voice = voice;
    [self.synthesizer speakUtterance:utterance];
}

- (AVSpeechSynthesisVoice *)voiceForAlternate:(BOOL)alternate
{
    NSString *key = alternate ? kMBCAlternateVoice : kMBCDefaultVoice;
    AVSpeechSynthesisVoice *voice = MBCIOSSpeechVoiceForIdentifier([self settingForKey:key]);
    if (voice || !alternate) return voice;

    /* An unavailable alternate voice falls back to the selected primary voice
     * before relying on the OS default. */
    return MBCIOSSpeechVoiceForIdentifier([self settingForKey:kMBCDefaultVoice]);
}

- (NSDictionary *)spokenLocalizationForVoice:(AVSpeechSynthesisVoice *)voice
{
    return [self.class localizationForVoiceLanguage:voice.language];
}

+ (NSDictionary *)localizationForVoiceLanguage:(NSString *)language
{
    static NSDictionary *spokenTable;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *tableURL = [[NSBundle mainBundle] URLForResource:@"Spoken" withExtension:@"loctable"];
        NSDictionary *table = tableURL ? [NSDictionary dictionaryWithContentsOfURL:tableURL] : nil;
        spokenTable = [table isKindOfClass:[NSDictionary class]] ? table : @{};
    });
    for (NSString *candidate in MBCIOSSpeechLocalizationCandidates(language)) {
        NSDictionary *catalogStrings = spokenTable[candidate];
        if ([catalogStrings isKindOfClass:[NSDictionary class]] && catalogStrings[@"move_fmt"]) {
            NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:language.length ? language : candidate];
            return @{ @"strings": catalogStrings, @"locale": locale };
        }
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"Spoken"
                                              withExtension:@"strings"
                                               subdirectory:nil
                                               localization:candidate];
        NSDictionary *strings = url ? [NSDictionary dictionaryWithContentsOfURL:url] : nil;
        if ([strings isKindOfClass:[NSDictionary class]]) {
            NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:language.length ? language : candidate];
            return @{ @"strings": strings, @"locale": locale };
        }
    }

    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:language.length ? language : @"en_US"];
    return @{ @"strings": @{}, @"locale": locale };
}

- (NSString *)speechTextForMove:(MBCMove *)move
                          wrapper:(NSString *)wrapper
                            voice:(AVSpeechSynthesisVoice *)voice
{
    if (!move || !self.board) return @"";
    NSDictionary *localization = [self spokenLocalizationForVoice:voice];
    NSString *text = [self.board extStringFromMove:move withLocalization:localization];
    if (!text.length) text = [move localizedText];
    if (wrapper.length) text = [NSString stringWithFormat:wrapper, text ?: @""];
    return MBCIOSSpeechCleanDirectives(text);
}

- (void)speakText:(NSString *)text alternateVoice:(BOOL)alternate
{
    if (!text.length) return;
    AVSpeechSynthesisVoice *voice = [self voiceForAlternate:alternate];
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.voice = voice;
    [self.synthesizer speakUtterance:utterance];
}

- (void)speakMove:(MBCMove *)move
     computerMove:(BOOL)computerMove
   alternateVoice:(BOOL)alternateVoice
{
    NSString *key = computerMove ? kMBCSpeakMoves : kMBCSpeakHumanMoves;
    if (![[self settingForKey:key] boolValue]) return;

    AVSpeechSynthesisVoice *voice = [self voiceForAlternate:alternateVoice];
    [self speakText:[self speechTextForMove:move wrapper:nil voice:voice]
     alternateVoice:alternateVoice];
}

- (void)announceHint:(MBCMove *)move alternateVoice:(BOOL)alternateVoice
{
    if (![[self settingForKey:kMBCSpeakMoves] boolValue] && ![[self settingForKey:kMBCSpeakHumanMoves] boolValue]) return;

    AVSpeechSynthesisVoice *voice = [self voiceForAlternate:alternateVoice];
    NSDictionary *localization = [self spokenLocalizationForVoice:voice];
    NSString *wrapper = localization[@"strings"][@"suggest_fmt"] ?: @"I would suggest \"%@\"";
    [self speakText:[self speechTextForMove:move wrapper:wrapper voice:voice]
     alternateVoice:alternateVoice];
}

- (void)announceLastMove:(MBCMove *)move alternateVoice:(BOOL)alternateVoice
{
    if (![[self settingForKey:kMBCSpeakMoves] boolValue] && ![[self settingForKey:kMBCSpeakHumanMoves] boolValue]) return;

    AVSpeechSynthesisVoice *voice = [self voiceForAlternate:alternateVoice];
    NSDictionary *localization = [self spokenLocalizationForVoice:voice];
    NSString *wrapper = localization[@"strings"][@"last_move_fmt"] ?: @"The last move was \"%@\"";
    [self speakText:[self speechTextForMove:move wrapper:wrapper voice:voice]
     alternateVoice:alternateVoice];
}

- (void)reloadSettings
{
    [self stop];
}

- (void)stop
{
    [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

@end
