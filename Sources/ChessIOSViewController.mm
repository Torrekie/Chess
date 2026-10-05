#import "ChessIOSViewController.h"

#import "MBCBoard.h"
#import "MBCIOSBoardBackend.h"
#import "MBCIOSRendererPreferences.h"
#import "MBCIOSChessEngine.h"
#import "MBCPlayer.h"
#import "MBCIOSGameStore.h"
#import "MBCIOSGameLibrary.h"
#import "MBCIOSGameCenterManager.h"
#import "MBCIOSGameInfoViewController.h"
#import "MBCIOSAboutViewController.h"
#import "MBCIOSCoordinateEntryViewController.h"
#import "MBCIOSSpeechController.h"
#import "MBCIOSLocalization.h"
#import "MBCUserDefaults.h"

// A shared material for controls floating over the board. The effect clips its
// own continuous corners; the outer view stays unclipped so its shadow can draw.
@interface MBCIOSBoardChromeView : UIView
- (instancetype)initWithCornerRadius:(CGFloat)radius;
@property (nonatomic, strong) UIVisualEffectView *materialView;
@property (nonatomic) BOOL contentVisible;
@end

@implementation MBCIOSBoardChromeView

- (instancetype)initWithCornerRadius:(CGFloat)radius
{
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _contentVisible = YES;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 10.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    _materialView = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _materialView.frame = self.bounds;
    _materialView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _materialView.layer.cornerRadius = radius;
    _materialView.layer.cornerCurve = kCACornerCurveContinuous;
    _materialView.clipsToBounds = YES;
    _materialView.userInteractionEnabled = NO;
    [self addSubview:_materialView];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(reduceTransparencyDidChange:)
        name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [self updateMaterialAppearance];
    return self;
}

- (void)updateMaterialAppearance
{
    BOOL opaque = UIAccessibilityIsReduceTransparencyEnabled();
    self.materialView.hidden = opaque;
    self.materialView.effect = self.contentVisible
        ? [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial] : nil;
    self.backgroundColor = opaque && self.contentVisible
        ? UIColor.secondarySystemBackgroundColor : UIColor.clearColor;
    self.layer.shadowOpacity = self.contentVisible ? 0.12 : 0.0;
}

- (void)setContentVisible:(BOOL)contentVisible
{
    _contentVisible = contentVisible;
    // Animate the blur effect itself: lowering a visual-effect ancestor's
    // alpha prevents UIKit from compositing its material correctly.
    [self updateMaterialAppearance];
    for (UIView *content in self.subviews) {
        if (content != self.materialView) content.alpha = contentVisible ? 1.0 : 0.0;
    }
}

- (void)reduceTransparencyDidChange:(NSNotification *)notification
{
    (void)notification;
    [self updateMaterialAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

typedef void (^MBCIOSNewGameCompletion)(BOOL confirmed,
                                         MBCVariant variant,
                                         MBCPlayers players,
                                         MBCSideCode sideCode,
                                         NSInteger searchTime,
                                         BOOL rotateAfterMove,
                                         BOOL confirmNextTurn,
                                         BOOL keepDisplayAwake);

static NSString *MBCIOSVariantTitle(MBCVariant variant)
{
    switch (variant) {
        case kVarCrazyhouse: return MBCIOSLocalizedString(@"ios_variant_crazyhouse", @"Crazyhouse");
        case kVarSuicide:    return MBCIOSLocalizedString(@"ios_variant_suicide", @"Suicide");
        case kVarLosers:     return MBCIOSLocalizedString(@"ios_variant_losers", @"Losers");
        case kVarNormal:
        default:             return MBCIOSLocalizedString(@"ios_variant_regular", @"Regular");
    }
}

static NSString *MBCIOSPlayersTitle(MBCPlayers players)
{
    switch (players) {
        case kHumanVsComputer:    return MBCIOSLocalizedString(@"ios_players_human_computer", @"Human vs. Computer");
        case kComputerVsHuman:    return MBCIOSLocalizedString(@"ios_players_computer_human", @"Computer vs. Human");
        case kComputerVsComputer: return MBCIOSLocalizedString(@"ios_players_computer_computer", @"Computer vs. Computer");
        case kHumanVsGameCenter:  return MBCIOSLocalizedString(@"ios_players_game_center", @"Game Center Match");
        case kHumanVsHuman:
        default:                  return MBCIOSLocalizedString(@"ios_players_human_human", @"Human vs. Human");
    }
}

static NSString *MBCIOSSideCodeTitle(MBCSideCode sideCode)
{
    switch (sideCode) {
        case kPlayBlack:  return MBCIOSLocalizedString(@"ios_side_black", @"Black");
        case kPlayEither: return MBCIOSLocalizedString(@"ios_side_either", @"Either");
        case kPlayWhite:
        default:          return MBCIOSLocalizedString(@"ios_side_white", @"White");
    }
}

static NSString *MBCIOSStrengthTitle(NSInteger searchTime)
{
    switch (searchTime) {
        case 1: return MBCIOSLocalizedString(@"fixed_depth_mode", @"Computer thinks 1 move ahead");
        case 2:
        case 3: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_depths_mode", @"Computer thinks %d moves ahead"), (int)searchTime];
        case 4: return MBCIOSLocalizedString(@"fixed_time_mode", @"Computer thinks 1 second per move");
        case 5: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 2];
        case 6: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 4];
        case 7: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 8];
        case 8: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 16];
        case 9: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 32];
        case 10: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 64];
        case 11: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 128];
        case 12: return [NSString localizedStringWithFormat:MBCIOSLocalizedString(@"fixed_times_mode", @"Computer thinks %d seconds per move"), 256];
        default: return MBCIOSLocalizedString(@"fixed_depth_mode", @"Computer thinks 1 move ahead");
    }
}

static NSString *MBCIOSGameResultTitle(MBCMoveCode command)
{
    switch (command) {
        case kCmdWhiteWins: return MBCIOSLocalizedString(@"ios_white_wins", @"White wins");
        case kCmdBlackWins: return MBCIOSLocalizedString(@"ios_black_wins", @"Black wins");
        case kCmdDraw:      return MBCIOSLocalizedString(@"ios_draw", @"Draw");
        default:            return nil;
    }
}

static NSString *MBCIOSGameStatusTitle(MBCBoard *board, NSDictionary *metadata)
{
    if (!board) return MBCIOSLocalizedString(@"ios_chess_title", @"Chess");
    NSString *result = MBCIOSGameResultTitle([board outcome]);
    if (!result) {
        NSString *storedResult = metadata[@"Result"];
        if ([storedResult isEqualToString:@"1-0"]) result = MBCIOSLocalizedString(@"ios_white_wins", @"White wins");
        else if ([storedResult isEqualToString:@"0-1"]) result = MBCIOSLocalizedString(@"ios_black_wins", @"Black wins");
        else if ([storedResult isEqualToString:@"1/2-1/2"]) result = MBCIOSLocalizedString(@"ios_draw", @"Draw");
    }
    if (result.length) return result;
    return ([board numMoves] & 1)
        ? MBCIOSLocalizedString(@"ios_black_to_move", @"Chess - Black to move")
        : MBCIOSLocalizedString(@"ios_white_to_move", @"Chess - White to move");
}

static NSString *MBCIOSMoveDisplayText(MBCMove *move)
{
    if (!move || move->fCommand == kCmdNull) return @"";
    NSString *localized = [move localizedText];
    if (localized.length) return localized;
    return [[move engineMove] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSHashTable<ChessIOSViewController *> *MBCIOSLiveGameControllers(void)
{
    static NSHashTable<ChessIOSViewController *> *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSHashTable weakObjectsHashTable]; });
    return controllers;
}

static const NSTimeInterval kMBCIOSMoveAnimationDuration = 1.0;

static MBCMove *MBCIOSCopyMove(MBCMove *source)
{
    if (!source) return nil;
    MBCMove *copy = [MBCMove moveWithCommand:source->fCommand];
    copy->fFromSquare = source->fFromSquare;
    copy->fToSquare = source->fToSquare;
    copy->fPiece = source->fPiece;
    copy->fPromotion = source->fPromotion;
    copy->fVictim = source->fVictim;
    copy->fCastling = source->fCastling;
    copy->fEnPassant = source->fEnPassant;
    copy->fCheck = source->fCheck;
    copy->fCheckMate = source->fCheckMate;
    copy->fAnimate = source->fAnimate;
    return copy;
}

static MBCSide MBCIOSHumanSideForPlayers(MBCPlayers players, MBCSideCode sideCode)
{
    /* The local player modes define their colors, as in the macOS New Game
     * sheet.  Playing is a choice only for a Game Center match. */
    (void)sideCode;
    switch (players) {
        case kHumanVsHuman:       return kBothSides;
        case kComputerVsComputer: return kNeitherSide;
        case kComputerVsHuman:    return kBlackSide;
        case kHumanVsGameCenter:  return kNeitherSide;
        case kHumanVsComputer:
        default:                  return kWhiteSide;
    }
}

static MBCSide MBCIOSEngineSideForPlayers(MBCPlayers players, MBCSideCode sideCode)
{
    if (players == kHumanVsGameCenter) return kNeitherSide;
    return MBCIOSHumanSideForPlayers(players, sideCode) == kWhiteSide
        ? kBlackSide
        : MBCIOSHumanSideForPlayers(players, sideCode) == kBlackSide
            ? kWhiteSide
            : MBCIOSHumanSideForPlayers(players, sideCode) == kBothSides
                ? kNeitherSide
                : kBothSides;
}

static NSString *MBCIOSMatchIDForMetadata(NSDictionary *metadata)
{
    NSString *matchID = [metadata[@"MatchID"] isKindOfClass:[NSString class]]
        ? metadata[@"MatchID"] : nil;
    if (!matchID.length) {
        matchID = [metadata[@"GameCenterMatchID"] isKindOfClass:[NSString class]]
            ? metadata[@"GameCenterMatchID"] : nil;
    }
    return matchID.length ? matchID : nil;
}

static MBCMoveCode MBCIOSStoredOutcome(MBCBoard *board, NSDictionary *metadata)
{
    MBCMoveCode outcome = board ? [board outcome] : kCmdNull;
    if (outcome != kCmdNull) return outcome;
    NSString *result = [metadata[@"Result"] isKindOfClass:[NSString class]]
        ? metadata[@"Result"] : nil;
    if ([result isEqualToString:@"1-0"]) return kCmdWhiteWins;
    if ([result isEqualToString:@"0-1"]) return kCmdBlackWins;
    if ([result isEqualToString:@"1/2-1/2"]) return kCmdDraw;
    return kCmdNull;
}

static MBCPlayers MBCIOSPlayersForHumanSide(MBCSide side)
{
    switch (side) {
        case kWhiteSide:   return kHumanVsComputer;
        case kBlackSide:   return kComputerVsHuman;
        case kNeitherSide: return kComputerVsComputer;
        case kBothSides:
        default:           return kHumanVsHuman;
    }
}

static BOOL MBCIOSPlayerTypeIsHuman(NSString *type, BOOL *known)
{
    NSString *lowercase = [type isKindOfClass:[NSString class]] ? type.lowercaseString : nil;
    if ([lowercase isEqualToString:@"human"] || [lowercase isEqualToString:@"user"]) {
        if (known) *known = YES;
        return YES;
    }
    if ([lowercase isEqualToString:@"program"] || [lowercase isEqualToString:@"computer"]) {
        if (known) *known = YES;
        return NO;
    }
    if (known) *known = NO;
    return NO;
}

static BOOL MBCIOSPlayersMatchHumanSide(MBCPlayers players, MBCSide side)
{
    switch (players) {
        case kHumanVsHuman:       return side == kBothSides;
        case kComputerVsComputer: return side == kNeitherSide;
        case kHumanVsComputer:
        case kComputerVsHuman:    return side == kWhiteSide || side == kBlackSide;
        case kHumanVsGameCenter:  return NO;
    }
    return NO;
}

@interface MBCIOSNewGameViewController : UITableViewController
- (instancetype)initWithVariant:(MBCVariant)variant
                         players:(MBCPlayers)players
                        sideCode:(MBCSideCode)sideCode
                      searchTime:(NSInteger)searchTime
                      completion:(MBCIOSNewGameCompletion)completion;
@end

@interface MBCIOSNewGameViewController ()
@property (nonatomic) MBCVariant selectedVariant;
@property (nonatomic) MBCPlayers selectedPlayers;
@property (nonatomic) MBCSideCode selectedSideCode;
@property (nonatomic) NSInteger selectedSearchTime;
@property (nonatomic, copy) MBCIOSNewGameCompletion completion;
@property (nonatomic, strong) UITableViewCell *strengthCell;
@property (nonatomic, strong) UISlider *strengthSlider;
@property (nonatomic, strong) UILabel *strengthDescription;
@property (nonatomic, strong) UISwitch *rotateAfterMoveSwitch;
@property (nonatomic, strong) UISwitch *confirmNextTurnSwitch;
@property (nonatomic, strong) UISwitch *keepDisplayAwakeSwitch;
@end

@implementation MBCIOSNewGameViewController

- (instancetype)initWithVariant:(MBCVariant)variant
                         players:(MBCPlayers)players
                        sideCode:(MBCSideCode)sideCode
                      searchTime:(NSInteger)searchTime
                      completion:(MBCIOSNewGameCompletion)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _selectedVariant = (variant >= kVarNormal && variant <= kVarLosers) ? variant : kVarNormal;
        _selectedPlayers = (players >= kHumanVsHuman && players <= kHumanVsGameCenter) ? players : kHumanVsHuman;
        _selectedSideCode = (sideCode >= kPlayWhite && sideCode <= kPlayEither) ? sideCode : kPlayEither;
        _selectedSearchTime = MAX(1, MIN(12, searchTime));
        _completion = [completion copy];
        self.preferredContentSize = CGSizeMake(460.0, 540.0);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = MBCIOSLocalizedString(@"ios_new_game_name_default", @"New Game");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                style:UIBarButtonItemStylePlain target:self action:@selector(cancelAction:)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel =
        MBCIOSLocalizedString(@"ios_cancel_new_game", @"Cancel new game");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:MBCIOSLocalizedString(@"ios_start", @"Start")
                style:UIBarButtonItemStyleDone target:self action:@selector(startAction:)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel =
        MBCIOSLocalizedString(@"ios_start_new_game", @"Start new game");

    self.rotateAfterMoveSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.rotateAfterMoveSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:kMBCAutoRotateBoard];
    self.confirmNextTurnSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.keepDisplayAwakeSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];

    self.strengthCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:nil];
    self.strengthCell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIStackView *strengthStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    strengthStack.translatesAutoresizingMaskIntoConstraints = NO;
    strengthStack.axis = UILayoutConstraintAxisVertical;
    strengthStack.spacing = 8.0;
    [self.strengthCell.contentView addSubview:strengthStack];
    UILayoutGuide *margins = self.strengthCell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [strengthStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [strengthStack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [strengthStack.topAnchor constraintEqualToAnchor:margins.topAnchor constant:4.0],
        [strengthStack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-4.0]
    ]];

    self.strengthSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.strengthSlider.minimumValue = 1.0;
    self.strengthSlider.maximumValue = 12.0;
    self.strengthSlider.continuous = YES;
    self.strengthSlider.value = (float)self.selectedSearchTime;
    self.strengthSlider.accessibilityLabel = MBCIOSLocalizedString(@"ios_computer_strength", @"Computer strength");
    self.strengthSlider.accessibilityValue = MBCIOSStrengthTitle(self.selectedSearchTime);
    [self.strengthSlider addTarget:self action:@selector(strengthChanged:) forControlEvents:UIControlEventValueChanged];
    [strengthStack addArrangedSubview:self.strengthSlider];

    UIStackView *rangeLabels = [[UIStackView alloc] initWithFrame:CGRectZero];
    rangeLabels.axis = UILayoutConstraintAxisHorizontal;
    rangeLabels.distribution = UIStackViewDistributionEqualSpacing;
    rangeLabels.spacing = 12.0;
    UILabel *faster = [[UILabel alloc] initWithFrame:CGRectZero];
    faster.text = MBCIOSLocalizedString(@"ios_faster", @"Faster");
    faster.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    faster.adjustsFontForContentSizeCategory = YES;
    faster.numberOfLines = 0;
    faster.textColor = UIColor.secondaryLabelColor;
    UILabel *stronger = [[UILabel alloc] initWithFrame:CGRectZero];
    stronger.text = MBCIOSLocalizedString(@"ios_stronger", @"Stronger");
    stronger.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    stronger.adjustsFontForContentSizeCategory = YES;
    stronger.numberOfLines = 0;
    stronger.textAlignment = NSTextAlignmentRight;
    stronger.textColor = UIColor.secondaryLabelColor;
    [rangeLabels addArrangedSubview:faster];
    [rangeLabels addArrangedSubview:stronger];
    [strengthStack addArrangedSubview:rangeLabels];

    self.strengthDescription = [[UILabel alloc] initWithFrame:CGRectZero];
    self.strengthDescription.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.strengthDescription.adjustsFontForContentSizeCategory = YES;
    self.strengthDescription.textColor = UIColor.secondaryLabelColor;
    self.strengthDescription.numberOfLines = 0;
    self.strengthDescription.text = MBCIOSStrengthTitle(self.selectedSearchTime);
    [strengthStack addArrangedSubview:self.strengthDescription];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.selectedPlayers == kHumanVsGameCenter ? 1 : 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) return self.selectedPlayers == kHumanVsGameCenter ? 3 : 2;
    return self.selectedPlayers == kHumanVsHuman ? 3 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) return MBCIOSLocalizedString(@"ios_start_new_game_title", @"Start a New Game?");
    return self.selectedPlayers == kHumanVsHuman
        ? MBCIOSLocalizedString(@"ios_shared_board_options", @"Shared Board Options")
        : MBCIOSLocalizedString(@"ios_computer_strength", @"Computer strength");
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (indexPath.section == 1 && self.selectedPlayers != kHumanVsHuman) return self.strengthCell;

    if (indexPath.section == 0) {
        NSArray<NSString *> *titles = @[
            MBCIOSLocalizedString(@"ios_variant_label", @"Variant"),
            MBCIOSLocalizedString(@"ios_players_label", @"Players"),
            MBCIOSLocalizedString(@"ios_side_label", @"Playing")
        ];
        NSArray<NSString *> *values = @[MBCIOSVariantTitle(self.selectedVariant),
            MBCIOSPlayersTitle(self.selectedPlayers), MBCIOSSideCodeTitle(self.selectedSideCode)];
        UIFont *bodyFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        NSDictionary *attributes = @{ NSFontAttributeName: bodyFont };
        CGFloat textWidth = [titles[(NSUInteger)indexPath.row] sizeWithAttributes:attributes].width +
            [values[(NSUInteger)indexPath.row] sizeWithAttributes:attributes].width;
        BOOL stacksValue = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ||
            textWidth > CGRectGetWidth(tableView.bounds) - 100.0;
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:stacksValue ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1
          reuseIdentifier:nil];
        cell.textLabel.text = titles[(NSUInteger)indexPath.row];
        cell.textLabel.font = bodyFont;
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.detailTextLabel.text = values[(NSUInteger)indexPath.row];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:stacksValue
            ? UIFontTextStyleSubheadline : UIFontTextStyleBody];
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityLabel = cell.textLabel.text;
        cell.accessibilityValue = cell.detailTextLabel.text;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray<NSString *> *titles = @[
        MBCIOSLocalizedString(@"ios_rotate_after_move_row", @"Rotate after each move"),
        MBCIOSLocalizedString(@"ios_confirm_next_turn", @"Confirm Next Turn"),
        MBCIOSLocalizedString(@"ios_keep_display_awake", @"Keep Display Awake While Playing")
    ];
    NSArray<UISwitch *> *controls = @[self.rotateAfterMoveSwitch,
        self.confirmNextTurnSwitch, self.keepDisplayAwakeSwitch];
    cell.textLabel.text = titles[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    UISwitch *control = controls[(NSUInteger)indexPath.row];
    control.accessibilityLabel = cell.textLabel.text;
    cell.accessoryView = control;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == 0) [self selectVariant:cell];
    else if (indexPath.row == 1) [self selectPlayers:cell];
    else [self selectSide:cell];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory
        isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.tableView reloadData];
    }
}

- (void)presentChoiceSheetFromCell:(UITableViewCell *)cell
                          options:(NSArray<NSString *> *)options
                        selection:(NSInteger)selection
                         callback:(void (^)(NSInteger index))callback
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:cell.textLabel.text
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger index = 0; index < options.count; ++index) {
        [sheet addAction:[UIAlertAction actionWithTitle:options[index]
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            callback((NSInteger)index);
        }]];
        sheet.actions[index].enabled = ((NSInteger)index != selection);
    }
    [sheet addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = self.tableView;
    popover.sourceRect = [self.tableView convertRect:cell.bounds fromView:cell];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)selectVariant:(UITableViewCell *)sender
{
    NSArray<NSString *> *options = @[MBCIOSVariantTitle(kVarNormal), MBCIOSVariantTitle(kVarCrazyhouse),
                                     MBCIOSVariantTitle(kVarSuicide), MBCIOSVariantTitle(kVarLosers)];
    [self presentChoiceSheetFromCell:sender options:options selection:self.selectedVariant callback:^(NSInteger index) {
        self.selectedVariant = (MBCVariant)index;
        [self.tableView reloadData];
    }];
}

- (void)selectPlayers:(UITableViewCell *)sender
{
    NSArray<NSString *> *options = @[MBCIOSPlayersTitle(kHumanVsHuman), MBCIOSPlayersTitle(kHumanVsComputer),
                                     MBCIOSPlayersTitle(kComputerVsHuman), MBCIOSPlayersTitle(kComputerVsComputer),
                                     MBCIOSPlayersTitle(kHumanVsGameCenter)];
    [self presentChoiceSheetFromCell:sender options:options selection:self.selectedPlayers callback:^(NSInteger index) {
        self.selectedPlayers = (MBCPlayers)index;
        [self.tableView reloadData];
    }];
}

- (void)selectSide:(UITableViewCell *)sender
{
    NSArray<NSString *> *options = @[MBCIOSSideCodeTitle(kPlayWhite), MBCIOSSideCodeTitle(kPlayBlack),
                                     MBCIOSSideCodeTitle(kPlayEither)];
    [self presentChoiceSheetFromCell:sender options:options selection:self.selectedSideCode callback:^(NSInteger index) {
        self.selectedSideCode = (MBCSideCode)index;
        [self.tableView reloadData];
    }];
}

- (void)strengthChanged:(UISlider *)sender
{
    self.selectedSearchTime = MAX(1, MIN(12, (NSInteger)lroundf(sender.value)));
    sender.value = (float)self.selectedSearchTime;
    self.strengthDescription.text = MBCIOSStrengthTitle(self.selectedSearchTime);
    sender.accessibilityValue = self.strengthDescription.text;
}

- (void)cancelAction:(UIBarButtonItem *)sender
{
    (void)sender;
    if (self.completion) self.completion(NO, self.selectedVariant, self.selectedPlayers,
        self.selectedSideCode, self.selectedSearchTime, self.rotateAfterMoveSwitch.isOn,
        self.confirmNextTurnSwitch.isOn, self.keepDisplayAwakeSwitch.isOn);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)startAction:(UIBarButtonItem *)sender
{
    sender.enabled = NO;
    MBCIOSNewGameCompletion completion = self.completion;
    MBCVariant variant = self.selectedVariant;
    MBCPlayers players = self.selectedPlayers;
    MBCSideCode sideCode = self.selectedPlayers == kHumanVsGameCenter
        ? self.selectedSideCode : self.selectedPlayers == kComputerVsHuman
            ? kPlayBlack : kPlayWhite;
    NSInteger searchTime = self.selectedSearchTime;
    BOOL rotateAfterMove = self.rotateAfterMoveSwitch.isOn;
    BOOL confirmNextTurn = self.confirmNextTurnSwitch.isOn;
    BOOL keepDisplayAwake = self.keepDisplayAwakeSwitch.isOn;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(YES, variant, players, sideCode, searchTime,
            rotateAfterMove, confirmNextTurn, keepDisplayAwake);
    }];
}

@end

typedef void (^MBCIOSSharedBoardOptionsCompletion)(BOOL rotateAfterMove,
    BOOL confirmNextTurn, BOOL keepDisplayAwake);

@interface MBCIOSSharedBoardOptionsViewController : UITableViewController
- (instancetype)initWithRotateAfterMove:(BOOL)rotateAfterMove
                       confirmNextTurn:(BOOL)confirmNextTurn
                      keepDisplayAwake:(BOOL)keepDisplayAwake
                            completion:(MBCIOSSharedBoardOptionsCompletion)completion;
@end

@interface MBCIOSSharedBoardOptionsViewController ()
@property (nonatomic, strong) UISwitch *rotateSwitch;
@property (nonatomic, strong) UISwitch *handoffSwitch;
@property (nonatomic, strong) UISwitch *awakeSwitch;
@property (nonatomic, copy) MBCIOSSharedBoardOptionsCompletion completion;
@end

@implementation MBCIOSSharedBoardOptionsViewController

- (instancetype)initWithRotateAfterMove:(BOOL)rotateAfterMove
                       confirmNextTurn:(BOOL)confirmNextTurn
                      keepDisplayAwake:(BOOL)keepDisplayAwake
                            completion:(MBCIOSSharedBoardOptionsCompletion)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _rotateSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _handoffSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _awakeSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _rotateSwitch.on = rotateAfterMove;
    _handoffSwitch.on = confirmNextTurn;
    _awakeSwitch.on = keepDisplayAwake;
    _completion = [completion copy];
    self.preferredContentSize = CGSizeMake(420.0, 330.0);
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = MBCIOSLocalizedString(@"ios_shared_board_options", @"Shared Board Options");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60.0;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self action:@selector(cancelAction:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(doneAction:)];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return 3;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString * const cellIdentifier = @"SharedBoardOption";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:cellIdentifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray<NSString *> *titles = @[
        MBCIOSLocalizedString(@"ios_rotate_after_move_row", @"Rotate after each move"),
        MBCIOSLocalizedString(@"ios_confirm_next_turn", @"Confirm Next Turn"),
        MBCIOSLocalizedString(@"ios_keep_display_awake", @"Keep Display Awake While Playing")
    ];
    NSArray<UISwitch *> *controls = @[self.rotateSwitch, self.handoffSwitch, self.awakeSwitch];
    cell.textLabel.text = titles[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    UISwitch *control = controls[(NSUInteger)indexPath.row];
    control.accessibilityLabel = cell.textLabel.text;
    cell.accessoryView = control;
    return cell;
}

- (void)cancelAction:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doneAction:(id)sender
{
    (void)sender;
    MBCIOSSharedBoardOptionsCompletion completion = self.completion;
    BOOL rotate = self.rotateSwitch.isOn;
    BOOL handoff = self.handoffSwitch.isOn;
    BOOL awake = self.awakeSwitch.isOn;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(rotate, handoff, awake);
    }];
}

@end

static NSArray<NSString *> *MBCIOSGamePreferenceKeys(void)
{
    return @[kMBCSpeakMoves, kMBCSpeakHumanMoves, kMBCDefaultVoice,
        kMBCAlternateVoice, kMBCSearchTime, kMBCBoardAngle, kMBCBoardSpin,
        kMBCShowEdgeNotation];
}

static void MBCIOSFillGamePreferences(NSMutableDictionary *metadata)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in MBCIOSGamePreferenceKeys()) {
        id value = metadata[key];
        BOOL voice = [key isEqualToString:kMBCDefaultVoice] || [key isEqualToString:kMBCAlternateVoice];
        if (voice ? ![value isKindOfClass:NSString.class] : ![value respondsToSelector:@selector(floatValue)])
            metadata[key] = [defaults objectForKey:key] ?: (voice ? @"" :
                ([key isEqualToString:kMBCShowEdgeNotation] ? @YES : @0));
    }
    metadata[kMBCSearchTime] = @(MAX(1, MIN(12, [metadata[kMBCSearchTime] integerValue])));
}

static NSArray<NSString *> *MBCIOSBoardStyleNames(void)
{
    return @[ @"Wood", @"Marble", @"Metal", @"Grass" ];
}

static NSArray<NSString *> *MBCIOSPieceStyleNames(void)
{
    return @[ @"Wood", @"Marble", @"Metal", @"Fur" ];
}

static NSArray<NSString *> *MBCIOSStyleDisplayNames(NSArray<NSString *> *styles)
{
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:styles.count];
    for (NSString *style in styles) [names addObject:MBCIOSLocalizedString(style, style)];
    return names;
}

@interface MBCIOSVoicePickerViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithTitle:(NSString *)title selectedIdentifier:(NSString *)identifier
                   completion:(void (^)(NSString *identifier))completion;
@end

@interface MBCIOSVoicePickerViewController ()
@property (nonatomic, strong) MBCIOSSpeechController *previewSpeech;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *choices;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *filteredChoices;
@property (nonatomic, copy) NSString *selectedIdentifier;
@property (nonatomic, copy) void (^completion)(NSString *identifier);
@end

@implementation MBCIOSVoicePickerViewController

- (instancetype)initWithTitle:(NSString *)title selectedIdentifier:(NSString *)identifier
                   completion:(void (^)(NSString *identifier))completion
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (!self) return nil;
    self.title = title;
    _selectedIdentifier = [identifier copy] ?: @"";
    _completion = [completion copy];
    MBCBoard *previewBoard = [[MBCBoard alloc] init];
    [previewBoard startGame:kVarNormal];
    _previewSpeech = [[MBCIOSSpeechController alloc] initWithBoard:previewBoard];
    _choices = [MBCIOSSpeechController availableVoiceChoices];
    _filteredChoices = _choices;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.previewSpeech stop];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) {
        self.filteredChoices = self.choices;
    } else {
        self.filteredChoices = [self.choices filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice, NSDictionary *bindings) {
                (void)bindings;
                return [choice[MBCIOSSpeechVoiceNameKey]
                    localizedCaseInsensitiveContainsString:query] ||
                    [choice[MBCIOSSpeechVoiceLanguageKey]
                    localizedCaseInsensitiveContainsString:query];
            }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return self.filteredChoices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString * const cellIdentifier = @"ChessVoiceChoice";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:cellIdentifier];
    NSDictionary *choice = self.filteredChoices[(NSUInteger)indexPath.row];
    cell.textLabel.text = choice[MBCIOSSpeechVoiceNameKey];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.accessibilityHint = MBCIOSLocalizedString(@"ios_preview_voice", @"Preview Voice");
    cell.accessibilityTraits |= UIAccessibilityTraitButton;
    cell.accessoryType = [choice[MBCIOSSpeechVoiceIdentifierKey]
        isEqualToString:self.selectedIdentifier] ?
            UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    NSString *identifier = self.filteredChoices[(NSUInteger)indexPath.row]
        [MBCIOSSpeechVoiceIdentifierKey];
    self.selectedIdentifier = identifier ?: @"";
    if (self.completion) self.completion(self.selectedIdentifier);
    [self.previewSpeech previewVoiceIdentifier:identifier];
    [tableView reloadData];
}

@end

