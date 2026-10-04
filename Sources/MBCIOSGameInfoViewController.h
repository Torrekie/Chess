/* UIKit move-log and game-status surface for the iOS Chess shell. */

#import <UIKit/UIKit.h>

#import "MBCBoard.h"

@class MBCBoard;

typedef void (^MBCIOSGameInfoSaveHandler)(NSDictionary * _Nonnull metadata);

NS_ASSUME_NONNULL_BEGIN

@interface MBCIOSGameInfoViewController : UITableViewController

- (instancetype)initWithBoard:(MBCBoard *)board;
- (instancetype)initWithBoard:(MBCBoard *)board
                      metadata:(NSDictionary * _Nullable)metadata
                          side:(MBCSide)side
                    saveHandler:(MBCIOSGameInfoSaveHandler _Nullable)saveHandler;

/* Creates the same editable sheet used by the Edit button. */
- (UITableViewController *)makeMetadataEditor;

/* Refreshes an open log when its owning game commits a move or changes state. */
- (void)updateWithBoard:(MBCBoard *)board metadata:(NSDictionary * _Nullable)metadata
                  side:(MBCSide)side;

/* Read-only presentation values keep the sheet's state testable without
 * reaching into UIKit's private labels. */
@property (nonatomic, copy, readonly) NSString *statusText;
@property (nonatomic, copy, readonly) NSString *summaryText;

@end

NS_ASSUME_NONNULL_END
