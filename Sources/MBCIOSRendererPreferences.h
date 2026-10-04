#import "MBCIOSBoardBackend.h"

FOUNDATION_EXPORT NSString * const MBCIOSRendererPreferenceKey;

@protocol MBCIOSRendererParticipant <NSObject>
- (BOOL)rendererSceneIsForeground;
- (MBCIOSBoardBackend *)prepareRenderer:(MBCIOSRendererKind)kind error:(NSError **)error;
- (void)requestRenderer:(MBCIOSRendererKind)kind
              revision:(NSUInteger)revision
              prepared:(MBCIOSBoardBackend *)prepared;
@end

@interface MBCIOSRendererPreferences : NSObject
+ (instancetype)sharedPreferences;
@property (nonatomic, readonly) MBCIOSRendererKind desiredRenderer;
@property (nonatomic, readonly) NSUInteger revision;
- (void)addParticipant:(id<MBCIOSRendererParticipant>)participant;
- (void)removeParticipant:(id<MBCIOSRendererParticipant>)participant;
- (BOOL)selectRenderer:(MBCIOSRendererKind)kind error:(NSError **)error;
@end
