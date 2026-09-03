//
//  SendspinBridge.mm
//  Sendspin Universal iOS Player
//

#import "SendspinBridge.h"
#import "AudioEngine.h"
#import <MediaPlayer/MediaPlayer.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include "sendspin/client.h"
#include "sendspin/player_role.h"
#include "sendspin/controller_role.h"
#include "sendspin/metadata_role.h"
#include "sendspin/artwork_role.h"
#include <thread>
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <atomic>
#include <algorithm>

struct DiscoveredServerInfo {
    std::string name;
    std::string host;
    uint16_t port{0};
    std::string path;
};

struct ServiceKey {
    std::string name;
    std::string regtype;
    std::string domain;

    bool operator<(const ServiceKey& o) const {
        if (name != o.name) return name < o.name;
        if (regtype != o.regtype) return regtype < o.regtype;
        return domain < o.domain;
    }
};

#import <ifaddrs.h>
#import <arpa/inet.h>
#import <fcntl.h>

static NSString *GetLocalWiFiIPAddress() {
    NSString *address = @"127.0.0.1";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *ifName = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([ifName isEqualToString:@"en0"] || [ifName isEqualToString:@"en1"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    if (interfaces) freeifaddrs(interfaces);
    return address;
}

@interface SendspinBonjourBrowser : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate> {
    NSMutableArray<NSNetServiceBrowser *> *_browsers;
    NSMutableArray<NSNetService *> *_resolvingServices;
    NSMutableDictionary<NSString *, NSDictionary *> *_discoveredMap;
}
@property (nonatomic, weak) SendspinBridge *bridge;
- (instancetype)initWithBridge:(SendspinBridge *)bridge;
- (void)start;
- (void)stop;
@end

@interface SendspinBridge () {
@public
    std::unique_ptr<sendspin::SendspinClient> _client;
    sendspin::PlayerRole *_playerRole;
    sendspin::ControllerRole *_controllerRole;
    sendspin::MetadataRole *_metadataRole;
    sendspin::ArtworkRole *_artworkRole;
    std::thread _workerThread;
    std::atomic<bool> _shouldRun;
    
    DNSServiceRef _registerRef;
    SendspinBonjourBrowser *_bonjourBrowser;
    NSMutableArray<NSDictionary *> *_discoveredServersInternal;
    NSMutableSet<NSString *> *_promptedServers;
}

@property (nonatomic, assign, readwrite) SendspinConnectionState connectionState;
@property (nonatomic, assign, readwrite) SendspinPlaybackState playbackState;
@property (nonatomic, copy, readwrite) NSString *playerName;
@property (nonatomic, copy, readwrite) NSString *connectedServerAddress;
@property (nonatomic, copy, readwrite) NSString *connectedServerName;
@property (nonatomic, assign, readwrite) uint16_t listeningPort;

@property (nonatomic, copy, readwrite) NSString *currentTitle;
@property (nonatomic, copy, readwrite) NSString *currentArtist;
@property (nonatomic, copy, readwrite) NSString *currentAlbum;
@property (nonatomic, copy, readwrite) NSString *currentGenre;
@property (nonatomic, assign, readwrite) uint16_t currentTrackNum;
@property (nonatomic, strong, readwrite) UIImage *currentArtwork;
@property (nonatomic, assign, readwrite) uint32_t currentProgressMs;
@property (nonatomic, assign, readwrite) uint32_t currentDurationMs;
@property (nonatomic, assign, readwrite) float currentVolume;
@property (nonatomic, assign, readwrite) BOOL currentMuted;

- (void)handleDiscoveredServers:(NSArray<NSDictionary *> *)servers;

@end

@implementation SendspinBonjourBrowser

- (instancetype)initWithBridge:(SendspinBridge *)bridge {
    if (self = [super init]) {
        _bridge = bridge;
        _browsers = [NSMutableArray array];
        _resolvingServices = [NSMutableArray array];
        _discoveredMap = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)start {
    [self stop];
    @synchronized (_discoveredMap) {
        [_discoveredMap removeAllObjects];
    }
    
    NSArray *serviceTypes = @[
        @"_sendspin-server._tcp."
    ];
    
    for (NSString *st in serviceTypes) {
        NSNetServiceBrowser *b = [[NSNetServiceBrowser alloc] init];
        b.delegate = self;
        [b searchForServicesOfType:st inDomain:@"local."];
        [_browsers addObject:b];
    }
    
    NSLog(@"[BonjourBrowser] Official _sendspin-server._tcp. discovery active");
}

- (void)rescanWithSubnetProbe {
    [self start];
    [self startSubnetProbe];
}

- (void)stop {
    for (NSNetServiceBrowser *b in _browsers) {
        [b stop];
        b.delegate = nil;
    }
    [_browsers removeAllObjects];
    
    for (NSNetService *s in _resolvingServices) {
        [s stop];
        s.delegate = nil;
    }
    [_resolvingServices removeAllObjects];
}

- (void)startSubnetProbe {
    NSString *localIP = GetLocalWiFiIPAddress();
    if ([localIP isEqualToString:@"127.0.0.1"]) return;
    
    NSArray *parts = [localIP componentsSeparatedByString:@"."];
    if (parts.count != 4) return;
    
    NSString *prefix = [NSString stringWithFormat:@"%@.%@.%@.", parts[0], parts[1], parts[2]];
    uint16_t localPort = _bridge.listeningPort;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 1; i <= 254; ++i) {
            NSString *targetIP = [NSString stringWithFormat:@"%@%d", prefix, i];
            uint16_t targetPort = 8927; // Music Assistant Sendspin server port
            
            if ([targetIP isEqualToString:localIP] && targetPort == localPort) {
                continue; // Skip self
            }
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                int sock = socket(AF_INET, SOCK_STREAM, 0);
                if (sock >= 0) {
                    fcntl(sock, F_SETFL, O_NONBLOCK);
                    struct sockaddr_in sa {};
                    sa.sin_family = AF_INET;
                    sa.sin_port = htons(targetPort);
                    inet_pton(AF_INET, [targetIP UTF8String], &sa.sin_addr);
                    
                    connect(sock, (struct sockaddr *)&sa, sizeof(sa));
                    
                    fd_set wset;
                    FD_ZERO(&wset);
                    FD_SET(sock, &wset);
                    struct timeval tv { 1, 200000 }; // 1.2s timeout
                    
                    if (select(sock + 1, NULL, &wset, NULL, &tv) > 0) {
                        int err = 0;
                        socklen_t len = sizeof(err);
                        getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len);
                        if (err == 0) {
                            NSString *key = [NSString stringWithFormat:@"%@:%u", targetIP, targetPort];
                            @synchronized (self->_discoveredMap) {
                                if (!self->_discoveredMap[key]) {
                                    self->_discoveredMap[key] = @{
                                        @"name": @"Music Assistant",
                                        @"host": targetIP,
                                        @"port": @(targetPort),
                                        @"path": @"/sendspin"
                                    };
                                }
                            }
                            NSLog(@"[BonjourBrowser] Discovered server via probe: %@:%u", targetIP, targetPort);
                            [self notifyBridge];
                        }
                    }
                    close(sock);
                }
            });
        }
    });
}

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    NSLog(@"[BonjourBrowser] Discovered service: %@ (type: %@)", service.name, service.type);
    service.delegate = self;
    [_resolvingServices addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
    NSString *key = [NSString stringWithFormat:@"%@_%@", service.type, service.name];
    @synchronized (_discoveredMap) {
        [_discoveredMap removeObjectForKey:key];
    }
    [self notifyBridge];
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *host = nil;
    for (NSData *address in service.addresses) {
        struct sockaddr_in *socketAddress = (struct sockaddr_in *)[address bytes];
        if (socketAddress && socketAddress->sin_family == AF_INET) {
            char ipStr[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &(socketAddress->sin_addr), ipStr, sizeof(ipStr))) {
                host = [NSString stringWithUTF8String:ipStr];
                break;
            }
        }
    }
    
    NSString *localIP = GetLocalWiFiIPAddress();
    uint16_t localPort = _bridge.listeningPort;
    NSInteger port = service.port;
    
    if (host.length > 0) {
        // Skip self
        if (([host isEqualToString:localIP] || [host isEqualToString:@"127.0.0.1"]) && port == localPort) {
            [_resolvingServices removeObject:service];
            return;
        }
        
        NSString *path = @"/sendspin";
        NSString *friendlyName = service.name ?: @"Music Assistant";
        
        NSData *txtData = service.TXTRecordData;
        if (txtData) {
            NSDictionary *txtDict = [NSNetService dictionaryFromTXTRecordData:txtData];
            NSData *pathData = txtDict[@"path"];
            if (pathData) {
                path = [[NSString alloc] initWithData:pathData encoding:NSUTF8StringEncoding] ?: @"/sendspin";
            }
            NSData *nameData = txtDict[@"name"];
            if (nameData) {
                friendlyName = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] ?: friendlyName;
            }
        }
        
        // Canonical deduplication key: host:port
        NSString *key = [NSString stringWithFormat:@"%@:%ld", host, (long)port];
        @synchronized (_discoveredMap) {
            _discoveredMap[key] = @{
                @"name": friendlyName,
                @"host": host,
                @"port": @(port),
                @"path": path
            };
        }
        NSLog(@"[BonjourBrowser] Resolved %@ -> %@:%ld%@", friendlyName, host, (long)port, path);
        [self notifyBridge];
    }
    [_resolvingServices removeObject:service];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict {
    NSLog(@"[BonjourBrowser] Failed to resolve service %@: %@", service.name, errorDict);
    [_resolvingServices removeObject:service];
}