@interface MBCIOSPreferencesViewController ()
@property (nonatomic, copy) NSString *selectedBoardStyleName;
@property (nonatomic, copy) NSString *selectedPieceStyleName;
@property (nonatomic) BOOL selectedAutoRotateBoard;
@property (nonatomic) BOOL selectedSpeakMoves;
@property (nonatomic) BOOL selectedSpeakHumanMoves;
@property (nonatomic, copy) NSString *selectedPrimaryVoiceIdentifier;
@property (nonatomic, copy) NSString *selectedAlternateVoiceIdentifier;
@property (nonatomic, copy) MBCIOSStylePairSelectionCompletion completion;
@property (nonatomic, strong, readwrite) UISegmentedControl *boardStyleControl;
@property (nonatomic, strong, readwrite) UISegmentedControl *pieceStyleControl;
@property (nonatomic, strong, readwrite) UISegmentedControl *rendererControl;
@property (nonatomic, strong, readwrite) UISwitch *autoRotateSwitch;
@property (nonatomic, strong, readwrite) UISwitch *speakMovesSwitch;
@property (nonatomic, strong, readwrite) UISwitch *speakHumanMovesSwitch;
@property (nonatomic, strong, readwrite) UIButton *primaryVoiceButton;
@property (nonatomic, strong, readwrite) UIButton *alternateVoiceButton;
@property (nonatomic, strong) UISlider *strengthSlider;
@property (nonatomic, strong) UILabel *strengthDescription;
@property (nonatomic) BOOL finished;

- (void)presentChoiceSheetFromButton:(UIButton *)button
                             options:(NSArray<NSString *> *)options
                           selection:(NSInteger)selection
                            callback:(void (^)(NSInteger index))callback;
- (UIButton *)voiceButtonWithTitle:(NSString *)title
                         identifier:(NSString *)identifier
                             action:(SEL)action;
- (void)setVoiceButton:(UIButton *)button
                 title:(NSString *)title
             identifier:(NSString *)identifier;
- (void)selectVoiceFromButton:(UIButton *)button
                        title:(NSString *)title
                   identifier:(NSString *)identifier
                   completion:(void (^)(NSString *identifier))completion;
@end

@implementation MBCIOSPreferencesViewController

- (void)setGameSettings:(NSDictionary *)settings
{
    _gameSettings = [settings copy];
    _selectedSpeakMoves = [settings[kMBCSpeakMoves] boolValue];
    _selectedSpeakHumanMoves = [settings[kMBCSpeakHumanMoves] boolValue];
    _selectedPrimaryVoiceIdentifier = [settings[kMBCDefaultVoice] copy] ?: @"";
    _selectedAlternateVoiceIdentifier = [settings[kMBCAlternateVoice] copy] ?: @"";
}

- (void)strengthChanged:(UISlider *)sender
{
    sender.value = roundf(sender.value);
    sender.accessibilityValue = MBCIOSStrengthTitle((NSInteger)sender.value);
    self.strengthDescription.text = sender.accessibilityValue;
}


- (instancetype)initWithStyleName:(NSString *)styleName
                   autoRotateBoard:(BOOL)autoRotateBoard
                        completion:(MBCIOSStyleSelectionCompletion)completion
{
    return [self initWithBoardStyle:styleName pieceStyle:styleName
                   autoRotateBoard:autoRotateBoard
                        completion:^(BOOL confirmed, NSString *boardStyle,
                                     NSString *pieceStyle, BOOL rotate) {
        (void)pieceStyle;
        if (completion) completion(confirmed, boardStyle, rotate);
    }];
}

- (instancetype)initWithBoardStyle:(NSString *)boardStyle
                       pieceStyle:(NSString *)pieceStyle
                  autoRotateBoard:(BOOL)autoRotateBoard
                       completion:(MBCIOSStylePairSelectionCompletion)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;

    NSArray<NSString *> *styles = MBCIOSBoardStyleNames();
    _selectedBoardStyleName = [styles containsObject:boardStyle] ? [boardStyle copy] : [styles firstObject];
    styles = MBCIOSPieceStyleNames();
    _selectedPieceStyleName = [styles containsObject:pieceStyle] ? [pieceStyle copy] : [styles firstObject];
    _rendererKind = MBCIOSRendererPreferences.sharedPreferences.desiredRenderer;
    _selectedAutoRotateBoard = autoRotateBoard;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _selectedSpeakMoves = [defaults objectForKey:kMBCSpeakMoves]
        ? [defaults boolForKey:kMBCSpeakMoves] : YES;
    _selectedSpeakHumanMoves = [defaults boolForKey:kMBCSpeakHumanMoves];
    _selectedPrimaryVoiceIdentifier = [[defaults stringForKey:kMBCDefaultVoice] copy] ?: @"";
    _selectedAlternateVoiceIdentifier = [[defaults stringForKey:kMBCAlternateVoice] copy] ?: @"";
    _completion = [completion copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = MBCIOSLocalizedString(@"ios_chess_preferences", @"Preferences");
    self.tableView.accessibilityLabel = self.title;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    self.preferredContentSize = CGSizeMake(440.0, 450.0);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                       target:self
                                                       action:@selector(cancelAction:)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(doneAction:)];

    self.rendererControl = [[UISegmentedControl alloc] initWithItems:@[@"Metal", @"OpenGL"]];
    self.rendererControl.accessibilityLabel = NSLocalizedString(@"Renderer", nil);
    self.rendererControl.accessibilityIdentifier = @"ChessPreferencesRenderer";
    self.rendererControl.selectedSegmentIndex = self.rendererKind;
    [self.rendererControl addTarget:self action:@selector(rendererChanged:) forControlEvents:UIControlEventValueChanged];
    self.boardStyleControl = [[UISegmentedControl alloc] initWithItems:MBCIOSStyleDisplayNames(MBCIOSBoardStyleNames())];
    self.boardStyleControl.accessibilityLabel = MBCIOSLocalizedString(@"ios_board_style", @"Board");
    self.boardStyleControl.accessibilityIdentifier = @"ChessPreferencesBoardStyle";
    self.boardStyleControl.selectedSegmentIndex =
        [MBCIOSBoardStyleNames() indexOfObject:self.selectedBoardStyleName];
    [self.boardStyleControl addTarget:self
                          action:@selector(styleChanged:)
                forControlEvents:UIControlEventValueChanged];

    self.pieceStyleControl = [[UISegmentedControl alloc] initWithItems:MBCIOSStyleDisplayNames(MBCIOSPieceStyleNames())];
    self.pieceStyleControl.accessibilityLabel = MBCIOSLocalizedString(@"ios_piece_style", @"Pieces");
    self.pieceStyleControl.accessibilityIdentifier = @"ChessPreferencesPieceStyle";
    self.pieceStyleControl.selectedSegmentIndex =
        [MBCIOSPieceStyleNames() indexOfObject:self.selectedPieceStyleName];
    [self.pieceStyleControl addTarget:self action:@selector(pieceStyleChanged:)
                     forControlEvents:UIControlEventValueChanged];

    self.autoRotateSwitch = [[UISwitch alloc] init];
    self.autoRotateSwitch.accessibilityLabel = MBCIOSLocalizedString(@"ios_rotate_board_after_move", @"Rotate board after each move");
    self.autoRotateSwitch.accessibilityIdentifier = @"ChessPreferencesAutoRotate";
    self.autoRotateSwitch.on = self.selectedAutoRotateBoard;
    [self.autoRotateSwitch addTarget:self
                              action:@selector(autoRotateChanged:)
                    forControlEvents:UIControlEventValueChanged];

    self.speakMovesSwitch = [[UISwitch alloc] init];
    self.speakMovesSwitch.accessibilityLabel = MBCIOSLocalizedString(@"ios_speak_computer_moves", @"Speak Computer Moves");
    self.speakMovesSwitch.accessibilityIdentifier = @"ChessPreferencesSpeakComputerMoves";
    self.speakMovesSwitch.on = self.selectedSpeakMoves;
    [self.speakMovesSwitch addTarget:self
                              action:@selector(speakMovesChanged:)
                    forControlEvents:UIControlEventValueChanged];

    self.speakHumanMovesSwitch = [[UISwitch alloc] init];
    self.speakHumanMovesSwitch.accessibilityLabel = MBCIOSLocalizedString(@"ios_speak_human_moves", @"Speak Human Moves");
    self.speakHumanMovesSwitch.accessibilityIdentifier = @"ChessPreferencesSpeakHumanMoves";
    self.speakHumanMovesSwitch.on = self.selectedSpeakHumanMoves;
    [self.speakHumanMovesSwitch addTarget:self
                                   action:@selector(speakHumanMovesChanged:)
                         forControlEvents:UIControlEventValueChanged];

    self.primaryVoiceButton = [self voiceButtonWithTitle:MBCIOSLocalizedString(@"ios_primary_voice", @"Primary Voice")
                                                  identifier:self.selectedPrimaryVoiceIdentifier
                                                      action:@selector(selectPrimaryVoice:)];
    self.alternateVoiceButton = [self voiceButtonWithTitle:MBCIOSLocalizedString(@"ios_alternate_voice", @"Alternate Voice")
                                                    identifier:self.selectedAlternateVoiceIdentifier
                                                        action:@selector(selectAlternateVoice:)];
    [self rendererChanged:self.rendererControl];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.showsComputerStrength ? 3 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 2) return MBCIOSLocalizedString(@"ios_computer_strength", @"Computer strength");
    return section == 0 ? MBCIOSLocalizedString(@"ios_board_piece_style", @"Style") :
        MBCIOSLocalizedString(@"ios_speech", @"Speech");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 3 : section == 1 ? 4 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? NSLocalizedString(@"Renderer applies to all windows. Grass boards and Fur pieces use Wood with Metal.", nil) : nil;
}

- (void)rendererChanged:(UISegmentedControl *)sender
{
    self.rendererKind = sender.selectedSegmentIndex == 1 ? MBCIOSRendererOpenGL : MBCIOSRendererMetal;
    BOOL legacy = self.rendererKind == MBCIOSRendererOpenGL;
    [self.boardStyleControl setEnabled:legacy forSegmentAtIndex:3];
    [self.pieceStyleControl setEnabled:legacy forSegmentAtIndex:3];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!self.strengthSlider) {
            self.strengthSlider = [[UISlider alloc] init];
            self.strengthSlider.minimumValue = 1;
            self.strengthSlider.maximumValue = 12;
            self.strengthSlider.value = MAX(1, MIN(12, [self.gameSettings[kMBCSearchTime] integerValue]));
            self.strengthSlider.accessibilityLabel = MBCIOSLocalizedString(@"ios_computer_strength", @"Computer strength");
            [self.strengthSlider addTarget:self action:@selector(strengthChanged:) forControlEvents:UIControlEventValueChanged];
            self.strengthDescription = [[UILabel alloc] init];
            self.strengthDescription.numberOfLines = 0;
            self.strengthDescription.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            self.strengthDescription.adjustsFontForContentSizeCategory = YES;
            [self strengthChanged:self.strengthSlider];
        }
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.strengthSlider, self.strengthDescription]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];
        UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor]
        ]];
        return cell;
    }
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = NSLocalizedString(@"Renderer", nil);
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = self.rendererControl;
            return cell;
        }
        BOOL boardStyle = indexPath.row == 1;
        NSString *identifier = boardStyle ? @"ChessBoardStyleRow" : @"ChessPieceStyleRow";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:identifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.tag = 101;
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            label.adjustsFontForContentSizeCategory = YES;
            label.numberOfLines = 0;
            [cell.contentView addSubview:label];
            UISegmentedControl *control = boardStyle ? self.boardStyleControl : self.pieceStyleControl;
            control.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:control];
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [label.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
                [control.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [control.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [control.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8.0],
                [control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0]
            ]];
        }
        UILabel *label = [cell.contentView viewWithTag:101];
        label.text = boardStyle ? MBCIOSLocalizedString(@"ios_board_style", @"Board") :
            MBCIOSLocalizedString(@"ios_piece_style", @"Pieces");
        return cell;
    }

    BOOL voiceRow = indexPath.row >= 2;
    NSString *identifier = voiceRow ? @"ChessPreferenceVoiceRow" : @"ChessPreferenceSwitchRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc]
        initWithStyle:voiceRow ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault
      reuseIdentifier:identifier];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    if (voiceRow) {
        BOOL primary = indexPath.row == 2;
        cell.textLabel.text = primary ? MBCIOSLocalizedString(@"ios_primary_voice", @"Primary Voice") :
            MBCIOSLocalizedString(@"ios_alternate_voice", @"Alternate Voice");
        cell.detailTextLabel.text = [MBCIOSSpeechController displayNameForVoiceIdentifier:
            primary ? self.selectedPrimaryVoiceIdentifier : self.selectedAlternateVoiceIdentifier];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = indexPath.row == 0 ?
            MBCIOSLocalizedString(@"ios_speak_computer_moves", @"Speak Computer Moves") :
            MBCIOSLocalizedString(@"ios_speak_human_moves", @"Speak Human Moves");
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = indexPath.row == 0 ? self.speakMovesSwitch : self.speakHumanMovesSwitch;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    if (indexPath.row == 2) [self selectPrimaryVoice:self.primaryVoiceButton];
    else if (indexPath.row == 3) [self selectAlternateVoice:self.alternateVoiceButton];
}

- (void)autoRotateChanged:(UISwitch *)sender
{
    self.selectedAutoRotateBoard = sender.isOn;
}

- (void)styleChanged:(UISegmentedControl *)sender
{
    NSArray<NSString *> *styles = MBCIOSBoardStyleNames();
    NSInteger index = sender.selectedSegmentIndex;
    if (index >= 0 && index < (NSInteger)styles.count) {
        self.selectedBoardStyleName = styles[index];
    }
}

- (void)pieceStyleChanged:(UISegmentedControl *)sender
{
    NSArray<NSString *> *styles = MBCIOSPieceStyleNames();
    NSInteger index = sender.selectedSegmentIndex;
    if (index >= 0 && index < (NSInteger)styles.count) {
        self.selectedPieceStyleName = styles[index];
    }
}

- (void)presentChoiceSheetFromButton:(UIButton *)button
                             options:(NSArray<NSString *> *)options
                           selection:(NSInteger)selection
                            callback:(void (^)(NSInteger index))callback
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:button.accessibilityLabel
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger index = 0; index < options.count; ++index) {
        [sheet addAction:[UIAlertAction actionWithTitle:options[index]
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            (void)action;
            callback((NSInteger)index);
        }]];
        sheet.actions[index].enabled = ((NSInteger)index != selection);
    }
    [sheet addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                                                style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.sourceView = button;
    popover.sourceRect = button.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UIButton *)voiceButtonWithTitle:(NSString *)title
                          identifier:(NSString *)identifier
                              action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    button.accessibilityLabel = title;
    button.accessibilityIdentifier = [title isEqualToString:MBCIOSLocalizedString(@"ios_primary_voice", @"Primary Voice")]
        ? @"ChessPreferencesPrimaryVoice" : @"ChessPreferencesAlternateVoice";
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:170.0].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self setVoiceButton:button title:title identifier:identifier];
    return button;
}

- (void)setVoiceButton:(UIButton *)button title:(NSString *)title identifier:(NSString *)identifier
{
    NSString *voiceName = [MBCIOSSpeechController displayNameForVoiceIdentifier:identifier];
    [button setTitle:voiceName forState:UIControlStateNormal];
    button.accessibilityLabel = title;
    button.accessibilityValue = voiceName;
}

