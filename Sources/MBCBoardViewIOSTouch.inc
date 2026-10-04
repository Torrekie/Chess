/* Shared UIKit move validation, promotion and camera gestures. */

static void MBCNotifyInteractionEnded(MBCIOSBoardTouchClass *view)
{
    __weak MBCIOSBoardTouchClass *weakView = view;
    dispatch_async(dispatch_get_main_queue(), ^{
        MBCIOSBoardTouchClass *source = weakView;
        if (source) [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCIOSBoardInteractionEndedNotification object:source];
    });
}

static NSUInteger MBCActiveTouchCount(MBCIOSBoardTouchClass *view, UIEvent *event)
{
    NSUInteger count = 0;
    for (UITouch *touch in event.allTouches) {
        if (touch.view != view) continue;
        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) continue;
        ++count;
    }
    return count;
}

static BOOL MBCGestureMetrics(MBCIOSBoardTouchClass *view, UIEvent *event,
                              CGPoint *center, CGFloat *span, NSUInteger *count)
{
    CGPoint sum = CGPointZero;
    CGPoint first = CGPointZero;
    NSUInteger activeCount = 0;
    for (UITouch *touch in event.allTouches) {
        if (touch.view != view) continue;
        if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) continue;
        CGPoint point = [touch locationInView:view];
        if (activeCount == 0) first = point;
        sum.x += point.x;
        sum.y += point.y;
        ++activeCount;
    }
    if (count) *count = activeCount;
    if (activeCount == 0) return NO;
    if (center) {
        center->x = sum.x / (CGFloat)activeCount;
        center->y = sum.y / (CGFloat)activeCount;
    }
    if (span) {
        CGFloat total = 0.0;
        for (UITouch *touch in event.allTouches) {
            if (touch.view != view) continue;
            if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) continue;
            CGPoint point = [touch locationInView:view];
            total += hypot(point.x - first.x, point.y - first.y);
        }
        *span = activeCount > 1 ? total / (CGFloat)activeCount : 0.0;
    }
    return YES;
}

static BOOL MBCIsPocketSquare(MBCSquare square)
{
    if (square <= kInHandSquare || square > kInHandSquare + Black(PAWN)) return NO;
    MBCPiece piece = square - kInHandSquare;
    return Piece(piece) >= QUEEN && Piece(piece) <= PAWN && What(piece) == piece;
}

static BOOL MBCPocketMayBeSelected(MBCIOSBoardTouchClass *view, MBCSquare square)
{
    if (!view.board || view.variant != kVarCrazyhouse || !MBCIsPocketSquare(square)) return NO;
    MBCPiece piece = square - kInHandSquare;
    BOOL whiteTurn = ([view.board numMoves] & 1) == 0;
    return Color(piece) == (whiteTurn ? kWhitePiece : kBlackPiece) &&
           [view.board curInHand:piece] > 0;
}

/* MBCMoveGenerator emits pseudo-legal destinations.  Check the king after the
 * proposed move here because local human games post directly to the board. */
static BOOL MBCMoveKeepsKingSafe(MBCBoard *board, MBCVariant variant,
                                 MBCPiece piece, MBCSquare from, MBCSquare to,
                                 BOOL castling, BOOL dropping)
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
        MBCSquare rookTo = middle;
        position.fBoard[rookTo] = position.fBoard[rookFrom];
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