- (void)notifyBridge {
    if (!_bridge) return;
    NSArray *servers = nil;
    @synchronized (_discoveredMap) {
        servers = [_discoveredMap allValues];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_bridge handleDiscoveredServers:servers];
    });
}

@end

struct AppNetworkProvider : public sendspin::SendspinNetworkProvider {
    bool is_network_ready() override { return true; }
};

class AppClientListener : public sendspin::SendspinClientListener {
public:
    AppClientListener(SendspinBridge *bridge) : bridge_(bridge) {}

    void on_group_update(const sendspin::GroupUpdateObject& group) override {
        (void)group;
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.connectionState = SendspinConnectionStateConnected;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
                [bridge_.delegate sendspinConnectionStateChanged:SendspinConnectionStateConnected message:@"Connected to Server"];
            }
            [bridge_ updateSystemNowPlayingInfo];
        });
    }

    void on_time_sync_updated(float error) override {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.connectionState = SendspinConnectionStateSynchronized;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
                [bridge_.delegate sendspinConnectionStateChanged:SendspinConnectionStateSynchronized message:@"Synchronized"];
            }
        });
    }

private:
    __weak SendspinBridge *bridge_;
};

class AppPlayerListener : public sendspin::PlayerRoleListener {
public:
    AppPlayerListener(SendspinBridge *bridge) : bridge_(bridge) {}

