/* Coordinate entry with the same move rules as the iOS touch board. */

#import "MBCIOSCoordinateEntryViewController.h"
#import "MBCIOSLocalization.h"
#import "MBCMoveGenerator.h"

#include <ctype.h>

static NSString *MBCEntryMessage(NSString *key, NSString *fallback)
{
    return MBCIOSLocalizedString(key, fallback);
}

static BOOL MBCEntryIsFile(unichar character)
{
    return character >= 'a' && character <= 'h';
}

static BOOL MBCEntryIsRank(unichar character)
{
    return character >= '1' && character <= '8';
}

static MBCPieceCode MBCEntryPieceForLetter(unichar character)
{
    switch (character) {
        case 'q': return QUEEN;
        case 'r': return ROOK;
        case 'b': return BISHOP;
        case 'n': return KNIGHT;
        case 'p': return PAWN;
        case 'k': return KING;
        default:  return EMPTY;
    }
}

static NSString *MBCEntryPromotionName(MBCPieceCode type)
{
    switch (type) {
        case QUEEN:  return MBCEntryMessage(@"queen", @"Queen");
        case ROOK:   return MBCEntryMessage(@"rook", @"Rook");
        case BISHOP: return MBCEntryMessage(@"bishop", @"Bishop");
        case KNIGHT: return MBCEntryMessage(@"knight", @"Knight");
        case KING:   return MBCEntryMessage(@"king", @"King");
        default:     return @"";
    }
}

static NSString *MBCEntryCompactText(NSString *input)
{
    NSString *lower = [input.lowercaseString stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableString *compact = [NSMutableString stringWithCapacity:lower.length];
    NSCharacterSet *spacing = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger index = 0; index < lower.length; ++index) {
        unichar character = [lower characterAtIndex:index];
        if ([spacing characterIsMember:character] || character == '-') continue;
        [compact appendFormat:@"%C", character];
    }
    return compact;
}

/* MBCMoveGenerator supplies pseudo-legal destinations. Mirror the touch
 * board's final king-safety and castling-transit checks before a move reaches
 * the controller's local-game notification path. */
static BOOL MBCEntryKeepsKingSafe(MBCBoard *board, MBCVariant variant,
                                   MBCPiece piece, MBCSquare from,
                                   MBCSquare to, BOOL castling, BOOL dropping)
{
    if (variant == kVarSuicide) return YES;
    BOOL white = ([board numMoves] & 1) == 0;
    MBCMoveGenerator checker(nil, variant, 0);
    MBCPieces position = *[board curPos];
    if (castling) {
        if (checker.InCheck(white, position)) return NO;
        MBCPieces transit = position;
        MBCSquare middle = Square(Col(to) == 'g' ? 'f' : 'd', Row(from));
        transit.fBoard[from] = EMPTY;
        transit.fBoard[middle] = piece;
        if (checker.InCheck(white, transit)) return NO;
        MBCSquare rookFrom = Square(Col(to) == 'g' ? 'h' : 'a', Row(from));
        position.fBoard[middle] = position.fBoard[rookFrom];
        position.fBoard[rookFrom] = EMPTY;
    }
    if (!dropping) {
        if (Piece(piece) == PAWN && Col(from) != Col(to) &&
            position.fBoard[to] == EMPTY && position.fEnPassant == to) {
            position.fBoard[Square(Col(to), Row(from))] = EMPTY;
        }
        position.fBoard[from] = EMPTY;
    }
    position.fBoard[to] = piece;
    return !checker.InCheck(white, position);
}

