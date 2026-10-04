/* Shared UIKit square, pocket and promotion accessibility. */
static CGRect MBCIOSAccessibilityFrameForPosition(UIView<MBCIOSBoardPresentation> *view, MBCPosition position)
{
    CGPoint point = [view iosProjectPosition:position];
    if (!std::isfinite(point.x) || !std::isfinite(point.y))
        return CGRectMake(view.bounds.size.width - 40.0, 0.0, 40.0, 40.0);
    CGFloat x = point.x;
    CGFloat y = point.y;
    return CGRectMake(x - 20.0, y - 20.0, 40.0, 40.0);
}

static CGRect MBCIOSAccessibilityFrameForSquare(UIView<MBCIOSBoardPresentation> *view, MBCSquare square)
{
    MBCPosition center = [view squareToPosition:square];
    if (view.bounds.size.width <= 0.0 || view.bounds.size.height <= 0.0)
        return MBCIOSAccessibilityFrameForPosition(view, center);

    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (unsigned column = 0; column < 2; ++column) {
        for (unsigned row = 0; row < 2; ++row) {
            MBCPosition corner = center;
            corner[0] += column ? 5.0f : -5.0f;
            corner[2] += row ? 5.0f : -5.0f;
            CGPoint point = [view iosProjectPosition:corner];
            CGFloat screenX = point.x;
            CGFloat screenY = point.y;
            if (!std::isfinite(screenX) || !std::isfinite(screenY))
                return MBCIOSAccessibilityFrameForPosition(view, center);
            minX = MIN(minX, screenX);
            minY = MIN(minY, screenY);
            maxX = MAX(maxX, screenX);
            maxY = MAX(maxY, screenY);
        }
    }
    return CGRectInset(CGRectMake(minX, minY, maxX - minX, maxY - minY), -1.0, -1.0);
}

static MBCSquare MBCIOSSquareInVisualReadingOrder(NSUInteger index, float azimuth)
{
    // Keep VoiceOver's swipe order aligned with the board as seen from each
    // seat. Algebraic square names stay fixed when the camera turns.
    float angle = std::fmod(azimuth, 360.0f);
    if (angle < 0.0f) angle += 360.0f;
    unsigned quadrant = (unsigned)std::floor((angle + 45.0f) / 90.0f) % 4;
    unsigned outer = (unsigned)index / 8;
    unsigned inner = (unsigned)index % 8;
    unsigned file = 0, row = 0;
    switch (quadrant) {
        case 0: file = 7 - inner; row = 1 + outer; break; // Black's seat.
        case 1: file = outer; row = 1 + inner; break;
        case 2: file = inner; row = 8 - outer; break;     // White's seat.
        default: file = 7 - outer; row = 8 - inner; break;
    }
    return Square((char)('a' + file), row);
}

static NSString *MBCIOSPocketName(MBCPiece piece)
{
    static NSString *names[] = {@"", @"king", @"queen", @"bishop", @"knight", @"rook", @"pawn"};
    NSString *color = Color(piece) == kWhitePiece ? @"white" : @"black";
    NSString *type = names[Piece(piece)];
    NSString *key = [NSString stringWithFormat:@"%@_%@", color, type];
    NSString *fallback = [NSString stringWithFormat:@"%@ %@",
                          [color capitalizedString], [type capitalizedString]];
    return [[NSBundle mainBundle] localizedStringForKey:key value:fallback table:nil];
}

@implementation MBCIOSBoardAccessibilityClass (IOSAccessibility)

- (MBCIOSChessSquareElement *)iosAccessibilityElementForSquare:(MBCSquare)square
{
    if (!_iosAccessibilitySquareElements) {
        _iosAccessibilitySquareElements = [NSMutableDictionary dictionaryWithCapacity:76];
    }
    NSNumber *key = @(square);
    MBCIOSChessSquareElement *element =
        (MBCIOSChessSquareElement *)_iosAccessibilitySquareElements[key];
    if (!element) {
        element = [[MBCIOSChessSquareElement alloc] initWithAccessibilityContainer:self];
        element.square = square;
        element.boardView = self;
        _iosAccessibilitySquareElements[key] = element;
    }
    return element;
}

- (BOOL)isAccessibilityElement
{
    return NO;
}

