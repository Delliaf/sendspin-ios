//
//  SendspinBridge.h
//  Sendspin Universal iOS Player
//
//  Architecture Role:
//    - High-level orchestrator connecting sendspin-cpp, mDNS discovery, and iOS UI.
//    - Coordinates PlayerRole (audio), ControllerRole (transport), MetadataRole, ArtworkRole.
//    - Native DNS-SD / Bonjour service browsing (_sendspin._tcp & _music-assistant._tcp).
//    - Lock Screen and Control Center integration via MPNowPlayingInfoCenter & MPRemoteCommandCenter.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SendspinConnectionState) {
    SendspinConnectionStateDisconnected,
    SendspinConnectionStateListening,
    SendspinConnectionStateConnecting,
    SendspinConnectionStateConnected,
    SendspinConnectionStateSynchronized,
    SendspinConnectionStateError
};

typedef NS_ENUM(NSInteger, SendspinPlaybackState) {
    SendspinPlaybackStateStopped,
    SendspinPlaybackStatePlaying,
    SendspinPlaybackStatePaused
};

@protocol SendspinBridgeDelegate <NSObject>
@optional
- (void)sendspinConnectionStateChanged:(SendspinConnectionState)state message:(NSString *)msg;
- (void)sendspinPlaybackStateChanged:(SendspinPlaybackState)playbackState;
- (void)sendspinMetadataUpdatedTitle:(NSString *)title 
                              artist:(NSString *)artist 
                               album:(NSString *)album 
                               genre:(NSString *)genre
                            trackNum:(uint16_t)trackNum
                          durationMs:(uint32_t)durationMs 
                          progressMs:(uint32_t)progressMs;
- (void)sendspinArtworkUpdated:(UIImage *)image;
- (void)sendspinVolumeUpdated:(float)volume muted:(BOOL)muted;
- (void)sendspinDiscoveredServersUpdated:(NSArray<NSDictionary *> *)servers;
- (void)sendspinPromptConnectToServer:(NSDictionary *)server;
@end

@interface SendspinBridge : NSObject

@property (nonatomic, weak) id<SendspinBridgeDelegate> delegate;
@property (nonatomic, assign, readonly) SendspinConnectionState connectionState;
@property (nonatomic, assign, readonly) SendspinPlaybackState playbackState;
@property (nonatomic, copy, readonly) NSString *playerName;
@property (nonatomic, copy, readonly) NSString *connectedServerAddress;
@property (nonatomic, copy, readonly) NSString *connectedServerName;
@property (nonatomic, assign, readonly) uint16_t listeningPort;

@property (nonatomic, copy, readonly) NSString *currentTitle;
@property (nonatomic, copy, readonly) NSString *currentArtist;
@property (nonatomic, copy, readonly) NSString *currentAlbum;
@property (nonatomic, copy, readonly) NSString *currentGenre;
@property (nonatomic, assign, readonly) uint16_t currentTrackNum;
@property (nonatomic, assign, readonly) uint32_t currentDurationMs;
@property (nonatomic, assign, readonly) uint32_t currentProgressMs;
@property (nonatomic, strong, readonly) UIImage *currentArtwork;
@property (nonatomic, assign, readonly) float currentVolume;

@property (nonatomic, copy, readonly) NSString *savedServerHost;
@property (nonatomic, assign, readonly) uint16_t savedServerPort;
@property (nonatomic, copy, readonly) NSString *savedServerName;
@property (nonatomic, assign) BOOL autoConnectToSavedServer;
@property (nonatomic, strong, readonly) NSArray<NSDictionary *> *discoveredServers;

+ (instancetype)sharedInstance;

- (void)startServiceWithName:(NSString *)name port:(uint16_t)port;
- (void)stop;

- (void)startBonjourDiscovery;
- (void)stopBonjourDiscovery;
- (void)rescanBonjourServers;

- (void)connectToRemoteServer:(NSString *)host port:(uint16_t)port name:(NSString *)name remember:(BOOL)remember;
- (void)disconnect;
- (void)forgetSavedServer;

- (void)togglePlayPause;
- (void)play;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
- (void)setVolume:(float)volume;
- (void)seekToMs:(uint32_t)positionMs;
- (void)adjustSyncDelayMs:(int16_t)deltaMs;

- (void)updateSystemNowPlayingInfo;

@end
