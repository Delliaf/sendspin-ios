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

class NativeMdnsBrowser;

struct ResolveContext {
    NativeMdnsBrowser* browser{nullptr};
    ServiceKey key;
    std::string name;
    uint16_t port{0};
    std::string path;
};

class NativeMdnsBrowser {
public:
    NativeMdnsBrowser(SendspinBridge *bridge) : bridge_(bridge) {}

    ~NativeMdnsBrowser() {
        stop();
    }

    bool start() {
        stop();
        {
            std::lock_guard<std::mutex> lock(servers_mutex_);
            servers_.clear();
        }
        running_.store(true);

        DNSServiceErrorType err1 = DNSServiceBrowse(
            &browse_ref_sendspin_, 0, 0, "_sendspin._tcp", nullptr, browse_callback, this);
        if (err1 != kDNSServiceErr_NoError) {
            NSLog(@"[NativeMdnsBrowser] Failed to browse _sendspin._tcp: %d", err1);
        }

        DNSServiceErrorType err2 = DNSServiceBrowse(
            &browse_ref_ma_, 0, 0, "_music-assistant._tcp", nullptr, browse_callback, this);
        if (err2 != kDNSServiceErr_NoError) {
            NSLog(@"[NativeMdnsBrowser] Failed to browse _music-assistant._tcp: %d", err2);
        }

        thread_ = std::thread([this] { run_loop(); });
        NSLog(@"[NativeMdnsBrowser] DNS-SD browser active");
        return true;
    }

    void stop() {
        running_.store(false);
        if (thread_.joinable()) {
            thread_.join();
        }

        {
            std::lock_guard<std::mutex> lock(resolve_mutex_);
            for (auto& ref : pending_resolves_) {
                DNSServiceRefDeallocate(ref);
            }
            pending_resolves_.clear();
        }

        if (browse_ref_sendspin_ != nullptr) {
            DNSServiceRefDeallocate(browse_ref_sendspin_);
            browse_ref_sendspin_ = nullptr;
        }
        if (browse_ref_ma_ != nullptr) {
            DNSServiceRefDeallocate(browse_ref_ma_);
            browse_ref_ma_ = nullptr;
        }
    }

    std::vector<DiscoveredServerInfo> get_servers() const {
        std::lock_guard<std::mutex> lock(servers_mutex_);
        std::vector<DiscoveredServerInfo> result;
        result.reserve(servers_.size());
        for (const auto& kv : servers_) {
            result.push_back(kv.second);
        }
        return result;
    }

private:
    void add_resolve_ref(DNSServiceRef ref) {
        std::lock_guard<std::mutex> lock(resolve_mutex_);
        pending_resolves_.push_back(ref);
    }

    void remove_resolve_ref(DNSServiceRef ref) {
        std::lock_guard<std::mutex> lock(resolve_mutex_);
        pending_resolves_.erase(
            std::remove(pending_resolves_.begin(), pending_resolves_.end(), ref),
            pending_resolves_.end());
    }

    void run_loop() {
        while (running_.load()) {
            std::vector<DNSServiceRef> refs;
            if (browse_ref_sendspin_) refs.push_back(browse_ref_sendspin_);
            if (browse_ref_ma_) refs.push_back(browse_ref_ma_);
            {
                std::lock_guard<std::mutex> lock(resolve_mutex_);
                refs.insert(refs.end(), pending_resolves_.begin(), pending_resolves_.end());
            }

            if (refs.empty()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }

            fd_set read_fds;
            FD_ZERO(&read_fds);
            int max_fd = -1;

            for (auto ref : refs) {
                int fd = DNSServiceRefSockFD(ref);
                if (fd >= 0) {
                    FD_SET(fd, &read_fds);
                    if (fd > max_fd) max_fd = fd;
                }
            }

            if (max_fd < 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                continue;
            }

            struct timeval tv { 0, 100000 };
            int res = select(max_fd + 1, &read_fds, nullptr, nullptr, &tv);
            if (res > 0) {
                for (auto ref : refs) {
                    int fd = DNSServiceRefSockFD(ref);
                    if (fd >= 0 && FD_ISSET(fd, &read_fds)) {
                        DNSServiceProcessResult(ref);
                    }
                }
            }
        }
    }

    static void DNSSD_API browse_callback(DNSServiceRef /*ref*/, DNSServiceFlags flags,
                                           uint32_t interface_index, DNSServiceErrorType error,
                                           const char* name, const char* regtype,
                                           const char* domain, void* context) {
        if (error != kDNSServiceErr_NoError) return;
        auto* browser = static_cast<NativeMdnsBrowser*>(context);

        ServiceKey key{name ? name : "", regtype ? regtype : "", domain ? domain : ""};

        if (flags & kDNSServiceFlagsAdd) {
            auto* ctx = new ResolveContext{browser, key, name ? name : "", 0, ""};
            DNSServiceRef resolve_ref = nullptr;
            DNSServiceErrorType err = DNSServiceResolve(
                &resolve_ref, 0, interface_index, name, regtype, domain, resolve_callback, ctx);
            if (err == kDNSServiceErr_NoError) {
                browser->add_resolve_ref(resolve_ref);
            } else {
                delete ctx;
            }
        } else {
            std::lock_guard<std::mutex> lock(browser->servers_mutex_);
            browser->servers_.erase(key);
            browser->notify_bridge();
        }
    }