- (void)selectVoiceFromButton:(UIButton *)button
                    title:(NSString *)title
              identifier:(NSString *)identifier
               completion:(void (^)(NSString *identifier))completion
{
    (void)button;
    MBCIOSVoicePickerViewController *picker = [[MBCIOSVoicePickerViewController alloc]
        initWithTitle:title selectedIdentifier:identifier completion:completion];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)selectPrimaryVoice:(UIButton *)sender
{
    [self selectVoiceFromButton:sender
                          title:MBCIOSLocalizedString(@"ios_primary_voice", @"Primary Voice")
                    identifier:self.selectedPrimaryVoiceIdentifier
                     completion:^(NSString *identifier) {
        self.selectedPrimaryVoiceIdentifier = [identifier copy];
        [self setVoiceButton:self.primaryVoiceButton
                       title:MBCIOSLocalizedString(@"ios_primary_voice", @"Primary Voice")
                  identifier:identifier];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:2 inSection:1]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)selectAlternateVoice:(UIButton *)sender
{
    [self selectVoiceFromButton:sender
                          title:MBCIOSLocalizedString(@"ios_alternate_voice", @"Alternate Voice")
                    identifier:self.selectedAlternateVoiceIdentifier
                     completion:^(NSString *identifier) {
        self.selectedAlternateVoiceIdentifier = [identifier copy];
        [self setVoiceButton:self.alternateVoiceButton
                       title:MBCIOSLocalizedString(@"ios_alternate_voice", @"Alternate Voice")
                  identifier:identifier];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:3 inSection:1]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)speakMovesChanged:(UISwitch *)sender
{
    self.selectedSpeakMoves = sender.isOn;
}

- (void)speakHumanMovesChanged:(UISwitch *)sender
{
    self.selectedSpeakHumanMoves = sender.isOn;
}

- (void)doneAction:(id)sender
{
    (void)sender;
    [self commitSelection];
}

- (void)cancelAction:(id)sender
{
    (void)sender;
    [self cancelSelection];
}

- (void)commitSelection
{
    if (self.finished) return;
    if (self.rendererControl) [self rendererChanged:self.rendererControl];
    if (self.rendererCompletion && !self.rendererCompletion(self.rendererKind)) return;
    self.rendererCompletion = nil;
    /* Keep programmatic and touch-driven selection paths identical. UIKit
     * sends ValueChanged for a tap, while state restoration
     * may set the selected segment directly. */
    if (self.boardStyleControl) [self styleChanged:self.boardStyleControl];
    if (self.pieceStyleControl) [self pieceStyleChanged:self.pieceStyleControl];
    if (self.autoRotateSwitch) [self autoRotateChanged:self.autoRotateSwitch];
    if (self.speakMovesSwitch) [self speakMovesChanged:self.speakMovesSwitch];
    if (self.speakHumanMovesSwitch) [self speakHumanMovesChanged:self.speakHumanMovesSwitch];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:self.selectedSpeakMoves forKey:kMBCSpeakMoves];
    [defaults setBool:self.selectedSpeakHumanMoves forKey:kMBCSpeakHumanMoves];
    [defaults setObject:self.selectedPrimaryVoiceIdentifier ?: @"" forKey:kMBCDefaultVoice];
    [defaults setObject:self.selectedAlternateVoiceIdentifier ?: @"" forKey:kMBCAlternateVoice];
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    settings[kMBCSpeakMoves] = @(self.selectedSpeakMoves);
    settings[kMBCSpeakHumanMoves] = @(self.selectedSpeakHumanMoves);
    settings[kMBCDefaultVoice] = self.selectedPrimaryVoiceIdentifier ?: @"";
    settings[kMBCAlternateVoice] = self.selectedAlternateVoiceIdentifier ?: @"";
    if (self.showsComputerStrength) {
        NSInteger strength = self.strengthSlider ? (NSInteger)roundf(self.strengthSlider.value) :
            MAX(1, MIN(12, [self.gameSettings[kMBCSearchTime] integerValue]));
        settings[kMBCSearchTime] = @(strength);
        [defaults setInteger:strength forKey:kMBCSearchTime];
    }
    if (self.settingsCompletion) self.settingsCompletion(settings);
    self.settingsCompletion = nil;
    self.finished = YES;
    MBCIOSStylePairSelectionCompletion completion = self.completion;
    self.completion = nil;
    if (completion) completion(YES, self.selectedBoardStyleName,
                               self.selectedPieceStyleName, self.selectedAutoRotateBoard);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancelSelection
{
    if (self.finished) return;
    self.finished = YES;
    self.rendererCompletion = nil;
    MBCIOSStylePairSelectionCompletion completion = self.completion;
    self.completion = nil;
    if (completion) completion(NO, nil, nil, self.selectedAutoRotateBoard);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

/* Keep the full command name below its symbol in the floating command group. */
@interface MBCIOSCommandButton : UIButton
@end

@implementation MBCIOSCommandButton

- (void)layoutSubviews
{
    [super layoutSubviews];

    UIImageView *imageView = self.imageView;
    UILabel *titleLabel = self.titleLabel;
    if (!imageView || !titleLabel || !imageView.image) return;

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (height < 55.0) {
        imageView.frame = CGRectMake((width - 23.0) * 0.5, (height - 23.0) * 0.5,
                                     23.0, 23.0);
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        titleLabel.hidden = YES;
        return;
    }
    BOOL horizontal = width >= 120.0 &&
        UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    CGFloat titleWidth = horizontal ? MAX(0.0, width - 46.0) : MAX(0.0, width - 8.0);
    CGSize required = [self.currentTitle boundingRectWithSize:CGSizeMake(titleWidth, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
        attributes:@{ NSFontAttributeName: titleLabel.font } context:nil].size;
    if (required.height > ceil(titleLabel.font.lineHeight * 2.0) + 1.0) {
        // The full command remains in the button's accessibility label and
        // its menu. A clipped command name would be misleading here.
        imageView.frame = CGRectMake((width - 23.0) * 0.5, (height - 23.0) * 0.5,
                                     23.0, 23.0);
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        titleLabel.hidden = YES;
        return;
    }
    titleLabel.hidden = NO;
    if (horizontal) {
        CGFloat iconSide = 23.0;
        imageView.frame = CGRectMake(10.0, (height - iconSide) * 0.5,
                                     iconSide, iconSide);
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        titleLabel.frame = CGRectMake(40.0, 4.0, MAX(0.0, width - 46.0), height - 8.0);
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 2;
        titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        return;
    }
    CGFloat iconSide = MIN(23.0, MAX(18.0, height * 0.34));
    CGSize sourceSize = imageView.image.size;
    CGFloat scale = (sourceSize.width > 0.0 && sourceSize.height > 0.0)
        ? MIN(iconSide / sourceSize.width, iconSide / sourceSize.height)
        : 1.0;
    CGSize imageSize = CGSizeMake(sourceSize.width * scale, sourceSize.height * scale);
    CGFloat imageTop = 5.0;
    imageView.frame = CGRectMake((width - imageSize.width) * 0.5,
                                 imageTop,
                                 imageSize.width,
                                 imageSize.height);
    imageView.contentMode = UIViewContentModeScaleAspectFit;

    CGFloat titleTop = CGRectGetMaxY(imageView.frame) + 2.0;
    titleLabel.frame = CGRectMake(4.0,
                                  titleTop,
                                  MAX(0.0, width - 8.0),
                                  MAX(0.0, height - titleTop - 3.0));
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 2;
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.65;
}

@end

typedef void (^MBCIOSPanelActionHandler)(void);

@interface MBCIOSActionPanelViewController : UITableViewController
- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections;
@end

@interface MBCIOSActionPanelViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@end

@implementation MBCIOSActionPanelViewController

- (instancetype)initWithSections:(NSArray<NSDictionary *> *)sections
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _sections = [sections copy];
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        self.preferredContentSize = CGSizeMake(420.0, 620.0);
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (!self.title.length) self.title = MBCIOSLocalizedString(@"ios_game_actions", @"Moves");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 50.0;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(closeAction:)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return [self.sections[section][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return self.sections[section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString * const identifier = @"ChessCommandRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:identifier];
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    BOOL enabled = [item[@"enabled"] boolValue];
    NSString *subtitle = item[@"subtitle"];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textColor = enabled ? UIColor.labelColor : UIColor.tertiaryLabelColor;
    cell.detailTextLabel.text = subtitle;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = enabled ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
    UIImage *symbol = [UIImage systemImageNamed:item[@"symbol"] ?: @"circle"];
    if (!symbol) symbol = [UIImage systemImageNamed:@"circle"];
    cell.imageView.image = [symbol
        imageWithConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody]];
    cell.imageView.tintColor = enabled ? self.view.tintColor : UIColor.tertiaryLabelColor;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = [item[@"selected"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityLabel = item[@"title"];
    cell.accessibilityValue = subtitle;
    cell.accessibilityHint = item[@"hint"];
    cell.accessibilityTraits = UIAccessibilityTraitButton | (enabled ? 0 : UIAccessibilityTraitNotEnabled);
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    return [item[@"enabled"] boolValue] ? indexPath : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.sections[indexPath.section][@"items"][indexPath.row];
    if (![item[@"enabled"] boolValue]) return;
    MBCIOSPanelActionHandler handler = item[@"handler"];
    UIViewController *sheet = self.navigationController ?: self;
    [sheet dismissViewControllerAnimated:YES completion:^{
        // Let UIKit finish dismissing before a command presents another sheet.
        if (handler) dispatch_async(dispatch_get_main_queue(), handler);
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    MBCIOSPanelActionHandler handler = self.sections[indexPath.section][@"items"][indexPath.row][@"deleteHandler"];
    if (!handler) return nil;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:MBCIOSLocalizedString(@"ios_delete_game", @"Delete Game")
        handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        (void)action; (void)view;
        completion(NO);
        [(self.navigationController ?: self) dismissViewControllerAnimated:YES completion:^{
            dispatch_async(dispatch_get_main_queue(), handler);
        }];
    }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)closeAction:(UIBarButtonItem *)sender
{
    (void)sender;
    UIViewController *sheet = self.navigationController ?: self;
    [sheet dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface ChessIOSViewController () <MBCIOSRendererParticipant>
@property (nonatomic, strong) MBCIOSBoardBackend *boardBackend;
@property (nonatomic, strong) MBCIOSBoardBackend *preparedBoardBackend;
@property (nonatomic, strong) MBCIOSBoardBackend *stagedBoardBackend;
@property (nonatomic) MBCIOSRendererKind requestedRenderer;
@property (nonatomic) NSUInteger rendererRevision;
@property (nonatomic) BOOL rendererChangePending;
@property (nonatomic) BOOL rendererChanging;
@property (nonatomic) BOOL recordingTransitioning;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *boardViewConstraints;
@property (nonatomic, strong) UIView *orientationTransitionCover;
@property (nonatomic, strong) UIView *orientationTransitionSnapshot;
@property (nonatomic) NSUInteger orientationTransitionGeneration;
@property (nonatomic) BOOL orientationTransitionCompleting;
@property (nonatomic) BOOL orientationTransitionFramePending;
@property (nonatomic) BOOL boardAccessibilityHiddenBeforeTransition;
- (void)beginBoardOrientationTransition;
- (void)finishBoardOrientationTransition:(NSUInteger)generation;
- (void)removeBoardOrientationTransitionCover:(NSUInteger)generation animated:(BOOL)animated;
- (void)applyPendingRendererChange;
- (void)installBoardView:(UIView<MBCIOSBoardPresentation> *)view;
@property (nonatomic, strong) MBCIOSBoardChromeView *actionToolbar;
@property (nonatomic, strong) UIStackView *actionButtonStack;
@property (nonatomic, copy) NSArray<UIButton *> *actionButtons;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *actionButtonHeightConstraints;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarCenterXConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionToolbarBottomConstraint;
@property (nonatomic) BOOL actionToolbarUsesTwoRows;
@property (nonatomic) BOOL actionToolbarLandscape;
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *takebackButton;
@property (nonatomic, strong) UIButton *cameraResetButton;
@property (nonatomic, strong) MBCIOSBoardChromeView *cameraResetChrome;
@property (nonatomic, strong) UILabel *gameResultLabel;
@property (nonatomic) BOOL hasAppearedOnScreen;
@property (nonatomic, strong) MBCIOSBoardChromeView *moveStatusStrip;
@property (nonatomic, strong) UILabel *moveStatusLabel;
@property (nonatomic, strong) NSLayoutConstraint *moveStatusHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *moveStatusLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *moveStatusTrailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *moveStatusTrailingLimitConstraint;
@property (nonatomic) BOOL boardOnly;
@property (nonatomic) BOOL boardOnlyStatusBarHidden;
@property (nonatomic) NSUInteger controlsVisibilityGeneration;
@property (nonatomic, strong) MBCIOSBoardChromeView *boardOnlyHintBanner;
@property (nonatomic, strong) MBCIOSChessEngine *engine;
@property (nonatomic, strong) MBCIOSSpeechController *speechController;
@property (nonatomic, strong) MBCIOSGameCenterManager *gameCenterManager;
@property (nonatomic, weak) MBCIOSGameInfoViewController *gameInfoController;
@property (nonatomic, strong) NSMutableDictionary *gameMetadata;
@property (nonatomic, strong) MBCIOSGameLibrary *gameLibrary;
@property (nonatomic, strong) MBCIOSGameRecord *activeGameRecord;
@property (nonatomic, copy) NSString *nextLibraryGameName;
@property (nonatomic, copy) NSDictionary *lastSavedGameSnapshot;
@property (nonatomic, copy) NSDictionary *pendingSceneImportInitialSnapshot;
@property (nonatomic, strong) NSError *pendingLibraryConflict;
@property (nonatomic, copy) NSString *notifiedLibraryConflictIdentifier;
@property (nonatomic) BOOL libraryConflictCheckScheduled;
@property (nonatomic) MBCPlayers players;
@property (nonatomic) MBCSide engineSide;
@property (nonatomic) BOOL gameCenterBoardActivated;
@property (nonatomic) BOOL gameCenterAwaitingRemoteTurn;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingGameCenterPresentations;
@property (nonatomic) BOOL gameCenterPresentationCheckScheduled;
@property (nonatomic, copy) NSString *activeGameCenterRequestKey;
@property (nonatomic, copy) NSString *lastGameCenterErrorFingerprint;
@property (nonatomic) NSTimeInterval lastGameCenterErrorTime;
@property (nonatomic, strong) NSError *gameCenterResumeError;
@property (nonatomic, copy) NSString *resumingGameCenterMatchID;
@property (nonatomic, strong) NSMutableArray<MBCMove *> *pendingMoveAnimations;
@property (nonatomic, strong) MBCMove *activeMoveAnimation;
@property (nonatomic, strong) CADisplayLink *moveAnimationDisplayLink;
@property (nonatomic) MBCPosition moveAnimationFromPosition;
@property (nonatomic) MBCPosition moveAnimationDelta;
@property (nonatomic) NSTimeInterval moveAnimationStartTime;
@property (nonatomic) BOOL activeMoveIsRemote;
@property (nonatomic, strong) NSMutableDictionary *pendingRemoteMetadata;
@property (nonatomic, copy) NSString *pendingRemoteResponse;
@property (nonatomic) BOOL gameCenterEndSubmitted;
@property (nonatomic, strong) CADisplayLink *boardTurnAnimationDisplayLink;
@property (nonatomic) float boardTurnAnimationFromAzimuth;
@property (nonatomic) float boardTurnAnimationDelta;
@property (nonatomic) float boardTurnAnimationTargetAzimuth;
@property (nonatomic) NSTimeInterval boardTurnAnimationStartTime;
@property (nonatomic) BOOL awaitingTurnHandoff;
- (UIButton *)commandButtonWithTitle:(NSString *)title
                                image:(NSString *)imageName
                               action:(SEL)action
                   accessibilityLabel:(NSString *)accessibilityLabel;
- (void)installActionToolbarInContainer:(UIView *)container;
- (void)updateActionToolbarLayout;
- (void)handleContentSizeCategoryChanged:(NSNotification *)notification;
- (void)installCameraResetButtonInContainer:(UIView *)container;
- (void)installGameResultIndicatorInContainer:(UIView *)container;
- (void)installMoveHistorySurfacesInContainer:(UIView *)container;
- (void)updateMoveHistoryUI;
- (void)setBoardOnly:(BOOL)boardOnly;
- (void)hideControlsAction:(id)sender;
- (void)showControlsAction:(id)sender;
- (void)showBoardOnlyHintIfNeeded;
- (void)handleBoardIdleTap:(NSNotification *)notification;
- (void)handleVoiceOverStatusChanged:(NSNotification *)notification;
- (void)gameMenuAction:(UIButton *)sender;
- (void)showGameLogAction:(id)sender;
- (void)showDocumentError:(NSError *)error;
- (void)openDocumentAction:(UIButton *)sender;
- (void)saveDocumentAction:(UIButton *)sender;
- (void)saveAsAction:(id)sender;
- (void)renameCurrentGameAction:(id)sender;
- (void)showRecentGamesAction:(id)sender;
- (void)openLibraryGameWithIdentifier:(NSString *)identifier saveCurrent:(BOOL)saveCurrent;
- (void)promptForGameNameWithTitle:(NSString *)title
                    suggestedName:(NSString *)suggestedName
                       completion:(void (^)(NSString *name))completion;
- (void)installLibraryBoard:(MBCBoard *)board variant:(MBCVariant)variant
                      side:(MBCSide)side boardStyle:(NSString *)boardStyle
                pieceStyle:(NSString *)pieceStyle metadata:(NSDictionary *)metadata
                    record:(MBCIOSGameRecord *)record;
- (BOOL)prepareForGameCenterMatchID:(NSString *)matchID;
- (void)exportAfterFormatPickerDismissal:(NSString *)extension;
- (void)exportCurrentGameWithExtension:(NSString *)extension;
- (void)toggleRecordingAction:(UIButton *)sender;
- (void)updateRecordingButtonForActive:(BOOL)recording;
- (void)shareLastRecordingAction:(UIAlertAction *)action;
- (void)presentRecordingExportForURL:(NSURL *)url sourceView:(UIView *)sourceView;
- (NSURL *)lastAvailableRecordingURL;
- (void)autosaveCurrentGame;
- (NSDictionary *)currentGameSnapshot;
- (void)presentPendingLibraryConflict;
- (BOOL)saveCurrentBoardAsCopyNamed:(NSString *)name error:(NSError **)error;
- (BOOL)canPresentLibraryAlert;
- (void)handleApplicationDidBecomeActive:(NSNotification *)notification;
- (void)handleSceneWillDeactivate:(NSNotification *)notification;
- (void)handleWindowDidBecomeKey:(NSNotification *)notification;
- (void)handleChessEngineDidStop:(NSNotification *)notification;
- (void)resumePausedComputerAction:(UITapGestureRecognizer *)gesture;
- (void)newGameAction:(UIButton *)sender;
- (void)actionsMenuAction:(UIButton *)sender;
- (void)takebackAction:(UIAlertAction *)action;
- (void)resignAction:(UIAlertAction *)action;
- (void)drawAction:(UIAlertAction *)action;
- (void)showHintAction:(UIAlertAction *)action;
- (void)showLastMoveAction:(UIAlertAction *)action;
- (void)toggleEdgeNotationAction:(UIAlertAction *)action;
- (void)showGameInfoAction:(UIAlertAction *)action;
- (void)sharedBoardOptionsAction:(id)sender;
- (void)flipBoardAction:(id)sender;
- (void)presentTurnHandoffIfNeeded;
- (void)updateIdleTimerForSharedGames;
- (void)showAboutAction:(id)sender;
- (void)coordinateEntryAction:(id)sender;
- (void)newWindowAction:(id)sender;
- (void)presentGameInfoSheet;
- (void)presentGameInfoSheetEditing:(BOOL)editing;
- (void)applyBoardStyle:(NSString *)boardStyle pieceStyle:(NSString *)pieceStyle;
- (void)resetCameraAction:(UIButton *)sender;
- (void)startNewGameWithVariant:(MBCVariant)variant
                        players:(MBCPlayers)players
                       sideCode:(MBCSideCode)sideCode
                     searchTime:(NSInteger)searchTime
               rotateAfterMove:(BOOL)rotateAfterMove
              confirmNextTurn:(BOOL)confirmNextTurn
             keepDisplayAwake:(BOOL)keepDisplayAwake
                           name:(NSString *)name;
- (void)handleUncheckedMove:(NSNotification *)notification;
- (void)handleLegalMove:(NSNotification *)notification;
- (void)handleIllegalMove:(NSNotification *)notification;
- (void)handleGameEndNotification:(NSNotification *)notification;
- (void)applyMoveNotification:(NSNotification *)notification;
- (void)enqueueMove:(MBCMove *)move;
- (void)startNextMoveAnimation;
- (void)stepMoveAnimation:(CADisplayLink *)displayLink;
- (void)finishMoveAnimation;
- (void)cancelMoveAnimation;
- (void)startBoardTurnAnimationIfNeeded;
- (void)stepBoardTurnAnimation:(CADisplayLink *)displayLink;
- (void)finishBoardTurnAnimation;
- (void)cancelBoardTurnAnimation;
- (BOOL)rotateAfterEachMoveForCurrentGame;
- (float)boardAzimuthForCurrentGame;
- (void)restoreSharedBoardOrientation;
- (BOOL)canUseLocalGameActions;
- (BOOL)isComputerMove:(MBCMove *)move;
- (BOOL)usesAlternateVoiceForMove:(MBCMove *)move computerMove:(BOOL)computerMove;
- (void)restartEngineFromCurrentBoard;
- (void)restorePlayerModeForSide:(MBCSide)side metadata:(NSDictionary *)metadata;
- (BOOL)isCurrentGameCenterMatchActive;
- (BOOL)isShowingGameCenterMatchID:(NSString *)matchID;
- (ChessIOSViewController *)otherGameCenterControllerForMatchID:(NSString *)matchID;
- (NSError *)gameCenterAlreadyOpenError;
- (BOOL)canReceiveLocalInput;
- (void)updateLoadedGameState;
- (void)updateGameStatusTitle;
- (void)clearGameResultIndicator;
- (NSData *)gameCenterMatchData;
- (NSData *)gameCenterMatchDataForBoard:(MBCBoard *)board;
- (BOOL)configureGameCenterBoardWithVariant:(MBCVariant)variant localSide:(MBCSide)localSide;
- (void)handleGameCenterResponse:(NSString *)response;
- (void)updateGameCenterAchievementsForMove:(MBCMove *)move remote:(BOOL)remote;
- (void)updateGameCenterAchievementsForResult:(MBCMoveCode)command;
- (void)showExistingMatchesAction:(UIAlertAction *)action;
- (void)resumeGameCenterMatchWithID:(NSString *)matchID;
- (void)enqueueGameCenterMessage:(NSString *)message;
- (void)enqueueGameCenterError:(NSError *)error;
- (void)drainGameCenterPresentations;
- (void)scheduleGameCenterPresentationCheck;
- (void)respondToGameCenterRequest:(NSString *)request
                             allow:(BOOL)allow
                           matchID:(NSString *)matchID;
@end

@implementation ChessIOSViewController

@synthesize boardOnly = _boardOnly;

- (void)setPreparedBoardBackend:(MBCIOSBoardBackend *)prepared
{
    if (_preparedBoardBackend == prepared) return;
    MBCIOSBoardBackend *previous = _preparedBoardBackend;
    _preparedBoardBackend = prepared;
    /* A staged first frame retains its owner until its completion handler.
     * Other discarded candidates must retire before their last reference is
     * dropped, including when an inactive scene receives a newer preference. */
    if (previous && previous != _boardBackend && previous != _stagedBoardBackend)
        [previous retireWithCompletion:nil];
}

- (BOOL)rendererSceneIsForeground
{
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene;
    return scene && scene.activationState == UISceneActivationStateForegroundActive &&
        UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
}

- (MBCIOSBoardBackend *)prepareRenderer:(MBCIOSRendererKind)kind error:(NSError **)error
{
    if (self.boardBackend.kind == kind) return self.boardBackend;
    CGRect frame = self.boardView ? self.boardView.frame : self.viewIfLoaded.bounds;
    return [MBCIOSBoardBackend backendWithKind:kind frame:frame board:self.board
        variant:self.variant side:self.side boardStyle:self.boardStyle ?: @"Wood"
        pieceStyle:self.pieceStyle ?: @"Wood" error:error];
}

- (void)requestRenderer:(MBCIOSRendererKind)kind revision:(NSUInteger)revision
              prepared:(MBCIOSBoardBackend *)prepared
{
    if (revision < self.rendererRevision) return;
    self.rendererRevision = revision;
    self.requestedRenderer = kind;
    self.rendererChangePending = self.boardBackend.kind != kind || self.rendererChanging;
    self.preparedBoardBackend = prepared == self.boardBackend ? nil : prepared;
    __weak ChessIOSViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyPendingRendererChange]; });
}

- (void)installBoardView:(UIView<MBCIOSBoardPresentation> *)view
{
    UIView<MBCIOSBoardPresentation> *oldView = self.boardView;
    [NSLayoutConstraint deactivateConstraints:self.boardViewConstraints ?: @[]];
    [self.view insertSubview:view atIndex:0];
    self.boardViewConstraints = @[
        [view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ];
    [NSLayoutConstraint activateConstraints:self.boardViewConstraints];
    self.boardView = view;
    if (oldView != view) [oldView removeFromSuperview];
}

- (void)applyPendingRendererChange
{
    if (!self.rendererChangePending || self.rendererChanging || ![self rendererSceneIsForeground]) return;
    if (self.activeMoveAnimation || self.boardTurnAnimationDisplayLink ||
        self.orientationTransitionCover || [self.boardView isOrientationTransitioning] ||
        [self.boardView iosHasActiveInteraction] ||
        self.recordingController.isRecording || self.recordingTransitioning) return;
    for (ChessIOSViewController *controller in MBCIOSLiveGameControllers().allObjects)
        if (controller.recordingController.isRecording || controller.recordingTransitioning) return;
    if (self.boardBackend.kind == self.requestedRenderer) {
        self.rendererChangePending = NO;
        self.preparedBoardBackend = nil;
        return;
    }
    NSUInteger revision = self.rendererRevision;
    MBCBoard *board = self.board;
    MBCIOSBoardBackend *previous = self.boardBackend;
    NSDictionary *state = [self.boardView iosCapturePresentationState];
    NSError *error = nil;
    MBCIOSBoardBackend *next = self.preparedBoardBackend ?: [self prepareRenderer:self.requestedRenderer error:&error];
    if (!next) {
        self.rendererChangePending = NO;
        if (error) [self showDocumentError:error];
        return;
    }
    self.stagedBoardBackend = next;
    self.rendererChanging = YES;
    [self.boardView wantMouse:NO];
    self.boardView.userInteractionEnabled = NO;
    [previous setRenderingActive:NO];
    [next.view setBoard:board];
    [next.view startGame:self.variant playing:self.side];
    [next.view setStyleForBoard:self.boardStyle pieces:self.pieceStyle];
    [next.view iosRestorePresentationState:state];
    next.view.frame = self.boardView.frame;
    [self.view insertSubview:next.view aboveSubview:self.boardView];
    NSArray<NSLayoutConstraint *> *stagingConstraints = @[
        [next.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [next.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [next.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [next.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ];
    [NSLayoutConstraint activateConstraints:stagingConstraints];
    [self.view layoutIfNeeded];
    if (![next prepareWithError:&error]) {
        [NSLayoutConstraint deactivateConstraints:stagingConstraints];
        [next.view removeFromSuperview];
        self.rendererChanging = NO;
        self.stagedBoardBackend = nil;
        self.rendererChangePending = NO;
        self.preparedBoardBackend = nil;
        self.boardView.userInteractionEnabled = YES;
        [previous setRenderingActive:YES];
        [self updateLoadedGameState];
        if (error) [self showDocumentError:error];
        [self startNextMoveAnimation];
        return;
    }
    __weak ChessIOSViewController *weakSelf = self;
    [next renderFirstFrameWithCompletion:^(NSError *frameError) {
        ChessIOSViewController *controller = weakSelf;
        [NSLayoutConstraint deactivateConstraints:stagingConstraints];
        BOOL current = controller && controller.board == board &&
            controller.rendererRevision == revision && [controller rendererSceneIsForeground] &&
            !controller.orientationTransitionCover && ![controller.boardView isOrientationTransitioning];
        if (!current || frameError) {
            [next.view removeFromSuperview];
            [next retireWithCompletion:nil];
            if (!controller) return;
            controller.rendererChanging = NO;
            if (controller.preparedBoardBackend == next) controller.preparedBoardBackend = nil;
            if (controller.stagedBoardBackend == next) controller.stagedBoardBackend = nil;
            if (frameError && current) controller.rendererChangePending = NO;
            controller.boardView.userInteractionEnabled = YES;
            [previous setRenderingActive:[controller rendererSceneIsForeground]];
            [controller updateLoadedGameState];
            if (frameError && current) [controller showDocumentError:frameError];
            if (!frameError) {
                dispatch_async(dispatch_get_main_queue(), ^{ [controller applyPendingRendererChange]; });
            }
            [controller startNextMoveAnimation];
            return;
        }
        /* Toolbar presentation commands can run while a Metal frame finishes.
         * Carry their latest state into the newly installed view. */
        [next.view iosRestorePresentationState:[controller.boardView iosCapturePresentationState]];
        [controller installBoardView:next.view];
        controller.boardBackend = next;
        controller.engine.moveSource = next.view;
        controller.preparedBoardBackend = nil;
        controller.stagedBoardBackend = nil;
        controller.rendererChangePending = NO;
        controller.rendererChanging = NO;
        next.view.userInteractionEnabled = YES;
        [controller updateLoadedGameState];
        [previous retireWithCompletion:nil];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, next.view);
        [controller startNextMoveAnimation];
    }];
}

- (void)handleRendererInteractionEnded:(NSNotification *)notification
{
    if (notification.object != self.boardView) return;
    [self applyPendingRendererChange];
}

- (NSString *)activeGameIdentifier
{
    return self.activeGameRecord.identifier;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    @synchronized([ChessIOSViewController class]) {
        [MBCIOSLiveGameControllers() addObject:self];
    }
    [MBCIOSRendererPreferences.sharedPreferences addParticipant:self];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleApplicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(handleApplicationDidBecomeActive:)
                   name:UISceneDidActivateNotification object:nil];
    [center addObserver:self selector:@selector(handleSceneWillDeactivate:)
                   name:UISceneWillDeactivateNotification object:nil];
    [center addObserver:self selector:@selector(handleSceneWillDeactivate:)
                   name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(handleWindowDidBecomeKey:)
                   name:UIWindowDidBecomeKeyNotification object:nil];
    [center addObserver:self selector:@selector(handleChessEngineDidStop:)
                   name:MBCIOSChessEngineDidStopNotification object:nil];
    [center addObserver:self selector:@selector(storeCameraPreferences:)
                   name:MBCIOSBoardCameraChangedNotification object:nil];
    [center addObserver:self selector:@selector(handleBoardIdleTap:)
                   name:MBCIOSBoardIdleTapNotification object:nil];
    [center addObserver:self selector:@selector(handleRendererInteractionEnded:)
                   name:MBCIOSBoardInteractionEndedNotification object:nil];
    [center addObserver:self selector:@selector(handleVoiceOverStatusChanged:)
                   name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(handleContentSizeCategoryChanged:)
                   name:UIContentSizeCategoryDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(handleUncheckedMove:)
                   name:MBCUncheckedWhiteMoveNotification object:nil];
    [center addObserver:self selector:@selector(handleUncheckedMove:)
                   name:MBCUncheckedBlackMoveNotification object:nil];
    [center addObserver:self selector:@selector(handleLegalMove:)
                   name:MBCWhiteMoveNotification object:nil];
    [center addObserver:self selector:@selector(handleLegalMove:)
                   name:MBCBlackMoveNotification object:nil];
    [center addObserver:self selector:@selector(handleIllegalMove:)
                   name:MBCIllegalMoveNotification object:nil];
    [center addObserver:self selector:@selector(handleGameEndNotification:)
                   name:MBCGameEndNotification object:nil];
}

- (void)dealloc
{
    [MBCIOSRendererPreferences.sharedPreferences removeParticipant:self];
    @synchronized([ChessIOSViewController class]) {
        [MBCIOSLiveGameControllers() removeObject:self];
    }
    [self updateIdleTimerForSharedGames];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelMoveAnimation];
    [self.speechController stop];
    [self cancelBoardTurnAnimation];
    [self.engine stop];
    [self.boardBackend retireWithCompletion:nil];
    [self.preparedBoardBackend retireWithCompletion:nil];
}

#pragma mark - Game Center bridge

- (UIViewController *)gameCenterPresentationViewControllerForManager:(MBCIOSGameCenterManager *)manager
{
    (void)manager;
    return self;
}

- (BOOL)gameCenterManager:(MBCIOSGameCenterManager *)manager
 shouldActivateMatch:(GKTurnBasedMatch *)match
{
    (void)manager;
    NSString *incomingID = match.matchID;
    if (!incomingID.length) return NO;
    NSString *currentID = MBCIOSMatchIDForMetadata(self.gameMetadata);
    if ([self otherGameCenterControllerForMatchID:incomingID]) return NO;
    if ([incomingID isEqualToString:currentID]) return YES;
    if (self.players == kHumanVsGameCenter && currentID.length &&
        ![self.resumingGameCenterMatchID isEqualToString:incomingID]) return NO;
    return YES;
}

- (void)scheduleGameCenterPresentationCheck
{
    if (self.gameCenterPresentationCheckScheduled || !self.pendingGameCenterPresentations.count) return;
    self.gameCenterPresentationCheckScheduled = YES;
    __weak ChessIOSViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.gameCenterPresentationCheckScheduled = NO;
        [strongSelf drainGameCenterPresentations];
    });
}

- (void)enqueueGameCenterMessage:(NSString *)message
{
    if (!message.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self enqueueGameCenterMessage:message]; });
        return;
    }
    if (!self.pendingGameCenterPresentations) self.pendingGameCenterPresentations = [NSMutableArray array];
    [self.pendingGameCenterPresentations addObject:@{ @"kind": @"message", @"message": message }];
    [self drainGameCenterPresentations];
}

- (void)enqueueGameCenterError:(NSError *)error
{
    if (!error || ([error.domain isEqualToString:GKErrorDomain] && error.code == GKErrorCancelled)) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self enqueueGameCenterError:error]; });
        return;
    }
    NSString *fingerprint = [NSString stringWithFormat:@"%@:%ld:%@", error.domain,
                             (long)error.code, error.localizedDescription];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ([fingerprint isEqualToString:self.lastGameCenterErrorFingerprint] &&
        now - self.lastGameCenterErrorTime < 1.0) return;
    self.lastGameCenterErrorFingerprint = fingerprint;
    self.lastGameCenterErrorTime = now;
    if (!self.pendingGameCenterPresentations) self.pendingGameCenterPresentations = [NSMutableArray array];
    [self.pendingGameCenterPresentations addObject:@{ @"kind": @"message",
        @"message": error.localizedDescription ?: MBCIOSLocalizedString(@"ios_game_center_failed", @"Game Center could not complete the request.") }];
    [self drainGameCenterPresentations];
}

- (void)drainGameCenterPresentations
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self drainGameCenterPresentations]; });
        return;
    }
    if (!self.pendingGameCenterPresentations.count) return;
    if (!self.isViewLoaded || !self.view.window || self.presentedViewController ||
        self.activeGameCenterRequestKey) {
        [self scheduleGameCenterPresentationCheck];
        return;
    }

    NSDictionary *entry = self.pendingGameCenterPresentations.firstObject;
    NSString *kind = entry[@"kind"];
    if ([kind isEqualToString:@"request"] &&
        (self.activeMoveAnimation || self.pendingMoveAnimations.count)) {
        [self scheduleGameCenterPresentationCheck];
        return;
    }
    [self.pendingGameCenterPresentations removeObjectAtIndex:0];
    if ([kind isEqualToString:@"matches"]) {
        NSArray<GKTurnBasedMatch *> *matches = entry[@"matches"];
        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        NSString *localID = self.gameCenterManager.localPlayer.playerID;
        __weak ChessIOSViewController *weakSelf = self;
        for (GKTurnBasedMatch *match in matches) {
            NSString *matchID = [match.matchID copy];
            if (!matchID.length) continue;
            NSString *opponent = nil;
            for (GKTurnBasedParticipant *participant in match.participants) {
                NSString *playerID = participant.player.playerID;
                if (playerID.length && [playerID isEqualToString:localID]) continue;
                opponent = participant.player.displayName;
                if (opponent.length) break;
            }
            if (!opponent.length) opponent = MBCIOSLocalizedString(@"ios_game_center_opponent", @"Opponent");
            NSString *status = match.status == GKTurnBasedMatchStatusEnded
                ? MBCIOSLocalizedString(@"ios_game_center_finished", @"Finished")
                : [match.currentParticipant.player.playerID isEqualToString:localID]
                    ? MBCIOSLocalizedString(@"ios_game_center_your_turn", @"Your turn")
                    : MBCIOSLocalizedString(@"ios_game_center_waiting", @"Waiting");
            NSString *shortID = [matchID substringFromIndex:matchID.length > 8 ? matchID.length - 8 : 0];
            NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@", opponent, status, shortID];
            [items addObject:@{ @"title": title, @"symbol": @"checkerboard.rectangle",
                @"hint": matchID, @"enabled": @YES,
                @"handler": ^{ [weakSelf resumeGameCenterMatchWithID:matchID]; } }];
        }
        if (!items.count) {
            [items addObject:@{ @"title": MBCIOSLocalizedString(@"ios_game_center_no_matches", @"No existing matches"),
                @"symbol": @"tray", @"enabled": @NO, @"handler": ^{} }];
        }
        MBCIOSActionPanelViewController *panel = [[MBCIOSActionPanelViewController alloc]
            initWithSections:@[@{ @"title": MBCIOSLocalizedString(@"ios_game_center_matches", @"Existing Matches"),
                                 @"items": items }]];
        [panel loadViewIfNeeded];
        panel.title = MBCIOSLocalizedString(@"ios_game_center_matches", @"Existing Matches");
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:panel];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        navigation.preferredContentSize = panel.preferredContentSize;
        [self presentViewController:navigation animated:YES completion:nil];
        return;
    }
    NSString *message = entry[@"message"];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MBCIOSLocalizedString(@"ios_game_center", @"Game Center")
                        message:message
                 preferredStyle:UIAlertControllerStyleAlert];
    __weak ChessIOSViewController *weakSelf = self;
    if ([kind isEqualToString:@"request"]) {
        NSString *request = entry[@"request"];
        NSString *matchID = entry[@"matchID"];
        NSString *currentID = MBCIOSMatchIDForMetadata(self.gameMetadata);
        if (self.players != kHumanVsGameCenter || !self.gameCenterBoardActivated ||
            ![matchID isEqualToString:currentID] ||
            ![matchID isEqualToString:self.gameCenterManager.activeMatch.matchID]) {
            [self drainGameCenterPresentations];
            return;
        }
        self.activeGameCenterRequestKey = entry[@"key"];
        NSString *yesTitle = [request isEqualToString:@"Takeback"]
            ? MBCIOSLocalizedString(@"takeback_request_yes", @"Allow")
            : MBCIOSLocalizedString(@"draw_request_yes", @"Accept");
        NSString *noTitle = [request isEqualToString:@"Takeback"]
            ? MBCIOSLocalizedString(@"takeback_request_no", @"Refuse")
            : MBCIOSLocalizedString(@"draw_request_no", @"Refuse");
        [alert addAction:[UIAlertAction actionWithTitle:noTitle
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf respondToGameCenterRequest:request allow:NO matchID:matchID];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:yesTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf respondToGameCenterRequest:request allow:YES matchID:matchID];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_ok", @"OK")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf scheduleGameCenterPresentationCheck];
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)respondToGameCenterRequest:(NSString *)request
                             allow:(BOOL)allow
                           matchID:(NSString *)matchID
{
    if (![matchID isEqualToString:MBCIOSMatchIDForMetadata(self.gameMetadata)] ||
        ![matchID isEqualToString:self.gameCenterManager.activeMatch.matchID]) {
        self.activeGameCenterRequestKey = nil;
        [self scheduleGameCenterPresentationCheck];
        return;
    }
    MBCBoard *proposedTakebackBoard = nil;
    if (allow && [request isEqualToString:@"Takeback"]) {
        MBCBoard *candidate = [[MBCBoard alloc] init];
        [candidate startGame:self.variant];
        [candidate setFen:self.board.fen holding:self.board.holding moves:self.board.moves
               initialFen:self.board.initialFen initialHolding:self.board.initialHolding];
        BOOL copied = candidate.numMoves == self.board.numMoves &&
            [candidate.fen isEqualToString:self.board.fen] &&
            [candidate.holding isEqualToString:self.board.holding] &&
            [candidate.moves isEqualToString:self.board.moves];
        allow = copied && ([candidate undoMoves:2] || [candidate undoMoves:1]);
        if (allow) {
            [candidate commitMove];
            [candidate setDefaultPromotion:[self.board defaultPromotion:YES] for:YES];
            [candidate setDefaultPromotion:[self.board defaultPromotion:NO] for:NO];
            proposedTakebackBoard = candidate;
        } else {
            [self enqueueGameCenterMessage:MBCIOSLocalizedString(@"ios_game_center_takeback_unavailable",
                @"This position cannot be taken back. The request will be declined.")];
        }
    }

    self.gameCenterAwaitingRemoteTurn = allow || ![request isEqualToString:@"Draw"];
    [self.boardView wantMouse:NO];
    MBCBoard *requestBoard = self.board;
    int requestMoveCount = self.board.numMoves;
    NSString *requestKey = [self.activeGameCenterRequestKey copy];
    NSData *responseData = [self gameCenterMatchDataForBoard:proposedTakebackBoard ?: requestBoard];
    __weak ChessIOSViewController *weakSelf = self;
    [self.gameCenterManager respondToRequest:request
                                      allow:allow
                                       data:responseData
                                 completion:^(NSError *error) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.activeGameCenterRequestKey isEqualToString:requestKey])
            strongSelf.activeGameCenterRequestKey = nil;
        BOOL samePosition = [strongSelf isShowingGameCenterMatchID:matchID] &&
            strongSelf.board == requestBoard && strongSelf.board.numMoves == requestMoveCount;
        if (error) {
            if (samePosition) {
                strongSelf.gameCenterBoardActivated = NO;
                strongSelf.gameCenterAwaitingRemoteTurn = NO;
                strongSelf.gameCenterResumeError = error;
                [strongSelf updateLoadedGameState];
            }
            [strongSelf enqueueGameCenterError:error];
        } else {
            if (samePosition && !allow && [request isEqualToString:@"Draw"]) {
                strongSelf.gameMetadata[@"IOSDeclinedDrawRequest"] = requestKey ?: @"";
                [strongSelf.gameMetadata removeObjectForKey:@"Request"];
                [strongSelf.gameMetadata removeObjectForKey:@"Response"];
                [strongSelf updateLoadedGameState];
                [strongSelf autosaveCurrentGame];
            }
            if (samePosition && allow && proposedTakebackBoard) {
                strongSelf.board = proposedTakebackBoard;
                strongSelf.gameMetadata[@"Result"] = @"*";
                [strongSelf.speechController setBoard:proposedTakebackBoard];
                [strongSelf.boardView setBoard:proposedTakebackBoard];
                [strongSelf.boardView startGame:strongSelf.variant playing:strongSelf.side];
                MBCMove *lastMove = proposedTakebackBoard.lastMove;
                if (lastMove) [strongSelf.boardView showMoveAsLast:lastMove];
                [strongSelf updateLoadedGameState];
                [strongSelf autosaveCurrentGame];
            }
            NSString *achievement = !allow
                ? ([request isEqualToString:@"Takeback"]
                    ? @"AppleChess_Cry_me_a_River" : @"AppleChess_Not_So_Fast")
                : ([request isEqualToString:@"Takeback"] ? @"AppleChess_Merciful" : nil);
            if (achievement.length)
                [strongSelf.gameCenterManager reportAchievementIdentifier:achievement
                                                           percentComplete:100.0];
            if (samePosition && allow && [request isEqualToString:@"Draw"]) {
                strongSelf.gameCenterEndSubmitted = YES;
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:MBCGameEndNotification object:strongSelf
                                  userInfo:(id)[MBCMove moveWithCommand:kCmdDraw]];
            }
        }
        [strongSelf scheduleGameCenterPresentationCheck];
    }];
}

- (void)showExistingMatchesAction:(UIAlertAction *)action
{
    (void)action;
    __weak ChessIOSViewController *weakSelf = self;
    [self.gameCenterManager fetchExistingMatchesWithCompletion:
     ^(NSArray<GKTurnBasedMatch *> *matches, NSError *error) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) [strongSelf enqueueGameCenterError:error];
        if (!matches.count && error) return;
        if (!strongSelf.pendingGameCenterPresentations) {
            strongSelf.pendingGameCenterPresentations = [NSMutableArray array];
        }
        [strongSelf.pendingGameCenterPresentations addObject:@{
            @"kind": @"matches", @"matches": matches ?: @[]
        }];
        [strongSelf drainGameCenterPresentations];
    }];
}

- (void)resumeGameCenterMatchWithID:(NSString *)matchID
{
    if (!matchID.length || !self.gameCenterManager.isAuthenticated) return;
    ChessIOSViewController *other = [self otherGameCenterControllerForMatchID:matchID];
    if (other && other != self) {
        [self enqueueGameCenterError:[self gameCenterAlreadyOpenError]];
        return;
    }
    if ([self.resumingGameCenterMatchID isEqualToString:matchID]) return;
    if ([self isCurrentGameCenterMatchActive] &&
        [self.gameCenterManager.activeMatch.matchID isEqualToString:matchID]) return;

    self.resumingGameCenterMatchID = [matchID copy];
    self.gameCenterResumeError = nil;
    if (self.players == kHumanVsGameCenter) [self updateLoadedGameState];
    __weak ChessIOSViewController *weakSelf = self;
    [self.gameCenterManager resumeMatchWithID:matchID
                                   completion:^(GKTurnBasedMatch *match, NSError *error) {
        (void)match;
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.resumingGameCenterMatchID isEqualToString:matchID]) return;
        strongSelf.resumingGameCenterMatchID = nil;
        if (error) {
            if ([error.domain isEqualToString:@"com.apple.Chess.iOSGameCenter"] &&
                error.code == 13) return;
            if (strongSelf.players == kHumanVsGameCenter &&
                [matchID isEqualToString:MBCIOSMatchIDForMetadata(strongSelf.gameMetadata)]) {
                strongSelf.gameCenterResumeError = error;
                [strongSelf updateLoadedGameState];
            }
            [strongSelf enqueueGameCenterError:error];
        } else {
            if ([strongSelf isShowingGameCenterMatchID:matchID] &&
                strongSelf.gameCenterBoardActivated)
                strongSelf.gameCenterResumeError = nil;
            if (strongSelf.players == kHumanVsGameCenter) [strongSelf updateLoadedGameState];
        }
    }];
}

- (NSData *)gameCenterMatchData
{
    return [self gameCenterMatchDataForBoard:self.board];
}