static MBCMove *MBCLegalMoveForSquares(MBCBoard *board, MBCVariant variant,
                                       MBCSquare from, MBCSquare to)
{
    if (!board || to >= kBoardSquares || from == to) return nil;

    BOOL dropping = MBCIsPocketSquare(from);
    BOOL whiteTurn = ([board numMoves] & 1) == 0;
    MBCPiece piece = EMPTY;
    if (dropping) {
        if (variant != kVarCrazyhouse) return nil;
        piece = from - kInHandSquare;
        if (Color(piece) != (whiteTurn ? kWhitePiece : kBlackPiece) ||
            [board curInHand:piece] < 1) return nil;
    } else if (from < kBoardSquares) {
        piece = [board curContents:from];
        if (Piece(piece) == EMPTY ||
            Color(piece) != (whiteTurn ? kWhitePiece : kBlackPiece)) return nil;
    } else {
        return nil;
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
    if (!permitted || !MBCMoveKeepsKingSafe(board, variant, piece, from, to,
                                            castling, dropping)) return nil;

    MBCMove *move = [MBCMove moveWithCommand:dropping ? kCmdDrop : kCmdMove];
    if (!dropping) move->fFromSquare = from;
    move->fToSquare = to;
    move->fPiece = piece;
    return move;
}

static BOOL MBCNeedsPromotionChoice(MBCMove *move)
{
    return move && move->fCommand == kCmdMove && Piece(move->fPiece) == PAWN &&
           Row(move->fToSquare) == (Color(move->fPiece) == kWhitePiece ? 8 : 1);
}

static NSString *MBCPromotionPieceName(MBCPieceCode type)
{
    switch (type) {
        case QUEEN:  return NSLocalizedString(@"queen", @"Queen");
        case ROOK:   return NSLocalizedString(@"rook", @"Rook");
        case BISHOP: return NSLocalizedString(@"bishop", @"Bishop");
        case KNIGHT: return NSLocalizedString(@"knight", @"Knight");
        case KING:   return NSLocalizedString(@"king", @"King");
        default:     return @"";
    }
}

static BOOL MBCHumanMayMove(MBCIOSBoardTouchClass *view)
{
    MBCSide side = view.side;
    if (side == kBothSides) return YES;
    if (side == kNeitherSide || !view.board) return NO;

    BOOL whiteTurn = (view.board.numMoves & 1) == 0;
    return whiteTurn ? side == kWhiteSide : side == kBlackSide;
}

static BOOL MBCExplicitPromotionIsValid(MBCMove *move, MBCVariant variant)
{
    if (!MBCNeedsPromotionChoice(move) || !move->fPromotion) return NO;
    switch (Piece(move->fPromotion)) {
        case QUEEN: case ROOK: case BISHOP: case KNIGHT: return YES;
        case KING: return variant == kVarSuicide;
        default: return NO;
    }
}

static void MBCPostUncheckedMove(MBCIOSBoardTouchClass *sourceView, MBCBoard *board,
                                 MBCMove *move)
{
    if (!sourceView || !board || !move) return;
    NSString *name = ([board numMoves] & 1) == 0
        ? MBCUncheckedWhiteMoveNotification
        : MBCUncheckedBlackMoveNotification;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:name object:sourceView userInfo:(NSDictionary *)move];
}

@implementation MBCIOSBoardTouchClass (IOSTouch)

- (BOOL)iosCyclePromotionForSquare:(MBCSquare)square
{
    if (square != kWhitePromoSquare && square != kBlackPromoSquare) return NO;
    if (!_board || !_wantMouse || _inAnimation || _awaitingPromotionChoice ||
        !MBCHumanMayMove(self)) return NO;
    BOOL white = square == kWhitePromoSquare;
    if (([_board numMoves] & 1) != (white ? 0 : 1) ||
        ![_board canPromote:white ? kWhiteSide : kBlackSide]) return NO;

    MBCPiece current = [_board defaultPromotion:white];
    MBCPiece next = QUEEN;
    switch (Piece(current)) {
        case QUEEN:  next = _variant == kVarSuicide ? KING : KNIGHT; break;
        case KING:   next = KNIGHT; break;
        case KNIGHT: next = ROOK; break;
        case ROOK:   next = BISHOP; break;
        case BISHOP: next = QUEEN; break;
        default: break;
    }
    [_board setDefaultPromotion:next for:white];
    [self drawNow];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                    MBCPromotionPieceName((MBCPieceCode)next));
    return YES;
}

