#import <UIKit/UIKit.h>

@class ChessIOSViewController;

@interface ChessIOSAppDelegate : UIResponder <UIApplicationDelegate>

/* Scene lifecycle hooks. */
- (BOOL)claimInitialScene;
- (nullable NSString *)gameIdentifierForSceneSession:(UISceneSession *)session;
- (void)recordGameIdentifier:(NSString *)identifier forSceneSession:(UISceneSession *)session;
- (void)sceneDidConnectController:(ChessIOSViewController *)viewController;
- (void)sceneDidBecomeActiveWithController:(ChessIOSViewController *)viewController;
@end