- (NSData *)gameCenterMatchDataForBoard:(MBCBoard *)board
{
    if (!board) return nil;
    NSMutableDictionary *dictionary = [[MBCIOSGameStore
        gameDictionaryForBoard:board
                       variant:self.variant
                          side:self.side
                    boardStyle:self.boardStyle ?: @"Wood"
                    pieceStyle:self.pieceStyle ?: @"Wood"
                      metadata:self.gameMetadata] mutableCopy];
    [dictionary removeObjectsForKeys:@[@"IOSPendingDrawOffer", @"IOSDeclinedDrawRequest"]];
    GKTurnBasedMatch *match = self.gameCenterManager.activeMatch;
    NSString *localID = self.gameCenterManager.localPlayer.playerID;
    for (GKTurnBasedParticipant *participant in match.participants) {
        NSString *playerID = participant.player.playerID;
        if (!playerID.length) continue;
        if ([playerID isEqualToString:localID]) {
            dictionary[self.side == kWhiteSide ? @"WhitePlayerID" : @"BlackPlayerID"] = playerID;
        } else if (!dictionary[@"WhitePlayerID"] ||
                   [dictionary[@"WhitePlayerID"] isEqualToString:localID]) {
            if (self.side == kWhiteSide) dictionary[@"BlackPlayerID"] = playerID;
            else dictionary[@"WhitePlayerID"] = playerID;
        }
    }
    if (match.matchID.length) {
        dictionary[@"MatchID"] = match.matchID;
        dictionary[@"GameCenterMatchID"] = match.matchID;
    }
    if (board != self.board) dictionary[@"Result"] = @"*";
    dictionary[@"Variant"] = gVariantName[self.variant] ?: @"normal";
    dictionary[@"WhiteType"] = @"human";
    dictionary[@"BlackType"] = @"human";
    return [MBCIOSGameCenterManager dataForGameDictionary:dictionary error:nil];
}

- (BOOL)configureGameCenterBoardWithVariant:(MBCVariant)variant localSide:(MBCSide)localSide
{
    if (![self prepareForGameCenterMatchID:self.gameCenterManager.activeMatch.matchID]) return NO;
    [self cancelMoveAnimation];
    [self.speechController stop];
    [self.engine stop];
    self.engine = [[MBCIOSChessEngine alloc] init];
    self.players = kHumanVsGameCenter;
    self.engineSide = kNeitherSide;
    self.gameCenterBoardActivated = YES;
    self.gameCenterAwaitingRemoteTurn = NO;
    self.gameCenterResumeError = nil;
    self.gameCenterEndSubmitted = NO;
    self.activeMoveIsRemote = NO;
    self.variant = variant;
    self.side = localSide;
    self.board = [[MBCBoard alloc] init];
    [self.board startGame:variant];
    [self.speechController setBoard:self.board];
    self.gameMetadata = [[MBCIOSGameStore defaultMetadataForSide:localSide] mutableCopy];
    GKTurnBasedMatch *match = self.gameCenterManager.activeMatch;
    if (match.matchID.length) {
        self.gameMetadata[@"MatchID"] = match.matchID;
        self.gameMetadata[@"GameCenterMatchID"] = match.matchID;
    }
    self.gameMetadata[@"IOSPlayers"] = @(self.players);
    [self.boardView setBoard:self.board];
    [self.boardView startGame:variant playing:localSide];
    [self applyGamePreferences];
    [self clearGameResultIndicator];
    [self updateLoadedGameState];
    return YES;
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
         didActivateMatch:(GKTurnBasedMatch *)match
                matchData:(NSData *)matchData
               localSide:(MBCSide)localSide
                 variant:(MBCVariant)variant
              isInitial:(BOOL)isInitial
{
    (void)isInitial;
    if ([self otherGameCenterControllerForMatchID:match.matchID]) {
        [self enqueueGameCenterError:[self gameCenterAlreadyOpenError]];
        return;
    }
    NSDictionary *base = [MBCIOSGameCenterManager gameDictionaryForData:matchData error:nil];
    if (![self configureGameCenterBoardWithVariant:variant localSide:localSide]) return;
    [self.gameMetadata addEntriesFromDictionary:base ?: @{}];
    NSString *matchID = [match.matchID copy];
    MBCBoard *initialBoard = self.board;
    self.gameCenterAwaitingRemoteTurn = YES;
    [self.boardView wantMouse:NO];
    [self autosaveCurrentGame];
    NSData *fullData = [self gameCenterMatchData];
    [manager completeInitialMatchSetupWithData:fullData
                                      localSide:localSide
                                      completion:^(NSError *error) {
        if (![self isShowingGameCenterMatchID:matchID] || self.board != initialBoard) {
            if (error) [self enqueueGameCenterError:error];
            return;
        }
        if (error) {
            self.gameCenterBoardActivated = NO;
            self.gameCenterResumeError = error;
            [self updateLoadedGameState];
            [self enqueueGameCenterError:error];
        } else {
            self.gameCenterAwaitingRemoteTurn = localSide == kBlackSide;
            [self updateLoadedGameState];
        }
        [self autosaveCurrentGame];
    }];
}

- (BOOL)installReceivedGameCenterBoard:(MBCBoard *)incoming
                              variant:(MBCVariant)variant
                                 side:(MBCSide)localSide
                             metadata:(NSDictionary *)metadata
{
    if (![self prepareForGameCenterMatchID:self.gameCenterManager.activeMatch.matchID]) return NO;
    [self cancelMoveAnimation];
    [self.engine stop];
    self.players = kHumanVsGameCenter;
    self.engineSide = kNeitherSide;
    self.gameCenterBoardActivated = YES;
    self.gameCenterAwaitingRemoteTurn = NO;
    self.gameCenterResumeError = nil;
    self.gameCenterEndSubmitted = NO;
    self.activeMoveIsRemote = NO;
    self.variant = variant;
    self.side = localSide;
    self.board = incoming;
    [self.speechController setBoard:incoming];
    NSMutableDictionary *merged = [[MBCIOSGameStore defaultMetadataForSide:localSide] mutableCopy];
    if (metadata) [merged addEntriesFromDictionary:metadata];
    if ([MBCIOSMatchIDForMetadata(self.gameMetadata) isEqualToString:self.gameCenterManager.activeMatch.matchID]) {
        for (NSString *key in [MBCIOSGamePreferenceKeys() arrayByAddingObjectsFromArray:
            @[@"IOSPendingDrawOffer", @"IOSDeclinedDrawRequest"]]) {
            if (self.gameMetadata[key]) merged[key] = self.gameMetadata[key];
            else [merged removeObjectForKey:key];
        }
    }
    NSString *matchID = self.gameCenterManager.activeMatch.matchID;
    if (matchID.length) {
        merged[@"MatchID"] = matchID;
        merged[@"GameCenterMatchID"] = matchID;
    }
    merged[@"IOSPlayers"] = @(self.players);
    self.gameMetadata = merged;
    [self.boardView setBoard:incoming];
    [self.boardView startGame:variant playing:localSide];
    [self applyGamePreferences];
    [self updateLoadedGameState];
    [self autosaveCurrentGame];
    return YES;
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
         didReceiveMatch:(GKTurnBasedMatch *)match
                matchData:(NSData *)matchData
{
    NSString *incomingMatchID = match.matchID;
    if (incomingMatchID.length &&
        ![MBCIOSMatchIDForMetadata(self.gameMetadata) isEqualToString:incomingMatchID]) {
        ChessIOSViewController *owner =
            [self otherGameCenterControllerForMatchID:incomingMatchID];
        if (owner) {
            [owner gameCenterManager:manager didReceiveMatch:match matchData:matchData];
            return;
        }
    }
    if ([self otherGameCenterControllerForMatchID:match.matchID]) {
        [self enqueueGameCenterError:[self gameCenterAlreadyOpenError]];
        return;
    }
    NSError *payloadError = nil;
    NSDictionary *dictionary = [MBCIOSGameCenterManager gameDictionaryForData:matchData
                                                                       error:&payloadError];
    if (!dictionary) {
        NSError *displayError = payloadError ?: [NSError
            errorWithDomain:@"com.apple.Chess.iOSGameCenterUI" code:2
                  userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(@"ios_game_center_invalid_board",
                      @"Game Center returned an invalid game position.")}];
        self.gameCenterBoardActivated = NO;
        self.gameCenterAwaitingRemoteTurn = NO;
        self.gameCenterResumeError = displayError;
        [self updateLoadedGameState];
        [self enqueueGameCenterError:displayError];
        return;
    }
    MBCBoard *incoming = [[MBCBoard alloc] init];
    MBCVariant variant = kVarNormal;
    MBCSide incomingSide = kBothSides;
    NSString *boardStyle = nil;
    NSString *pieceStyle = nil;
    NSDictionary *metadata = nil;
    NSError *error = nil;
    if (![MBCIOSGameStore loadBoard:incoming
                             variant:&variant
                                side:&incomingSide
                          boardStyle:&boardStyle
                          pieceStyle:&pieceStyle
                             metadata:&metadata
                   fromGameDictionary:dictionary
                               error:&error]) {
        NSError *displayError = error ?: [NSError
            errorWithDomain:@"com.apple.Chess.iOSGameCenterUI" code:1
                  userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(@"ios_game_center_invalid_board",
                      @"Game Center returned an invalid game position.")}];
        self.gameCenterBoardActivated = NO;
        self.gameCenterAwaitingRemoteTurn = NO;
        self.gameCenterResumeError = displayError;
        [self updateLoadedGameState];
        [self enqueueGameCenterError:displayError];
        return;
    }
    NSString *localID = manager.localPlayer.playerID;
    if ([dictionary[@"WhitePlayerID"] isEqualToString:localID]) incomingSide = kWhiteSide;
    else if ([dictionary[@"BlackPlayerID"] isEqualToString:localID]) incomingSide = kBlackSide;
    if (incomingSide != kWhiteSide && incomingSide != kBlackSide) {
        [self enqueueGameCenterMessage:MBCIOSLocalizedString(@"ios_game_center_not_participant",
            @"This Game Center account is not a participant in the match.")];
        return;
    }
    if (self.players == kHumanVsGameCenter && self.gameCenterBoardActivated && self.board &&
        [self isShowingGameCenterMatchID:match.matchID] &&
        variant == self.variant && incoming.numMoves == self.board.numMoves + 1 &&
        [incoming.moves hasPrefix:self.board.moves] &&
        incoming.lastMove) {
        NSMutableDictionary *remoteMetadata = [metadata mutableCopy];
        [remoteMetadata removeObjectsForKeys:[MBCIOSGamePreferenceKeys() arrayByAddingObjectsFromArray:
            @[@"IOSPendingDrawOffer", @"IOSDeclinedDrawRequest"]]];
        self.pendingRemoteMetadata = remoteMetadata;
        self.pendingRemoteResponse = [dictionary[@"Response"] isKindOfClass:[NSString class]]
            ? [dictionary[@"Response"] copy] : nil;
        self.gameCenterAwaitingRemoteTurn = NO;
        self.boardStyle = boardStyle ?: self.boardStyle;
        self.pieceStyle = pieceStyle ?: self.pieceStyle;
        self.activeMoveIsRemote = YES;
        MBCMove *move = MBCIOSCopyMove(incoming.lastMove);
        move->fAnimate = YES;
        [self enqueueMove:move];
        return;
    }
    if (![self installReceivedGameCenterBoard:incoming variant:variant side:incomingSide
                                    metadata:metadata]) return;
    self.pendingRemoteResponse = nil;
    [self handleGameCenterResponse:dictionary[@"Response"]];
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
        didReceiveRequest:(NSString *)request
                 matchData:(NSData *)matchData
{
    if (![request isEqualToString:@"Takeback"] && ![request isEqualToString:@"Draw"]) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self gameCenterManager:manager didReceiveRequest:request matchData:matchData];
        });
        return;
    }
    NSString *matchID = manager.activeMatch.matchID ?: MBCIOSMatchIDForMetadata(self.gameMetadata);
    if (!matchID.length) return;
    if (![MBCIOSMatchIDForMetadata(self.gameMetadata) isEqualToString:matchID]) {
        ChessIOSViewController *owner = [self otherGameCenterControllerForMatchID:matchID];
        if (owner) {
            [owner gameCenterManager:manager didReceiveRequest:request matchData:matchData];
            return;
        }
    }
    NSString *text = [request isEqualToString:@"Takeback"]
        ? MBCIOSLocalizedString(@"takeback_request_text", @"Your opponent would like to take back the last move.")
        : MBCIOSLocalizedString(@"draw_request_text", @"Your opponent offers a draw.");
    NSString *key = [NSString stringWithFormat:@"%@:%@:%lu", matchID, request,
                     (unsigned long)matchData.hash];
    if ([self.gameMetadata[@"IOSDeclinedDrawRequest"] isEqualToString:key] ||
        [self.activeGameCenterRequestKey isEqualToString:key]) return;
    for (NSDictionary *entry in self.pendingGameCenterPresentations) {
        if ([entry[@"key"] isEqualToString:key]) return;
    }
    if (!self.pendingGameCenterPresentations) self.pendingGameCenterPresentations = [NSMutableArray array];
    [self.pendingGameCenterPresentations addObject:@{
        @"kind": @"request", @"request": request, @"matchID": matchID,
        @"message": text, @"key": key
    }];
    [self drainGameCenterPresentations];
}

- (void)handleGameCenterResponse:(NSString *)response
{
    if (![response isKindOfClass:[NSString class]] || !response.length) return;
    if ([response isEqualToString:@"Draw"]) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCGameEndNotification object:self
                          userInfo:(id)[MBCMove moveWithCommand:kCmdDraw]];
        return;
    }
    NSString *message = nil;
    if ([response isEqualToString:@"Takeback"]) {
        message = MBCIOSLocalizedString(@"takeback_msg", @"Takeback requested");
    } else if ([response isEqualToString:@"NoTakeback"]) {
        message = MBCIOSLocalizedString(@"takeback_refused", @"Your opponent refused to let you take back this move.");
    } else if ([response isEqualToString:@"NoDraw"]) {
        message = MBCIOSLocalizedString(@"draw_request_no", @"Your opponent refused the draw.");
    }
    if (message.length) {
        [self enqueueGameCenterMessage:message];
    }
}

- (void)updateGameCenterAchievementsForMove:(MBCMove *)move remote:(BOOL)remote
{
    if (remote || !move || !self.gameCenterManager.isAuthenticated ||
        self.players == kComputerVsComputer || [self isComputerMove:move]) return;

    MBCVariant variant = self.variant;
    BOOL notAntiChess = variant == kVarNormal || variant == kVarCrazyhouse;
    MBCPieces *position = [self.board curPos];
    if (!position) return;
    MBCPieceCode ourColor = Color(move->fPiece);
    MBCPieceCode opponentColor = (MBCPieceCode)Opposite(ourColor);

    if (notAntiChess) {
        if (move->fCheck)
            [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Checker"
                                                   percentComplete:100.0];
        if (move->fEnPassant)
            [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Sidestepped"
                                                   percentComplete:100.0];
        if (move->fPromotion) {
            NSString *identifier = Piece(move->fPromotion) == QUEEN
                ? @"AppleChess_Promotional_Value" : @"AppleChess_Promotional_Discount";
            [self.gameCenterManager reportAchievementIdentifier:identifier percentComplete:100.0];
        }
        if (move->fCommand == kCmdMove && Piece(move->fPiece) == PAWN &&
            labs((int)Row(move->fFromSquare) - (int)Row(move->fToSquare)) == 2) {
            [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_One_Step_Beyond"
                                                   percentComplete:100.0];
        }
        if (move->fVictim && variant == kVarNormal) {
            if ((Piece(move->fVictim) == PAWN || Promoted(move->fVictim)) &&
                position->fInHand[ourColor + PAWN] == 5) {
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Pawnbroker"
                                                       percentComplete:100.0];
            }
            if (Piece(move->fVictim) == KNIGHT &&
                position->fInHand[ourColor + KNIGHT] == 2) {
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Pikeman"
                                                       percentComplete:100.0];
            }
            if (position->NoPieces(opponentColor)) {
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Take_no_Prisoners"
                                                       percentComplete:100.0];
            }
        }
        if (move->fCheckMate) {
            if ([self.board numMoves] < 19)
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Blitz"
                                                       percentComplete:100.0];
            if (variant == kVarNormal) {
                int materialBalance =
                    (position->fInHand[ourColor + QUEEN] - position->fInHand[opponentColor + QUEEN]) * 9
                  + (position->fInHand[ourColor + ROOK] - position->fInHand[opponentColor + ROOK]) * 5
                  + (position->fInHand[ourColor + KNIGHT] - position->fInHand[opponentColor + KNIGHT]) * 3
                  + (position->fInHand[ourColor + BISHOP] - position->fInHand[opponentColor + BISHOP]) * 3
                  + (position->fInHand[ourColor + PAWN] - position->fInHand[opponentColor + PAWN]);
                if (materialBalance <= -9)
                    [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Last_Ditch_Effort"
                                                           percentComplete:100.0];
            } else if (variant == kVarCrazyhouse && move->fCommand == kCmdDrop) {
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Aerial_Attack"
                                                       percentComplete:100.0];
            }
        }
        if (move->fCastling != kNoCastle) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSInteger sides = [defaults integerForKey:kMBCCastleSides] | move->fCastling;
            [defaults setInteger:sides forKey:kMBCCastleSides];
            if (sides == (kCastleKingside | kCastleQueenside))
                [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Duck_and_Cover"
                                                       percentComplete:100.0];
        }
    }
}

- (void)updateGameCenterAchievementsForResult:(MBCMoveCode)command
{
    if (!self.gameCenterManager.isAuthenticated) return;
    MBCSide humanSide = self.players == kHumanVsGameCenter ? self.side :
        (self.engineSide == kWhiteSide ? kBlackSide :
         self.engineSide == kBlackSide ? kWhiteSide : kBothSides);
    BOOL won = (command == kCmdWhiteWins && SideIncludesWhite(humanSide)) ||
               (command == kCmdBlackWins && SideIncludesBlack(humanSide));
    if (!won) return;

    if (self.engineSide != kNeitherSide)
        [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Luddite"
                                               percentComplete:100.0];
    if (self.players == kHumanVsGameCenter) {
        [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_King_of_the_Cloud"
                                               percentComplete:100.0];
        NSMutableDictionary *victories = [[[NSUserDefaults standardUserDefaults]
                                            dictionaryForKey:kMBCGCVictories] mutableCopy];
        if (!victories) victories = [NSMutableDictionary dictionary];
        NSString *localID = self.gameCenterManager.localPlayer.playerID;
        for (GKTurnBasedParticipant *participant in self.gameCenterManager.activeMatch.participants) {
            NSString *opponentID = participant.player.playerID;
            if (opponentID.length && ![opponentID isEqualToString:localID])
                victories[opponentID] = @YES;
        }
        [[NSUserDefaults standardUserDefaults] setObject:victories forKey:kMBCGCVictories];
        if (victories.count >= 10)
            [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Battle_Royal"
                                                   percentComplete:100.0];
    }
    if ((self.variant == kVarSuicide || self.variant == kVarLosers) &&
        self.board.numMoves < 39) {
        [self.gameCenterManager reportAchievementIdentifier:@"AppleChess_Lightning_Loser"
                                               percentComplete:100.0];
    }
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
             didEndMatch:(GKTurnBasedMatch *)match
            localOutcome:(GKTurnBasedMatchOutcome)outcome
{
    (void)manager;
    NSString *currentMatchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
    if (match.matchID.length && ![match.matchID isEqualToString:currentMatchID]) {
        ChessIOSViewController *owner = [self otherGameCenterControllerForMatchID:match.matchID];
        if (owner) {
            [owner gameCenterManager:manager didEndMatch:match localOutcome:outcome];
            return;
        }
    }
    if (self.players != kHumanVsGameCenter || !self.gameCenterBoardActivated ||
        !currentMatchID.length || ![match.matchID isEqualToString:currentMatchID]) return;
    MBCMoveCode command = kCmdDraw;
    if (outcome == GKTurnBasedMatchOutcomeWon) {
        command = self.side == kWhiteSide ? kCmdWhiteWins : kCmdBlackWins;
    } else if (outcome == GKTurnBasedMatchOutcomeLost || outcome == GKTurnBasedMatchOutcomeQuit) {
        command = self.side == kWhiteSide ? kCmdBlackWins : kCmdWhiteWins;
    }
    if (match.matchID.length) {
        self.gameMetadata[@"MatchID"] = match.matchID;
        self.gameMetadata[@"GameCenterMatchID"] = match.matchID;
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MBCGameEndNotification object:self
                      userInfo:(id)[MBCMove moveWithCommand:command]];
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
  didChangeAuthentication:(BOOL)authenticated
{
    (void)manager;
    if (!authenticated && self.players == kHumanVsGameCenter) {
        self.gameCenterBoardActivated = NO;
        self.gameCenterAwaitingRemoteTurn = NO;
        self.gameCenterResumeError = nil;
    }
    if (authenticated) {
        NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
        if (matchID.length) [self resumeGameCenterMatchWithID:matchID];
    }
    if (self.players == kHumanVsGameCenter) [self updateLoadedGameState];
    NSLog(@"Game Center authentication %@", authenticated ? @"succeeded" : @"unavailable");
}

- (void)gameCenterManager:(MBCIOSGameCenterManager *)manager
       didFailWithError:(NSError *)error
{
    NSLog(@"Game Center: %@", error.localizedDescription);
    if ([error.domain isEqualToString:@"com.apple.Chess.iOSGameCenter"] &&
        error.code == 16) {
        [self enqueueGameCenterError:error];
        return;
    }
    NSString *activeMatchID = manager.activeMatch.matchID;
    if (activeMatchID.length &&
        ![MBCIOSMatchIDForMetadata(self.gameMetadata) isEqualToString:activeMatchID]) {
        ChessIOSViewController *owner =
            [self otherGameCenterControllerForMatchID:activeMatchID];
        if (owner) {
            [owner enqueueGameCenterError:error];
            return;
        }
    }
    /* GameKit can report the same sign-in failure on every launch.  A local
     * game's Actions menu shows the sign-in state and presents the explicit
     * error when Game Center is selected.  A stored online match still needs
     * the error immediately so its blocked state is explained. */
    if (!manager.isAuthenticated && self.players != kHumanVsGameCenter &&
        [error.domain isEqualToString:GKErrorDomain]) return;
    [self enqueueGameCenterError:error];
}

- (void)handleUncheckedMove:(NSNotification *)notification
{
    if (notification.object != self.boardView) return;
    /* The engine consumes unchecked moves when a computer is playing.  In a
     * local human game or a Game Center game the iOS shell is the trusted
     * local player.  A Game Center match still accepts only the side assigned
     * to this participant. */
    if (self.engineSide != kNeitherSide ||
        (self.players != kHumanVsHuman && self.players != kHumanVsGameCenter)) return;
    if (MBCIOSStoredOutcome(self.board, self.gameMetadata) != kCmdNull) return;
    if (![self canReceiveLocalInput]) return;
    MBCMove *move = (MBCMove *)notification.userInfo;
    if (self.players == kHumanVsGameCenter && move &&
        [self.board sideOfMove:move] != self.side) return;
    [self applyMoveNotification:notification];
}

- (void)handleLegalMove:(NSNotification *)notification
{
    if (notification.object != self.engine) return;
    [self applyMoveNotification:notification];
}

- (void)handleIllegalMove:(NSNotification *)notification
{
    if (notification.object != self.engine) return;
    /* The touch selection has already been cleared.  Keep the board in the
     * pre-move state and leave the notification available to future UI work. */
    NSLog(@"Chess engine rejected a move");
}

- (void)handleGameEndNotification:(NSNotification *)notification
{
    if (notification.object != self && notification.object != self.engine) return;
    MBCMove *result = (MBCMove *)notification.userInfo;
    MBCMoveCode command = result ? result->fCommand : [self.board outcome];
    NSString *title = MBCIOSGameResultTitle(command);
    if (!title) return;

    if (!self.gameMetadata) self.gameMetadata = [NSMutableDictionary dictionary];
    self.gameMetadata[@"Result"] = command == kCmdWhiteWins ? @"1-0" :
        command == kCmdBlackWins ? @"0-1" : @"1/2-1/2";

    self.gameResultLabel.text = title;
    self.gameResultLabel.accessibilityValue = title;
    self.gameResultLabel.hidden = NO;
    self.title = title;
    [self updateMoveHistoryUI];
    [self updateGameCenterAchievementsForResult:command];

    /* Keep the final board and last-move arrow visible, but prevent another
     * local move and stop any pending computer turn. */
    [self cancelBoardTurnAnimation];
    self.awaitingTurnHandoff = NO;
    [self.boardView wantMouse:NO];
    [self.boardView unselectPiece];
    [self.engine stop];
    [self.pendingMoveAnimations removeAllObjects];
    [self.boardView drawNow];
    BOOL gameCenterMatchIsOpen = [self isCurrentGameCenterMatchActive];
    if (self.players == kHumanVsGameCenter && !self.gameCenterEndSubmitted &&
        gameCenterMatchIsOpen && self.gameCenterManager.isLocalPlayerTurn) {
        self.gameCenterEndSubmitted = YES;
        NSData *matchData = [self gameCenterMatchData];
        [self.gameCenterManager finishWithCommand:command data:matchData completion:^(NSError *error) {
            if (error) [self enqueueGameCenterError:error];
        }];
    }
    [self autosaveCurrentGame];
    [self updateIdleTimerForSharedGames];
}

- (void)applyMoveNotification:(NSNotification *)notification
{
    MBCMove *move = (MBCMove *)notification.userInfo;
    if (!move || !self.board || !self.boardView) return;
    [self enqueueMove:move];
}

- (void)enqueueMove:(MBCMove *)move
{
    if (!move || (move->fCommand != kCmdMove && move->fCommand != kCmdDrop)) return;
    if (!self.pendingMoveAnimations) {
        self.pendingMoveAnimations = [NSMutableArray array];
    }
    [self.pendingMoveAnimations addObject:move];
    [self startNextMoveAnimation];
}

- (void)startNextMoveAnimation
{
    if (self.rendererChanging) return;
    if (self.rendererChangePending && !self.activeMoveAnimation && !self.boardTurnAnimationDisplayLink) {
        [self applyPendingRendererChange];
        if (self.rendererChanging) return;
    }
    if (self.activeMoveAnimation || !self.board || !self.boardView ||
        self.pendingMoveAnimations.count == 0) {
        return;
    }

    MBCMove *move = self.pendingMoveAnimations.firstObject;
    [self.pendingMoveAnimations removeObjectAtIndex:0];
    self.activeMoveAnimation = move;

    /* Clear touch selection before taking the old board snapshot.  This also
     * prevents a stale selected piece from surviving an engine move. */
    [self.boardView unselectPiece];
    [self.boardView hideMoves];
    [self.board makeMove:move];

    MBCSquare fromSquare = move->fFromSquare;
    MBCPiece movingPiece = move->fCommand == kCmdDrop
        ? move->fPiece
        : [self.board oldContents:fromSquare];
    if (move->fCommand == kCmdDrop) {
        fromSquare = (MBCSquare)(kInHandSquare + move->fPiece);
    }

    if (!move->fAnimate || !movingPiece || move->fToSquare >= kSyntheticSquare) {
        [self.boardView showMoveAsLast:move];
        [self.boardView drawNow];
        [self finishMoveAnimation];
        return;
    }

    self.moveAnimationFromPosition = [self.boardView squareToPosition:fromSquare];
    MBCPosition destination = [self.boardView squareToPosition:move->fToSquare];
    self.moveAnimationDelta = destination - self.moveAnimationFromPosition;
    self.moveAnimationStartTime = 0.0;

    [self.boardView startAnimation];
    [self.boardView selectPiece:movingPiece at:fromSquare to:move->fToSquare];
    MBCPosition initialPosition = self.moveAnimationFromPosition;
    [self.boardView moveSelectionTo:&initialPosition];
    [self.boardView drawNow];

    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self
                                                               selector:@selector(stepMoveAnimation:)];
    self.moveAnimationDisplayLink = displayLink;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stepMoveAnimation:(CADisplayLink *)displayLink
{
    if (!self.activeMoveAnimation || !self.boardView) {
        [self finishMoveAnimation];
        return;
    }

    if (self.moveAnimationStartTime == 0.0) {
        self.moveAnimationStartTime = displayLink.timestamp;
    }
    NSTimeInterval elapsed = displayLink.timestamp - self.moveAnimationStartTime;
    float progress = (float)MIN(MAX(elapsed / kMBCIOSMoveAnimationDuration, 0.0), 1.0);
    MBCPosition position = self.moveAnimationFromPosition;
    position[0] += progress * self.moveAnimationDelta[0];
    position[2] += progress * self.moveAnimationDelta[2];
    [self.boardView moveSelectionTo:&position];
    [self.boardView drawNow];

    if (progress >= 1.0) {
        [self finishMoveAnimation];
    }
}

- (void)finishMoveAnimation
{
    MBCMove *move = self.activeMoveAnimation;
    if (!move) return;
    BOOL remoteMove = self.activeMoveIsRemote;

    [self.moveAnimationDisplayLink invalidate];
    self.moveAnimationDisplayLink = nil;
    self.moveAnimationStartTime = 0.0;
    /* MBCBoard keeps the last committed position separately from its current
     * position.  The renderer uses that snapshot while _inAnimation is set;
     * commit it before the next move can arrive so later animations start
     * from the position that was just presented instead of the initial game
     * position. */
    [self.board commitMove];
    [self.boardView animationDone];
    [self.boardView unselectPiece];
    [self.boardView showMoveAsLast:move];
    [self.boardView drawNow];

    BOOL computerMove = [self isComputerMove:move];
    [self.speechController speakMove:move
                        computerMove:computerMove
                      alternateVoice:[self usesAlternateVoiceForMove:move
                                                        computerMove:computerMove]];

    self.activeMoveAnimation = nil;
    self.activeMoveIsRemote = NO;
    if (remoteMove && self.pendingRemoteMetadata) {
        [self.gameMetadata addEntriesFromDictionary:self.pendingRemoteMetadata];
        self.pendingRemoteMetadata = nil;
    }
    NSString *remoteResponse = self.pendingRemoteResponse;
    self.pendingRemoteResponse = nil;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MBCEndMoveNotification object:self userInfo:(id)move];

    MBCMoveCode outcome = [self.board outcome];
    [self updateGameCenterAchievementsForMove:move remote:remoteMove];
    if (outcome != kCmdNull) {
        MBCMove *result = [MBCMove moveWithCommand:outcome];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCGameEndNotification object:self userInfo:(id)result];
    } else {
        [self updateGameStatusTitle];
        [self.engine movePresentationDidFinish];
        if (self.players == kHumanVsGameCenter && !remoteMove) {
            self.gameCenterAwaitingRemoteTurn = YES;
            [self.boardView wantMouse:NO];
            NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
            MBCBoard *sentBoard = self.board;
            int sentMoveCount = self.board.numMoves;
            NSMutableDictionary *payload = [[MBCIOSGameCenterManager
                gameDictionaryForData:[self gameCenterMatchData] error:nil] mutableCopy];
            [payload removeObjectsForKeys:@[@"Request", @"Response"]];
            if ([self.gameMetadata[@"IOSPendingDrawOffer"] boolValue] && !payload[@"Request"])
                payload[@"Request"] = @"Draw";
            NSData *matchData = [MBCIOSGameCenterManager dataForGameDictionary:payload error:nil];
            [self.gameCenterManager sendCurrentTurnWithData:matchData completion:^(NSError *error) {
                if (error) {
                    if ([self isShowingGameCenterMatchID:matchID] &&
                        self.board == sentBoard && self.board.numMoves == sentMoveCount) {
                        self.gameCenterBoardActivated = NO;
                        self.gameCenterAwaitingRemoteTurn = NO;
                        self.gameCenterResumeError = error;
                        [self updateLoadedGameState];
                    }
                    [self enqueueGameCenterError:error];
                } else if ([self isShowingGameCenterMatchID:matchID] && self.board == sentBoard) {
                    [self.gameMetadata removeObjectForKey:@"IOSPendingDrawOffer"];
                    [self autosaveCurrentGame];
                }
            }];
        }
    }
    if (remoteResponse.length) [self handleGameCenterResponse:remoteResponse];
    if (remoteMove && outcome == kCmdNull && self.pendingMoveAnimations.count == 0)
        [self.boardView wantMouse:[self canReceiveLocalInput]];
    [self autosaveCurrentGame];

    if (outcome == kCmdNull) {
        if (self.players == kHumanVsHuman &&
            [self.gameMetadata[@"IOSConfirmNextTurn"] boolValue]) {
            self.awaitingTurnHandoff = YES;
            [self.boardView wantMouse:NO];
        }
        [self startBoardTurnAnimationIfNeeded];
        if (!self.boardTurnAnimationDisplayLink) {
            [self startNextMoveAnimation];
            [self presentTurnHandoffIfNeeded];
        }
    } else {
        [self applyPendingRendererChange];
    }
}