    size_t on_audio_write(uint8_t* data, size_t length, uint32_t timeout_ms) override {
        (void)timeout_ms;
        return [[AudioEngine sharedInstance] writeAudioData:data length:length];
    }

    void on_stream_start() override {
        NSLog(@"[SendspinBridge] Audio stream start");
        if (bridge_ && bridge_->_playerRole) {
            const auto& params = bridge_->_playerRole->get_current_stream_params();
            uint32_t sr = params.sample_rate.value_or(48000);
            uint8_t ch = params.channels.value_or(2);
            uint8_t bd = params.bit_depth.value_or(16);
            [[AudioEngine sharedInstance] configureSampleRate:sr channels:ch bitDepth:bd];
        }
        [[AudioEngine sharedInstance] start];
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.playbackState = SendspinPlaybackStatePlaying;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinPlaybackStateChanged:)]) {
                [bridge_.delegate sendspinPlaybackStateChanged:SendspinPlaybackStatePlaying];
            }
            [bridge_ updateSystemNowPlayingInfo];
        });
    }

    void on_stream_end() override {
        NSLog(@"[SendspinBridge] Audio stream end");
        [[AudioEngine sharedInstance] clearBuffer];
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.playbackState = SendspinPlaybackStateStopped;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinPlaybackStateChanged:)]) {
                [bridge_.delegate sendspinPlaybackStateChanged:SendspinPlaybackStateStopped];
            }
            [bridge_ updateSystemNowPlayingInfo];
        });
    }

    void on_volume_changed(uint8_t volume) override {
        float norm = static_cast<float>(volume) / 100.0f;
        if (norm > 0.005f) {
            [AudioEngine sharedInstance].volume = norm;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.currentVolume = (norm > 0.005f) ? norm : 1.0f;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinVolumeUpdated:muted:)]) {
                [bridge_.delegate sendspinVolumeUpdated:bridge_.currentVolume muted:bridge_.currentMuted];
            }
        });
    }

    void on_mute_changed(bool muted) override {
        [AudioEngine sharedInstance].isMuted = muted;
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.currentMuted = muted;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinVolumeUpdated:muted:)]) {
                [bridge_.delegate sendspinVolumeUpdated:bridge_.currentVolume muted:muted];
            }
        });
    }