- (void)iosSubmitMove:(MBCMove *)move
{
    if (!move || !_board || _awaitingPromotionChoice) return;
    if (MBCNeedsPromotionChoice(move) && move->fPromotion) {
        if (!MBCExplicitPromotionIsValid(move, _variant) ||
            !MBCHumanMayMove(self)) return;
        MBCMove *legalMove = MBCLegalMoveForSquares(_board, _variant,
                                                   move->fFromSquare, move->fToSquare);
        if (!legalMove || legalMove->fPiece != move->fPiece ||
            !MBCNeedsPromotionChoice(legalMove)) return;
        legalMove->fPromotion = Piece(move->fPromotion);
        [_board setDefaultPromotion:legalMove->fPromotion
                               for:Color(legalMove->fPiece) == kWhitePiece];
        MBCPostUncheckedMove(self, _board, legalMove);
        return;
    }
    if (!MBCNeedsPromotionChoice(move)) {
        MBCPostUncheckedMove(self, _board, move);
        return;
    }

    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    UIViewController *presenter = (UIViewController *)responder;
    if (!presenter || !self.window || presenter.presentedViewController) return;

    MBCBoard *board = _board;
    MBCVariant variant = _variant;
    MBCSquare from = move->fFromSquare;
    MBCSquare to = move->fToSquare;
    MBCPiece originalPiece = move->fPiece;
    int moveCount = [board numMoves];
    NSString *position = [board fen];
    NSString *holding = [board holding];
    BOOL white = Color(originalPiece) == kWhitePiece;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSLocalizedString(@"promote_to", @"Promote to") localizedCapitalizedString]
                         message:nil preferredStyle:UIAlertControllerStyleAlert];
    const MBCPieceCode choices[] = {QUEEN, ROOK, BISHOP, KNIGHT, KING};
    NSUInteger choiceCount = variant == kVarSuicide ? 5 : 4;
    __weak MBCIOSBoardTouchClass *weakView = self;
    for (NSUInteger index = 0; index < choiceCount; ++index) {
        MBCPieceCode choice = choices[index];
        [alert addAction:[UIAlertAction
            actionWithTitle:[MBCPromotionPieceName(choice) localizedCapitalizedString]
                    style:UIAlertActionStyleDefault
                  handler:^(__unused UIAlertAction *action) {
            MBCIOSBoardTouchClass *view = weakView;
            if (!view) return;
            view->_awaitingPromotionChoice = NO;
            MBCNotifyInteractionEnded(view);
            if (!view.window || view->_board != board || view->_variant != variant ||
                !view->_wantMouse || view->_inAnimation || !MBCHumanMayMove(view) ||
                [board numMoves] != moveCount ||
                [board curContents:from] != originalPiece ||
                ![[board fen] isEqualToString:position] ||
                ![[board holding] isEqualToString:holding]) return;
            MBCMove *currentMove = MBCLegalMoveForSquares(board, variant, from, to);
            if (!currentMove || !MBCNeedsPromotionChoice(currentMove)) return;
            currentMove->fPromotion = choice;
            [board setDefaultPromotion:choice for:white];
            MBCPostUncheckedMove(view, board, currentMove);
        }]];
    }
    [alert addAction:[UIAlertAction
        actionWithTitle:MBCIOSLocalizedString(@"ios_cancel", @"Cancel")
                style:UIAlertActionStyleCancel
              handler:^(__unused UIAlertAction *action) {
        MBCIOSBoardTouchClass *view = weakView;
        if (view) {
            view->_awaitingPromotionChoice = NO;
            MBCNotifyInteractionEnded(view);
        }
    }]];
    _awaitingPromotionChoice = YES;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)beginTwoFingerManipulationWithEvent:(UIEvent *)event
{
    CGPoint center = CGPointZero;
    CGFloat span = 0.0;
    NSUInteger count = 0;
    if (!MBCGestureMetrics(self, event, &center, &span, &count) || count < 2) return;

    _inTwoFingerManipulation = YES;
    _inBoardManipulation = NO;
    _boardManipulationDidMove = YES;
    _previousGestureCenter = center;
    _previousGestureSpan = span;
    _pickedSquare = kInvalidSquare;
    [self unselectPiece];
}

