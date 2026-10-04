/* UIKit move-log and game-status surface for the iOS Chess shell. */

#import "MBCIOSGameInfoViewController.h"

#import "MBCBoard.h"
#import "MBCIOSLocalization.h"
#import "MBCUserDefaults.h"
#import <math.h>

static NSString *MBCIOSInfoResultTitle(MBCMoveCode command)
{
    switch (command) {
        case kCmdWhiteWins: return MBCIOSLocalizedString(@"ios_white_wins", @"White wins");
        case kCmdBlackWins: return MBCIOSLocalizedString(@"ios_black_wins", @"Black wins");
        case kCmdDraw:      return MBCIOSLocalizedString(@"ios_draw", @"Draw");
        default:            return nil;
    }
}

static NSString *MBCIOSInfoMoveText(MBCMove *move)
{
    if (!move) return @"";
    NSString *localized = [move localizedText];
    if (localized.length) return localized;
    NSString *engine = [move engineMove];
    return [engine stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSString *MBCIOSMetadataResultTitle(NSString *result)
{
    if ([result isEqualToString:@"1-0"]) return MBCIOSLocalizedString(@"ios_white_wins", @"White wins");
    if ([result isEqualToString:@"0-1"]) return MBCIOSLocalizedString(@"ios_black_wins", @"Black wins");
    if ([result isEqualToString:@"1/2-1/2"]) return MBCIOSLocalizedString(@"ios_draw", @"Draw");
    return nil;
}

@interface MBCIOSGameMetadataViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithMetadata:(NSDictionary *)metadata
                             side:(MBCSide)side
                       saveHandler:(MBCIOSGameInfoSaveHandler)saveHandler;
@end

@interface MBCIOSGameMetadataViewController ()
@property (nonatomic, copy) NSDictionary *initialMetadata;
@property (nonatomic) MBCSide side;
@property (nonatomic, copy) MBCIOSGameInfoSaveHandler saveHandler;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@end

@implementation MBCIOSGameMetadataViewController

- (instancetype)initWithMetadata:(NSDictionary *)metadata
                             side:(MBCSide)side
                       saveHandler:(MBCIOSGameInfoSaveHandler)saveHandler
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _initialMetadata = [metadata copy] ?: @{};
        _side = side;
        _saveHandler = [saveHandler copy];
        _fields = [NSMutableDictionary dictionary];
        self.title = MBCIOSLocalizedString(@"ios_edit_game_information", @"Edit Game Information");
    }
    return self;
}

- (NSArray<NSString *> *)metadataKeys
{
    return @[@"White", @"Black", @"City", @"Country", @"Event"];
}

- (NSDictionary<NSString *, NSString *> *)metadataLabels
{
    return @{@"White": MBCIOSLocalizedString(@"ios_metadata_white", @"White"),
             @"Black": MBCIOSLocalizedString(@"ios_metadata_black", @"Black"),
             @"City": MBCIOSLocalizedString(@"ios_metadata_city", @"City"),
             @"Country": MBCIOSLocalizedString(@"ios_metadata_country", @"Country"),
             @"Event": MBCIOSLocalizedString(@"ios_metadata_event", @"Event")};
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                       target:self
                                                       action:@selector(cancelAction:)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                       target:self
                                                       action:@selector(saveAction:)];
    self.tableView.accessibilityLabel = MBCIOSLocalizedString(@"ios_editable_game_information", @"Editable game information");
}

- (BOOL)isEditableKey:(NSString *)key
{
    if (([key isEqualToString:@"White"] || [key isEqualToString:@"Black"]) &&
        ([self.initialMetadata[@"MatchID"] length] ||
         [self.initialMetadata[@"GameCenterMatchID"] length])) return NO;
    if ([key isEqualToString:@"White"]) return SideIncludesWhite(self.side);
    if ([key isEqualToString:@"Black"]) return SideIncludesBlack(self.side);
    return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.metadataKeys.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"ChessMetadataCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *key = self.metadataKeys[indexPath.row];
    UITextField *field = self.fields[key];
    if (!field) {
        field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220.0, 44.0)];
        field.textAlignment = NSTextAlignmentRight;
        field.adjustsFontForContentSizeCategory = YES;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.delegate = self;
        self.fields[key] = field;
    }
    field.text = [self.initialMetadata[key] isKindOfClass:[NSString class]]
        ? self.initialMetadata[key] : @"";
    field.enabled = [self isEditableKey:key];
    field.accessibilityLabel = self.metadataLabels[key];
    cell.textLabel.text = self.metadataLabels[key];
    cell.accessoryView = field;
    cell.accessibilityLabel = self.metadataLabels[key];
    cell.accessibilityValue = field.text;
    return cell;
}