private:
    __weak SendspinBridge *bridge_;
};

class AppControllerListener : public sendspin::ControllerRoleListener {
public:
    AppControllerListener(SendspinBridge *bridge) : bridge_(bridge) {}

    void on_controller_state(const sendspin::ServerStateControllerObject& state) override {
        float norm = static_cast<float>(state.volume) / 100.0f;
        if (norm > 0.005f) {
            [AudioEngine sharedInstance].volume = norm;
        }
        [AudioEngine sharedInstance].isMuted = state.muted;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (norm > 0.005f) {
                bridge_.currentVolume = norm;
            }
            bridge_.currentMuted = state.muted;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinVolumeUpdated:muted:)]) {
                [bridge_.delegate sendspinVolumeUpdated:bridge_.currentVolume muted:state.muted];
            }
        });
    }

    void on_controller_state_clear() override {
        NSLog(@"[SendspinBridge] Controller state clear");
    }

private:
    __weak SendspinBridge *bridge_;
};

class AppMetadataListener : public sendspin::MetadataRoleListener {
public:
    AppMetadataListener(SendspinBridge *bridge) : bridge_(bridge) {}

    void on_metadata(const sendspin::ServerMetadataStateObject& md) override {
        NSString *title = [NSString stringWithUTF8String:md.title.value_or("").c_str()];
        NSString *artist = [NSString stringWithUTF8String:md.artist.value_or("").c_str()];
        NSString *album = [NSString stringWithUTF8String:md.album.value_or("").c_str()];
        uint16_t track = md.track.value_or(0);
        uint32_t progress = md.progress ? md.progress->track_progress : 0;
        uint32_t duration = md.progress ? md.progress->track_duration : 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.currentTitle = title;
            bridge_.currentArtist = artist;
            bridge_.currentAlbum = album;
            bridge_.currentTrackNum = track;
            bridge_.currentProgressMs = progress;
            bridge_.currentDurationMs = duration;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinMetadataUpdatedTitle:artist:album:genre:trackNum:durationMs:progressMs:)]) {
                [bridge_.delegate sendspinMetadataUpdatedTitle:title 
                                                        artist:artist 
                                                         album:album 
                                                         genre:bridge_.currentGenre 
                                                      trackNum:track 
                                                    durationMs:duration 
                                                    progressMs:progress];
            }
            [bridge_ updateSystemNowPlayingInfo];
        });
    }

private:
    __weak SendspinBridge *bridge_;
};

class AppArtworkListener : public sendspin::ArtworkRoleListener {
public:
    AppArtworkListener(SendspinBridge *bridge) : bridge_(bridge) {}

    void on_image_decode(uint8_t slot, const uint8_t* data, size_t length, sendspin::SendspinImageFormat format) override {
        (void)slot;
        (void)format;
        if (!data || length == 0) return;

        NSData *nsData = [NSData dataWithBytes:data length:length];
        UIImage *image = [UIImage imageWithData:nsData];
        if (image) {
            decodedImage_ = image;
        }
    }

    void on_image_display(uint8_t slot, uint32_t lateness_ms) override {
        (void)slot;
        (void)lateness_ms;
        if (decodedImage_) {
            UIImage *img = decodedImage_;
            dispatch_async(dispatch_get_main_queue(), ^{
                bridge_.currentArtwork = img;
                if ([bridge_.delegate respondsToSelector:@selector(sendspinArtworkUpdated:)]) {
                    [bridge_.delegate sendspinArtworkUpdated:img];
                }
                [bridge_ updateSystemNowPlayingInfo];
            });
        }
    }

