#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Redirect standard defaults to a disposable suite during renderer tests. */
@interface MBCGraphicsTestDefaults : NSObject
@property (nonatomic, strong, readonly) NSUserDefaults *defaults;
- (void)restore;
@end

NS_ASSUME_NONNULL_END
