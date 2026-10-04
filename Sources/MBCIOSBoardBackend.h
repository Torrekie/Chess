#import "MBCIOSBoardPresentation.h"

@interface MBCIOSBoardBackend : NSObject
@property (nonatomic, readonly) MBCIOSRendererKind kind;
@property (nonatomic, strong, readonly) UIView<MBCIOSBoardPresentation> *view;
+ (instancetype)backendWithKind:(MBCIOSRendererKind)kind
                           frame:(CGRect)frame
                           board:(MBCBoard *)board
                         variant:(MBCVariant)variant
                            side:(MBCSide)side
                      boardStyle:(NSString *)boardStyle
                      pieceStyle:(NSString *)pieceStyle
                           error:(NSError **)error;
- (BOOL)prepareWithError:(NSError **)error;
- (void)setRenderingActive:(BOOL)active;
- (void)renderFirstFrameWithCompletion:(void (^)(NSError *error))completion;
- (void)retireWithCompletion:(void (^)(void))completion;
@end