- (void)cancelAction:(UIBarButtonItem *)sender
{
    (void)sender;
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)saveAction:(UIBarButtonItem *)sender
{
    (void)sender;
    NSMutableDictionary *metadata = [self.initialMetadata mutableCopy];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *defaultKeys = @{@"White": kMBCHumanName, @"Black": kMBCHumanName2,
        @"City": kMBCGameCity, @"Country": kMBCGameCountry, @"Event": kMBCGameEvent};
    for (NSString *key in self.metadataKeys) {
        UITextField *field = self.fields[key];
        if (field && [self isEditableKey:key]) {
            NSString *value = field.text ?: @"";
            metadata[key] = value;
            if (![value isEqual:self.initialMetadata[key]])
                [defaults setObject:value forKey:defaultKeys[key]];
        }
    }
    if (self.saveHandler) self.saveHandler([metadata copy]);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface MBCIOSGameInfoViewController ()
@property (nonatomic, strong) MBCBoard *board;
@property (nonatomic, strong) NSMutableDictionary *metadata;
@property (nonatomic) MBCSide side;
@property (nonatomic, copy) MBCIOSGameInfoSaveHandler saveHandler;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic) BOOL hasShownLatestMove;
@end

@implementation MBCIOSGameInfoViewController

- (instancetype)initWithBoard:(MBCBoard *)board
{
    return [self initWithBoard:board metadata:nil side:kBothSides saveHandler:nil];
}

- (instancetype)initWithBoard:(MBCBoard *)board
                      metadata:(NSDictionary *)metadata
                          side:(MBCSide)side
                    saveHandler:(MBCIOSGameInfoSaveHandler)saveHandler
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _board = board;
        _metadata = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        _side = side;
        _saveHandler = [saveHandler copy];
        self.title = MBCIOSLocalizedString(@"ios_game_information", @"Game Information");
        self.preferredContentSize = CGSizeMake(430.0, 560.0);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(doneAction:)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:MBCIOSLocalizedString(@"ios_edit", @"Edit")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(editInfoAction:)];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 94.0)];
    self.headerView = header;

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    status.adjustsFontForContentSizeCategory = YES;
    status.numberOfLines = 0;
    status.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_status", @"Game status");
    [header addSubview:status];
    self.statusLabel = status;

    UILabel *summary = [[UILabel alloc] initWithFrame:CGRectZero];
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    summary.textColor = UIColor.secondaryLabelColor;
    summary.adjustsFontForContentSizeCategory = YES;
    summary.numberOfLines = 0;
    summary.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_summary", @"Game summary");
    [header addSubview:summary];
    self.summaryLabel = summary;

    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20.0],
        [status.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20.0],
        [status.topAnchor constraintEqualToAnchor:header.topAnchor constant:14.0],
        [summary.leadingAnchor constraintEqualToAnchor:status.leadingAnchor],
        [summary.trailingAnchor constraintEqualToAnchor:status.trailingAnchor],
        [summary.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:5.0],
        [summary.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12.0]
    ]];
    self.tableView.tableHeaderView = header;
    [self updateHeader];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateHeader];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.hasShownLatestMove) {
        self.hasShownLatestMove = YES;
        [self scrollToLatestMove];
    }
}

- (void)scrollToLatestMove
{
    if (!self.board.numMoves) return;
    [self.tableView layoutIfNeeded];
    NSIndexPath *last = [NSIndexPath indexPathForRow:(self.board.numMoves - 1) / 2
                                         inSection:0];
    [self.tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionBottom
                                animated:NO];
}

- (void)updateWithBoard:(MBCBoard *)board metadata:(NSDictionary *)metadata side:(MBCSide)side
{
    BOOL followLatest = NO;
    if (self.isViewLoaded) {
        CGFloat visibleBottom = self.tableView.contentOffset.y + self.tableView.bounds.size.height
            - self.tableView.adjustedContentInset.bottom;
        followLatest = visibleBottom >= self.tableView.contentSize.height - 44.0 &&
            !self.tableView.dragging && !self.tableView.decelerating;
    }
    self.board = board;
    self.metadata = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
    self.side = side;
    if (self.isViewLoaded) {
        [self updateHeader];
        [self.tableView reloadData];
        if (followLatest && self.view.window) [self scrollToLatestMove];
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0.0 || !self.headerView) return;
    CGSize fitted = [self.headerView systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = ceil(fitted.height);
    if (fabs(CGRectGetHeight(self.headerView.frame) - height) < 1.0 &&
        fabs(CGRectGetWidth(self.headerView.frame) - width) < 1.0) return;
    self.headerView.frame = CGRectMake(0.0, 0.0, width, height);
    self.tableView.tableHeaderView = self.headerView;
}

- (void)doneAction:(UIBarButtonItem *)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)editInfoAction:(UIBarButtonItem *)sender
{
    (void)sender;
    [self.navigationController pushViewController:[self makeMetadataEditor] animated:YES];
}