static MBCMove *MBCEntryLegalMove(MBCBoard *board, MBCVariant variant,
                                  MBCSide allowedSide, MBCSquare from,
                                  MBCSquare to, MBCPieceCode dropType)
{
    if (!board || to >= kBoardSquares || variant < kVarNormal || variant > kVarLosers) return nil;
    BOOL whiteTurn = ([board numMoves] & 1) == 0;
    if (whiteTurn ? !SideIncludesWhite(allowedSide) : !SideIncludesBlack(allowedSide)) return nil;
    BOOL dropping = dropType != EMPTY;
    MBCPiece piece = EMPTY;
    if (dropping) {
        if (variant != kVarCrazyhouse || dropType == KING || dropType > PAWN) return nil;
        piece = whiteTurn ? White(dropType) : Black(dropType);
        if ([board curInHand:piece] < 1) return nil;
    } else {
        if (from >= kBoardSquares || from == to) return nil;
        piece = [board curContents:from];
        if (Piece(piece) == EMPTY ||
            Color(piece) != (whiteTurn ? kWhitePiece : kBlackPiece)) return nil;
    }

    MBCMoveCollector *collector = [[MBCMoveCollector alloc] init];
    MBCMoveGenerator generator(collector, variant, 0);
    generator.Generate(whiteTurn, *[board curPos]);
    MBCMoveCollection *collection = [collector collection];
    BOOL permitted = NO;
    BOOL castling = NO;
    if (dropping) {
        MBCBoardMask target = 1ULL << to;
        permitted = Piece(piece) == PAWN
            ? (collection->fPawnDrops & target) != 0
            : (collection->fPieceDrops & target) != 0 &&
              (collection->fDroppablePieces & (1 << Piece(piece))) != 0;
    } else {
        MBCPieceMoves &moves = collection->fMoves[Piece(piece)];
        for (int index = 0; index < moves.fNumInstances; ++index) {
            if (moves.fFrom[index] == from && (moves.fTo[index] & (1ULL << to))) {
                permitted = YES;
                break;
            }
        }
        if (!permitted && Piece(piece) == KING && from == Square('e', whiteTurn ? 1 : 8) &&
            (to == Square('g', whiteTurn ? 1 : 8) ||
             to == Square('c', whiteTurn ? 1 : 8))) {
            castling = YES;
            permitted = Col(to) == 'g' ? collection->fCastleKingside
                                       : collection->fCastleQueenside;
        }
    }
    if (!permitted || !MBCEntryKeepsKingSafe(board, variant, piece, from, to,
                                              castling, dropping)) return nil;
    MBCMove *move = [MBCMove moveWithCommand:dropping ? kCmdDrop : kCmdMove];
    if (!dropping) move->fFromSquare = from;
    move->fToSquare = to;
    move->fPiece = piece;
    move->fAnimate = YES;
    return move;
}

@interface MBCIOSCoordinateEntryViewController () <UITextFieldDelegate>
@property (nonatomic, weak, readwrite, nullable) MBCBoard *board;
@property (nonatomic, readwrite) MBCVariant variant;
@property (nonatomic, readwrite) MBCSide allowedSide;
@property (nonatomic, strong, readwrite) UITextField *coordinateField;
@property (nonatomic, strong, readwrite) UILabel *feedbackLabel;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, copy) MBCIOSCoordinateMoveSubmissionHandler submissionHandler;
@property (nonatomic, copy) NSString *initialFEN;
@property (nonatomic, copy) NSString *initialHolding;
@property (nonatomic) int initialMoveCount;
@end

@implementation MBCIOSCoordinateEntryViewController

- (instancetype)initWithBoard:(MBCBoard *)board variant:(MBCVariant)variant
                  allowedSide:(MBCSide)allowedSide
            submissionHandler:(MBCIOSCoordinateMoveSubmissionHandler)submissionHandler
{
    NSParameterAssert(board && submissionHandler);
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _board = board;
        _variant = variant;
        _allowedSide = allowedSide;
        _submissionHandler = [submissionHandler copy];
        _initialFEN = [board.fen copy];
        _initialHolding = [board.holding copy];
        _initialMoveCount = board.numMoves;
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        self.preferredContentSize = CGSizeMake(460.0, 385.0);
    }
    return self;
}