    static void DNSSD_API resolve_callback(DNSServiceRef ref, DNSServiceFlags /*flags*/,
                                            uint32_t /*interface_index*/, DNSServiceErrorType error,
                                            const char* /*fullname*/, const char* hosttarget,
                                            uint16_t port, uint16_t txt_len,
                                            const unsigned char* txt_record, void* context) {
        auto* ctx = static_cast<ResolveContext*>(context);

        if (error != kDNSServiceErr_NoError || !hosttarget) {
            ctx->browser->remove_resolve_ref(ref);
            DNSServiceRefDeallocate(ref);
            delete ctx;
            return;
        }

        ctx->port = ntohs(port);

        uint8_t path_len = 0;
        const void* path_val = TXTRecordGetValuePtr(txt_len, txt_record, "path", &path_len);
        if (path_val != nullptr && path_len > 0) {
            ctx->path = std::string(static_cast<const char*>(path_val), path_len);
        }

        ctx->browser->remove_resolve_ref(ref);
        DNSServiceRefDeallocate(ref);

        std::thread([ctx, host = std::string(hosttarget)]() {
            struct addrinfo hints {};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;

            struct addrinfo* res = nullptr;
            if (getaddrinfo(host.c_str(), nullptr, &hints, &res) == 0 && res != nullptr) {
                char addr_str[INET_ADDRSTRLEN] = {};
                const auto* addr_in = reinterpret_cast<const struct sockaddr_in*>(res->ai_addr);
                inet_ntop(AF_INET, &addr_in->sin_addr, addr_str, sizeof(addr_str));
                freeaddrinfo(res);

                if (addr_str[0] != '\0') {
                    DiscoveredServerInfo server;
                    server.name = ctx->name;
                    server.host = addr_str;
                    server.port = ctx->port;
                    server.path = ctx->path;

                    std::lock_guard<std::mutex> lock(ctx->browser->servers_mutex_);
                    ctx->browser->servers_[ctx->key] = std::move(server);
                    ctx->browser->notify_bridge();
                }
            } else if (res != nullptr) {
                freeaddrinfo(res);
            }
            delete ctx;
        }).detach();
    }

    void notify_bridge();

    __weak SendspinBridge *bridge_{nil};
    DNSServiceRef browse_ref_sendspin_{nullptr};
    DNSServiceRef browse_ref_ma_{nullptr};
    std::atomic<bool> running_{false};
    std::thread thread_;

    mutable std::mutex servers_mutex_;
    std::map<ServiceKey, DiscoveredServerInfo> servers_;

    std::mutex resolve_mutex_;
    std::vector<DNSServiceRef> pending_resolves_;
};

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
    std::unique_ptr<NativeMdnsBrowser> _mdnsBrowser;
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

void NativeMdnsBrowser::notify_bridge() {
    if (!bridge_) return;

    auto list = get_servers();
    NSMutableArray<NSDictionary *> *nsList = [NSMutableArray array];
    NSString *localPlayerName = bridge_.playerName;
    uint16_t localPort = bridge_.listeningPort;

    for (const auto& s : list) {
        NSString *sName = [NSString stringWithUTF8String:s.name.c_str()];
        NSString *sHost = [NSString stringWithUTF8String:s.host.c_str()];

        if (s.port == localPort && [sName isEqualToString:localPlayerName]) {
            continue;
        }

        [nsList addObject:@{
            @"name": sName ?: @"Music Assistant",
            @"host": sHost ?: @"",
            @"port": @(s.port),
            @"path": [NSString stringWithUTF8String:s.path.c_str()] ?: @"/sendspin"
        }];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [bridge_ handleDiscoveredServers:nsList];
    });
}

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
        if (norm > 0.0f || bridge_.currentMuted) {
            [AudioEngine sharedInstance].volume = norm;
            dispatch_async(dispatch_get_main_queue(), ^{
                bridge_.currentVolume = norm;
                if ([bridge_.delegate respondsToSelector:@selector(sendspinVolumeUpdated:muted:)]) {
                    [bridge_.delegate sendspinVolumeUpdated:norm muted:bridge_.currentMuted];
                }
            });
        }
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
        [AudioEngine sharedInstance].volume = norm;
        [AudioEngine sharedInstance].isMuted = state.muted;

        dispatch_async(dispatch_get_main_queue(), ^{
            bridge_.currentVolume = norm;
            bridge_.currentMuted = state.muted;
            if ([bridge_.delegate respondsToSelector:@selector(sendspinVolumeUpdated:muted:)]) {
                [bridge_.delegate sendspinVolumeUpdated:norm muted:state.muted];
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

    // If we have a saved server and auto-connect is enabled, connect immediately
    if (_autoConnectToSavedServer && _savedServerHost.length > 0 && _savedServerPort > 0) {
        NSLog(@"[SendspinBridge] Connecting to saved server %@:%u", _savedServerHost, _savedServerPort);
        [self connectToRemoteServer:_savedServerHost port:_savedServerPort name:_savedServerName remember:NO];
    }
}

- (void)connectToRemoteServer:(NSString *)host port:(uint16_t)port name:(NSString *)name remember:(BOOL)remember {
    if (!_client) {
        [self startServiceWithName:_playerName port:_listeningPort];
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
    [self startBonjourDiscovery];
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
    if (!_mdnsBrowser) {
        _mdnsBrowser = std::make_unique<NativeMdnsBrowser>(self);
    }
    _mdnsBrowser->start();
}

- (void)stopBonjourDiscovery {
    if (_mdnsBrowser) {
        _mdnsBrowser->stop();
    }
}

- (void)handleDiscoveredServers:(NSArray<NSDictionary *> *)servers {
    _discoveredServersInternal = [servers mutableCopy];

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

    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:info];
}

@end