- (NSArray *)accessibilityElements
{
    NSMutableArray *elements = [NSMutableArray arrayWithCapacity:75];
    uint64_t legalDropTargets = [self iosLegalDropTargets];
    BOOL whiteTurn = _board && ([_board numMoves] & 1) == 0;
    BOOL humanTurn = _board && [self wantsMouse] &&
        (_side == kBothSides || (whiteTurn ? _side == kWhiteSide : _side == kBlackSide));

    for (NSUInteger index = 0; index < 64; ++index) {
        MBCSquare square = MBCIOSSquareInVisualReadingOrder(index, self.azimuth);
        MBCIOSChessSquareElement *element = [self iosAccessibilityElementForSquare:square];
        element.canActivate = humanTurn;
        element.accessibilityLabel = [self describeSquare:square];
        element.accessibilityHint = legalDropTargets & (1ULL << square)
            ? MBCIOSLocalizedString(@"ios_legal_drop_destination", @"Legal drop destination")
            : nil;
        element.accessibilityIdentifier = [NSString stringWithFormat:@"square-%c%u",
                                           Col(square), Row(square)];
        element.accessibilityTraits = humanTurn
            ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
        // The board can rotate and tilt independently of the view.
        // Keep VoiceOver's square target centered on the rendered square.
        element.accessibilityFrameInContainerSpace =
            MBCIOSAccessibilityFrameForSquare(self, square);
        [elements addObject:element];
    }

    if (_variant == kVarCrazyhouse && _board) {
        const MBCPieceCode types[] = {PAWN, BISHOP, KNIGHT, ROOK, QUEEN};
        for (int colorIndex = 0; colorIndex < 2; ++colorIndex) {
            BOOL white = colorIndex == 0;
            for (MBCPieceCode type : types) {
                MBCPiece piece = white ? White(type) : Black(type);
                int count = [_board curInHand:piece];
                if (count < 1) continue;
                MBCSquare square = kInHandSquare + piece;
                MBCIOSChessSquareElement *element =
                    [self iosAccessibilityElementForSquare:square];
                element.canActivate = humanTurn && white == whiteTurn;
                element.accessibilityLabel = MBCIOSPocketName(piece);
                element.accessibilityValue = [NSString stringWithFormat:@"%d", count];
                element.accessibilityHint = element.canActivate
                    ? MBCIOSLocalizedString(@"ios_pocket_select_hint", @"Select, then choose a board square. Activate again to cancel.")
                    : nil;
                static NSString *typeNames[] = {@"", @"king", @"queen", @"bishop", @"knight", @"rook", @"pawn"};
                element.accessibilityIdentifier = [NSString stringWithFormat:@"pocket-%@-%@",
                    white ? @"white" : @"black", typeNames[Piece(piece)]];
                element.accessibilityTraits = element.canActivate
                    ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
                element.accessibilityFrameInContainerSpace =
                    MBCIOSAccessibilityFrameForPosition(self, [self squareToPosition:square]);
                [elements addObject:element];
            }
        }
    }

    if (_board && [self wantsMouse]) {
        MBCSide side = whiteTurn ? kWhiteSide : kBlackSide;
        if ((_side == kBothSides || _side == side) && [_board canPromote:side]) {
            MBCSquare square = whiteTurn ? kWhitePromoSquare : kBlackPromoSquare;
            MBCIOSChessSquareElement *element =
                [self iosAccessibilityElementForSquare:square];
            element.canActivate = YES;
            element.accessibilityLabel = MBCIOSLocalizedString(@"ios_promotion_choice", @"Promotion choice");
            MBCPiece choice = [_board defaultPromotion:whiteTurn];
            element.accessibilityValue = MBCIOSPocketName(whiteTurn ? White((MBCPieceCode)choice)
                                                                  : Black((MBCPieceCode)choice));
            element.accessibilityHint = MBCIOSLocalizedString(@"ios_promotion_cycle_hint", @"Activate to cycle the promotion piece.");
            element.accessibilityIdentifier = whiteTurn ? @"promotion-white" : @"promotion-black";
            element.accessibilityTraits = UIAccessibilityTraitButton;
            MBCPosition position = {{whiteTurn ? -kPromotionPieceX : kPromotionPieceX,
                                     0.0f, whiteTurn ? -kPromotionPieceZ : kPromotionPieceZ}};
            element.accessibilityFrameInContainerSpace =
                MBCIOSAccessibilityFrameForPosition(self, position);
            [elements addObject:element];
        }
    }
    if (!_iosVisibleAccessibilityElements) {
        _iosVisibleAccessibilityElements = [NSMutableArray arrayWithArray:elements];
    } else if (![_iosVisibleAccessibilityElements isEqualToArray:elements]) {
        [_iosVisibleAccessibilityElements setArray:elements];
    }
    return _iosVisibleAccessibilityElements;
}

- (NSInteger)accessibilityElementCount
{
    return self.accessibilityElements.count;
}

- (id)accessibilityElementAtIndex:(NSInteger)index
{
    NSArray *elements = self.accessibilityElements;
    return index >= 0 && index < (NSInteger)elements.count ? elements[index] : nil;
}

- (NSInteger)indexOfAccessibilityElement:(id)element
{
    NSUInteger index = [self.accessibilityElements indexOfObjectIdenticalTo:element];
    return index == NSNotFound ? NSNotFound : (NSInteger)index;
}

- (NSString *)describeSquare:(MBCSquare)square
{
    MBCPiece piece = _board ? [_board curContents:square] : EMPTY;
    if (piece && Piece(piece) != EMPTY) {
        return [NSString localizedStringWithFormat:@"%@, %c%u", MBCIOSPocketName(piece),
                Col(square), Row(square)];
    }
    return [NSString stringWithFormat:@"%c%u", Col(square), Row(square)];
}

- (void)accessibilityActivateSquare:(MBCSquare)square
{
    [self iosSelectSquare:square];
}

@end