- (void)cancelMoveAnimation
{
    self.awaitingTurnHandoff = NO;
    [self cancelBoardTurnAnimation];
    [self.moveAnimationDisplayLink invalidate];
    self.moveAnimationDisplayLink = nil;
    self.moveAnimationStartTime = 0.0;
    self.activeMoveAnimation = nil;
    self.activeMoveIsRemote = NO;
    self.pendingRemoteMetadata = nil;
    self.pendingRemoteResponse = nil;
    [self.pendingMoveAnimations removeAllObjects];
    [self.boardView animationDone];
    [self.boardView unselectPiece];
}

- (void)startBoardTurnAnimationIfNeeded
{
    if (self.players != kHumanVsHuman || !self.boardView ||
        ![self rotateAfterEachMoveForCurrentGame] ||
        self.boardTurnAnimationDisplayLink ||
        [self.board outcome] != kCmdNull) {
        return;
    }

    float from = fmodf(self.boardView.azimuth + 360.0f, 360.0f);
    float target = [self boardAzimuthForCurrentGame];
    float delta = target - from;
    if (delta > 180.0f) delta -= 360.0f;
    else if (delta < -180.0f) delta += 360.0f;
    if (fabsf(delta) < 0.5f) {
        self.boardView.azimuth = target;
        [self.boardView drawNow];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
        return;
    }
    if (UIAccessibilityIsReduceMotionEnabled()) {
        self.boardView.azimuth = target;
        [self.boardView drawNow];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
        return;
    }
    self.boardTurnAnimationFromAzimuth = from;
    self.boardTurnAnimationTargetAzimuth = target;
    self.boardTurnAnimationDelta = delta;
    self.boardTurnAnimationStartTime = 0.0;
    [self.boardView wantMouse:NO];
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self
                                                               selector:@selector(stepBoardTurnAnimation:)];
    self.boardTurnAnimationDisplayLink = displayLink;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stepBoardTurnAnimation:(CADisplayLink *)displayLink
{
    if (!self.boardView) {
        [self finishBoardTurnAnimation];
        return;
    }

    if (self.boardTurnAnimationStartTime == 0.0) {
        self.boardTurnAnimationStartTime = displayLink.timestamp;
    }
    NSTimeInterval elapsed = displayLink.timestamp - self.boardTurnAnimationStartTime;
    float progress = (float)MIN(MAX(elapsed / 0.45, 0.0), 1.0);
    self.boardView.azimuth = fmodf(self.boardTurnAnimationFromAzimuth +
                                   self.boardTurnAnimationDelta * progress + 360.0f,
                                   360.0f);
    [self.boardView drawNow];
    if (progress >= 1.0) {
        [self finishBoardTurnAnimation];
    }
}

- (void)finishBoardTurnAnimation
{
    [self.boardTurnAnimationDisplayLink invalidate];
    self.boardTurnAnimationDisplayLink = nil;
    self.boardTurnAnimationStartTime = 0.0;
    if (self.boardView) {
        self.boardView.azimuth = self.boardTurnAnimationTargetAzimuth;
        [self.boardView wantMouse:[self canReceiveLocalInput]];
        [self.boardView drawNow];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
    }
    [self startNextMoveAnimation];
    [self presentTurnHandoffIfNeeded];
}

- (BOOL)rotateAfterEachMoveForCurrentGame
{
    id stored = self.gameMetadata[@"IOSRotateAfterEachMove"];
    return stored ? [stored boolValue] :
        [[NSUserDefaults standardUserDefaults] boolForKey:kMBCAutoRotateBoard];
}

- (float)boardAzimuthForCurrentGame
{
    if (self.players == kHumanVsHuman) {
        if ([self rotateAfterEachMoveForCurrentGame])
            return (self.board.numMoves & 1) ? 0.0f : 180.0f;
        return [self.gameMetadata[@"IOSFixedBoardBlack"] boolValue] ? 0.0f : 180.0f;
    }
    return self.side == kBlackSide ? 0.0f : 180.0f;
}

- (void)applyGamePreferences
{
    if (!self.gameMetadata[kMBCBoardSpin]) {
        self.gameMetadata[kMBCBoardSpin] = self.gameMetadata[@"IOSFixedBoardBlack"]
            ? ([self.gameMetadata[@"IOSFixedBoardBlack"] boolValue] ? @0 : @180)
            : @(self.boardView.azimuth);
    }
    MBCIOSFillGamePreferences(self.gameMetadata);
    self.speechController.gameSettings = self.gameMetadata;
    self.boardView.elevation = MAX(10.0f, MIN(90.0f, [self.gameMetadata[kMBCBoardAngle] floatValue]));
    self.boardView.azimuth = fmodf([self.gameMetadata[kMBCBoardSpin] floatValue] + 360.0f, 360.0f);
    self.boardView.drawEdgeNotationLabels = [self.gameMetadata[kMBCShowEdgeNotation] boolValue];
    if (self.players == kHumanVsHuman && [self rotateAfterEachMoveForCurrentGame])
        [self restoreSharedBoardOrientation];
}

- (void)storeCameraPreferences:(NSNotification *)notification
{
    if (notification && notification.object != self.boardView) return;
    if (!self.boardView || !self.gameMetadata) return;
    self.gameMetadata[kMBCBoardAngle] = @(self.boardView.elevation);
    self.gameMetadata[kMBCBoardSpin] = @(self.boardView.azimuth);
    [self autosaveCurrentGame];
}

- (void)restoreSharedBoardOrientation
{
    if (self.players != kHumanVsHuman || !self.boardView) return;
    self.boardView.azimuth = [self boardAzimuthForCurrentGame];
    [self.boardView drawNow];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
}

- (void)cancelBoardTurnAnimation
{
    [self.boardTurnAnimationDisplayLink invalidate];
    self.boardTurnAnimationDisplayLink = nil;
    self.boardTurnAnimationStartTime = 0.0;
}

- (void)presentTurnHandoffIfNeeded
{
    if (!self.awaitingTurnHandoff || self.players != kHumanVsHuman ||
        self.boardTurnAnimationDisplayLink || self.activeMoveAnimation ||
        !self.viewIfLoaded.window || self.presentedViewController) return;
    UIWindowScene *scene = self.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return;
    MBCBoard *board = self.board;
    int moveCount = board.numMoves;
    NSString *turn = MBCIOSGameStatusTitle(board, self.gameMetadata);
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@", turn,
        MBCIOSLocalizedString(@"ios_pass_device", @"Pass the device, then tap Continue.")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        MBCIOSLocalizedString(@"ios_next_turn_ready", @"Ready for Next Turn")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak ChessIOSViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:
        MBCIOSLocalizedString(@"ios_continue", @"Continue")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.board != board ||
            strongSelf.board.numMoves != moveCount) return;
        strongSelf.awaitingTurnHandoff = NO;
        [strongSelf updateLoadedGameState];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                        MBCIOSGameStatusTitle(board, strongSelf.gameMetadata));
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)canUseLocalGameActions
{
    BOOL turnAvailable = self.players != kHumanVsGameCenter || [self canReceiveLocalInput];
    return self.board && self.boardView && turnAvailable && !self.rendererChanging && !self.awaitingTurnHandoff &&
        !self.activeMoveAnimation &&
        !self.boardTurnAnimationDisplayLink && self.pendingMoveAnimations.count == 0 &&
        MBCIOSStoredOutcome(self.board, self.gameMetadata) == kCmdNull;
}

- (BOOL)isComputerMove:(MBCMove *)move
{
    if (!move || !self.board) return NO;
    if (self.players == kHumanVsHuman) return NO;
    if (self.players == kComputerVsComputer) return YES;
    return [self.board sideOfMove:move] == self.engineSide;
}

- (BOOL)usesAlternateVoiceForMove:(MBCMove *)move computerMove:(BOOL)computerMove
{
    if (!move || !self.board) return NO;
    if (self.players == kHumanVsHuman || self.players == kComputerVsComputer) {
        return [self.board sideOfMove:move] == kBlackSide;
    }
    /* The macOS sheet uses the alternate voice for the human side and the
     * default voice for the computer side in a local game. */
    return !computerMove;
}

- (void)restartEngineFromCurrentBoard
{
    if (self.engineSide == kNeitherSide || !self.board ||
        MBCIOSStoredOutcome(self.board, self.gameMetadata) != kCmdNull) return;
    UIWindowScene *scene = self.view.window.windowScene;
    if (!self.view.window || (scene && scene.activationState != UISceneActivationStateForegroundActive))
        return;
    if (self.engine.isRunning) return;
    NSLog(@"Chess engine resume in scene %@ key=%@",
          scene.session.persistentIdentifier ?: @"none",
          self.view.window.isKeyWindow ? @"YES" : @"NO");
    MBCIOSFillGamePreferences(self.gameMetadata);
    NSInteger searchTime = [self.gameMetadata[kMBCSearchTime] integerValue];
    if (searchTime < 1) searchTime = 1;
    [self.engine stop];
    self.engine = [[MBCIOSChessEngine alloc] init];
    self.engine.moveSource = self.boardView;
    self.engine.sessionIdentifier = [NSString stringWithFormat:@"%@-%@",
        self.activeGameRecord.identifier ?: NSUUID.UUID.UUIDString,
        scene.session.persistentIdentifier ?: NSUUID.UUID.UUIDString];
    [self.engine startGame:self.variant
                   playing:self.engineSide
                searchTime:searchTime
                 fromBoard:self.board];
    [self updateLoadedGameState];
}

- (void)restorePlayerModeForSide:(MBCSide)side metadata:(NSDictionary *)metadata
{
    BOOL whiteKnown = NO;
    BOOL blackKnown = NO;
    BOOL whiteHuman = MBCIOSPlayerTypeIsHuman(metadata[@"WhiteType"], &whiteKnown);
    BOOL blackHuman = MBCIOSPlayerTypeIsHuman(metadata[@"BlackType"], &blackKnown);
    MBCSide humanSide = side;
    if (whiteKnown && blackKnown) {
        humanSide = whiteHuman ? (blackHuman ? kBothSides : kWhiteSide)
                               : (blackHuman ? kBlackSide : kNeitherSide);
    }

    NSString *matchID = MBCIOSMatchIDForMetadata(metadata);
    if (matchID.length) {
        self.players = kHumanVsGameCenter;
        /* A Game Center document may describe both participants as human.
         * The local side is established authoritatively by the match data
         * when GameKit activates it. */
        self.side = side;
        self.engineSide = kNeitherSide;
    } else {
        MBCPlayers players = MBCIOSPlayersForHumanSide(humanSide);
        NSNumber *savedPlayers = [metadata[@"IOSPlayers"] isKindOfClass:[NSNumber class]]
            ? metadata[@"IOSPlayers"] : nil;
        if (savedPlayers && savedPlayers.integerValue >= kHumanVsHuman &&
            savedPlayers.integerValue <= kComputerVsComputer &&
            MBCIOSPlayersMatchHumanSide((MBCPlayers)savedPlayers.integerValue, humanSide)) {
            players = (MBCPlayers)savedPlayers.integerValue;
        }
        self.players = players;
        self.side = humanSide;
        self.engineSide = humanSide == kWhiteSide ? kBlackSide :
            humanSide == kBlackSide ? kWhiteSide :
            humanSide == kNeitherSide ? kBothSides : kNeitherSide;
    }
    self.gameMetadata[@"IOSPlayers"] = @(self.players);
}

- (BOOL)isCurrentGameCenterMatchActive
{
    if (self.players != kHumanVsGameCenter || !self.gameCenterBoardActivated ||
        !self.gameCenterManager.isAuthenticated) return NO;
    GKTurnBasedMatch *match = self.gameCenterManager.activeMatch;
    NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
    return match && matchID.length && [match.matchID isEqualToString:matchID] &&
        match.status != GKTurnBasedMatchStatusEnded;
}

- (ChessIOSViewController *)otherGameCenterControllerForMatchID:(NSString *)matchID
{
    if (!matchID.length) return nil;
    @synchronized([ChessIOSViewController class]) {
        for (ChessIOSViewController *controller in MBCIOSLiveGameControllers()) {
            if (controller == self || controller.players != kHumanVsGameCenter) continue;
            if ([MBCIOSMatchIDForMetadata(controller.gameMetadata) isEqualToString:matchID])
                return controller;
        }
    }
    return nil;
}


- (NSError *)gameCenterAlreadyOpenError
{
    return [NSError errorWithDomain:@"com.apple.Chess.iOSGameCenterUI" code:5
                          userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(
        @"ios_game_center_other_window",
        @"A Game Center game is open in another window. Close it there before opening one here.")}];
}

- (BOOL)isShowingGameCenterMatchID:(NSString *)matchID
{
    return self.players == kHumanVsGameCenter && matchID.length &&
        [MBCIOSMatchIDForMetadata(self.gameMetadata) isEqualToString:matchID] &&
        [self.gameCenterManager.activeMatch.matchID isEqualToString:matchID];
}

- (BOOL)canReceiveLocalInput
{
    if (!self.board || self.rendererChanging || self.orientationTransitionCover || self.awaitingTurnHandoff ||
        MBCIOSStoredOutcome(self.board, self.gameMetadata) != kCmdNull) return NO;
    if (self.players == kHumanVsGameCenter) {
        return [self isCurrentGameCenterMatchActive] &&
            !self.gameCenterEndSubmitted && !self.gameCenterAwaitingRemoteTurn && self.gameCenterManager.isLocalPlayerTurn;
    }
    return self.engineSide != kBothSides &&
        (self.engineSide == kNeitherSide || self.engine.isRunning);
}

- (UIButton *)commandButtonWithTitle:(NSString *)title
                                image:(NSString *)imageName
                               action:(SEL)action
                   accessibilityLabel:(NSString *)accessibilityLabel
{
    UIButton *button = [MBCIOSCommandButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    button.titleLabel.adjustsFontForContentSizeCategory = NO;
    button.tintColor = UIColor.labelColor;
    button.layer.cornerRadius = 13.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.accessibilityLabel = accessibilityLabel ?: title;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    [button setTitle:title forState:UIControlStateNormal];
    UIImage *image = imageName.length ? [UIImage systemImageNamed:imageName] : nil;
    if (image) {
        [button setImage:image forState:UIControlStateNormal];
    }
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)installActionToolbarInContainer:(UIView *)container
{
    MBCIOSBoardChromeView *dock = [[MBCIOSBoardChromeView alloc] initWithCornerRadius:22.0];
    dock.translatesAutoresizingMaskIntoConstraints = NO;
    dock.accessibilityLabel = MBCIOSLocalizedString(@"ios_chess_actions", @"Chess actions");
    [container addSubview:dock];

    UIStackView *buttons = [[UIStackView alloc] initWithFrame:CGRectZero];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentFill;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 2.0;
    [dock addSubview:buttons];

    UIButton *gameButton = [self commandButtonWithTitle:MBCIOSLocalizedString(@"ios_game_section", @"Game")
                                                 image:@"square.stack"
                                                action:@selector(gameMenuAction:)
                                    accessibilityLabel:MBCIOSLocalizedString(@"ios_game_section", @"Game")];
    UIButton *movesButton = [self commandButtonWithTitle:MBCIOSLocalizedString(@"ios_actions", @"Moves")
                                                  image:@"list.bullet"
                                                 action:@selector(actionsMenuAction:)
                                     accessibilityLabel:MBCIOSLocalizedString(@"ios_actions", @"Moves")];
    self.takebackButton = [self commandButtonWithTitle:MBCIOSLocalizedString(@"ios_take_back", @"Take Back Move")
                                                  image:@"arrow.uturn.left"
                                                 action:@selector(takebackAction:)
                                     accessibilityLabel:MBCIOSLocalizedString(@"ios_take_back", @"Take Back Move")];
    UIButton *hideButton = [self commandButtonWithTitle:MBCIOSLocalizedString(@"ios_hide_controls", @"Hide Controls")
                                                 image:@"arrow.up.left.and.arrow.down.right"
                                                action:@selector(hideControlsAction:)
                                    accessibilityLabel:MBCIOSLocalizedString(@"ios_hide_controls", @"Hide Controls")];
    NSMutableArray<NSLayoutConstraint *> *buttonHeights = [NSMutableArray arrayWithCapacity:4];
    for (UIButton *button in @[gameButton, movesButton, self.takebackButton, hideButton]) {
        NSLayoutConstraint *height = [button.heightAnchor constraintEqualToConstant:62.0];
        height.active = YES;
        [buttonHeights addObject:height];
        [buttons addArrangedSubview:button];
    }
    self.actionButtons = @[gameButton, movesButton, self.takebackButton, hideButton];
    self.actionButtonHeightConstraints = buttonHeights;
    self.actionButtonStack = buttons;
    NSLayoutConstraint *preferredWidth = [dock.widthAnchor constraintEqualToConstant:304.0];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    self.actionToolbarWidthConstraint = preferredWidth;
    self.actionToolbarCenterXConstraint = [dock.centerXAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.centerXAnchor];
    self.actionToolbarLeadingConstraint = [dock.leadingAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:8.0];
    self.actionToolbarTopConstraint = [dock.topAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:8.0];
    self.actionToolbarBottomConstraint = [dock.bottomAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.bottomAnchor constant:-8.0];
    [NSLayoutConstraint activateConstraints:@[
        self.actionToolbarCenterXConstraint,
        [dock.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:8.0],
        [dock.trailingAnchor constraintLessThanOrEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-8.0],
        preferredWidth,
        self.actionToolbarBottomConstraint,
        [buttons.leadingAnchor constraintEqualToAnchor:dock.leadingAnchor constant:6.0],
        [buttons.trailingAnchor constraintEqualToAnchor:dock.trailingAnchor constant:-6.0],
        [buttons.topAnchor constraintEqualToAnchor:dock.topAnchor constant:6.0],
        [buttons.bottomAnchor constraintEqualToAnchor:dock.bottomAnchor constant:-6.0]
    ]];
    self.actionToolbarHeightConstraint = [dock.heightAnchor constraintEqualToConstant:74.0];
    self.actionToolbarHeightConstraint.active = YES;
    self.actionToolbar = dock;
    [self updateActionToolbarLayout];
}

- (void)updateActionToolbarLayout
{
    if (!self.actionButtonStack || self.actionButtons.count != 4) return;
    CGSize viewport = self.actionToolbar.superview.bounds.size;
    BOOL landscapePhone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        viewport.width > viewport.height;
    BOOL twoRows = !landscapePhone && UIContentSizeCategoryIsAccessibilityCategory(
        self.traitCollection.preferredContentSizeCategory);
    if (self.actionToolbarLandscape != landscapePhone) {
        if (landscapePhone) {
            [NSLayoutConstraint deactivateConstraints:@[
                self.actionToolbarCenterXConstraint, self.actionToolbarBottomConstraint]];
            [NSLayoutConstraint activateConstraints:@[
                self.actionToolbarLeadingConstraint, self.actionToolbarTopConstraint]];
            if (self.moveStatusLeadingConstraint) {
                [NSLayoutConstraint deactivateConstraints:@[
                    self.moveStatusLeadingConstraint, self.moveStatusTrailingLimitConstraint]];
                self.moveStatusTrailingConstraint.active = YES;
            }
        } else {
            [NSLayoutConstraint deactivateConstraints:@[
                self.actionToolbarLeadingConstraint, self.actionToolbarTopConstraint]];
            [NSLayoutConstraint activateConstraints:@[
                self.actionToolbarCenterXConstraint, self.actionToolbarBottomConstraint]];
            if (self.moveStatusLeadingConstraint) {
                self.moveStatusTrailingConstraint.active = NO;
                [NSLayoutConstraint activateConstraints:@[
                    self.moveStatusLeadingConstraint, self.moveStatusTrailingLimitConstraint]];
            }
        }
        self.actionToolbarLandscape = landscapePhone;
    }
    self.actionToolbarWidthConstraint.constant = landscapePhone ? 248.0 : 304.0;
    self.actionToolbarHeightConstraint.constant = landscapePhone ? 56.0 : twoRows ? 138.0 : 74.0;
    for (NSLayoutConstraint *height in self.actionButtonHeightConstraints)
        height.constant = landscapePhone ? 44.0 : 62.0;
    self.cameraResetButton.hidden = landscapePhone;
    UIFont *font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13.0]
        maximumPointSize:twoRows ? 22.0 : 18.0
        compatibleWithTraitCollection:self.traitCollection];
    for (UIButton *button in self.actionButtons) button.titleLabel.font = font;
    if (self.actionToolbarUsesTwoRows == twoRows) {
        [self.actionButtonStack setNeedsLayout];
        return;
    }

    UIStackView *stack = self.actionButtonStack;
    for (UIView *item in [stack.arrangedSubviews copy]) {
        if ([item isKindOfClass:[UIStackView class]]) {
            UIStackView *row = (UIStackView *)item;
            for (UIView *button in [row.arrangedSubviews copy]) {
                [row removeArrangedSubview:button];
                [button removeFromSuperview];
            }
        }
        [stack removeArrangedSubview:item];
        [item removeFromSuperview];
    }
    stack.axis = twoRows ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    if (twoRows) {
        for (NSUInteger rowIndex = 0; rowIndex < 2; ++rowIndex) {
            UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.alignment = UIStackViewAlignmentFill;
            row.distribution = UIStackViewDistributionFillEqually;
            row.spacing = 2.0;
            [row addArrangedSubview:self.actionButtons[rowIndex * 2]];
            [row addArrangedSubview:self.actionButtons[rowIndex * 2 + 1]];
            [stack addArrangedSubview:row];
        }
    } else {
        for (UIButton *button in self.actionButtons) [stack addArrangedSubview:button];
    }
    self.actionToolbarUsesTwoRows = twoRows;
    [stack setNeedsLayout];
}

- (void)handleContentSizeCategoryChanged:(NSNotification *)notification
{
    (void)notification;
    [self updateActionToolbarLayout];
    [self updateMoveHistoryUI];
}

- (void)installMoveHistorySurfacesInContainer:(UIView *)container
{
    MBCIOSBoardChromeView *strip = [[MBCIOSBoardChromeView alloc] initWithCornerRadius:16.0];
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:strip];
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    status.adjustsFontForContentSizeCategory = YES;
    status.textColor = UIColor.labelColor;
    status.numberOfLines = 1;
    status.lineBreakMode = NSLineBreakByTruncatingMiddle;
    status.minimumScaleFactor = 0.85;
    status.adjustsFontSizeToFitWidth = YES;
    status.accessibilityIdentifier = @"ChessCurrentMoveStatus";
    [strip addSubview:status];
    NSLayoutConstraint *preferredWidth = [strip.widthAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.widthAnchor multiplier:0.7];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    self.moveStatusLeadingConstraint = [strip.leadingAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:8.0];
    self.moveStatusTrailingLimitConstraint = [strip.trailingAnchor
        constraintLessThanOrEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-60.0];
    self.moveStatusTrailingConstraint = [strip.trailingAnchor
        constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-8.0];
    [NSLayoutConstraint activateConstraints:@[
        self.moveStatusLeadingConstraint,
        self.moveStatusTrailingLimitConstraint,
        [strip.widthAnchor constraintLessThanOrEqualToConstant:340.0],
        preferredWidth,
        [strip.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:8.0],
        [status.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor constant:12.0],
        [status.trailingAnchor constraintEqualToAnchor:strip.trailingAnchor constant:-12.0],
        [status.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor]
    ]];
    self.moveStatusHeightConstraint = [strip.heightAnchor constraintEqualToConstant:44.0];
    self.moveStatusHeightConstraint.active = YES;
    self.moveStatusStrip = strip;
    self.moveStatusLabel = status;
    if (self.actionToolbarLandscape) {
        [NSLayoutConstraint deactivateConstraints:@[
            self.moveStatusLeadingConstraint, self.moveStatusTrailingLimitConstraint]];
        self.moveStatusTrailingConstraint.active = YES;
    }
}

- (void)updateMoveHistoryUI
{
    if (!self.board) return;
    [self.gameInfoController updateWithBoard:self.board metadata:self.gameMetadata side:self.side];
    NSString *status = MBCIOSGameStatusTitle(self.board, self.gameMetadata);
    MBCMove *last = self.board.lastMove;
    NSString *lastText = MBCIOSMoveDisplayText(last);
    NSString *summary = lastText.length
        ? [NSString stringWithFormat:@"%@ · %@", status, lastText]
        : status;
    NSString *name = self.activeGameRecord.name;
    NSString *fullLabel = name.length ? [NSString stringWithFormat:@"%@ · %@", name, summary] : summary;
    BOOL largeText = !self.actionToolbarLandscape && UIContentSizeCategoryIsAccessibilityCategory(
        self.traitCollection.preferredContentSizeCategory);
    self.moveStatusLabel.font = self.actionToolbarLandscape
        ? [UIFont systemFontOfSize:16.0]
        : [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline
                    compatibleWithTraitCollection:self.traitCollection];
    self.moveStatusLabel.numberOfLines = largeText ? 2 : 1;
    self.moveStatusLabel.adjustsFontSizeToFitWidth = !largeText;
    self.moveStatusLabel.lineBreakMode = largeText
        ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingMiddle;
    self.moveStatusHeightConstraint.constant = largeText
        ? ceil(self.moveStatusLabel.font.lineHeight * 2.0 + 16.0) : 44.0;
    NSString *label = largeText && name.length
        ? [NSString stringWithFormat:@"%@\n%@", name, status] : fullLabel;
    self.moveStatusLabel.text = label;
    self.moveStatusLabel.accessibilityLabel = fullLabel;
    self.takebackButton.enabled = [self canUseLocalGameActions] &&
        (self.players == kHumanVsGameCenter ? self.board.numMoves >= 1 : [self.board canUndo]);
    self.takebackButton.alpha = self.takebackButton.enabled ? 1.0 : 0.45;
}

- (void)setBoardOnly:(BOOL)boardOnly
{
    // VoiceOver needs a persistent route back to the command group.
    if (boardOnly && UIAccessibilityIsVoiceOverRunning()) return;
    if (_boardOnly == boardOnly) return;
    _boardOnly = boardOnly;
    NSUInteger generation = ++self.controlsVisibilityGeneration;
    NSArray<UIView *> *controls = @[self.actionToolbar, self.moveStatusStrip, self.cameraResetButton];
    for (UIView *control in controls) {
        control.userInteractionEnabled = !boardOnly;
        control.accessibilityElementsHidden = boardOnly;
    }
    MBCIOSBoardChromeView *hint = boardOnly ? nil : self.boardOnlyHintBanner;
    if (hint) {
        self.boardOnlyHintBanner = nil;
        // This outgoing overlay is still visible while the status bar returns.
        // Keep its current frame for the exit fade as the safe area changes.
        CGRect frame = hint.frame;
        for (NSLayoutConstraint *constraint in [self.view.constraints copy]) {
            if (constraint.firstItem == hint || constraint.secondItem == hint)
                constraint.active = NO;
        }
        hint.translatesAutoresizingMaskIntoConstraints = YES;
        hint.frame = frame;
    }

    // Restore the safe area before fading controls in. When hiding, retain
    // that layout until the controls are transparent so the top row cannot
    // jump into the status-bar area during its fade.
    if (!boardOnly) {
        self.boardOnlyStatusBarHidden = NO;
        [self setNeedsStatusBarAppearanceUpdate];
        [self.view layoutIfNeeded];
    }

    // Keep the overlays in place and reverse an interrupted fade from its
    // current presentation. Their visibility never participates in board layout.
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.18 : 0.28
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.actionToolbar.contentVisible = !boardOnly;
        self.moveStatusStrip.contentVisible = !boardOnly;
        self.cameraResetChrome.contentVisible = !boardOnly;
        self.cameraResetButton.imageView.alpha = boardOnly ? 0.0 : 1.0;
        self.cameraResetButton.titleLabel.alpha = boardOnly ? 0.0 : 1.0;
        hint.contentVisible = NO;
    } completion:^(BOOL finished) {
        [hint removeFromSuperview];
        if (!finished || generation != self.controlsVisibilityGeneration) return;
        if (boardOnly) {
            self.boardOnlyStatusBarHidden = YES;
            [self setNeedsStatusBarAppearanceUpdate];
            [self showBoardOnlyHintIfNeeded];
        }
    }];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation
{
    return UIStatusBarAnimationFade;
}

- (BOOL)prefersStatusBarHidden
{
    return self.boardOnlyStatusBarHidden;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return self.boardOnly;
}

- (void)hideControlsAction:(id)sender
{
    (void)sender;
    if (UIAccessibilityIsVoiceOverRunning()) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
            MBCIOSLocalizedString(@"ios_controls_visible_voiceover",
                                  @"Controls stay visible while VoiceOver is on."));
        return;
    }
    self.boardOnly = YES;
}

- (void)showBoardOnlyHintIfNeeded
{
    static NSString * const hintShownKey = @"MBCIOSBoardOnlyHintShown";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:hintShownKey] || !self.boardOnly) return;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:hintShownKey];

    MBCIOSBoardChromeView *hint = [[MBCIOSBoardChromeView alloc] initWithCornerRadius:16.0];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.userInteractionEnabled = NO;
    UILabel *message = [[UILabel alloc] initWithFrame:CGRectZero];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.text = MBCIOSLocalizedString(@"ios_board_only_hint",
        @"Tap an empty square to show controls.");
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    message.adjustsFontForContentSizeCategory = YES;
    message.numberOfLines = 0;
    message.textAlignment = NSTextAlignmentCenter;
    message.textColor = UIColor.labelColor;
    [hint addSubview:message];
    [self.view addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14.0],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        [hint.widthAnchor constraintLessThanOrEqualToConstant:320.0],
        [hint.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        [message.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor constant:16.0],
        [message.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor constant:-16.0],
        [message.topAnchor constraintEqualToAnchor:hint.topAnchor constant:12.0],
        [message.bottomAnchor constraintEqualToAnchor:hint.bottomAnchor constant:-12.0]
    ]];
    self.boardOnlyHintBanner = hint;
    hint.contentVisible = NO;
    [UIView animateWithDuration:0.2 delay:0.28
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{ hint.contentVisible = YES; } completion:nil];
    __weak ChessIOSViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ChessIOSViewController *strongSelf = weakSelf;
        if (strongSelf.boardOnlyHintBanner != hint) return;
        [UIView animateWithDuration:0.2
                         animations:^{ hint.contentVisible = NO; }
                         completion:^(BOOL finished) {
            (void)finished;
            [hint removeFromSuperview];
            if (strongSelf.boardOnlyHintBanner == hint) strongSelf.boardOnlyHintBanner = nil;
        }];
    });
}