    void on_image_clear(uint8_t slot) override {
        (void)slot;
        decodedImage_ = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.currentArtwork = nil;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinArtworkUpdated:)]) {
                [bridge_.delegate sendspinArtworkUpdated:nil];
            }
            [bridge_ updateSystemNowPlayingInfo];
        });
    }

private:
    __weak SendspinBridge *bridge_;
    UIImage *decodedImage_{nil};
};

@implementation SendspinBridge {
    std::unique_ptr<AppNetworkProvider> _networkProvider;
    std::unique_ptr<AppClientListener> _clientListener;
    std::unique_ptr<AppPlayerListener> _playerListener;
    std::unique_ptr<AppControllerListener> _controllerListener;
    std::unique_ptr<AppMetadataListener> _metadataListener;
    std::unique_ptr<AppArtworkListener> _artworkListener;
}

+ (instancetype)sharedInstance {
    static SendspinBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SendspinBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectionState = SendspinConnectionStateDisconnected;
        _playbackState = SendspinPlaybackStateStopped;
        _currentVolume = 1.0f;
        _currentMuted = NO;
        _currentTitle = @"Ready";
        _currentArtist = @"Sendspin Player";
        _currentAlbum = @"";
        _currentGenre = @"";
        _currentTrackNum = 0;
        _shouldRun = false;
        _registerRef = nullptr;
        _playerRole = nullptr;
        _controllerRole = nullptr;
        _metadataRole = nullptr;
        _artworkRole = nullptr;
        _playerName = @"Sendspin Player";
        _listeningPort = 8928;
        _discoveredServersInternal = [NSMutableArray array];
        _promptedServers = [NSMutableSet set];
        
        // Load saved server from NSUserDefaults
        _savedServerHost = [[NSUserDefaults standardUserDefaults] stringForKey:@"SavedServerHost"];
        _savedServerPort = (uint16_t)[[NSUserDefaults standardUserDefaults] integerForKey:@"SavedServerPort"];
        _savedServerName = [[NSUserDefaults standardUserDefaults] stringForKey:@"SavedServerName"];
        if (![[NSUserDefaults standardUserDefaults] objectForKey:@"AutoConnectToSavedServer"]) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AutoConnectToSavedServer"];
        }
        _autoConnectToSavedServer = [[NSUserDefaults standardUserDefaults] boolForKey:@"AutoConnectToSavedServer"];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSArray<NSDictionary *> *)discoveredServers {
    return [_discoveredServersInternal copy];
}