+ (MBCMove *)moveForInput:(NSString *)input board:(MBCBoard *)board
                  variant:(MBCVariant)variant allowedSide:(MBCSide)allowedSide
                 feedback:(NSString **)feedback
{
    if (feedback) *feedback = nil;
    if (!board) {
        if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_board_unavailable",
                                                   @"The board is no longer available.");
        return nil;
    }
    NSString *text = MBCEntryCompactText(input ?: @"");
    if (!text.length) {
        if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_empty",
                                                   @"Enter a move such as e2e4.");
        return nil;
    }
    BOOL whiteTurn = (board.numMoves & 1) == 0;
    if (whiteTurn ? !SideIncludesWhite(allowedSide) : !SideIncludesBlack(allowedSide)) {
        if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_not_your_turn",
                                                   @"It is not your turn to move.");
        return nil;
    }

    MBCMove *move = nil;
    MBCPieceCode requestedPromotion = EMPTY;
    if (text.length == 4 && [text characterAtIndex:1] == '@' &&
        MBCEntryIsFile([text characterAtIndex:2]) &&
        MBCEntryIsRank([text characterAtIndex:3])) {
        MBCPieceCode dropType = MBCEntryPieceForLetter([text characterAtIndex:0]);
        if (dropType == EMPTY || dropType == KING || variant != kVarCrazyhouse) {
            if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_drop_format",
                                                       @"Use N@f3 for a Crazyhouse drop.");
            return nil;
        }
        MBCSquare to = Square((char)[text characterAtIndex:2],
                              [text characterAtIndex:3] - '0');
        move = MBCEntryLegalMove(board, variant, allowedSide, kInvalidSquare, to, dropType);
    } else {
        BOOL hasPromotion = text.length == 5 ||
            (text.length == 6 && [text characterAtIndex:4] == '=');
        if ((!hasPromotion && text.length != 4) ||
            !MBCEntryIsFile([text characterAtIndex:0]) ||
            !MBCEntryIsRank([text characterAtIndex:1]) ||
            !MBCEntryIsFile([text characterAtIndex:2]) ||
            !MBCEntryIsRank([text characterAtIndex:3])) {
            if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_format",
                                                       @"Use coordinates such as e2e4 or e7e8=Q.");
            return nil;
        }
        if (hasPromotion) {
            requestedPromotion = MBCEntryPieceForLetter([text characterAtIndex:text.length - 1]);
            if (requestedPromotion == EMPTY || requestedPromotion == PAWN ||
                (requestedPromotion == KING && variant != kVarSuicide)) {
                if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_promotion_format",
                                                           @"Choose Q, R, B, or N for promotion (K in Suicide).");
                return nil;
            }
        }
        MBCSquare from = Square((char)[text characterAtIndex:0],
                                [text characterAtIndex:1] - '0');
        MBCSquare to = Square((char)[text characterAtIndex:2],
                              [text characterAtIndex:3] - '0');
        move = MBCEntryLegalMove(board, variant, allowedSide, from, to, EMPTY);
        if (move) {
            BOOL isPromotion = Piece(move->fPiece) == PAWN &&
                Row(move->fToSquare) == (whiteTurn ? 8 : 1);
            if (requestedPromotion && !isPromotion) {
                if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_promotion_not_pawn",
                                                           @"Only a pawn reaching the last rank can promote.");
                return nil;
            }
            if (isPromotion) {
                MBCPieceCode choice = requestedPromotion != EMPTY
                    ? requestedPromotion
                    : (MBCPieceCode)Piece([board defaultPromotion:whiteTurn]);
                if (choice == KING && variant != kVarSuicide) choice = QUEEN;
                move->fPromotion = choice;
            }
        }
    }
    if (!move && feedback) {
        *feedback = MBCEntryMessage(@"ios_coordinate_illegal",
                                    @"That move is not legal in this position.");
    }
    return move;
}

