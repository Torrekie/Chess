/* A compact UIKit counterpart to Chess's macOS About window. */

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MBCIOSAboutViewController : UIViewController

/* Uses the app bundle for name, version, build, copyright, and any bundled
 * COPYING/Chess.txt license. Present directly as a form or page sheet. */
- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
