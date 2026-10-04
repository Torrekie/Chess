#import "MBCIOSRendererPreferences.h"

NSString * const MBCIOSRendererPreferenceKey = @"MBCBoardRenderer";

@interface MBCIOSRendererPreferences ()
@property (nonatomic, strong) NSHashTable<id<MBCIOSRendererParticipant>> *participants;
@property (nonatomic, readwrite) NSUInteger revision;
@end

@implementation MBCIOSRendererPreferences
+ (instancetype)sharedPreferences
{
    static MBCIOSRendererPreferences *preferences;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        preferences = [[self alloc] init];
    });
    return preferences;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _participants = [NSHashTable weakObjectsHashTable];
        _revision = 1;
    }
    return self;
}

- (MBCIOSRendererKind)desiredRenderer
{
    return [[[NSUserDefaults standardUserDefaults] stringForKey:MBCIOSRendererPreferenceKey]
        isEqualToString:@"OpenGL"] ? MBCIOSRendererOpenGL : MBCIOSRendererMetal;
}

- (void)addParticipant:(id<MBCIOSRendererParticipant>)participant
{
    [self.participants addObject:participant];
}

- (void)removeParticipant:(id<MBCIOSRendererParticipant>)participant
{
    [self.participants removeObject:participant];
}

- (BOOL)selectRenderer:(MBCIOSRendererKind)kind error:(NSError **)error
{
    NSAssert(NSThread.isMainThread, @"Renderer preferences are applied on the main thread.");
    if (error) *error = nil;
    if (kind != MBCIOSRendererMetal && kind != MBCIOSRendererOpenGL) return NO;
    NSArray<id<MBCIOSRendererParticipant>> *scenes = self.participants.allObjects;
    NSMapTable *prepared = [NSMapTable strongToStrongObjectsMapTable];
    for (id<MBCIOSRendererParticipant> scene in scenes) {
        if (![scene rendererSceneIsForeground]) continue;
        MBCIOSBoardBackend *candidate = [scene prepareRenderer:kind error:error];
        if (!candidate) return NO;
        [prepared setObject:candidate forKey:scene];
    }
    [[NSUserDefaults standardUserDefaults] setObject:
        kind == MBCIOSRendererOpenGL ? @"OpenGL" : @"Metal"
        forKey:MBCIOSRendererPreferenceKey];
    NSUInteger revision = ++self.revision;
    for (id<MBCIOSRendererParticipant> scene in scenes) {
        [scene requestRenderer:kind revision:revision prepared:[prepared objectForKey:scene]];
    }
    return YES;
}
@end