- (void)startServiceWithName:(NSString *)name port:(uint16_t)port {
    [self stop];

    _playerName = (name && name.length > 0) ? [name copy] : @"Sendspin Player";
    _listeningPort = (port > 0) ? port : 8928;
    _shouldRun = true;

    self.connectionState = SendspinConnectionStateListening;
    if ([self.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
        [self.delegate sendspinConnectionStateChanged:self.connectionState 
                                              message:[NSString stringWithFormat:@"Listening on port %u (mDNS active)", _listeningPort]];
    }

    [self publishBonjourService];

    _workerThread = std::thread([self, nameStr = std::string([_playerName UTF8String]), portNum = _listeningPort]() {
        @autoreleasepool {
            sendspin::SendspinClientConfig config;
            config.client_id = "sendspin-ios-player";
            config.name = nameStr;
            config.product_name = "Sendspin iOS Player";
            config.manufacturer = "Sendspin";
            config.software_version = "1.0.0";
            config.server_port = portNum;

            self->_client = std::make_unique<sendspin::SendspinClient>(std::move(config));

            self->_networkProvider = std::make_unique<AppNetworkProvider>();
            self->_client->set_network_provider(self->_networkProvider.get());

            self->_clientListener = std::make_unique<AppClientListener>(self);
            self->_client->set_listener(self->_clientListener.get());

            sendspin::PlayerRoleConfig player_config;
            player_config.audio_formats = {
                {sendspin::SendspinCodecFormat::FLAC, 2, 44100, 16},
                {sendspin::SendspinCodecFormat::FLAC, 2, 48000, 16},
                {sendspin::SendspinCodecFormat::OPUS, 2, 48000, 16},
                {sendspin::SendspinCodecFormat::PCM, 2, 44100, 16},
                {sendspin::SendspinCodecFormat::PCM, 2, 48000, 16}
            };
            player_config.audio_buffer_capacity = 1048576;

            self->_playerRole = &self->_client->add_player(std::move(player_config));
            self->_playerListener = std::make_unique<AppPlayerListener>(self);
            self->_playerRole->set_listener(self->_playerListener.get());
            [[AudioEngine sharedInstance] setPlayerRole:self->_playerRole];

            self->_controllerRole = &self->_client->add_controller();
            self->_controllerListener = std::make_unique<AppControllerListener>(self);
            self->_controllerRole->set_listener(self->_controllerListener.get());

            self->_metadataRole = &self->_client->add_metadata();
            self->_metadataListener = std::make_unique<AppMetadataListener>(self);
            self->_metadataRole->set_listener(self->_metadataListener.get());

            sendspin::ArtworkRoleConfig artwork_config;
            artwork_config.preferred_formats = {
                {sendspin::SendspinImageSource::ALBUM, sendspin::SendspinImageFormat::JPEG, 300, 300},
                {sendspin::SendspinImageSource::ALBUM, sendspin::SendspinImageFormat::PNG, 300, 300}
            };
            self->_artworkRole = &self->_client->add_artwork(std::move(artwork_config));
            self->_artworkListener = std::make_unique<AppArtworkListener>(self);
            self->_artworkRole->set_listener(self->_artworkListener.get());

            if (!self->_client->start_server()) {
                NSLog(@"[SendspinBridge] Failed to start WebSocket server on port %u", portNum);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectionState = SendspinConnectionStateError;
                    if ([self.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
                        [self.delegate sendspinConnectionStateChanged:self.connectionState message:@"Port Bind Failed"];
                    }
                });
                return;
            }

            NSLog(@"[SendspinBridge] Sendspin WebSocket server running on port %u", portNum);

            while (self->_shouldRun) {
                self->_client->loop();
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
        }
    });

    // If we have a saved server and auto-connect is enabled, connect asynchronously
    if (_autoConnectToSavedServer && _savedServerHost.length > 0 && _savedServerPort > 0) {
        NSString *localIP = GetLocalWiFiIPAddress();
        if (!([_savedServerHost isEqualToString:localIP] || [_savedServerHost isEqualToString:@"127.0.0.1"])) {
            NSString *sHost = [_savedServerHost copy];
            uint16_t sPort = _savedServerPort;
            NSString *sName = [_savedServerName copy];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self connectToRemoteServer:sHost port:sPort name:sName remember:NO];
            });
        }
    }
}

- (void)connectToRemoteServer:(NSString *)host port:(uint16_t)port name:(NSString *)name remember:(BOOL)remember {
    NSString *localIP = GetLocalWiFiIPAddress();
    if (([host isEqualToString:localIP] || [host isEqualToString:@"127.0.0.1"]) && (port == _listeningPort || port == 0)) {
        NSLog(@"[SendspinBridge] Refusing to connect to self (%@:%u)", host, port);
        return;
    }

    if (!_client) {
        [self startServiceWithName:_playerName port:_listeningPort];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self connectToRemoteServer:host port:port name:name remember:remember];
        });
        return;
    }

    _connectedServerAddress = [NSString stringWithFormat:@"%@:%u", host, port];
    _connectedServerName = (name && name.length > 0) ? [name copy] : @"Music Assistant";
    
    if (remember) {
        _savedServerHost = [host copy];
        _savedServerPort = port;
        _savedServerName = [_connectedServerName copy];
        [[NSUserDefaults standardUserDefaults] setObject:_savedServerHost forKey:@"SavedServerHost"];
        [[NSUserDefaults standardUserDefaults] setInteger:_savedServerPort forKey:@"SavedServerPort"];
        [[NSUserDefaults standardUserDefaults] setObject:_savedServerName forKey:@"SavedServerName"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[SendspinBridge] Saved default server: %@ (%@:%u)", _savedServerName, _savedServerHost, _savedServerPort);
    }

    NSString *wsUrl = [NSString stringWithFormat:@"ws://%@:%u/sendspin", host, port > 0 ? port : 8927];
    NSLog(@"[SendspinBridge] Dialing remote server %@", wsUrl);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connectionState = SendspinConnectionStateConnecting;
        if ([self.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
            [self.delegate sendspinConnectionStateChanged:self.connectionState 
                                                  message:[NSString stringWithFormat:@"Connecting to %@...", host]];
        }
    });
    
    if (_client) {
        _client->connect_to([wsUrl UTF8String]);
    }
}

