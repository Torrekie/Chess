/* iOS speech adapter for the shared Chess move model. */

#import <Foundation/Foundation.h>

#import "MBCBoard.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const MBCIOSSpeechVoiceIdentifierKey;
FOUNDATION_EXPORT NSString * const MBCIOSSpeechVoiceNameKey;
FOUNDATION_EXPORT NSString * const MBCIOSSpeechVoiceLanguageKey;

@interface MBCIOSSpeechController : NSObject
@property (nonatomic, copy, nullable) NSDictionary *gameSettings;
- (void)previewVoiceIdentifier:(nullable NSString *)identifier;

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableVoiceChoices;
+ (NSString *)displayNameForVoiceIdentifier:(nullable NSString *)identifier;
/* Resolve Apple's spoken-move catalog by the selected voice language, with
 * region/script fallback and an English fallback on older installations. */
+ (NSDictionary *)localizationForVoiceLanguage:(nullable NSString *)language;

- (instancetype)initWithBoard:(MBCBoard *)board;
- (void)setBoard:(MBCBoard *)board;

/* The computer/human switches use the game settings, falling back to defaults.
 * The alternate voice follows the macOS convention: it is used for the
 * human side in a local human/computer game, and for Black in symmetric
 * human-vs-human or computer-vs-computer games. */
- (void)speakMove:(MBCMove *)move
     computerMove:(BOOL)computerMove
   alternateVoice:(BOOL)alternateVoice;
- (void)announceHint:(MBCMove *)move alternateVoice:(BOOL)alternateVoice;
- (void)announceLastMove:(MBCMove *)move alternateVoice:(BOOL)alternateVoice;

/* Settings are read on each utterance. Reloading stops queued speech after a
 * preference commit so a stale voice or disabled channel cannot continue. */
- (void)reloadSettings;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
