//
//  AudioEngine.h
//  Sendspin Universal iOS Player
//
//  Architecture Role:
//    - Lock-Free CoreAudio RemoteIO audio engine.
//    - Manages hardware audio session (AVAudioSession on iOS 4+, C AudioSession on iOS 3).
//    - Single-Producer Single-Consumer (SPSC) lock-free atomic ring buffer.
//    - Sub-millisecond buffer duration and phase-delay calibration.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

@protocol AudioEngineDelegate <NSObject>
@optional
- (void)audioEngineRouteChanged:(NSString *)newRoute;
@end

#ifdef __cplusplus
namespace sendspin { class PlayerRole; }
#endif

@interface AudioEngine : NSObject

@property (nonatomic, weak) id<AudioEngineDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isRunning;
@property (nonatomic, assign) float volume;              // 0.0 to 1.0
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) int32_t pioneerDelayMs;    // Hardware sync offset (-1000 to +1000 ms)
@property (nonatomic, assign) BOOL keepAliveEnabled;     // Silent stream to prevent iOS RAM eviction

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