- (void)disconnect {
    _connectedServerAddress = nil;
    _connectedServerName = nil;
    if (_client) {
        _client->disconnect(sendspin::SendspinGoodbyeReason::USER_REQUEST);
    }
    self.connectionState = SendspinConnectionStateListening;
    if ([self.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
        [self.delegate sendspinConnectionStateChanged:self.connectionState message:@"Ready (mDNS Active)"];
    }
}

- (void)forgetSavedServer {
    _savedServerHost = nil;
    _savedServerPort = 0;
    _savedServerName = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SavedServerHost"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SavedServerPort"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SavedServerName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[SendspinBridge] Forgot saved server");
}

- (void)rescanBonjourServers {
    [_discoveredServersInternal removeAllObjects];
    [_promptedServers removeAllObjects];
    if (!_bonjourBrowser) {
        _bonjourBrowser = [[SendspinBonjourBrowser alloc] initWithBridge:self];
    }
    [_bonjourBrowser rescanWithSubnetProbe];
}

- (void)publishBonjourService {
    [self unpublishBonjourService];

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, nullptr);
    const char *pathStr = "/sendspin";
    TXTRecordSetValue(&txt, "path", (uint8_t)strlen(pathStr), pathStr);
    const char *nameStr = [_playerName UTF8String];
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(nameStr), nameStr);

    DNSServiceErrorType err = DNSServiceRegister(
        &_registerRef,
        0,
        0,
        [_playerName UTF8String],
        "_sendspin._tcp",
        nullptr,
        nullptr,
        htons(_listeningPort),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        nullptr,
        nullptr
    );

    TXTRecordDeallocate(&txt);

    if (err == kDNSServiceErr_NoError) {
        NSLog(@"[SendspinBridge] Advertising _sendspin._tcp on port %u (name: %@)", _listeningPort, _playerName);
    }
}

- (void)unpublishBonjourService {
    if (_registerRef != nullptr) {
        DNSServiceRefDeallocate(_registerRef);
        _registerRef = nullptr;
    }
}

- (void)startBonjourDiscovery {
    if (!_bonjourBrowser) {
        _bonjourBrowser = [[SendspinBonjourBrowser alloc] initWithBridge:self];
    }
    [_bonjourBrowser start];
}

- (void)stopBonjourDiscovery {
    if (_bonjourBrowser) {
        [_bonjourBrowser stop];
    }
}

- (void)handleDiscoveredServers:(NSArray<NSDictionary *> *)servers {
    _discoveredServersInternal = [servers mutableCopy];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"SendspinDiscoveredServersUpdated" object:nil];

    if ([self.delegate respondsToSelector:@selector(sendspinDiscoveredServersUpdated:)]) {
        [self.delegate sendspinDiscoveredServersUpdated:[_discoveredServersInternal copy]];
    }

    // Check if we should prompt or auto-connect
    if (servers.count > 0 && (self.connectionState == SendspinConnectionStateListening || self.connectionState == SendspinConnectionStateDisconnected)) {
        for (NSDictionary *srv in servers) {
            NSString *host = srv[@"host"];
            uint16_t port = [srv[@"port"] unsignedShortValue];
            NSString *key = [NSString stringWithFormat:@"%@:%u", host, port];

            // If it matches the saved server and auto-connect is on -> connect automatically
            if (_autoConnectToSavedServer && [_savedServerHost isEqualToString:host] && _savedServerPort == port) {
                NSLog(@"[SendspinBridge] Auto-connecting to saved server %@ (%@:%u)", srv[@"name"], host, port);
                [self connectToRemoteServer:host port:port name:srv[@"name"] remember:NO];
                break;
            }

            // Otherwise prompt user to connect if not prompted yet
            if (![_promptedServers containsObject:key]) {
                [_promptedServers addObject:key];
                if ([self.delegate respondsToSelector:@selector(sendspinPromptConnectToServer:)]) {
                    [self.delegate sendspinPromptConnectToServer:srv];
                }
                break;
            }
        }
    }
}