- (UITableViewController *)makeMetadataEditor
{
    __weak MBCIOSGameInfoViewController *weakSelf = self;
    MBCIOSGameMetadataViewController *editor =
        [[MBCIOSGameMetadataViewController alloc] initWithMetadata:self.metadata
                                                               side:self.side
                                                         saveHandler:^(NSDictionary *metadata) {
        MBCIOSGameInfoViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // The board can advance while the metadata editor is open.
        for (NSString *key in @[@"White", @"Black", @"City", @"Country", @"Event"])
            if (metadata[key]) strongSelf.metadata[key] = metadata[key];
        [strongSelf updateHeader];
        [strongSelf.tableView reloadData];
        if (strongSelf.saveHandler) strongSelf.saveHandler([strongSelf.metadata copy]);
    }];
    return editor;
}

- (void)updateHeader
{
    if (!self.board) return;
    self.statusLabel.text = self.statusText;
    self.statusLabel.accessibilityValue = self.statusText;
    self.summaryLabel.text = self.summaryText;
    self.summaryLabel.accessibilityValue = self.summaryText;
    [self.view setNeedsLayout];
}

- (NSString *)statusText
{
    MBCMoveCode outcome = [self.board outcome];
    NSString *result = MBCIOSInfoResultTitle(outcome);
    if (!result) result = MBCIOSMetadataResultTitle(self.metadata[@"Result"]);
    if (result) return result;
    return ([self.board numMoves] & 1)
        ? MBCIOSLocalizedString(@"ios_black_to_move", @"Black to move")
        : MBCIOSLocalizedString(@"ios_white_to_move", @"White to move");
}

- (NSString *)summaryText
{
    NSInteger moveCount = [self.board numMoves];
    if (moveCount == 0) return MBCIOSLocalizedString(@"ios_no_moves_yet", @"No moves yet");
    NSInteger fullMoves = (moveCount + 1) / 2;
    return fullMoves == 1 ? MBCIOSLocalizedString(@"ios_one_full_move", @"1 full move") :
        [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_full_moves", @"%ld full moves"), (long)fullMoves];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    NSInteger rows = self.board ? ([self.board numMoves] + 1) / 2 : 0;
    return MAX(rows, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"ChessMoveCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }

    NSInteger rows = self.board ? ([self.board numMoves] + 1) / 2 : 0;
    if (rows == 0) {
        cell.textLabel.text = MBCIOSLocalizedString(@"ios_no_moves_yet", @"No moves yet");
        cell.detailTextLabel.text = nil;
        cell.accessibilityLabel = MBCIOSLocalizedString(@"ios_no_moves_yet", @"No moves yet");
        return cell;
    }

    NSInteger whiteIndex = indexPath.row * 2;
    NSInteger blackIndex = whiteIndex + 1;
    MBCMove *white = whiteIndex < [self.board numMoves] ? [self.board move:(int)whiteIndex] : nil;
    MBCMove *black = blackIndex < [self.board numMoves] ? [self.board move:(int)blackIndex] : nil;
    NSString *whiteText = MBCIOSInfoMoveText(white);
    NSString *blackText = MBCIOSInfoMoveText(black);
    cell.textLabel.text = [NSString stringWithFormat:@"%ld.", (long)indexPath.row + 1];
    cell.detailTextLabel.text = [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_move_row_detail", @"White  %@    Black  %@"),
                                 whiteText.length ? whiteText : @"—",
                                 blackText.length ? blackText : @"—"];
    cell.accessibilityLabel = [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"ios_move_row_accessibility", @"Move %ld. White %@. Black %@"),
                               (long)indexPath.row + 1,
                               whiteText.length ? whiteText : MBCIOSLocalizedString(@"ios_not_played", @"not played"),
                               blackText.length ? blackText : MBCIOSLocalizedString(@"ios_not_played", @"not played")];
    return cell;
}

@end