- (void)showControlsAction:(id)sender
{
    (void)sender;
    self.boardOnly = NO;
}

- (void)handleBoardIdleTap:(NSNotification *)notification
{
    if (notification.object == self.boardView && self.boardOnly &&
        !self.presentedViewController) [self showControlsAction:nil];
}

- (void)handleVoiceOverStatusChanged:(NSNotification *)notification
{
    (void)notification;
    if (UIAccessibilityIsVoiceOverRunning()) self.boardOnly = NO;
}

- (void)newGameAction:(UIButton *)sender
{
    (void)sender;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    MBCVariant variant = self.variant;
    MBCPlayers players = (MBCPlayers)[defaults integerForKey:kMBCNewGamePlayers];
    MBCSideCode sideCode = (MBCSideCode)[defaults integerForKey:kMBCNewGameSides];
    NSInteger searchTime = [defaults integerForKey:kMBCSearchTime];
    if (searchTime < 1) searchTime = 1;

    __weak ChessIOSViewController *weakSelf = self;
    MBCIOSNewGameViewController *newGame =
        [[MBCIOSNewGameViewController alloc] initWithVariant:variant
                                                     players:players
                                                    sideCode:sideCode
                                                  searchTime:searchTime
                                                  completion:^(BOOL confirmed,
                                                               MBCVariant selectedVariant,
                                                               MBCPlayers selectedPlayers,
                                                               MBCSideCode selectedSideCode,
                                                               NSInteger selectedSearchTime,
                                                               BOOL rotateAfterMove,
                                                               BOOL confirmNextTurn,
                                                               BOOL keepDisplayAwake) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || !confirmed) return;
        if (selectedPlayers == kHumanVsGameCenter) {
            if (strongSelf.players == kHumanVsGameCenter &&
                MBCIOSMatchIDForMetadata(strongSelf.gameMetadata).length) {
                [strongSelf enqueueGameCenterMessage:MBCIOSLocalizedString(
                    @"ios_game_center_switch_local_first",
                    @"Open a local game before starting another Game Center match.")];
                return;
            }
            NSError *saveError = nil;
            if (![strongSelf saveCurrentGame:&saveError]) {
                [strongSelf showDocumentError:saveError];
                return;
            }
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setInteger:selectedPlayers forKey:kMBCNewGamePlayers];
            [defaults setInteger:selectedVariant forKey:kMBCNewGameVariant];
            [defaults setInteger:selectedSideCode forKey:kMBCNewGameSides];
            [defaults setInteger:selectedSearchTime forKey:kMBCSearchTime];
            [strongSelf.gameCenterManager presentMatchmakerForVariant:selectedVariant
                                                               sideCode:selectedSideCode
                                                              presenter:strongSelf];
            return;
        }
        [strongSelf startNewGameWithVariant:selectedVariant
                                    players:selectedPlayers
                                   sideCode:selectedSideCode
                                 searchTime:selectedSearchTime
                           rotateAfterMove:rotateAfterMove
                          confirmNextTurn:confirmNextTurn
                         keepDisplayAwake:keepDisplayAwake
                                       name:MBCIOSLocalizedString(@"ios_new_game_name_default", @"New Game")];
    }];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:newGame];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.preferredContentSize = newGame.preferredContentSize;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)gameMenuAction:(UIButton *)sender
{
    (void)sender;
    __weak ChessIOSViewController *weakSelf = self;
    BOOL recording = self.recordingController.isRecording;
    NSMutableArray *gameItems = [@[
        @{ @"title": MBCIOSLocalizedString(@"ios_new_menu", @"New…"),
           @"symbol": @"plus", @"enabled": @YES,
           @"handler": ^{ [weakSelf newGameAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_open", @"Open…"),
           @"symbol": @"folder", @"enabled": @YES,
           @"handler": ^{ [weakSelf openDocumentAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_recent_games", @"Open Recent"),
           @"symbol": @"clock.arrow.circlepath", @"enabled": @(self.gameLibrary != nil),
           @"handler": ^{ [weakSelf showRecentGamesAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_save", @"Save"),
           @"symbol": @"square.and.arrow.down", @"enabled": @(self.board != nil),
           @"handler": ^{ [weakSelf saveDocumentAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_save_game_as", @"Save As…"),
           @"symbol": @"square.on.square", @"enabled": @(self.board != nil && self.gameLibrary != nil),
           @"handler": ^{ [weakSelf saveAsAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_rename_game", @"Rename Game"),
           @"symbol": @"pencil", @"enabled": @(self.activeGameRecord != nil),
           @"handler": ^{ [weakSelf renameCurrentGameAction:nil]; } },
        @{ @"title": recording
                ? MBCIOSLocalizedString(@"ios_stop", @"Stop Recording")
                : MBCIOSLocalizedString(@"ios_record", @"Record Game"),
           @"symbol": recording ? @"stop.circle" : @"record.circle", @"enabled": @YES,
           @"handler": ^{ [weakSelf toggleRecordingAction:weakSelf.recordButton]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_share_last_recording", @"Share Last Recording"),
           @"symbol": @"square.and.arrow.up", @"enabled": @([self lastAvailableRecordingURL] != nil),
           @"handler": ^{ [weakSelf shareLastRecordingAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_game_information", @"Edit Game Information"),
           @"symbol": @"info.circle", @"enabled": @(self.board != nil),
           @"handler": ^{ [weakSelf showGameInfoAction:nil]; } }
    ] mutableCopy];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [gameItems addObject:@{ @"title": MBCIOSLocalizedString(@"ios_new_window", @"New Window"),
           @"symbol": @"rectangle.on.rectangle", @"enabled": @YES,
           @"handler": ^{ [weakSelf newWindowAction:nil]; } }];
    }

    NSMutableArray *viewItems = [@[
        @{ @"title": MBCIOSLocalizedString(@"ios_edge_notation", @"Edge Notation"),
           @"subtitle": self.boardView.drawEdgeNotationLabels
               ? MBCIOSLocalizedString(@"ios_on", @"On")
               : MBCIOSLocalizedString(@"ios_off", @"Off"),
           @"symbol": @"textformat", @"enabled": @(self.boardView != nil),
           @"handler": ^{ [weakSelf toggleEdgeNotationAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_reset_camera", @"Reset Camera"),
           @"symbol": @"arrow.counterclockwise", @"enabled": @(self.boardView != nil),
           @"handler": ^{ [weakSelf resetCameraAction:nil]; } }
    ] mutableCopy];
    if (self.players == kHumanVsHuman) {
        [viewItems addObjectsFromArray:@[
            @{ @"title": MBCIOSLocalizedString(@"ios_flip_board", @"Flip Board"),
               @"symbol": @"arrow.triangle.2.circlepath", @"enabled": @(self.boardView != nil),
               @"handler": ^{ [weakSelf flipBoardAction:nil]; } },
            @{ @"title": MBCIOSLocalizedString(@"ios_shared_board_options", @"Shared Board Options"),
               @"symbol": @"person.2", @"enabled": @YES,
               @"handler": ^{ [weakSelf sharedBoardOptionsAction:nil]; } }
        ]];
    }
    [viewItems addObject:@{ @"title": MBCIOSLocalizedString(@"ios_hide_controls", @"Hide Controls"),
        @"symbol": @"arrow.up.left.and.arrow.down.right", @"enabled": @YES,
        @"handler": ^{ [weakSelf hideControlsAction:nil]; } }];
    NSArray *chessItems = @[
        @{ @"title": MBCIOSLocalizedString(@"ios_preferences", @"Preferences…"),
           @"symbol": @"slider.horizontal.3", @"enabled": @YES,
           @"handler": ^{ [weakSelf preferencesAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_chess_help", @"Chess Help"),
           @"symbol": @"questionmark.circle", @"enabled": @YES,
           @"handler": ^{ [weakSelf showHelpAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_about_chess", @"About Chess"),
           @"symbol": @"info.circle", @"enabled": @YES,
           @"handler": ^{ [weakSelf showAboutAction:nil]; } }
    ];
    NSArray *gameCenterItems = @[
        @{ @"title": self.gameCenterManager.isAuthenticated
                ? MBCIOSLocalizedString(@"ios_game_center", @"Game Center")
                : MBCIOSLocalizedString(@"ios_game_center_sign_in_required", @"Game Center · Sign In Required"),
           @"symbol": @"person.2", @"enabled": @YES,
           @"handler": ^{ [weakSelf.gameCenterManager presentDashboardFromPresenter:weakSelf]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_game_center_matches", @"Existing Matches"),
           @"symbol": @"square.stack.3d.up", @"enabled": @(self.gameCenterManager.isAuthenticated),
           @"handler": ^{ [weakSelf showExistingMatchesAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_game_center_achievements", @"Achievements"),
           @"symbol": @"rosette", @"enabled": @(self.gameCenterManager.isAuthenticated),
           @"handler": ^{ [weakSelf.gameCenterManager presentAchievementsFromPresenter:weakSelf]; } }
    ];
    NSArray *sections = @[
        @{ @"title": MBCIOSLocalizedString(@"ios_game_section", @"Game"), @"items": gameItems },
        @{ @"title": MBCIOSLocalizedString(@"ios_view_section", @"View"), @"items": viewItems },
        @{ @"title": MBCIOSLocalizedString(@"ios_chess_section", @"Chess"), @"items": chessItems },
        @{ @"title": MBCIOSLocalizedString(@"ios_game_center", @"Game Center"), @"items": gameCenterItems }
    ];
    MBCIOSActionPanelViewController *panel =
        [[MBCIOSActionPanelViewController alloc] initWithSections:sections];
    panel.title = MBCIOSLocalizedString(@"ios_game_section", @"Game");
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = panel.preferredContentSize;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)actionsMenuAction:(UIButton *)sender
{
    (void)sender;
    BOOL available = [self canUseLocalGameActions];
    BOOL humanGame = self.players != kComputerVsComputer && self.engineSide != kBothSides;
    __weak ChessIOSViewController *weakSelf = self;
    NSArray *moves = @[
        @{ @"title": MBCIOSLocalizedString(@"ios_take_back", @"Take Back Move"),
           @"symbol": @"arrow.uturn.left", @"enabled": @(available &&
               (self.players == kHumanVsGameCenter ? self.board.numMoves >= 1 : [self.board canUndo])),
           @"handler": ^{ [weakSelf takebackAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_resign", @"Resign"),
           @"symbol": @"flag", @"enabled": @([self canResignCurrentGame]),
           @"handler": ^{ [weakSelf resignAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_offer_draw", @"Offer Draw"),
           @"symbol": @"equal.circle", @"enabled": @(available && humanGame),
           @"selected": @([self.gameMetadata[@"IOSPendingDrawOffer"] boolValue]),
           @"subtitle": [self.gameMetadata[@"IOSPendingDrawOffer"] boolValue] ?
               MBCIOSLocalizedString(@"ios_draw_offer_pending", @"Draw offer will accompany your next move.") : @"",
           @"handler": ^{ [weakSelf drawAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_enter_move", @"Enter Move"),
           @"symbol": @"keyboard", @"enabled": @([self canUseLocalGameActions] &&
               [self canReceiveLocalInput]),
           @"hint": @"⌘↩",
           @"handler": ^{ [weakSelf coordinateEntryAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_show_hint", @"Show Hint"),
           @"symbol": @"lightbulb", @"enabled": @(available && self.engine.lastPonder != nil),
           @"handler": ^{ [weakSelf showHintAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_show_last_move", @"Show Last Move"),
           @"symbol": @"arrow.turn.up.right", @"enabled": @(available && self.board.lastMove != nil),
           @"handler": ^{ [weakSelf showLastMoveAction:nil]; } },
        @{ @"title": MBCIOSLocalizedString(@"ios_game_log", @"Game Log"),
           @"symbol": @"list.number", @"enabled": @(self.board != nil),
           @"handler": ^{ [weakSelf showGameLogAction:nil]; } }
    ];
    MBCIOSActionPanelViewController *panel =
        [[MBCIOSActionPanelViewController alloc] initWithSections:@[
            @{ @"title": MBCIOSLocalizedString(@"ios_game_actions", @"Moves"), @"items": moves }
        ]];
    panel.title = MBCIOSLocalizedString(@"ios_game_actions", @"Moves");
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:panel];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = panel.preferredContentSize;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)takebackAction:(UIAlertAction *)action
{
    (void)action;
    if (![self canUseLocalGameActions]) return;

    if (self.players == kHumanVsGameCenter) {
        self.gameCenterAwaitingRemoteTurn = YES;
        [self.boardView wantMouse:NO];
        NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
        MBCBoard *requestBoard = self.board;
        int requestMoveCount = self.board.numMoves;
        NSData *matchData = [self gameCenterMatchData];
        [self.gameCenterManager requestTakebackWithData:matchData completion:^(NSError *error) {
            if (error) {
                if ([self isShowingGameCenterMatchID:matchID] &&
                    self.board == requestBoard && self.board.numMoves == requestMoveCount) {
                    self.gameCenterAwaitingRemoteTurn = NO;
                    [self updateLoadedGameState];
                }
                [self enqueueGameCenterError:error];
            }
        }];
        return;
    }
    if (![self.board canUndo]) return;

    [self.speechController stop];
    [self.engine stop];
    // A newly imported or custom-start game can have only one move to take back.
    // Retain the usual two-ply takeback when both plies exist.
    if (![self.board undoMoves:2] && ![self.board undoMoves:1]) return;
    if (!self.gameMetadata) self.gameMetadata = [NSMutableDictionary dictionary];
    self.gameMetadata[@"Result"] = @"*";
    [self.board commitMove];
    [self.boardView hideMoves];
    [self.boardView unselectPiece];
    MBCMove *lastMove = [self.board lastMove];
    if (lastMove) [self.boardView showMoveAsLast:lastMove];
    [self.boardView wantMouse:[self canReceiveLocalInput]];
    if (self.players == kHumanVsHuman && [self rotateAfterEachMoveForCurrentGame])
        [self resetCameraAction:nil];
    [self.boardView drawNow];
    [self updateGameStatusTitle];
    [self restartEngineFromCurrentBoard];
    [self autosaveCurrentGame];
}

- (BOOL)canResignCurrentGame
{
    if (self.players != kHumanVsGameCenter)
        return [self canUseLocalGameActions] && self.engineSide != kBothSides;
    return self.board && self.gameCenterBoardActivated && !self.gameCenterEndSubmitted &&
        !self.activeMoveAnimation && self.pendingMoveAnimations.count == 0 &&
        self.gameCenterManager.isAuthenticated &&
        [self.gameCenterManager.activeMatch.matchID isEqualToString:MBCIOSMatchIDForMetadata(self.gameMetadata)] &&
        self.gameCenterManager.activeMatch.status == GKTurnBasedMatchStatusOpen &&
        MBCIOSStoredOutcome(self.board, self.gameMetadata) == kCmdNull;
}

- (void)resignAction:(UIAlertAction *)action
{
    (void)action;
    if (![self canResignCurrentGame]) return;
    MBCBoard *board = self.board;
    NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:
        MBCIOSLocalizedString(@"ios_resign_game_title", @"Resign Game?") message:
        MBCIOSLocalizedString(@"ios_resign_game_message", @"End this game and declare the other side the winner?")
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_resign", @"Resign")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *confirm) {
        (void)confirm;
        if (self.board != board || ![self canResignCurrentGame]) return;
        MBCSide side = self.side;
        if (self.players == kHumanVsHuman || (side != kWhiteSide && side != kBlackSide))
            side = (board.numMoves & 1) ? kBlackSide : kWhiteSide;
        MBCMoveCode winner = side == kWhiteSide ? kCmdBlackWins : kCmdWhiteWins;
        if (self.players == kHumanVsGameCenter) {
            self.gameCenterEndSubmitted = YES;
            [self.boardView wantMouse:NO];
            [self.gameCenterManager resignWithData:[self gameCenterMatchData] completion:^(NSError *error) {
                if (self.board != board || ![self isShowingGameCenterMatchID:matchID]) return;
                if (error) {
                    self.gameCenterEndSubmitted = NO;
                    [self updateLoadedGameState];
                    [self enqueueGameCenterError:error];
                } else {
                    [[NSNotificationCenter defaultCenter] postNotificationName:MBCGameEndNotification
                        object:self userInfo:(id)[MBCMove moveWithCommand:winner]];
                }
            }];
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:MBCGameEndNotification
                object:self userInfo:(id)[MBCMove moveWithCommand:winner]];
        }
    }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (void)drawAction:(UIAlertAction *)action
{
    (void)action;
    if (![self canUseLocalGameActions] || self.engineSide == kBothSides) return;

    if (self.players == kHumanVsGameCenter) {
        self.gameMetadata[@"IOSPendingDrawOffer"] = @(![self.gameMetadata[@"IOSPendingDrawOffer"] boolValue]);
        [self autosaveCurrentGame];
        if ([self.gameMetadata[@"IOSPendingDrawOffer"] boolValue])
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                MBCIOSLocalizedString(@"ios_draw_offer_pending", @"Draw offer will accompany your next move."));
        return;
    }

    UIAlertController *confirmation =
        [UIAlertController alertControllerWithTitle:MBCIOSLocalizedString(@"ios_declare_draw_title", @"Declare a Draw?")
                                            message:MBCIOSLocalizedString(@"ios_declare_draw_message", @"End this local game as a draw?")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_draw_action", @"Draw")
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *confirm) {
        (void)confirm;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCGameEndNotification
                          object:self
                        userInfo:(id)[MBCMove moveWithCommand:kCmdDraw]];
    }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (void)showHintAction:(UIAlertAction *)action
{
    (void)action;
    MBCMove *hint = self.engine.lastPonder;
    if (!hint || !self.boardView) return;
    [self.boardView showMoveAsHint:hint];
    [self.boardView drawNow];
    BOOL computerMove = [self isComputerMove:hint];
    [self.speechController announceHint:hint
                         alternateVoice:[self usesAlternateVoiceForMove:hint
                                                           computerMove:computerMove]];
}

- (void)coordinateEntryAction:(id)sender
{
    (void)sender;
    if (![self canUseLocalGameActions] || ![self canReceiveLocalInput] ||
        self.presentedViewController) return;
    MBCBoard *entryBoard = self.board;
    __weak ChessIOSViewController *weakSelf = self;
    MBCIOSCoordinateEntryViewController *entry =
        [[MBCIOSCoordinateEntryViewController alloc]
            initWithBoard:entryBoard variant:self.variant allowedSide:self.side
            submissionHandler:^BOOL(MBCMove *move, NSString **rejectionMessage) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.board != entryBoard ||
            ![strongSelf canUseLocalGameActions] || ![strongSelf canReceiveLocalInput]) {
            if (rejectionMessage) *rejectionMessage = MBCIOSLocalizedString(
                @"ios_coordinate_turn_changed", @"The turn changed. Reopen move entry to continue.");
            return NO;
        }
        [strongSelf.boardView iosSubmitMove:move];
        return YES;
    }];
    entry.promotionChangedHandler = ^(MBCPieceCode choice) {
        (void)choice;
        [weakSelf.boardView drawNow];
    };
    [self presentViewController:entry animated:YES completion:nil];
}

- (void)showAboutAction:(id)sender
{
    (void)sender;
    MBCIOSAboutViewController *about = [[MBCIOSAboutViewController alloc] init];
    [self presentViewController:about animated:YES completion:nil];
}

- (void)showHelpAction:(id)sender
{
    (void)sender;
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://support.apple.com/guide/chess/welcome/mac"]
        options:@{} completionHandler:nil];
}

- (void)newWindowAction:(id)sender
{
    (void)sender;
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    UISceneActivationRequestOptions *options = nil;
    if (@available(iOS 15.0, *)) {
        UIWindowSceneActivationRequestOptions *windowOptions =
            [[UIWindowSceneActivationRequestOptions alloc] init];
        windowOptions.preferredPresentationStyle = UIWindowScenePresentationStyleProminent;
        options = windowOptions;
    } else {
        options = [[UISceneActivationRequestOptions alloc] init];
    }
    options.requestingScene = self.view.window.windowScene;
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:@"com.apple.Chess.game"];
    activity.title = MBCIOSLocalizedString(@"ios_new_window", @"New Window");
    activity.targetContentIdentifier = NSUUID.UUID.UUIDString;
    activity.eligibleForHandoff = NO;
    activity.eligibleForSearch = NO;
    NSLog(@"Chess requested a new iPad scene from %@", options.requestingScene.session.persistentIdentifier);
    __weak ChessIOSViewController *weakSelf = self;
    [UIApplication.sharedApplication requestSceneSessionActivation:nil
        userActivity:activity options:options errorHandler:^(NSError *error) {
        NSLog(@"Chess new-window request failed: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf showDocumentError:error]; });
    }];
}

- (void)showLastMoveAction:(UIAlertAction *)action
{
    (void)action;
    MBCMove *lastMove = self.board.lastMove;
    if (!lastMove || !self.boardView) return;
    [self.boardView showMoveAsLast:lastMove];
    [self.boardView drawNow];
    BOOL computerMove = [self isComputerMove:lastMove];
    [self.speechController announceLastMove:lastMove
                            alternateVoice:[self usesAlternateVoiceForMove:lastMove
                                                              computerMove:computerMove]];
}

- (void)toggleEdgeNotationAction:(UIAlertAction *)action
{
    (void)action;
    if (!self.boardView) return;
    BOOL showing = self.boardView.drawEdgeNotationLabels;
    self.boardView.drawEdgeNotationLabels = !showing;
    [[NSUserDefaults standardUserDefaults] setBool:!showing forKey:kMBCShowEdgeNotation];
    self.gameMetadata[kMBCShowEdgeNotation] = @(!showing);
    [self.boardView drawNow];
    [self autosaveCurrentGame];
}

- (void)preferencesAction:(UIAlertAction *)action
{
    (void)action;
    __weak ChessIOSViewController *weakSelf = self;
    MBCBoard *preferenceBoard = self.board;
    MBCIOSFillGamePreferences(self.gameMetadata);
    NSString *currentBoardStyle = [MBCIOSBoardStyleNames() containsObject:self.boardStyle]
        ? self.boardStyle : @"Wood";
    NSString *currentPieceStyle = [MBCIOSPieceStyleNames() containsObject:self.pieceStyle]
        ? self.pieceStyle : @"Wood";
    BOOL autoRotateBoard = [[NSUserDefaults standardUserDefaults]
                            boolForKey:kMBCAutoRotateBoard];
    MBCIOSPreferencesViewController *preferences =
        [[MBCIOSPreferencesViewController alloc]
            initWithBoardStyle:currentBoardStyle pieceStyle:currentPieceStyle
              autoRotateBoard:autoRotateBoard
                   completion:^(BOOL confirmed, NSString *boardStyle,
                                NSString *pieceStyle, BOOL rotateBoard) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.board != preferenceBoard || !confirmed || !boardStyle.length || !pieceStyle.length) return;
        [strongSelf applyBoardStyle:boardStyle pieceStyle:pieceStyle];
        [strongSelf applyAutoRotatePreference:rotateBoard];
        [strongSelf.speechController reloadSettings];
    }];
    __weak MBCIOSPreferencesViewController *weakPreferences = preferences;
    preferences.rendererCompletion = ^BOOL(MBCIOSRendererKind kind) {
        NSError *error = nil;
        if ([MBCIOSRendererPreferences.sharedPreferences selectRenderer:kind error:&error]) return YES;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:
            NSLocalizedString(@"Unable to Change Renderer", nil)
            message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_ok", @"OK")
            style:UIAlertActionStyleDefault handler:nil]];
        [weakPreferences presentViewController:alert animated:YES completion:nil];
        return NO;
    };
    preferences.gameSettings = self.gameMetadata;
    preferences.showsComputerStrength = self.engineSide != kNeitherSide;
    preferences.settingsCompletion = ^(NSDictionary *settings) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.board != preferenceBoard) return;
        [strongSelf.gameMetadata addEntriesFromDictionary:settings];
        if (settings[kMBCSearchTime]) {
            NSInteger minimum = [strongSelf.gameMetadata[kMBCMinSearchTime] integerValue];
            NSInteger strength = [settings[kMBCSearchTime] integerValue];
            strongSelf.gameMetadata[kMBCMinSearchTime] = @(minimum > 0 ? MIN(minimum, strength) : strength);
        }
        strongSelf.speechController.gameSettings = strongSelf.gameMetadata;
        if (settings[kMBCSearchTime]) [strongSelf.engine setSearchTime:[settings[kMBCSearchTime] integerValue]];
        [strongSelf autosaveCurrentGame];
    };
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:preferences];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)applyStylePreference:(NSString *)styleName
{
    [self applyBoardStyle:styleName pieceStyle:styleName];
}

- (void)applyBoardStylePreference:(NSString *)styleName
{
    [self applyBoardStyle:styleName pieceStyle:self.pieceStyle ?: @"Wood"];
}

- (void)applyPieceStylePreference:(NSString *)styleName
{
    [self applyBoardStyle:self.boardStyle ?: @"Wood" pieceStyle:styleName];
}

- (void)applyBoardStyle:(NSString *)boardStyle pieceStyle:(NSString *)pieceStyle
{
    if (![MBCIOSBoardStyleNames() containsObject:boardStyle] ||
        ![MBCIOSPieceStyleNames() containsObject:pieceStyle]) return;
    self.boardStyle = boardStyle;
    self.pieceStyle = pieceStyle;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:boardStyle forKey:kMBCBoardStyle];
    [defaults setObject:pieceStyle forKey:kMBCPieceStyle];

    if (self.boardView) {
        [self.boardView setStyleForBoard:self.boardStyle pieces:self.pieceStyle];
        [self.boardView drawNow];
    }
    [self autosaveCurrentGame];
}

- (void)applyAutoRotatePreference:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kMBCAutoRotateBoard];
}

- (void)sharedBoardOptionsAction:(id)sender
{
    (void)sender;
    if (self.players != kHumanVsHuman || !self.board) return;
    id storedRotation = self.gameMetadata[@"IOSRotateAfterEachMove"];
    BOOL rotate = storedRotation ? [storedRotation boolValue] :
        [[NSUserDefaults standardUserDefaults] boolForKey:kMBCAutoRotateBoard];
    BOOL handoff = [self.gameMetadata[@"IOSConfirmNextTurn"] boolValue];
    BOOL awake = [self.gameMetadata[@"IOSKeepDisplayAwake"] boolValue];
    __weak ChessIOSViewController *weakSelf = self;
    MBCIOSSharedBoardOptionsViewController *options =
        [[MBCIOSSharedBoardOptionsViewController alloc]
            initWithRotateAfterMove:rotate confirmNextTurn:handoff
                  keepDisplayAwake:awake
                        completion:^(BOOL selectedRotate, BOOL selectedHandoff,
                                     BOOL selectedAwake) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.players != kHumanVsHuman) return;
        if (rotate && !selectedRotate) {
            [strongSelf cancelBoardTurnAnimation];
            BOOL fixedBlack = [strongSelf.boardView facing] == kBlackSide;
            strongSelf.gameMetadata[@"IOSFixedBoardBlack"] = @(fixedBlack);
            strongSelf.boardView.azimuth = fixedBlack ? 0.0f : 180.0f;
            [strongSelf.boardView drawNow];
        }
        strongSelf.gameMetadata[@"IOSRotateAfterEachMove"] = @(selectedRotate);
        strongSelf.gameMetadata[@"IOSConfirmNextTurn"] = @(selectedHandoff);
        strongSelf.gameMetadata[@"IOSKeepDisplayAwake"] = @(selectedAwake);
        if (selectedRotate && !rotate) [strongSelf resetCameraAction:nil];
        [strongSelf updateIdleTimerForSharedGames];
        [strongSelf autosaveCurrentGame];
    }];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:options];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)flipBoardAction:(id)sender
{
    (void)sender;
    if (self.players != kHumanVsHuman || !self.boardView ||
        self.boardTurnAnimationDisplayLink) return;
    self.boardView.azimuth = fmodf(self.boardView.azimuth + 180.0f + 360.0f, 360.0f);
    self.gameMetadata[@"IOSFixedBoardBlack"] = @([self.boardView facing] == kBlackSide);
    [self.boardView drawNow];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
    [self autosaveCurrentGame];
}

- (void)updateIdleTimerForSharedGames
{
    BOOL keepAwake = NO;
    @synchronized([ChessIOSViewController class]) {
        for (ChessIOSViewController *controller in MBCIOSLiveGameControllers()) {
            UIWindow *window = controller.viewIfLoaded.window;
            UIWindowScene *scene = window.windowScene;
            if (!window || (scene &&
                scene.activationState != UISceneActivationStateForegroundActive)) continue;
            if (controller.players == kHumanVsHuman &&
                [controller.gameMetadata[@"IOSKeepDisplayAwake"] boolValue] &&
                MBCIOSStoredOutcome(controller.board, controller.gameMetadata) == kCmdNull) {
                keepAwake = YES;
                break;
            }
        }
    }
    UIApplication.sharedApplication.idleTimerDisabled = keepAwake;
}

- (void)showGameInfoAction:(UIAlertAction *)action
{
    (void)action;
    [self presentGameInfoSheetEditing:YES];
}

- (void)showGameLogAction:(id)sender
{
    (void)sender;
    [self presentGameInfoSheet];
}

- (void)presentGameInfoSheet
{
    [self presentGameInfoSheetEditing:NO];
}

- (void)presentGameInfoSheetEditing:(BOOL)editing
{
    if (!self.board) return;
    __weak ChessIOSViewController *weakSelf = self;
    MBCIOSGameInfoViewController *info =
        [[MBCIOSGameInfoViewController alloc] initWithBoard:self.board
                                                   metadata:self.gameMetadata
                                                       side:self.side
                                                 saveHandler:^(NSDictionary *metadata) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        for (NSString *key in @[@"White", @"Black", @"City", @"Country", @"Event"]) {
            if (metadata[key]) strongSelf.gameMetadata[key] = metadata[key];
        }
        [strongSelf updateGameStatusTitle];
        [strongSelf autosaveCurrentGame];
    }];
    self.gameInfoController = info;
    info.title = MBCIOSLocalizedString(@"ios_game_log", @"Game Log");
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:info];
    if (editing) [navigation pushViewController:[info makeMetadataEditor] animated:NO];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)installCameraResetButtonInContainer:(UIView *)container
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *resetImage = [UIImage systemImageNamed:@"arrow.counterclockwise"];
    if (resetImage) [button setImage:resetImage forState:UIControlStateNormal];
    else [button setTitle:@"↺" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightMedium];
    button.accessibilityLabel = MBCIOSLocalizedString(@"ios_reset_camera", @"Reset camera");
    button.accessibilityHint = MBCIOSLocalizedString(@"ios_restore_default_board_view", @"Restore the default board view");
    button.tintColor = UIColor.labelColor;
    MBCIOSBoardChromeView *material = [[MBCIOSBoardChromeView alloc] initWithCornerRadius:22.0];
    material.frame = button.bounds;
    material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    material.userInteractionEnabled = NO;
    // Realize UIButton's lazily created image view before placing the material.
    // Otherwise UIKit can insert the symbol below our background on first layout.
    UIView *buttonContent = resetImage ? button.imageView : button.titleLabel;
    [button insertSubview:material belowSubview:buttonContent];
    self.cameraResetChrome = material;
    [button addTarget:self action:@selector(resetCameraAction:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:8.0],
        [button.trailingAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-8.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0]
    ]];
    self.cameraResetButton = button;
}

- (void)installGameResultIndicatorInContainer:(UIView *)container
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.hidden = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.78];
    label.layer.cornerRadius = 15.0;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.layer.masksToBounds = YES;
    label.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_result", @"Game result");
    label.isAccessibilityElement = YES;
    label.userInteractionEnabled = NO;
    UITapGestureRecognizer *resumeTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(resumePausedComputerAction:)];
    [label addGestureRecognizer:resumeTap];
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.topAnchor constant:12.0],
        [label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.safeAreaLayoutGuide.leadingAnchor constant:64.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:container.safeAreaLayoutGuide.trailingAnchor constant:-64.0],
        [label.heightAnchor constraintGreaterThanOrEqualToConstant:38.0]
    ]];
    self.gameResultLabel = label;
}

- (void)clearGameResultIndicator
{
    self.gameResultLabel.hidden = YES;
    self.gameResultLabel.text = nil;
    self.gameResultLabel.accessibilityValue = nil;
    self.gameResultLabel.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_result", @"Game result");
    self.gameResultLabel.accessibilityHint = nil;
    self.gameResultLabel.accessibilityTraits = UIAccessibilityTraitStaticText;
    self.gameResultLabel.userInteractionEnabled = NO;
    [self updateGameStatusTitle];
}

- (void)updateLoadedGameState
{
    self.gameResultLabel.userInteractionEnabled = NO;
    self.gameResultLabel.accessibilityHint = nil;
    self.gameResultLabel.accessibilityTraits = UIAccessibilityTraitStaticText;
    MBCMoveCode outcome = MBCIOSStoredOutcome(self.board, self.gameMetadata);
    if (outcome != kCmdNull) {
        MBCMoveCode boardOutcome = [self.board outcome];
        if (boardOutcome != kCmdNull) {
            self.gameMetadata[@"Result"] = boardOutcome == kCmdWhiteWins ? @"1-0" :
                boardOutcome == kCmdBlackWins ? @"0-1" : @"1/2-1/2";
        }
        NSString *title = MBCIOSGameResultTitle(outcome);
        self.gameResultLabel.text = title;
        self.gameResultLabel.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_result", @"Game result");
        self.gameResultLabel.accessibilityValue = title;
        self.gameResultLabel.hidden = NO;
        [self.boardView wantMouse:NO];
        [self.engine stop];
    } else if (self.players == kHumanVsGameCenter && ![self isCurrentGameCenterMatchActive]) {
        NSString *status = nil;
        if (!self.gameCenterManager.isAuthenticated) {
            status = MBCIOSLocalizedString(@"ios_game_center_sign_in_to_resume", @"Sign in to Game Center to resume this match.");
        } else if (self.gameCenterResumeError) {
            status = [NSString localizedStringWithFormat:
                MBCIOSLocalizedString(@"ios_game_center_resume_failed",
                    @"Could not open this match: %@. Open Existing Matches to retry."),
                self.gameCenterResumeError.localizedDescription];
        } else {
            status = MBCIOSLocalizedString(@"ios_game_center_opening_match", @"Opening Game Center match…");
        }
        self.gameResultLabel.text = status;
        self.gameResultLabel.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_center", @"Game Center");
        self.gameResultLabel.accessibilityValue = status;
        self.gameResultLabel.hidden = NO;
        [self.boardView wantMouse:NO];
    } else if (self.engineSide != kNeitherSide && !self.engine.isRunning) {
        NSString *status = MBCIOSLocalizedString(@"ios_computer_paused_tap",
            @"Computer opponent paused. Tap here to resume.");
        self.gameResultLabel.text = status;
        self.gameResultLabel.accessibilityLabel = MBCIOSLocalizedString(@"ios_game_status", @"Game status");
        self.gameResultLabel.accessibilityValue = status;
        self.gameResultLabel.accessibilityHint = MBCIOSLocalizedString(
            @"ios_resume_computer_hint", @"Resume computer play in this window.");
        self.gameResultLabel.accessibilityTraits = UIAccessibilityTraitButton;
        self.gameResultLabel.userInteractionEnabled = YES;
        self.gameResultLabel.hidden = NO;
        [self.boardView wantMouse:NO];
    } else {
        [self clearGameResultIndicator];
        [self.boardView wantMouse:[self canReceiveLocalInput]];
    }
    [self updateGameStatusTitle];
    [self.boardView drawNow];
    [self updateIdleTimerForSharedGames];
}

- (void)updateGameStatusTitle
{
    self.title = MBCIOSGameStatusTitle(self.board, self.gameMetadata);
    [self updateMoveHistoryUI];
}

- (void)resetCameraAction:(UIButton *)sender
{
    (void)sender;
    [self cancelBoardTurnAnimation];
    [self.boardView resetCamera];
    self.boardView.azimuth = [self boardAzimuthForCurrentGame];
    [self.boardView wantMouse:[self canReceiveLocalInput]];
    [self.boardView drawNow];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.boardView);
    [self storeCameraPreferences:nil];
    [self presentTurnHandoffIfNeeded];
}

- (void)showDocumentError:(NSError *)error
{
    if (!error || error.code == MBCIOSDocumentErrorCancelled) return;
    if ([error.domain isEqualToString:MBCIOSGameLibraryErrorDomain] &&
        error.code == MBCIOSGameLibraryErrorConflict) {
        if (![self canPresentLibraryAlert]) {
            self.pendingLibraryConflict = error;
            return;
        }
        self.pendingLibraryConflict = nil;
        self.notifiedLibraryConflictIdentifier = self.activeGameRecord.identifier;
        NSString *message = [NSString stringWithFormat:@"%@\n%@",
            error.localizedDescription ?: MBCIOSLocalizedString(@"ios_library_conflict", @"This saved game changed in another window."),
            MBCIOSLocalizedString(@"ios_library_conflict_recovery",
                @"The current board is still open. Save a copy to keep its changes.")];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:MBCIOSLocalizedString(@"ios_library_conflict_title", @"Saved Game Changed")
                            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_keep_playing", @"Keep Playing")
                                                  style:UIAlertActionStyleCancel handler:nil]];
        __weak ChessIOSViewController *weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_save_copy", @"Save Copy")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf saveAsAction:nil]; });
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:MBCIOSLocalizedString(@"ios_chess_title", @"Chess")
                                                                       message:error.localizedDescription ?: MBCIOSLocalizedString(@"ios_document_operation_failed", @"The document operation failed.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_ok", @"OK")
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification
{
    if ([notification.object isKindOfClass:[UIScene class]] && self.view.window.windowScene &&
        notification.object != self.view.window.windowScene) return;
    if (![self rendererSceneIsForeground]) return;
    [self.boardBackend setRenderingActive:YES];
    if (self.orientationTransitionCompleting)
        [self finishBoardOrientationTransition:self.orientationTransitionGeneration];
    MBCIOSRendererPreferences *preferences = MBCIOSRendererPreferences.sharedPreferences;
    if (preferences.desiredRenderer != self.boardBackend.kind || preferences.revision > self.rendererRevision)
        [self requestRenderer:preferences.desiredRenderer revision:preferences.revision prepared:nil];
    [self applyPendingRendererChange];
    if (self.engineSide != kNeitherSide && !self.engine.isRunning)
        [self restartEngineFromCurrentBoard];
    [self updateIdleTimerForSharedGames];
    [self presentTurnHandoffIfNeeded];
    [self presentPendingLibraryConflict];
}

- (void)handleWindowDidBecomeKey:(NSNotification *)notification
{
    if (notification.object != self.view.window) return;
    [self.gameCenterManager becomePreferredEventTarget];
    if (self.engineSide != kNeitherSide && !self.engine.isRunning)
        [self restartEngineFromCurrentBoard];
    [self presentPendingLibraryConflict];
}

- (void)handleSceneWillDeactivate:(NSNotification *)notification
{
    if ([notification.object isKindOfClass:[UIScene class]] &&
        notification.object != self.view.window.windowScene) return;
    [self.boardBackend setRenderingActive:NO];
    if (self.engine.isRunning) {
        [self.engine stop];
        [self updateLoadedGameState];
    }
    __weak ChessIOSViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateIdleTimerForSharedGames];
    });
}