+ (BOOL)applyPromotionShortcut:(NSString *)input board:(MBCBoard *)board
                       variant:(MBCVariant)variant feedback:(NSString **)feedback
{
    if (feedback) *feedback = nil;
    NSString *text = MBCEntryCompactText(input ?: @"");
    if (text.length != 2 || [text characterAtIndex:0] != '=') {
        if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_promotion_shortcut",
                                                   @"Use =Q, =R, =B, or =N (also =K in Suicide).");
        return NO;
    }
    MBCPieceCode choice = MBCEntryPieceForLetter([text characterAtIndex:1]);
    if (!board || choice == EMPTY || choice == PAWN ||
        (choice == KING && variant != kVarSuicide)) {
        if (feedback) *feedback = MBCEntryMessage(@"ios_coordinate_promotion_shortcut",
                                                   @"Use =Q, =R, =B, or =N (also =K in Suicide).");
        return NO;
    }
    [board setDefaultPromotion:choice for:YES];
    [board setDefaultPromotion:choice for:NO];
    if (feedback) {
        *feedback = [NSString stringWithFormat:MBCEntryMessage(@"ios_coordinate_promotion_set",
                                                                @"Default promotion: %@"),
                     MBCEntryPromotionName(choice)];
    }
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = MBCEntryMessage(@"ios_coordinate_title", @"Enter Move");

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    self.scrollView = scroll;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24.0],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24.0],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48.0]
    ]];

    UILabel *heading = [[UILabel alloc] initWithFrame:CGRectZero];
    heading.text = self.title;
    heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    heading.adjustsFontForContentSizeCategory = YES;
    heading.accessibilityTraits |= UIAccessibilityTraitHeader;
    [stack addArrangedSubview:heading];

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.delegate = self;
    field.placeholder = MBCEntryMessage(@"ios_coordinate_placeholder", @"e2e4");
    field.font = [UIFont monospacedSystemFontOfSize:21.0 weight:UIFontWeightMedium];
    field.keyboardType = UIKeyboardTypeASCIICapable;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.returnKeyType = UIReturnKeyGo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.accessibilityLabel = MBCEntryMessage(@"ios_coordinate_field", @"Coordinate move");
    field.accessibilityHint = MBCEntryMessage(@"ios_coordinate_field_hint",
                                               @"Type a move such as e2e4, then press Return.");
    field.accessibilityIdentifier = @"coordinate-move-field";
    field.backgroundColor = UIColor.secondarySystemBackgroundColor;
    field.layer.cornerRadius = 9.0;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.layer.borderWidth = 1.0;
    field.layer.borderColor = UIColor.separatorColor.CGColor;
    UIView *padding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    field.leftView = padding;
    field.leftViewMode = UITextFieldViewModeAlways;
    [field addTarget:self action:@selector(inputChanged:)
     forControlEvents:UIControlEventEditingChanged];
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;
    [stack addArrangedSubview:field];
    self.coordinateField = field;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = self.variant == kVarCrazyhouse
        ? MBCEntryMessage(@"ios_coordinate_hint_crazyhouse",
                          @"Examples: e2e4, e7e8=Q, N@f3. Press Return to play.")
        : MBCEntryMessage(@"ios_coordinate_hint",
                          @"Examples: e2e4, e7e8=Q. Press Return to play.");
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:hint];

    UILabel *promotionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    promotionTitle.text = MBCEntryMessage(@"ios_coordinate_promotion_heading",
                                           @"Promotion shortcut");
    promotionTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    promotionTitle.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:promotionTitle];

    UIStackView *promotionRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    promotionRow.axis = UILayoutConstraintAxisHorizontal;
    promotionRow.distribution = UIStackViewDistributionFillEqually;
    promotionRow.spacing = 8.0;
    NSString *choices = self.variant == kVarSuicide ? @"qrbnk" : @"qrbn";
    for (NSUInteger index = 0; index < choices.length; ++index) {
        unichar character = [choices characterAtIndex:index];
        MBCPieceCode piece = MBCEntryPieceForLetter(character);
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:[NSString stringWithFormat:@"=%C", (unichar)toupper(character)]
               forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont monospacedSystemFontOfSize:17.0
                                                            weight:UIFontWeightSemibold];
        button.tag = piece;
        button.backgroundColor = UIColor.secondarySystemBackgroundColor;
        button.layer.cornerRadius = 8.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.accessibilityLabel = [NSString stringWithFormat:
            MBCEntryMessage(@"ios_coordinate_set_promotion", @"Set promotion to %@"),
            MBCEntryPromotionName(piece)];
        [button addTarget:self action:@selector(promotionButtonTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
        [promotionRow addArrangedSubview:button];
    }
    [stack addArrangedSubview:promotionRow];

    UILabel *feedbackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    feedbackLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    feedbackLabel.adjustsFontForContentSizeCategory = YES;
    feedbackLabel.textColor = UIColor.secondaryLabelColor;
    feedbackLabel.numberOfLines = 0;
    feedbackLabel.accessibilityIdentifier = @"coordinate-feedback";
    feedbackLabel.text = MBCEntryMessage(@"ios_coordinate_promotion_tip",
        @"Type =Q, =R, =B, or =N to change the default promotion.");
    [feedbackLabel.heightAnchor constraintGreaterThanOrEqualToConstant:42.0].active = YES;
    [stack addArrangedSubview:feedbackLabel];
    self.feedbackLabel = feedbackLabel;

    UIStackView *actions = [[UIStackView alloc] initWithFrame:CGRectZero];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.spacing = 12.0;
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:MBCEntryMessage(@"ios_cancel", @"Cancel") forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelEntry:) forControlEvents:UIControlEventTouchUpInside];
    cancel.accessibilityIdentifier = @"coordinate-cancel";
    [cancel.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    [actions addArrangedSubview:cancel];
    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    [play setTitle:MBCEntryMessage(@"ios_coordinate_play", @"Play Move")
          forState:UIControlStateNormal];
    play.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    play.accessibilityIdentifier = @"coordinate-play";
    [play addTarget:self action:@selector(submitEntry:) forControlEvents:UIControlEventTouchUpInside];
    [play.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    [actions addArrangedSubview:play];
    [stack addArrangedSubview:actions];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(keyboardFrameChanged:)
            name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(keyboardFrameChanged:)
            name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)keyboardFrameChanged:(NSNotification *)notification
{
    if (!self.view.window) return;
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!frameValue) return;
    CGRect frame = [self.view convertRect:frameValue.CGRectValue fromView:nil];
    CGRect overlap = CGRectIntersection(self.view.bounds, frame);
    CGFloat inset = CGRectIsNull(overlap) ? 0.0 : CGRectGetHeight(overlap);
    UIEdgeInsets contentInsets = self.scrollView.contentInset;
    contentInsets.bottom = inset;
    self.scrollView.contentInset = contentInsets;
    self.scrollView.scrollIndicatorInsets = contentInsets;
    if (inset > 0.0 && self.coordinateField.isFirstResponder) {
        CGRect field = [self.coordinateField convertRect:self.coordinateField.bounds
                                                  toView:self.scrollView];
        [self.scrollView scrollRectToVisible:field animated:YES];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.coordinateField becomeFirstResponder];
}