- (BOOL)updateTwoFingerManipulationWithEvent:(UIEvent *)event
{
    CGPoint center = CGPointZero;
    CGFloat span = 0.0;
    NSUInteger count = 0;
    if (!MBCGestureMetrics(self, event, &center, &span, &count) || count < 2) return NO;

    CGPoint centerDelta = CGPointMake(center.x - _previousGestureCenter.x,
                                      center.y - _previousGestureCenter.y);
    MBCTranslateCameraByScreenDelta(self, centerDelta);
    if (_previousGestureSpan > 1.0 && span > 1.0) {
        MBCMultiplyCameraDistance(self, (float)(_previousGestureSpan / span));
    }
    _previousGestureCenter = center;
    _previousGestureSpan = span;
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    // The move animator owns the selection until it commits the move.
    if (_inAnimation || _awaitingPromotionChoice) return;
    UITouch *touch = [touches anyObject];
    if (!touch || !_board || self.drawableSize.width <= 0.0 || self.drawableSize.height <= 0.0) {
        return;
    }

    if (MBCActiveTouchCount(self, event) >= 2) {
        [self beginTwoFingerManipulationWithEvent:event];
        return;
    }

    CGPoint point = [touch locationInView:self];
    MBCPosition position = MBCPositionForTouch(self, point);
    _selectedDestination = [self positionToSquareOrRegion:&position];


    BOOL hasPiece = _selectedDestination < kBoardSquares &&
                    Piece([_board curContents:_selectedDestination]) != EMPTY &&
                    Color([_board curContents:_selectedDestination]) ==
                        (([_board numMoves] & 1) ? kBlackPiece : kWhitePiece);
    BOOL hasPocket = MBCPocketMayBeSelected(self, _selectedDestination);
    BOOL promotionRegion = _selectedDestination == kWhitePromoSquare ||
                           _selectedDestination == kBlackPromoSquare;
    if (_pickedSquare == kInvalidSquare &&
        (_selectedDestination == kBorderRegion ||
         _selectedDestination == kInvalidSquare ||
         (!hasPiece && !hasPocket && !promotionRegion))) {
        _inBoardManipulation = YES;
        _boardManipulationStartPoint = point;
        _boardManipulationDidMove = NO;
        _previousMousePosition = point;
        _currentMousePosition = point;
        _rawAzimuth = self.azimuth;
        return;
    }

    if ((_selectedDestination >= kSyntheticSquare && !hasPocket) || !_wantMouse ||
        _inAnimation) {
        return;
    }

    if (!MBCHumanMayMove(self)) {
        return;
    }

    if (_pickedSquare != kInvalidSquare) {
        return;
    }

    MBCPiece piece = hasPocket
        ? _selectedDestination - kInHandSquare
        : [_board curContents:_selectedDestination];
    if (hasPiece || hasPocket) {
        _previousMousePosition = point;
        _currentMousePosition = point;
        [self selectPiece:piece at:_selectedDestination];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (_inAnimation || _awaitingPromotionChoice) return;
    UITouch *touch = [touches anyObject];
    if (!touch) {
        return;
    }

    CGPoint point = [touch locationInView:self];
    _currentMousePosition = point;

    if (_inTwoFingerManipulation || MBCActiveTouchCount(self, event) >= 2) {
        if (!_inTwoFingerManipulation) {
            [self beginTwoFingerManipulationWithEvent:event];
        }
        if ([self updateTwoFingerManipulationWithEvent:event]) {
            [self drawNow];
        }
        return;
    }

    if (_inBoardManipulation) {
        if (!_boardManipulationDidMove) {
            if (hypot(point.x - _boardManipulationStartPoint.x,
                      point.y - _boardManipulationStartPoint.y) <= 10.0) return;
            _boardManipulationDidMove = YES;
        }
        CGFloat dx = point.x - _previousMousePosition.x;
        CGFloat dy = point.y - _previousMousePosition.y;
        if (fabs(dx) >= fabs(dy)) {
            self.azimuth = fmodf(self.azimuth + (float)dx * 0.5f + 360.0f, 360.0f);
        } else {
            // UIKit's y axis grows downward. Match macOS's upward drag
            // convention by adding the UIKit delta here.
            self.elevation = MAX(kMinElevation, MIN(kMaxElevation,
                self.elevation + (float)dy * 0.5f));
        }
        _previousMousePosition = point;
        [self drawNow];
        return;
    }

    if (_selectedPiece != EMPTY && !_inAnimation) {
        _selectedPosition = MBCPositionForTouch(self, point);
        [self snapToSquare:&_selectedPosition];
        [self drawNow];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    MBCNotifyInteractionEnded(self);
    if (_inAnimation || _awaitingPromotionChoice) return;
    UITouch *touch = [touches anyObject];
    if (!touch) {
        return;
    }

    CGPoint point = [touch locationInView:self];
    MBCPosition position = MBCPositionForTouch(self, point);

    if (_inTwoFingerManipulation) {
        if (MBCActiveTouchCount(self, event) == 0) {
            _inTwoFingerManipulation = NO;
            _previousGestureCenter = CGPointZero;
            _previousGestureSpan = 0.0;
            [[NSNotificationCenter defaultCenter]
                postNotificationName:MBCIOSBoardCameraChangedNotification object:self];
            [self drawNow];
        }
        return;
    }

    if (_inBoardManipulation) {
        BOOL stationary = !_boardManipulationDidMove &&
            hypot(point.x - _boardManipulationStartPoint.x,
                  point.y - _boardManipulationStartPoint.y) <= 10.0;
        _inBoardManipulation = NO;
        if (!stationary) [[NSNotificationCenter defaultCenter]
            postNotificationName:MBCIOSBoardCameraChangedNotification object:self];
        _selectedDestination = kInvalidSquare;
        [self drawNow];
        if (stationary && _pickedSquare == kInvalidSquare && _selectedPiece == EMPTY) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:MBCIOSBoardIdleTapNotification object:self];
        }
        return;
    }

    if (!_wantMouse || _inAnimation || !_board || !MBCHumanMayMove(self)) {
        [self unselectPiece];
        _selectedDestination = kInvalidSquare;
        return;
    }

    MBCSquare destination = [self positionToSquareOrRegion:&position];
    if ((_selectedDestination == kWhitePromoSquare ||
         _selectedDestination == kBlackPromoSquare) &&
        destination == _selectedDestination) {
        [self iosCyclePromotionForSquare:destination];
        _selectedDestination = kInvalidSquare;
        return;
    }
    MBCMove *move = nil;
    if (_pickedSquare != kInvalidSquare) {
        move = MBCLegalMoveForSquares(_board, _variant, _pickedSquare, destination);
        _pickedSquare = kInvalidSquare;
        [self unselectPiece];
    } else if (_selectedPiece != EMPTY) {
        // A tap picks the piece for a second tap; a drag supplies its target.
        BOOL dragged = hypot(point.x - _previousMousePosition.x,
                             point.y - _previousMousePosition.y) > 12.0;
        if (dragged && destination != _selectedSquare) {
            move = MBCLegalMoveForSquares(_board, _variant, _selectedSquare, destination);
            [self unselectPiece];
        } else {
            [self clickPiece];
        }
    }

    _selectedDestination = kInvalidSquare;
    // Human-vs-Human delivery starts the animation synchronously. Finish
    // touch cleanup first so it cannot erase the animator's piece/destination.
    if (move) {
        [self iosSubmitMove:move];
    }
    [self drawNow];

}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    MBCNotifyInteractionEnded(self);
    (void)touches;
    (void)event;
    if (_inAnimation) return;
    _inBoardManipulation = NO;
    _boardManipulationDidMove = NO;
    _inTwoFingerManipulation = NO;
    _previousGestureCenter = CGPointZero;
    _previousGestureSpan = 0.0;
    _selectedDestination = kInvalidSquare;
    [self unselectPiece];
    [self drawNow];
}