- (void)handleChessEngineDidStop:(NSNotification *)notification
{
    if (notification.object == self.engine && !self.engine.isRunning)
        [self updateLoadedGameState];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
    if (self.view.window.isKeyWindow) [self.gameCenterManager becomePreferredEventTarget];
    self.hasAppearedOnScreen = YES;
    if ([self rendererSceneIsForeground]) {
        [self.boardBackend setRenderingActive:YES];
        if (self.orientationTransitionCompleting)
            [self finishBoardOrientationTransition:self.orientationTransitionGeneration];
        MBCIOSRendererPreferences *preferences = MBCIOSRendererPreferences.sharedPreferences;
        if (preferences.desiredRenderer != self.boardBackend.kind || preferences.revision > self.rendererRevision)
            [self requestRenderer:preferences.desiredRenderer revision:preferences.revision prepared:nil];
        [self applyPendingRendererChange];
    }
    if (self.engineSide != kNeitherSide && !self.engine.isRunning)
        [self restartEngineFromCurrentBoard];
    [self updateIdleTimerForSharedGames];
    [self presentTurnHandoffIfNeeded];
    [self presentPendingLibraryConflict];
}

- (void)resumePausedComputerAction:(UITapGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded ||
        self.engineSide == kNeitherSide || self.engine.isRunning) return;
    [self restartEngineFromCurrentBoard];
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray array];
    void (^add)(NSString *, UIKeyModifierFlags, SEL, NSString *) =
        ^(NSString *input, UIKeyModifierFlags flags, SEL action, NSString *title) {
        UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:input modifierFlags:flags action:action];
        command.discoverabilityTitle = title;
        [commands addObject:command];
    };
    add(@"z", UIKeyModifierCommand, @selector(takebackAction:), MBCIOSLocalizedString(@"ios_take_back", @"Take Back Move"));
    add(@"]", UIKeyModifierCommand, @selector(showHintAction:), MBCIOSLocalizedString(@"ios_show_hint", @"Show Hint"));
    add(@"[", UIKeyModifierCommand, @selector(showLastMoveAction:), MBCIOSLocalizedString(@"ios_show_last_move", @"Show Last Move"));
    add(@"l", UIKeyModifierCommand, @selector(showGameLogAction:), MBCIOSLocalizedString(@"ios_game_log", @"Game Log"));
    add(@"\r", UIKeyModifierCommand, @selector(coordinateEntryAction:), MBCIOSLocalizedString(@"ios_enter_move", @"Enter Move"));
    add(@"n", UIKeyModifierCommand, @selector(newGameAction:), MBCIOSLocalizedString(@"ios_new_game", @"New Game"));
    add(@"o", UIKeyModifierCommand, @selector(openDocumentAction:), MBCIOSLocalizedString(@"ios_open", @"Open…"));
    add(@"s", UIKeyModifierCommand, @selector(saveDocumentAction:), MBCIOSLocalizedString(@"ios_save", @"Save"));
    add(@",", UIKeyModifierCommand, @selector(preferencesAction:), MBCIOSLocalizedString(@"ios_preferences", @"Preferences…"));
    if (self.boardOnly) add(UIKeyInputEscape, 0, @selector(showControlsAction:), MBCIOSLocalizedString(@"ios_show_controls", @"Show Controls"));
    return commands;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
    for (UIKeyCommand *command in self.keyCommands) {
        if (command.action != action) continue;
        if (self.presentedViewController) return NO;
        if (action == @selector(takebackAction:))
            return [self canUseLocalGameActions] && (self.players == kHumanVsGameCenter ? self.board.numMoves >= 1 : [self.board canUndo]);
        if (action == @selector(showHintAction:)) return [self canUseLocalGameActions] && self.engine.lastPonder != nil;
        if (action == @selector(showLastMoveAction:)) return self.board.lastMove != nil;
        if (action == @selector(coordinateEntryAction:)) return [self canUseLocalGameActions] && [self canReceiveLocalInput];
        return YES;
    }
    return [super canPerformAction:action withSender:sender];
}

- (BOOL)canPresentLibraryAlert
{
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        !self.isViewLoaded || !self.view.window || self.presentedViewController) return NO;
    UIWindowScene *scene = self.view.window.windowScene;
    return !scene || scene.activationState == UISceneActivationStateForegroundActive;
}

- (void)presentPendingLibraryConflict
{
    if (!self.pendingLibraryConflict || self.libraryConflictCheckScheduled) return;
    if (![self canPresentLibraryAlert]) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (!self.isViewLoaded || !self.view.window ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            (scene && scene.activationState != UISceneActivationStateForegroundActive)) return;
        self.libraryConflictCheckScheduled = YES;
        __weak ChessIOSViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChessIOSViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.libraryConflictCheckScheduled = NO;
            [strongSelf presentPendingLibraryConflict];
        });
        return;
    }
    NSError *error = self.pendingLibraryConflict;
    self.pendingLibraryConflict = nil;
    [self showDocumentError:error];
}

- (BOOL)saveCurrentBoardAsCopyNamed:(NSString *)name error:(NSError **)error
{
    if (error) *error = nil;
    if (!self.board || !self.gameLibrary) {
        if (error) *error = [NSError errorWithDomain:MBCIOSGameLibraryErrorDomain
                                               code:MBCIOSGameLibraryErrorInvalidRequest
                                           userInfo:@{NSLocalizedDescriptionKey:
            MBCIOSLocalizedString(@"ios_no_active_game_save", @"Chess has no active board to save.")}];
        return NO;
    }
    NSMutableDictionary *metadata = [self.gameMetadata mutableCopy] ?: [NSMutableDictionary dictionary];
    metadata[@"IOSPlayers"] = @(self.players);
    MBCSide copySide = self.side;
    if (MBCIOSMatchIDForMetadata(metadata).length) {
        [metadata removeObjectsForKeys:@[@"MatchID", @"GameCenterMatchID",
            @"WhitePlayerID", @"BlackPlayerID", @"Request", @"Response",
            @"IOSPendingDrawOffer", @"IOSDeclinedDrawRequest"]];
        metadata[@"WhiteType"] = @"human";
        metadata[@"BlackType"] = @"human";
        metadata[@"IOSPlayers"] = @(kHumanVsHuman);
        copySide = kBothSides;
    }
    MBCIOSGameRecord *copy = [self.gameLibrary createGameNamed:name board:self.board
        variant:self.variant side:copySide boardStyle:self.boardStyle ?: @"Wood"
        pieceStyle:self.pieceStyle ?: @"Wood" metadata:metadata error:error];
    if (!copy) return NO;
    [self installLibraryBoard:self.board variant:self.variant side:copySide
                  boardStyle:self.boardStyle pieceStyle:self.pieceStyle
                    metadata:metadata record:copy];
    return YES;
}

- (BOOL)saveCurrentBoardAsRecoveredCopy:(NSError **)error
{
    NSString *originalName = self.activeGameRecord.name ?:
        MBCIOSLocalizedString(@"ios_casual_game_name", @"Casual Game");
    NSString *prefix = MBCIOSLocalizedString(@"ios_recovered_game_prefix", @"Recovered ");
    NSString *date = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterShortStyle
                                                    timeStyle:NSDateFormatterShortStyle];
    NSString *suffix = [NSString stringWithFormat:@" (%@)", date];
    NSUInteger availableLength = 120 > prefix.length + suffix.length
        ? 120 - prefix.length - suffix.length : 1;
    if (originalName.length > availableLength)
        originalName = [originalName substringToIndex:availableLength];
    NSString *name = [NSString stringWithFormat:@"%@%@%@", prefix, originalName, suffix];
    return [self saveCurrentBoardAsCopyNamed:name error:error];
}

- (void)promptForGameNameWithTitle:(NSString *)title
                    suggestedName:(NSString *)suggestedName
                       completion:(void (^)(NSString *name))completion
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = suggestedName;
        field.placeholder = MBCIOSLocalizedString(@"ios_game_name", @"Game name");
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    __weak ChessIOSViewController *weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_save", @"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        NSString *name = [weakAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length || name.length > 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf promptForGameNameWithTitle:MBCIOSLocalizedString(@"ios_game_name_invalid",
                    @"Use a name of 1 to 120 characters") suggestedName:name completion:completion];
            });
            return;
        }
        if (completion) completion(name);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)installLibraryBoard:(MBCBoard *)board variant:(MBCVariant)variant
                      side:(MBCSide)side boardStyle:(NSString *)boardStyle
                pieceStyle:(NSString *)pieceStyle metadata:(NSDictionary *)metadata
                    record:(MBCIOSGameRecord *)record
{
    [self cancelMoveAnimation];
    [self.speechController stop];
    [self.engine stop];
    if (![MBCIOSMatchIDForMetadata(metadata) isEqualToString:self.gameCenterManager.activeMatch.matchID])
        [self.gameCenterManager releaseActiveMatch];
    self.gameCenterBoardActivated = NO;
    self.gameCenterAwaitingRemoteTurn = NO;
    self.gameCenterResumeError = nil;
    self.gameCenterEndSubmitted = NO;
    self.activeMoveIsRemote = NO;
    self.board = board;
    self.variant = variant;
    self.boardStyle = boardStyle ?: @"Wood";
    self.pieceStyle = pieceStyle ?: @"Wood";
    NSMutableDictionary *merged = [[MBCIOSGameStore defaultMetadataForSide:side] mutableCopy];
    if (metadata) [merged addEntriesFromDictionary:metadata];
    self.gameMetadata = merged;
    self.activeGameRecord = record;
    self.nextLibraryGameName = nil;
    [self restorePlayerModeForSide:side metadata:merged];
    [self.speechController setBoard:board];
    [self.boardView setBoard:board];
    [self.boardView startGame:variant playing:self.side];
    [self applyGamePreferences];
    [self.boardView setStyleForBoard:self.boardStyle pieces:self.pieceStyle];
    [self updateLoadedGameState];
    self.lastSavedGameSnapshot = [self currentGameSnapshot];
    self.pendingLibraryConflict = nil;
    self.notifiedLibraryConflictIdentifier = nil;
    if (self.engineSide != kNeitherSide) {
        [self restartEngineFromCurrentBoard];
    } else if (self.players == kHumanVsGameCenter && self.gameCenterManager.isAuthenticated) {
        [self resumeGameCenterMatchWithID:MBCIOSMatchIDForMetadata(merged)];
    }
}

- (void)openLibraryGameWithIdentifier:(NSString *)identifier saveCurrent:(BOOL)saveCurrent
{
    if (!identifier.length || !self.gameLibrary) return;
    if ([identifier isEqualToString:self.activeGameRecord.identifier]) return;
    NSError *error = nil;
    if (saveCurrent && ![self saveCurrentGame:&error]) {
        [self showDocumentError:error];
        return;
    }
    MBCBoard *board = nil;
    MBCVariant variant = kVarNormal;
    MBCSide side = kBothSides;
    NSString *boardStyle = nil;
    NSString *pieceStyle = nil;
    NSDictionary *metadata = nil;
    MBCIOSGameRecord *record = [self.gameLibrary openGameWithIdentifier:identifier
        board:&board variant:&variant side:&side boardStyle:&boardStyle
        pieceStyle:&pieceStyle metadata:&metadata error:&error];
    if (!record) {
        [self showDocumentError:error];
        return;
    }
    if ([self otherGameCenterControllerForMatchID:MBCIOSMatchIDForMetadata(metadata)]) {
        [self showDocumentError:[self gameCenterAlreadyOpenError]];
        return;
    }
    [self installLibraryBoard:board variant:variant side:side
                  boardStyle:boardStyle pieceStyle:pieceStyle
                    metadata:metadata record:record];
}

- (void)showRecentGamesAction:(id)sender
{
    (void)sender;
    [self showLibraryGamesRecent:YES];
}

- (void)showSavedGamesAction:(id)sender
{
    (void)sender;
    [self showLibraryGamesRecent:NO];
}

- (NSSet<NSString *> *)openGameIdentifiers
{
    NSMutableSet *identifiers = [NSMutableSet set];
    @synchronized([ChessIOSViewController class]) {
        for (ChessIOSViewController *controller in MBCIOSLiveGameControllers()) {
            if (controller.activeGameIdentifier) [identifiers addObject:controller.activeGameIdentifier];
        }
    }
    return identifiers;
}

- (void)deleteSavedGame:(MBCIOSGameRecord *)record
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:record.name message:
        MBCIOSLocalizedString(@"ios_delete_game_message", @"Delete this saved game? This cannot be undone.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_delete_game", @"Delete Game")
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (![self.gameLibrary deleteGame:record excludingIdentifiers:[self openGameIdentifiers] error:&error])
            [self showDocumentError:error];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLibraryGamesRecent:(BOOL)recent
{
    NSError *error = nil;
    NSArray<MBCIOSGameRecord *> *records = recent ? [self.gameLibrary recentGamesWithError:&error] :
        [self.gameLibrary allGamesWithError:&error];
    if (!records) {
        [self showDocumentError:error];
        return;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    __weak ChessIOSViewController *weakSelf = self;
    for (MBCIOSGameRecord *record in records) {
        NSString *name = record.name;
        NSString *date = [formatter stringFromDate:record.modifiedAt];
        NSString *mode = record.matchID
            ? MBCIOSLocalizedString(@"ios_players_game_center", @"Game Center Match")
            : MBCIOSLocalizedString(@"ios_local_game", @"Local Game");
        NSString *subtitle = [NSString stringWithFormat:@"%@ · %@", mode, date];
        NSString *identifier = [record.identifier copy];
        NSMutableDictionary *item = [@{ @"title": name, @"subtitle": subtitle,
            @"symbol": @"checkerboard.rectangle",
            @"selected": @([record.identifier isEqualToString:self.activeGameRecord.identifier]),
            @"enabled": @YES,
            @"handler": ^{ [weakSelf openLibraryGameWithIdentifier:identifier saveCurrent:YES]; } } mutableCopy];
        if (![[self openGameIdentifiers] containsObject:identifier])
            item[@"deleteHandler"] = ^{ [weakSelf deleteSavedGame:record]; };
        [items addObject:item];
    }
    if (!items.count) {
        [items addObject:@{ @"title": MBCIOSLocalizedString(@"ios_no_saved_games", @"No saved games"),
            @"symbol": @"tray", @"enabled": @NO, @"handler": ^{} }];
    }
    if (recent) {
        [items addObject:@{ @"title": MBCIOSLocalizedString(@"ios_saved_games", @"Saved Games"),
            @"symbol": @"folder", @"enabled": @YES,
            @"handler": ^{ [weakSelf showSavedGamesAction:nil]; } }];
        [items addObject:@{ @"title": MBCIOSLocalizedString(@"ios_clear_menu", @"Clear Menu"),
            @"symbol": @"xmark.circle", @"enabled": @(records.count != 0),
            @"handler": ^{
                NSError *clearError = nil;
                if (![weakSelf.gameLibrary clearRecentGamesWithError:&clearError]) [weakSelf showDocumentError:clearError];
            } }];
    }
    NSString *title = recent ? MBCIOSLocalizedString(@"ios_recent_games", @"Open Recent") :
        MBCIOSLocalizedString(@"ios_saved_games", @"Saved Games");
    MBCIOSActionPanelViewController *panel = [[MBCIOSActionPanelViewController alloc]
        initWithSections:@[@{ @"title": title,
                             @"items": items }]];
    [panel loadViewIfNeeded];
    panel.title = title;
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:panel];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.preferredContentSize = panel.preferredContentSize;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)saveAsAction:(id)sender
{
    (void)sender;
    if (!self.board || !self.gameLibrary) return;
    NSString *sourceName = self.activeGameRecord.name ?:
        MBCIOSLocalizedString(@"ios_casual_game_name", @"Casual Game");
    [self promptForGameNameWithTitle:MBCIOSLocalizedString(@"ios_save_game_as", @"Save As…")
                    suggestedName:[sourceName stringByAppendingString:
                        MBCIOSLocalizedString(@"ios_game_copy_suffix", @" Copy")]
                       completion:^(NSString *name) {
        NSError *error = nil;
        if (![self saveCurrentBoardAsCopyNamed:name error:&error]) [self showDocumentError:error];
    }];
}

- (void)renameCurrentGameAction:(id)sender
{
    (void)sender;
    if (!self.activeGameRecord) return;
    MBCIOSGameRecord *source = self.activeGameRecord;
    [self promptForGameNameWithTitle:MBCIOSLocalizedString(@"ios_rename_game", @"Rename Game")
                    suggestedName:source.name
                       completion:^(NSString *name) {
        NSError *error = nil;
        MBCIOSGameRecord *record = [self.gameLibrary renameGame:source
                                                          toName:name error:&error];
        if (record) {
            if ([self.activeGameRecord.identifier isEqualToString:source.identifier]) {
                self.activeGameRecord = record;
                [self updateMoveHistoryUI];
            }
        } else {
            [self showDocumentError:error];
        }
    }];
}

- (BOOL)prepareForGameCenterMatchID:(NSString *)matchID
{
    if (!matchID.length || !self.activeGameRecord ||
        [self.activeGameRecord.matchID isEqualToString:matchID]) return YES;
    NSError *error = nil;
    if (![self saveCurrentGame:&error]) {
        NSError *recoveryError = nil;
        BOOL recovered = [error.domain isEqualToString:MBCIOSGameLibraryErrorDomain] &&
            error.code == MBCIOSGameLibraryErrorConflict &&
            [self saveCurrentBoardAsRecoveredCopy:&recoveryError];
        if (!recovered) {
            [self showDocumentError:recoveryError ?: error];
            return NO;
        }
    }
    self.activeGameRecord = nil;
    self.lastSavedGameSnapshot = nil;
    return YES;
}

- (void)openDocumentAction:(UIButton *)sender
{
    (void)sender;
    __weak ChessIOSViewController *weakSelf = self;
    [self.documentController presentOpenDocumentPickerWithCompletion:
     ^(MBCBoard *board, MBCVariant variant, MBCSide side,
       NSString *boardStyle, NSString *pieceStyle, NSError *error) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!error && board) {
            [strongSelf applyImportedBoard:board variant:variant side:side
                                 boardStyle:boardStyle pieceStyle:pieceStyle];
        }
        [strongSelf showDocumentError:error];
    }];
}

