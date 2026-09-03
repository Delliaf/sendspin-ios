//
//  AudioEngine.h
//  Sendspin Universal iOS Player
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
namespace sendspin {
    class PlayerRole;
}
#endif

@protocol AudioEngineDelegate <NSObject>
@optional
- (void)audioEngineRouteChanged:(NSString *)newRoute;
@end

@interface AudioEngine : NSObject

@property (nonatomic, weak) id<AudioEngineDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isRunning;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) int32_t pioneerDelayMs;
@property (nonatomic, assign) BOOL keepAliveEnabled;

+ (instancetype)sharedInstance;

- (BOOL)setupAudioSessionWithError:(NSError **)error;
- (BOOL)start;
- (void)stop;
- (void)configureSampleRate:(uint32_t)sampleRate channels:(uint8_t)channels bitDepth:(uint8_t)bitDepth;
- (size_t)writeAudioData:(const uint8_t *)data length:(size_t)length;
- (void)clearBuffer;

#ifdef __cplusplus
- (void)setPlayerRole:(sendspin::PlayerRole *)playerRole;
#endif

@end