- (NSArray<UIKeyCommand *> *)keyCommands
{
    UIKeyCommand *escape = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape
                                               modifierFlags:0 action:@selector(cancelEntry:)];
    escape.discoverabilityTitle = MBCEntryMessage(@"ios_cancel", @"Cancel");
    return @[escape];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    (void)textField;
    [self submitEntry:nil];
    return NO;
}

- (void)inputChanged:(id)sender
{
    (void)sender;
    self.coordinateField.layer.borderColor = UIColor.separatorColor.CGColor;
    self.feedbackLabel.textColor = UIColor.secondaryLabelColor;
    self.feedbackLabel.text = @"";
}

- (void)showFeedback:(NSString *)message success:(BOOL)success
{
    self.feedbackLabel.text = message;
    self.feedbackLabel.textColor = success ? UIColor.systemGreenColor : UIColor.systemRedColor;
    self.coordinateField.layer.borderColor = success ? UIColor.separatorColor.CGColor
                                                      : UIColor.systemRedColor.CGColor;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}

- (void)promotionButtonTapped:(UIButton *)button
{
    if (![self positionIsCurrent]) {
        [self showFeedback:MBCEntryMessage(@"ios_coordinate_position_changed",
            @"The position changed. Close and reopen move entry.") success:NO];
        return;
    }
    MBCPieceCode piece = (MBCPieceCode)button.tag;
    char letter = piece == QUEEN ? 'q' : piece == ROOK ? 'r' :
                  piece == BISHOP ? 'b' : piece == KNIGHT ? 'n' : 'k';
    NSString *shortcut = [NSString stringWithFormat:@"=%c", letter];
    NSString *feedback = nil;
    BOOL success = [self.class applyPromotionShortcut:shortcut board:self.board
                                             variant:self.variant feedback:&feedback];
    [self showFeedback:feedback ?: @"" success:success];
    if (success) {
        if (self.promotionChangedHandler) self.promotionChangedHandler(piece);
        if ([MBCEntryCompactText(self.coordinateField.text) hasPrefix:@"="]) {
            self.coordinateField.text = @"";
        }
        [self.coordinateField becomeFirstResponder];
    }
}