- (void)saveDocumentAction:(UIButton *)sender
{
    UIAlertController *formatPicker =
        [UIAlertController alertControllerWithTitle:self.activeGameRecord.name ?:
            MBCIOSLocalizedString(@"ios_save_game", @"Save Game")
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    __weak ChessIOSViewController *weakSelf = self;
    [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_save", @"Save")
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        (void)action;
        NSError *error = nil;
        if (![weakSelf saveCurrentGame:&error]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf showDocumentError:error]; });
        }
    }]];
    [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_save_game_as", @"Save As…")
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf saveAsAction:nil]; });
    }]];
    if (self.activeGameRecord) {
        [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_rename_game", @"Rename Game")
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction *action) {
            (void)action;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf renameCurrentGameAction:nil]; });
        }]];
    }
    [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_chess_game_format", @"Chess game (.game)")
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        (void)action;
        /* Let the action sheet finish dismissing before presenting the
         * document provider. iOS 14 can otherwise reject the second modal
         * presentation while the sheet is still its presenter. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChessIOSViewController *strongSelf = weakSelf;
            [strongSelf exportAfterFormatPickerDismissal:@"game"];
        });
    }]];
    [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_pgn_format", @"Portable Game Notation (.pgn)")
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
        (void)action;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChessIOSViewController *strongSelf = weakSelf;
            [strongSelf exportAfterFormatPickerDismissal:@"pgn"];
        });
    }]];
    [formatPicker addAction:[UIAlertAction actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
    UIView *anchor = sender.window ? sender :
        (self.actionToolbar.window && !self.actionToolbar.hidden ? self.actionToolbar : self.view);
    formatPicker.popoverPresentationController.sourceView = anchor;
    formatPicker.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:formatPicker animated:YES completion:nil];
}

- (void)exportAfterFormatPickerDismissal:(NSString *)extension
{
    if ([self.presentedViewController isKindOfClass:[UIAlertController class]]) {
        __weak ChessIOSViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ChessIOSViewController *strongSelf = weakSelf;
            [strongSelf exportAfterFormatPickerDismissal:extension];
        });
        return;
    }
    [self exportCurrentGameWithExtension:extension];
}

- (void)exportCurrentGameWithExtension:(NSString *)extension
{
    NSError *saveError = nil;
    if (!self.board || !self.documentController) {
        saveError = [NSError errorWithDomain:MBCIOSGameStoreErrorDomain
                                         code:MBCIOSGameStoreErrorInvalidGame
                                     userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(@"ios_no_active_game_export", @"Chess has no active game to export.")}];
        [self showDocumentError:saveError];
        return;
    }

    __weak ChessIOSViewController *weakSelf = self;
    [self.documentController presentExportForBoard:self.board
                                           variant:self.variant
                                              side:self.side
                                        boardStyle:self.boardStyle ?: @"Wood"
                                        pieceStyle:self.pieceStyle ?: @"Wood"
                                           metadata:self.gameMetadata
                                      suggestedName:self.activeGameRecord.name
                                         extension:extension
                                         completion:^(NSURL *destinationURL, NSError *error) {
        (void)destinationURL;
        ChessIOSViewController *strongSelf = weakSelf;
        if (strongSelf) [strongSelf showDocumentError:error];
    }];
}

- (void)updateRecordingButtonForActive:(BOOL)recording
{
    NSString *title = recording
        ? MBCIOSLocalizedString(@"ios_stop", @"Stop")
        : MBCIOSLocalizedString(@"ios_record", @"Record");
    [self.recordButton setTitle:title forState:UIControlStateNormal];
    [self.recordButton setImage:[UIImage systemImageNamed:
        recording ? @"stop.circle" : @"record.circle"] forState:UIControlStateNormal];
    self.recordButton.accessibilityLabel = title;
    self.recordButton.accessibilityValue = recording
        ? MBCIOSLocalizedString(@"ios_recording", @"Recording") : nil;
    self.recordButton.enabled = YES;
}

- (void)toggleRecordingAction:(UIButton *)sender
{
    if (self.recordingTransitioning || self.rendererChanging) return;
    if (self.recordingController.isRecording) {
        self.recordingTransitioning = YES;
        sender.enabled = NO;
        __weak ChessIOSViewController *weakSelf = self;
        [self.recordingController stopRecordingWithCompletionHandler:^(NSError *error) {
            ChessIOSViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.recordingTransitioning = NO;
            [strongSelf updateRecordingButtonForActive:NO];
            for (ChessIOSViewController *controller in MBCIOSLiveGameControllers().allObjects)
                [controller applyPendingRendererChange];
            if (error) {
                [strongSelf showDocumentError:error];
                return;
            }
            NSURL *outputURL = strongSelf.recordingController.outputURL;
            if (!outputURL) {
                [strongSelf showDocumentError:
                    [NSError errorWithDomain:MBCIOSRecordingErrorDomain
                                        code:MBCIOSRecordingErrorInvalidURL
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        MBCIOSLocalizedString(@"ios_recording_missing_output", @"The finished recording has no MP4 file to share.")}]];
                return;
            }
            NSDictionary *attributes = [[NSFileManager defaultManager]
                attributesOfItemAtPath:outputURL.path error:nil];
            if ([attributes fileSize] == 0) {
                [strongSelf presentRecordingExportForURL:outputURL sourceView:sender];
                return;
            }
            [MBCIOSRecordingController rememberCompletedRecordingAtURL:outputURL];
            [strongSelf presentRecordingExportForURL:outputURL sourceView:sender];
        }];
        return;
    }

    NSError *urlError = nil;
    NSURL *url = [MBCIOSRecordingController defaultRecordingURLWithError:&urlError];
    if (!url || ![MBCIOSRecordingController isAvailable]) {
        [self showDocumentError:urlError ?: [NSError errorWithDomain:MBCIOSRecordingErrorDomain
                                                                    code:MBCIOSRecordingErrorUnavailable
                                                                userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(@"ios_screen_recording_unavailable", @"Screen recording is unavailable in this runtime.")}]];
        return;
    }

    __weak ChessIOSViewController *weakSelf = self;
    sender.enabled = NO;
    self.recordingTransitioning = YES;
    self.recordingController.failureHandler = ^(NSError *error) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.recordingTransitioning = NO;
        [strongSelf updateRecordingButtonForActive:NO];
        for (ChessIOSViewController *controller in MBCIOSLiveGameControllers().allObjects)
            [controller applyPendingRendererChange];
        [strongSelf showDocumentError:error];
    };
    [self.recordingController startRecordingToURL:url completionHandler:^(NSError *error) {
        ChessIOSViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.recordingTransitioning = NO;
        if (error) {
            [strongSelf updateRecordingButtonForActive:NO];
            for (ChessIOSViewController *controller in MBCIOSLiveGameControllers().allObjects)
                [controller applyPendingRendererChange];
            [strongSelf showDocumentError:error];
            return;
        }
        [strongSelf updateRecordingButtonForActive:
            strongSelf.recordingController.isRecording];
    }];
}

- (NSURL *)lastAvailableRecordingURL
{
    return [MBCIOSRecordingController lastAvailableRecordingURL];
}

- (void)shareLastRecordingAction:(UIAlertAction *)action
{
    (void)action;
    [self presentRecordingExportForURL:[self lastAvailableRecordingURL]
                            sourceView:self.recordButton];
}

- (void)presentRecordingExportForURL:(NSURL *)url sourceView:(UIView *)sourceView
{
    NSError *fileError = nil;
    NSDictionary *attributes = url.isFileURL
        ? [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&fileError]
        : nil;
    if (!attributes || [attributes fileSize] == 0) {
        [self showDocumentError:fileError ?: [NSError errorWithDomain:MBCIOSRecordingErrorDomain
                                                                  code:MBCIOSRecordingErrorNoVideo
                                                              userInfo:@{NSLocalizedDescriptionKey:
                                                                  MBCIOSLocalizedString(@"ios_recording_no_shareable_video", @"The recording MP4 is unavailable or empty.")}]];
        return;
    }

    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    UIView *anchor = sourceView.window ? sourceView : self.view;
    activity.popoverPresentationController.sourceView = anchor;
    activity.popoverPresentationController.sourceRect = anchor.bounds;
    __weak ChessIOSViewController *weakSelf = self;
    activity.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                            NSArray *returnedItems, NSError *error) {
        (void)activityType;
        (void)completed;
        (void)returnedItems;
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf showDocumentError:error];
        });
    };
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)loadView
{
    if (!self.gameCenterManager) self.gameCenterManager = [[MBCIOSGameCenterManager alloc] init];
    self.gameCenterManager.delegate = self;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.variant = kVarNormal;
    self.players = (MBCPlayers)[defaults integerForKey:kMBCNewGamePlayers];
    if (self.players < kHumanVsHuman || self.players > kHumanVsGameCenter) {
        self.players = kHumanVsHuman;
    }
    MBCSideCode initialSideCode = (MBCSideCode)[defaults integerForKey:kMBCNewGameSides];
    if (initialSideCode < kPlayWhite || initialSideCode > kPlayEither) {
        initialSideCode = kPlayEither;
    }
    self.side = MBCIOSHumanSideForPlayers(self.players, initialSideCode);
    self.engineSide = MBCIOSEngineSideForPlayers(self.players, initialSideCode);
    self.boardStyle = [defaults stringForKey:kMBCBoardStyle] ?: @"Wood";
    self.pieceStyle = [defaults stringForKey:kMBCPieceStyle] ?: @"Wood";
    self.gameMetadata = [[MBCIOSGameStore defaultMetadataForSide:self.side] mutableCopy];

    NSError *libraryError = nil;
    self.gameLibrary = [MBCIOSGameLibrary sharedLibraryWithError:&libraryError];
    if (self.gameLibrary && ![self.gameLibrary migrateLegacyAutosaveIfNeededWithError:&libraryError]) {
        NSLog(@"Chess legacy autosave migration skipped: %@", libraryError);
    }

    MBCBoard *restoredBoard = nil;
    MBCVariant restoredVariant = kVarNormal;
    MBCSide restoredSide = kBothSides;
    NSString *restoredBoardStyle = nil;
    NSString *restoredPieceStyle = nil;
    NSDictionary *restoredMetadata = nil;
    NSError *restoreError = libraryError;
    MBCIOSGameRecord *lastOpened = (!self.startsWithNewLibraryGame &&
                                   !self.preferredInitialGameIdentifier.length)
        ? [self.gameLibrary lastOpenedGameWithError:&restoreError] : nil;
    NSString *initialIdentifier = self.startsWithNewLibraryGame ? nil :
        (self.preferredInitialGameIdentifier ?: lastOpened.identifier);
    MBCIOSGameRecord *restoredRecord = initialIdentifier.length
        ? [self.gameLibrary openGameWithIdentifier:initialIdentifier
                                            board:&restoredBoard
                                          variant:&restoredVariant
                                             side:&restoredSide
                                       boardStyle:&restoredBoardStyle
                                       pieceStyle:&restoredPieceStyle
                                         metadata:&restoredMetadata
                                            error:&restoreError] : nil;
    BOOL blockedGameCenterRestoration = restoredRecord &&
        [self otherGameCenterControllerForMatchID:MBCIOSMatchIDForMetadata(restoredMetadata)];
    if (blockedGameCenterRestoration) {
        restoreError = [self gameCenterAlreadyOpenError];
        restoredRecord = nil;
        restoredBoard = nil;
    }
    BOOL restored = restoredRecord != nil;
    if (restored) {
        self.activeGameRecord = restoredRecord;
        self.board = restoredBoard;
        self.variant = restoredVariant;
        self.boardStyle = restoredBoardStyle ?: self.boardStyle;
        self.pieceStyle = restoredPieceStyle ?: self.pieceStyle;
        NSMutableDictionary *metadata =
            [[MBCIOSGameStore defaultMetadataForSide:restoredSide] mutableCopy];
        if (restoredMetadata) [metadata addEntriesFromDictionary:restoredMetadata];
        self.gameMetadata = metadata;
        [self restorePlayerModeForSide:restoredSide metadata:metadata];
    } else {
        if (restoreError) NSLog(@"Chess autosave restore skipped: %@", restoreError);
        if (self.players == kHumanVsGameCenter) {
            /* A saved New Game preference is not itself a GameKit match. */
            self.players = kHumanVsHuman;
            self.side = kBothSides;
            self.engineSide = kNeitherSide;
        }
        self.gameMetadata = [[MBCIOSGameStore defaultMetadataForSide:self.side] mutableCopy];
        self.gameMetadata[@"IOSPlayers"] = @(self.players);
        self.board = [[MBCBoard alloc] init];
        [self.board startGame:self.variant];
    }
    MBCIOSRendererPreferences *rendererPreferences = MBCIOSRendererPreferences.sharedPreferences;
    self.requestedRenderer = rendererPreferences.desiredRenderer;
    self.rendererRevision = rendererPreferences.revision;
    NSError *rendererError = nil;
    self.boardBackend = [MBCIOSBoardBackend backendWithKind:self.requestedRenderer
        frame:UIScreen.mainScreen.bounds board:self.board variant:self.variant side:self.side
        boardStyle:self.boardStyle pieceStyle:self.pieceStyle error:&rendererError];
    if (!self.boardBackend) {
        MBCIOSRendererKind fallback = self.requestedRenderer == MBCIOSRendererMetal
            ? MBCIOSRendererOpenGL : MBCIOSRendererMetal;
        self.boardBackend = [MBCIOSBoardBackend backendWithKind:fallback
            frame:UIScreen.mainScreen.bounds board:self.board variant:self.variant side:self.side
            boardStyle:self.boardStyle pieceStyle:self.pieceStyle error:&rendererError];
    }
    if (!self.boardBackend) {
        UILabel *errorView = [[UILabel alloc] initWithFrame:UIScreen.mainScreen.bounds];
        errorView.backgroundColor = UIColor.blackColor;
        errorView.textColor = UIColor.whiteColor;
        errorView.textAlignment = NSTextAlignmentCenter;
        errorView.numberOfLines = 0;
        errorView.text = rendererError.localizedDescription;
        self.view = errorView;
        return;
    }
    UIView<MBCIOSBoardPresentation> *view = self.boardBackend.view;
    view.userInteractionEnabled = YES;

    UIView *container = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    container.backgroundColor = UIColor.blackColor;
    [container addSubview:view];
    // The board fills the canvas; controls follow the safe area.
    self.boardViewConstraints = @[
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [view.topAnchor constraintEqualToAnchor:container.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ];
    [NSLayoutConstraint activateConstraints:self.boardViewConstraints];

    [self installActionToolbarInContainer:container];
    [self installMoveHistorySurfacesInContainer:container];
    [self installCameraResetButtonInContainer:container];
    [self installGameResultIndicatorInContainer:container];
    [self updateActionToolbarLayout];

    self.boardView = view;
    [self applyGamePreferences];
    self.view = container;
    /* Keep the provider and recording adapters owned by the shell so the
     * UIKit action bar can reach the same document and window-recording
     * responsibilities without importing macOS window state. */
    self.documentController = [[MBCIOSDocumentController alloc] initWithPresenter:self];
    self.recordingController = [[MBCIOSRecordingController alloc] init];
    self.engine = [[MBCIOSChessEngine alloc] init];
    self.speechController = [[MBCIOSSpeechController alloc] initWithBoard:self.board];
    [self applyGamePreferences];
    self.pendingMoveAnimations = [NSMutableArray array];
    [self updateLoadedGameState];
    if (restored) self.lastSavedGameSnapshot = [self currentGameSnapshot];
    if (!restored && self.defersInitialLibrarySaveForImport)
        self.pendingSceneImportInitialSnapshot = [self currentGameSnapshot];
    if (!restored && self.gameLibrary) [self autosaveCurrentGame];
    MBCMoveCode restoredOutcome = MBCIOSStoredOutcome(self.board, self.gameMetadata);
    if (self.engineSide != kNeitherSide && restoredOutcome == kCmdNull) {
        [self restartEngineFromCurrentBoard];
    }
    if (restored && self.players == kHumanVsGameCenter &&
        self.gameCenterManager.isAuthenticated) {
        [self resumeGameCenterMatchWithID:MBCIOSMatchIDForMetadata(self.gameMetadata)];
    }
    if (blockedGameCenterRestoration) [self enqueueGameCenterError:restoreError];
}

- (void)startNewGameWithVariant:(MBCVariant)variant
                        players:(MBCPlayers)players
                       sideCode:(MBCSideCode)sideCode
                     searchTime:(NSInteger)searchTime
               rotateAfterMove:(BOOL)rotateAfterMove
              confirmNextTurn:(BOOL)confirmNextTurn
             keepDisplayAwake:(BOOL)keepDisplayAwake
                           name:(NSString *)name
{
    if (players == kHumanVsGameCenter && self.players == kHumanVsGameCenter &&
        MBCIOSMatchIDForMetadata(self.gameMetadata).length) {
        [self enqueueGameCenterMessage:MBCIOSLocalizedString(
            @"ios_game_center_switch_local_first",
            @"Open a local game before starting another Game Center match.")];
        return;
    }
    NSError *saveError = nil;
    if (![self saveCurrentGame:&saveError]) {
        [self showDocumentError:saveError];
        return;
    }
    if (players == kHumanVsGameCenter) {
        [self.gameCenterManager presentMatchmakerForVariant:variant sideCode:sideCode
                                                 presenter:self];
        return;
    }
    MBCSide side = MBCIOSHumanSideForPlayers(players, sideCode);
    MBCBoard *newBoard = [[MBCBoard alloc] init];
    [newBoard startGame:variant];
    NSMutableDictionary *metadata = [[MBCIOSGameStore defaultMetadataForSide:side] mutableCopy];
    MBCIOSFillGamePreferences(metadata);
    metadata[kMBCSearchTime] = @(MAX(1, MIN(12, searchTime)));
    metadata[kMBCMinSearchTime] = metadata[kMBCSearchTime];
    metadata[kMBCBoardSpin] = side == kBlackSide ? @0 : @180;
    metadata[@"IOSPlayers"] = @(players);
    if (players == kHumanVsHuman) {
        /* Local presentation options travel with .game files, but do not
         * affect the position or player types of imported games. */
        metadata[@"IOSRotateAfterEachMove"] = @(rotateAfterMove);
        metadata[@"IOSConfirmNextTurn"] = @(confirmNextTurn);
        metadata[@"IOSKeepDisplayAwake"] = @(keepDisplayAwake);
    }
    MBCIOSGameRecord *newRecord = [self.gameLibrary createGameNamed:name
        board:newBoard variant:variant side:side boardStyle:self.boardStyle ?: @"Wood"
        pieceStyle:self.pieceStyle ?: @"Wood" metadata:metadata error:&saveError];
    if (!newRecord) {
        [self showDocumentError:saveError];
        return;
    }
    [self.gameCenterManager releaseActiveMatch];
    [self cancelMoveAnimation];
    [self.speechController stop];
    [self.engine stop];
    self.engine = [[MBCIOSChessEngine alloc] init];
    self.engine.moveSource = self.boardView;
    [self clearGameResultIndicator];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:players forKey:kMBCNewGamePlayers];
    [defaults setInteger:variant forKey:kMBCNewGameVariant];
    [defaults setInteger:sideCode forKey:kMBCNewGameSides];
    [defaults setInteger:searchTime forKey:kMBCSearchTime];

    self.players = players;
    self.engineSide = MBCIOSEngineSideForPlayers(players, sideCode);
    self.gameCenterBoardActivated = NO;
    self.gameCenterAwaitingRemoteTurn = NO;
    self.gameCenterResumeError = nil;
    self.board = newBoard;
    [self.speechController setBoard:newBoard];
    self.variant = variant;
    self.side = side;
    self.gameMetadata = metadata;
    self.activeGameRecord = newRecord;
    [self.boardView setBoard:newBoard];
    [self.boardView startGame:variant playing:side];
    [self applyGamePreferences];
    [self updateLoadedGameState];
    self.lastSavedGameSnapshot = [self currentGameSnapshot];
    if (self.engineSide != kNeitherSide) [self restartEngineFromCurrentBoard];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    BOOL landscapePhone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        self.view.bounds.size.width > self.view.bounds.size.height;
    if (landscapePhone != self.actionToolbarLandscape) {
        [self updateActionToolbarLayout];
        [self updateMoveHistoryUI];
    }
    if (self.boardView && !self.boardView.isOrientationTransitioning) {
        [self.boardView drawNow];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [self beginBoardOrientationTransition];
    NSUInteger generation = self.orientationTransitionGeneration;
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (!self.boardView) return;
    __weak ChessIOSViewController *weakSelf = self;
    void (^finishTransition)(id<UIViewControllerTransitionCoordinatorContext>) =
    ^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        [weakSelf finishBoardOrientationTransition:generation];
    };
    if (coordinator) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            (void)context;
            [weakSelf.viewIfLoaded layoutIfNeeded];
        } completion:finishTransition];
    } else {
        finishTransition(nil);
    }
}

- (void)beginBoardOrientationTransition
{
    if (!self.boardView) return;
    ++self.orientationTransitionGeneration;
    self.orientationTransitionCompleting = NO;
    self.orientationTransitionFramePending = NO;
    if (!self.orientationTransitionCover) {
        UIView *snapshot = [self.boardView snapshotViewAfterScreenUpdates:NO];
        UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
        cover.translatesAutoresizingMaskIntoConstraints = NO;
        cover.backgroundColor = self.view.backgroundColor ?: UIColor.blackColor;
        cover.opaque = YES;
        cover.clipsToBounds = YES;
        cover.userInteractionEnabled = YES;
        cover.accessibilityElementsHidden = YES;
        // Keep the GPU surface attached beneath the cover for the final frame.
        UIView *coveredView = self.stagedBoardBackend.view.superview == self.view
            ? self.stagedBoardBackend.view : self.boardView;
        [self.view insertSubview:cover aboveSubview:coveredView];
        [NSLayoutConstraint activateConstraints:@[
            [cover.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [cover.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [cover.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [cover.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
        if (snapshot) {
            snapshot.translatesAutoresizingMaskIntoConstraints = NO;
            snapshot.userInteractionEnabled = NO;
            [cover addSubview:snapshot];
            // Only the center moves; the captured scene keeps its size in points.
            [NSLayoutConstraint activateConstraints:@[
                [snapshot.widthAnchor constraintEqualToConstant:self.boardView.bounds.size.width],
                [snapshot.heightAnchor constraintEqualToConstant:self.boardView.bounds.size.height],
                [snapshot.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
                [snapshot.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor]
            ]];
        }
        self.orientationTransitionSnapshot = snapshot;
        self.orientationTransitionCover = cover;
        self.boardAccessibilityHiddenBeforeTransition = self.boardView.accessibilityElementsHidden;
        self.boardView.accessibilityElementsHidden = YES;
        [self.view layoutIfNeeded];
    } else {
        // A second rotation reuses the undistorted capture and cancels its fade.
        [self.orientationTransitionCover.layer removeAllAnimations];
        self.orientationTransitionCover.alpha = 1.0;
    }
    [self.boardView beginOrientationTransition];
}

- (void)finishBoardOrientationTransition:(NSUInteger)generation
{
    if (generation != self.orientationTransitionGeneration || !self.orientationTransitionCover) return;
    [self.boardView endOrientationTransition];
    self.orientationTransitionCompleting = YES;
    // An interrupted transition waits for foreground resume before touching GPU resources.
    if (![self rendererSceneIsForeground] || self.orientationTransitionFramePending) return;
    [self.view layoutIfNeeded];
    NSError *error = nil;
    MBCIOSBoardBackend *backend = self.boardBackend;
    if (![backend prepareWithError:&error]) {
        [self removeBoardOrientationTransitionCover:generation animated:NO];
        if (error) [self showDocumentError:error];
        return;
    }
    self.orientationTransitionFramePending = YES;
    __weak ChessIOSViewController *weakSelf = self;
    [backend renderFirstFrameWithCompletion:^(NSError *frameError) {
        ChessIOSViewController *controller = weakSelf;
        if (!controller || generation != controller.orientationTransitionGeneration ||
            controller.boardBackend != backend) return;
        controller.orientationTransitionFramePending = NO;
        if (![controller rendererSceneIsForeground]) return;
        [controller removeBoardOrientationTransitionCover:generation animated:frameError == nil];
        if (frameError) [controller showDocumentError:frameError];
    }];
}

- (void)removeBoardOrientationTransitionCover:(NSUInteger)generation animated:(BOOL)animated
{
    UIView *cover = self.orientationTransitionCover;
    if (!cover || generation != self.orientationTransitionGeneration) return;
    __weak ChessIOSViewController *weakSelf = self;
    void (^removeCover)(void) = ^{
        ChessIOSViewController *controller = weakSelf;
        if (!controller || generation != controller.orientationTransitionGeneration ||
            controller.orientationTransitionCover != cover) return;
        [cover removeFromSuperview];
        controller.orientationTransitionCover = nil;
        controller.orientationTransitionSnapshot = nil;
        controller.orientationTransitionCompleting = NO;
        controller.orientationTransitionFramePending = NO;
        controller.boardView.accessibilityElementsHidden = controller.boardAccessibilityHiddenBeforeTransition;
        [controller updateLoadedGameState];
        [controller applyPendingRendererChange];
    };
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
            animations:^{ cover.alpha = 0.0; }
            completion:^(BOOL finished) { (void)finished; removeCover(); }];
    } else {
        [cover.layer removeAllAnimations];
        removeCover();
    }
}

- (void)applyImportedBoard:(MBCBoard *)board
                   variant:(MBCVariant)variant
                      side:(MBCSide)side
                boardStyle:(NSString *)boardStyle
                pieceStyle:(NSString *)pieceStyle
{
    NSError *error = nil;
    if (![self tryApplyImportedBoard:board variant:variant side:side
                         boardStyle:boardStyle pieceStyle:pieceStyle error:&error])
        [self showDocumentError:error];
}

- (BOOL)tryApplyImportedBoard:(MBCBoard *)board
                      variant:(MBCVariant)variant
                         side:(MBCSide)side
                   boardStyle:(NSString *)boardStyle
                   pieceStyle:(NSString *)pieceStyle
                        error:(NSError **)error
{
    if (error) *error = nil;
    if (!board || !self.boardView) {
        if (error) *error = [NSError errorWithDomain:MBCIOSGameStoreErrorDomain
                                               code:MBCIOSGameStoreErrorInvalidGame
                                           userInfo:@{NSLocalizedDescriptionKey:
            MBCIOSLocalizedString(@"ios_import_unavailable", @"The imported game could not be opened.")}];
        return NO;
    }
    NSError *__autoreleasing localError = nil;
    NSError *__autoreleasing *errorOutput = error ?: &localError;
    if (![self saveCurrentGame:errorOutput]) return NO;
    NSDictionary *importedMetadata = self.documentController.lastImportedMetadata;
    NSMutableDictionary *metadata =
        [[MBCIOSGameStore defaultMetadataForSide:side] mutableCopy];
    if (importedMetadata) [metadata addEntriesFromDictionary:importedMetadata];
    NSString *matchID = MBCIOSMatchIDForMetadata(metadata);
    if ([self otherGameCenterControllerForMatchID:matchID]) {
        *errorOutput = [self gameCenterAlreadyOpenError];
        return NO;
    }
    MBCIOSGameRecord *existing = matchID
        ? [self.gameLibrary recordForMatchID:matchID error:errorOutput] : nil;
    if (*errorOutput) return NO;
    NSString *fileName = self.documentController.lastImportedURL.lastPathComponent;
    NSString *name = [fileName.stringByDeletingPathExtension
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) name = MBCIOSLocalizedString(@"ios_imported_game", @"Imported Game");
    if (name.length > 120) {
        NSRange lastSequence = [name rangeOfComposedCharacterSequenceAtIndex:119];
        NSUInteger end = NSMaxRange(lastSequence) > 120 ? lastSequence.location : 120;
        name = [name substringToIndex:end];
    }
    MBCIOSGameRecord *record = existing
        ? [self.gameLibrary saveGame:existing board:board variant:variant side:side
                        boardStyle:boardStyle ?: @"Wood" pieceStyle:pieceStyle ?: @"Wood"
                          metadata:metadata error:errorOutput]
        : [self.gameLibrary createGameNamed:name board:board variant:variant side:side
                                boardStyle:boardStyle ?: @"Wood" pieceStyle:pieceStyle ?: @"Wood"
                                  metadata:metadata error:errorOutput];
    if (!record) return NO;
    if (existing) {
        MBCBoard *openedBoard = nil;
        MBCVariant openedVariant = kVarNormal;
        MBCSide openedSide = kBothSides;
        NSString *openedBoardStyle = nil;
        NSString *openedPieceStyle = nil;
        NSDictionary *openedMetadata = nil;
        MBCIOSGameRecord *opened = [self.gameLibrary openGameWithIdentifier:record.identifier
            board:&openedBoard variant:&openedVariant side:&openedSide
            boardStyle:&openedBoardStyle pieceStyle:&openedPieceStyle
            metadata:&openedMetadata error:errorOutput];
        if (!opened) return NO;
        board = openedBoard;
        variant = openedVariant;
        side = openedSide;
        boardStyle = openedBoardStyle;
        pieceStyle = openedPieceStyle;
        metadata = [openedMetadata mutableCopy];
        record = opened;
    }
    [self installLibraryBoard:board variant:variant side:side boardStyle:boardStyle
                  pieceStyle:pieceStyle metadata:metadata record:record];
    return YES;
}

- (void)autosaveCurrentGame
{
    NSError *error = nil;
    if (![self saveCurrentGame:&error] && error) {
        NSLog(@"Chess autosave failed: %@", error);
        if ([error.domain isEqualToString:MBCIOSGameLibraryErrorDomain] &&
            error.code == MBCIOSGameLibraryErrorConflict)
            [self presentPendingLibraryConflict];
    }
}

- (NSDictionary *)currentGameSnapshot
{
    MBCIOSFillGamePreferences(self.gameMetadata);
    if (self.boardView) {
        self.gameMetadata[kMBCBoardAngle] = @(self.boardView.elevation);
        self.gameMetadata[kMBCBoardSpin] = @(self.boardView.azimuth);
        self.gameMetadata[kMBCShowEdgeNotation] = @(self.boardView.drawEdgeNotationLabels);
    }
    return [MBCIOSGameStore gameDictionaryForBoard:self.board variant:self.variant side:self.side
        boardStyle:self.boardStyle ?: @"Wood" pieceStyle:self.pieceStyle ?: @"Wood"
          metadata:self.gameMetadata];
}

- (BOOL)finishInitialSceneImportWithError:(NSError **)error
{
    if (error) *error = nil;
    if (!self.defersInitialLibrarySaveForImport) return YES;
    self.defersInitialLibrarySaveForImport = NO;
    self.pendingSceneImportInitialSnapshot = nil;
    return self.activeGameRecord ? YES : [self saveCurrentGame:error];
}

- (BOOL)saveCurrentGame:(NSError **)error
{
    if (error) *error = nil;
    if (!self.board) {
        if (error) {
            *error = [NSError errorWithDomain:MBCIOSGameStoreErrorDomain
                                          code:MBCIOSGameStoreErrorInvalidGame
                                      userInfo:@{NSLocalizedDescriptionKey: MBCIOSLocalizedString(@"ios_no_active_game_save", @"Chess has no active board to save.")}];
        }
        return NO;
    }
    if (!self.gameMetadata) {
        self.gameMetadata = [[MBCIOSGameStore defaultMetadataForSide:self.side] mutableCopy];
    }
    self.gameMetadata[@"IOSPlayers"] = @(self.players);
    NSDictionary *snapshot = [self currentGameSnapshot];
    /* An import-launch window has no game of its own yet. Keep its untouched
     * placeholder out of the library, including lifecycle saves and the save
     * immediately before installing the imported board. A move or setting
     * change still makes the placeholder a real, separately saved game. */
    if (self.defersInitialLibrarySaveForImport && !self.activeGameRecord &&
        [snapshot isEqualToDictionary:self.pendingSceneImportInitialSnapshot]) return YES;
    if (!self.gameLibrary) {
        if (error) *error = [NSError errorWithDomain:MBCIOSGameLibraryErrorDomain
                                               code:MBCIOSGameLibraryErrorInvalidRequest
                                           userInfo:@{NSLocalizedDescriptionKey:
                MBCIOSLocalizedString(@"ios_library_unavailable", @"The Chess game library is unavailable.")}];
        return NO;
    }
    NSString *matchID = MBCIOSMatchIDForMetadata(self.gameMetadata);
    MBCIOSGameRecord *record = self.activeGameRecord;
    NSError *__autoreleasing localError = nil;
    NSError *__autoreleasing *errorOutput = error ?: &localError;
    if (!record && matchID) {
        record = [self.gameLibrary recordForMatchID:matchID error:errorOutput];
        if (*errorOutput) return NO;
    }
    BOOL adoptingExistingMatch = record && !self.activeGameRecord;
    if (record && ((record.matchID || matchID) && ![record.matchID isEqualToString:matchID])) {
        *errorOutput = [NSError errorWithDomain:MBCIOSGameLibraryErrorDomain
                                           code:MBCIOSGameLibraryErrorConflict
                                       userInfo:@{NSLocalizedDescriptionKey:
            MBCIOSLocalizedString(@"ios_library_match_conflict", @"This board belongs to a different saved game.")}];
        return NO;
    }
    if (record && [snapshot isEqualToDictionary:self.lastSavedGameSnapshot]) return YES;
    NSString *name = self.nextLibraryGameName;
    if (!name.length && matchID.length) {
        NSString *shortID = [matchID substringFromIndex:matchID.length > 8 ? matchID.length - 8 : 0];
        name = [NSString stringWithFormat:MBCIOSLocalizedString(@"ios_game_center_game_name", @"Game Center %@"), shortID];
    }
    if (!name.length) name = MBCIOSLocalizedString(@"ios_casual_game_name", @"Casual Game");
    MBCIOSGameRecord *saved = record
        ? [self.gameLibrary saveGame:record board:self.board variant:self.variant side:self.side
                        boardStyle:self.boardStyle ?: @"Wood" pieceStyle:self.pieceStyle ?: @"Wood"
                          metadata:self.gameMetadata error:errorOutput]
        : [self.gameLibrary createGameNamed:name board:self.board variant:self.variant side:self.side
                                boardStyle:self.boardStyle ?: @"Wood" pieceStyle:self.pieceStyle ?: @"Wood"
                                  metadata:self.gameMetadata error:errorOutput];
    if (!saved) {
        if ([(*errorOutput).domain isEqualToString:MBCIOSGameLibraryErrorDomain] &&
            (*errorOutput).code == MBCIOSGameLibraryErrorConflict &&
            ![self.notifiedLibraryConflictIdentifier isEqualToString:record.identifier]) {
            self.pendingLibraryConflict = *errorOutput;
        }
        return NO;
    }
    if (adoptingExistingMatch) {
        MBCBoard *openedBoard = nil;
        MBCVariant openedVariant = kVarNormal;
        MBCSide openedSide = kBothSides;
        MBCIOSGameRecord *opened = [self.gameLibrary openGameWithIdentifier:saved.identifier
            board:&openedBoard variant:&openedVariant side:&openedSide boardStyle:nil
            pieceStyle:nil metadata:nil error:errorOutput];
        if (!opened) {
            self.activeGameRecord = saved;
            return NO;
        }
        saved = opened;
    }
    self.activeGameRecord = saved;
    self.lastSavedGameSnapshot = snapshot;
    self.pendingLibraryConflict = nil;
    self.notifiedLibraryConflictIdentifier = nil;
    self.nextLibraryGameName = nil;
    return YES;
}

@end