- (void)stop {
    _shouldRun = false;
    [self unpublishBonjourService];
    [self stopBonjourDiscovery];

    if (_workerThread.joinable()) {
        _workerThread.join();
    }
    _client.reset();
    _playerRole = nullptr;
    _controllerRole = nullptr;
    _metadataRole = nullptr;
    _artworkRole = nullptr;
    [[AudioEngine sharedInstance] setPlayerRole:nullptr];
    [[AudioEngine sharedInstance] stop];

    self.connectionState = SendspinConnectionStateDisconnected;
    if ([self.delegate respondsToSelector:@selector(sendspinConnectionStateChanged:message:)]) {
        [self.delegate sendspinConnectionStateChanged:self.connectionState message:@"Stopped"];
    }
}

#pragma mark - Transport Commands

- (void)togglePlayPause {
    if (self.playbackState == SendspinPlaybackStatePlaying) {
        [self pause];
    } else {
        [self play];
    }
}

- (void)play {
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::PLAY});
    }
}

- (void)pause {
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::PAUSE});
    }
}

- (void)nextTrack {
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::NEXT});
    }
}

- (void)previousTrack {
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::PREVIOUS});
    }
}

- (void)setVolume:(float)volume {
    _currentVolume = std::max(0.0f, std::min(1.0f, volume));
    [AudioEngine sharedInstance].volume = _currentVolume;
    uint8_t volByte = static_cast<uint8_t>(_currentVolume * 100.0f);

    if (_playerRole) {
        _playerRole->update_volume(volByte);
    }
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::VOLUME, .volume = volByte});
    }
}

- (void)seekToMs:(uint32_t)positionMs {
    if (_controllerRole) {
        _controllerRole->send_command({.command = sendspin::SendspinControllerCommand::SEEK, .position_ms = positionMs});
    }
}

- (void)adjustSyncDelayMs:(int16_t)deltaMs {
    int32_t currentDelay = [AudioEngine sharedInstance].pioneerDelayMs;
    int32_t newDelay = currentDelay + deltaMs;
    [AudioEngine sharedInstance].pioneerDelayMs = newDelay;
    NSLog(@"[SendspinBridge] Sync delay offset: %d ms", (int)newDelay);
}

- (void)updateSystemNowPlayingInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    if (self.currentTitle && self.currentTitle.length > 0) {
        info[MPMediaItemPropertyTitle] = self.currentTitle;
    } else {
        info[MPMediaItemPropertyTitle] = @"Sendspin Player";
    }

    if (self.currentArtist && self.currentArtist.length > 0) {
        info[MPMediaItemPropertyArtist] = self.currentArtist;
    }

    if (self.currentAlbum && self.currentAlbum.length > 0) {
        info[MPMediaItemPropertyAlbumTitle] = self.currentAlbum;
    }

    if (self.currentGenre && self.currentGenre.length > 0) {
        info[MPMediaItemPropertyGenre] = self.currentGenre;
    }

    if (self.currentTrackNum > 0) {
        info[MPMediaItemPropertyAlbumTrackNumber] = @(self.currentTrackNum);
    }

    if (self.currentDurationMs > 0) {
        double durationSec = (double)self.currentDurationMs / 1000.0;
        double progressSec = (double)self.currentProgressMs / 1000.0;
        info[MPMediaItemPropertyPlaybackDuration] = @(durationSec);
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(progressSec);
    }

    double rate = (self.playbackState == SendspinPlaybackStatePlaying) ? 1.0 : 0.0;
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(rate);

    if (self.currentArtwork) {
        if (NSClassFromString(@"MPMediaItemArtwork")) {
            MPMediaItemArtwork *art = [[MPMediaItemArtwork alloc] initWithImage:self.currentArtwork];
            info[MPMediaItemPropertyArtwork] = art;
        }
    }

    if (NSClassFromString(@"MPNowPlayingInfoCenter")) {
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:info];
    }
}

@end
