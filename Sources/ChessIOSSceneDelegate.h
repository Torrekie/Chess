#import <UIKit/UIKit.h>

@class ChessIOSViewController;

@interface ChessIOSSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong, readonly) ChessIOSViewController *viewController;

/* Used by UIKit's scene URL callback and the legacy app-delegate fallback. */
- (BOOL)importURL:(NSURL *)url;
- (void)saveActiveGame;
- (void)saveActiveGameRecoveringConflict;

@end