- (BOOL)positionIsCurrent
{
    MBCBoard *board = self.board;
    return board && board.numMoves == self.initialMoveCount &&
        [board.fen isEqualToString:self.initialFEN] &&
        [board.holding isEqualToString:self.initialHolding];
}

- (void)submitEntry:(id)sender
{
    (void)sender;
    MBCBoard *board = self.board;
    if (![self positionIsCurrent]) {
        [self showFeedback:MBCEntryMessage(@"ios_coordinate_position_changed",
            @"The position changed. Close and reopen move entry.") success:NO];
        return;
    }
    NSString *input = self.coordinateField.text ?: @"";
    if ([[MBCEntryCompactText(input) lowercaseString] hasPrefix:@"="]) {
        NSString *feedback = nil;
        BOOL success = [self.class applyPromotionShortcut:input board:board
                                                 variant:self.variant feedback:&feedback];
        [self showFeedback:feedback ?: @"" success:success];
        if (success) {
            MBCPieceCode choice = (MBCPieceCode)Piece([board defaultPromotion:YES]);
            if (self.promotionChangedHandler) self.promotionChangedHandler(choice);
            self.coordinateField.text = @"";
        }
        return;
    }

    NSString *feedback = nil;
    MBCMove *move = [self.class moveForInput:input board:board variant:self.variant
                               allowedSide:self.allowedSide feedback:&feedback];
    if (!move) {
        [self showFeedback:feedback ?: MBCEntryMessage(@"ios_coordinate_illegal",
            @"That move is not legal in this position.") success:NO];
        return;
    }
    NSString *rejection = nil;
    if (!self.submissionHandler(move, &rejection)) {
        [self showFeedback:rejection.length ? rejection : MBCEntryMessage(
            @"ios_coordinate_rejected", @"This move cannot be played right now.") success:NO];
        return;
    }
    if (move->fPromotion) {
        BOOL white = (self.initialMoveCount & 1) == 0;
        MBCPieceCode choice = (MBCPieceCode)Piece(move->fPromotion);
        [board setDefaultPromotion:choice for:white];
        if (self.promotionChangedHandler) self.promotionChangedHandler(choice);
    }
    [self.coordinateField resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)cancelEntry:(id)sender
{
    (void)sender;
    [self.coordinateField resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