- (void)iosSelectSquare:(MBCSquare)square
{
    if (!_board || !_wantMouse || _inAnimation || _awaitingPromotionChoice ||
        !MBCHumanMayMove(self)) {
        return;
    }
    if (square == kWhitePromoSquare || square == kBlackPromoSquare) {
        [self iosCyclePromotionForSquare:square];
        return;
    }
    if (square >= kBoardSquares && !MBCPocketMayBeSelected(self, square) &&
        _pickedSquare == kInvalidSquare) return;
    if (_pickedSquare != kInvalidSquare) {
        MBCMove *move = MBCLegalMoveForSquares(_board, _variant, _pickedSquare, square);
        _pickedSquare = kInvalidSquare;
        [self unselectPiece];
        if (move) {
            [self iosSubmitMove:move];
        }
    } else {
        MBCPiece piece = MBCIsPocketSquare(square)
            ? square - kInHandSquare : [_board curContents:square];
        if (Piece(piece) != EMPTY &&
            Color(piece) == (([_board numMoves] & 1) ? kBlackPiece : kWhitePiece)) {
            [self selectPiece:piece at:square];
            [self clickPiece];
        }
    }
    [self drawNow];
}

- (uint64_t)iosLegalDropTargets
{
    MBCSquare source = MBCIsPocketSquare(_pickedSquare) ? _pickedSquare :
        (_selectedPiece != EMPTY && MBCIsPocketSquare(_selectedSquare)
            ? _selectedSquare : kInvalidSquare);
    if (!MBCIsPocketSquare(source) || !_board || _variant != kVarCrazyhouse ||
        !_wantMouse || _inAnimation || !MBCHumanMayMove(self)) return 0;
    MBCPiece piece = source - kInHandSquare;
    int moveCount = [_board numMoves];
    BOOL white = (moveCount & 1) == 0;
    if (Color(piece) != (white ? kWhitePiece : kBlackPiece) ||
        [_board curInHand:piece] < 1) return 0;
    if (_legalDropTargetsValid && _legalDropOrigin == source &&
        _legalDropMoveCount == moveCount) return _legalDropTargetsMask;

    MBCMoveCollector *collector = [[MBCMoveCollector alloc] init];
    MBCMoveGenerator generator(collector, _variant, 0);
    generator.Generate(white, *[_board curPos]);
    MBCMoveCollection *collection = [collector collection];
    uint64_t candidates = Piece(piece) == PAWN ? collection->fPawnDrops
        : (collection->fDroppablePieces & (1 << Piece(piece)))
            ? collection->fPieceDrops : 0;
    uint64_t legal = 0;
    for (MBCSquare square = 0; square < kBoardSquares; ++square) {
        if ((candidates & (1ULL << square)) &&
            MBCMoveKeepsKingSafe(_board, _variant, piece, source, square,
                                 NO, YES)) legal |= (1ULL << square);
    }
    _legalDropOrigin = source;
    _legalDropMoveCount = moveCount;
    _legalDropTargetsMask = legal;
    _legalDropTargetsValid = YES;
    return legal;
}

@end
