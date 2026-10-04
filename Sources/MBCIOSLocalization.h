/* Shared iOS localization bridge for the UIKit shell. */

#import <Foundation/Foundation.h>

/*
 * The macOS catalog predates the UIKit shell and therefore does not contain
 * an entry for every iOS-only key.  A few of those keys intentionally mirror
 * an existing Chess key.  Resolve those aliases only when the iOS entry is
 * still the English fallback; this preserves a real translation supplied by a
 * locale-specific iOS strings file and lets the shipped Apple translation be
 * used otherwise.
 */
static inline NSString *MBCIOSLocalizedString(NSString *key, NSString *fallback)
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *value = [bundle localizedStringForKey:key value:fallback table:nil];
    if (![value isEqualToString:fallback]) return value;

    static NSDictionary<NSString *, NSString *> *aliases;
    static NSDictionary<NSString *, NSString *> *aliasEnglishValues;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @{
            @"ios_chess_title": @"Chess",
            @"ios_white_wins": @"white_win_msg",
            @"ios_black_wins": @"black_win_msg",
            @"ios_draw": @"draw_msg",
            @"ios_draw_action": @"draw_msg",
            @"ios_white_to_move": @"white_move_msg",
            @"ios_black_to_move": @"black_move_msg",
            @"ios_speak_computer_moves": @"engine_opponent",
            @"ios_game_center": @"cloud_city",
            @"ios_ok": @"takeback_refused_ok",
        };
        aliasEnglishValues = @{
            @"Chess": @"Chess",
            @"cloud_city": @"Game Center",
            @"white_win_msg": @"White wins!",
            @"black_win_msg": @"Black wins!",
            @"draw_msg": @"Draw!",
            @"white_move_msg": @"White to Move",
            @"black_move_msg": @"Black to Move",
            @"engine_opponent": @"Speak Computer Moves",
            @"takeback_refused_ok": @"OK",
        };
    });

    NSString *alias = aliases[key];
    if (alias) {
        NSString *aliasValue = [bundle localizedStringForKey:alias
                                                        value:aliasEnglishValues[alias]
                                                        table:nil];
        NSString *aliasFallback = aliasEnglishValues[alias] ?: alias;
        if (aliasValue.length > 0 && ![aliasValue isEqualToString:aliasFallback]) {
            return aliasValue;
        }
    }

    /* UIKit owns translations for a small set of standard action words.  Use
     * those only after the app catalog has had a chance to provide a value;
     * this keeps the lookup safe on older iOS releases and avoids replacing
     * a deliberate product translation. */
    Class alertControllerClass = NSClassFromString(@"UIAlertController");
    NSBundle *systemBundle = alertControllerClass ? [NSBundle bundleForClass:alertControllerClass] : nil;
    NSString *systemValue = systemBundle
        ? [systemBundle localizedStringForKey:fallback value:fallback table:nil]
        : fallback;
    if (systemValue.length > 0 && ![systemValue isEqualToString:fallback]) {
        return systemValue;
    }
    return value;
}
