//
//  AudioEngine.mm
//  Sendspin Universal iOS Player
//

#import "AudioEngine.h"
#import <mach/mach_time.h>
#include "sendspin/player_role.h"
#include "sendspin/platform/time.h"
#include <vector>
#include <atomic>
#include <cstring>
#include <cmath>
#include <algorithm>

static mach_timebase_info_data_t s_timebase_info = {0, 0};

static inline uint64_t mach_to_microseconds(uint64_t mach_time) {
    if (__builtin_expect(s_timebase_info.denom == 0, 0)) {
        mach_timebase_info(&s_timebase_info);
    }
    return (mach_time * s_timebase_info.numer) / (s_timebase_info.denom * 1000ULL);
}

// True Lock-Free Single-Producer Single-Consumer (SPSC) Audio Ring Buffer
class LockFreeAudioRingBuffer {
public:
    LockFreeAudioRingBuffer(size_t capacity = 1048576) // 1MB buffer (power of 2)
        : buffer_(capacity), capacity_(capacity), mask_(capacity - 1), write_pos_(0), read_pos_(0) {}

    size_t write(const uint8_t* data, size_t length) {
        if (!data || length == 0) return 0;

        const size_t current_read = read_pos_.load(std::memory_order_acquire);
        const size_t current_write = write_pos_.load(std::memory_order_relaxed);

        const size_t available = capacity_ - (current_write - current_read);
        const size_t to_write = std::min(length, available);
        if (to_write == 0) return 0;

        const size_t write_idx = current_write & mask_;
        const size_t first_part = std::min(to_write, capacity_ - write_idx);
        std::memcpy(&buffer_[write_idx], data, first_part);
        const size_t second_part = to_write - first_part;
        if (second_part > 0) {
            std::memcpy(&buffer_[0], data + first_part, second_part);
        }

        write_pos_.store(current_write + to_write, std::memory_order_release);
        return to_write;
    }

    size_t read(uint8_t* out_data, size_t length) {
        if (!out_data || length == 0) return 0;

        const size_t current_write = write_pos_.load(std::memory_order_acquire);
        const size_t current_read = read_pos_.load(std::memory_order_relaxed);

        const size_t available = current_write - current_read;
        const size_t to_read = std::min(length, available);
        if (to_read == 0) return 0;

        const size_t read_idx = current_read & mask_;
        const size_t first_part = std::min(to_read, capacity_ - read_idx);
        std::memcpy(out_data, &buffer_[read_idx], first_part);
        const size_t second_part = to_read - first_part;
        if (second_part > 0) {
            std::memcpy(out_data + first_part, &buffer_[0], second_part);
        }

        read_pos_.store(current_read + to_read, std::memory_order_release);
        return to_read;
    }

    void clear() {
        read_pos_.store(write_pos_.load(std::memory_order_relaxed), std::memory_order_release);
    }

    size_t available_read() const {
        return write_pos_.load(std::memory_order_relaxed) - read_pos_.load(std::memory_order_relaxed);
    }

private:
    std::vector<uint8_t> buffer_;
    size_t capacity_;
    size_t mask_;
    alignas(64) std::atomic<size_t> write_pos_;
    alignas(64) std::atomic<size_t> read_pos_;
};

@interface AudioEngine () {
@public
    AudioComponentInstance _audioUnit;
    LockFreeAudioRingBuffer _ringBuffer;
    sendspin::PlayerRole *_playerRole;
    std::atomic<bool> _isRunning;
    std::atomic<float> _volume;
    std::atomic<bool> _muted;
    std::atomic<int32_t> _pioneerDelayMs;
    std::atomic<bool> _keepAliveEnabled;
    uint32_t _sampleRate;
    uint8_t _channels;
    uint8_t _bitDepth;
}
@end

static OSStatus CoreAudioRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    AudioEngine *engine = (__bridge AudioEngine *)inRefCon;
    if (!engine || !ioData || ioData->mNumberBuffers == 0) return noErr;

    int16_t *outBuffer = (int16_t *)ioData->mBuffers[0].mData;
    if (!outBuffer) return noErr;
    size_t bytesNeeded = inNumberFrames * 2 * sizeof(int16_t);

    static uint32_t s_renderCount = 0;
    if ((++s_renderCount % 200) == 1) {
        NSLog(@"[AudioEngine] RenderCallback firing: frames=%u, ringAvail=%zu, vol=%.2f, muted=%d",
              (unsigned int)inNumberFrames, engine->_ringBuffer.available_read(), engine.volume, engine.isMuted);
    }

    size_t bytesRead = engine->_ringBuffer.read((uint8_t *)outBuffer, bytesNeeded);
    if (bytesRead < bytesNeeded) {
        std::memset((uint8_t *)outBuffer + bytesRead, 0, bytesNeeded - bytesRead);
    }

    float vol = engine.volume;
    if (engine.isMuted || vol <= 0.001f) {
        std::memset(outBuffer, 0, bytesNeeded);
    } else if (std::abs(vol - 1.0f) > 0.005f) {
        size_t samples = bytesNeeded / sizeof(int16_t);
        for (size_t i = 0; i < samples; ++i) {
            int32_t sample = static_cast<int32_t>(outBuffer[i] * vol);
            outBuffer[i] = static_cast<int16_t>(std::max(-32768, std::min(32767, sample)));
        }
    }

    if (engine->_playerRole) {
        int64_t nowUs = sendspin::platform_time_us() + (static_cast<int64_t>(engine.pioneerDelayMs) * 1000LL);
        if (nowUs < 0) nowUs = 0;
        
        uint32_t framesRendered = static_cast<uint32_t>(bytesRead / (2 * sizeof(int16_t)));
        if (framesRendered > 0) {
            engine->_playerRole->notify_audio_played(framesRendered, nowUs);
        }
    }

    return noErr;
}

@implementation AudioEngine

+ (instancetype)sharedInstance {
    static AudioEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        mach_timebase_info(&s_timebase_info);
        _audioUnit = NULL;
        _playerRole = nullptr;
        _isRunning = false;
        _volume = 1.0f;
        _muted = false;
        _pioneerDelayMs = 0;
        _keepAliveEnabled = true;
        _sampleRate = 48000;
        _channels = 2;
        _bitDepth = 16;

        [self setupAudioSessionWithError:nil];
        [self initAudioUnit];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
}

- (BOOL)setupAudioSessionWithError:(NSError **)error {
    if (NSClassFromString(@"AVAudioSession")) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        BOOL success = [session setCategory:AVAudioSessionCategoryPlayback error:error];
        if (!success) {
            NSLog(@"[AudioEngine] Failed to set AVAudioSessionCategoryPlayback: %@", error ? *error : nil);
            return NO;
        }

        if ([session respondsToSelector:@selector(setPreferredSampleRate:error:)]) {
            [session setPreferredSampleRate:48000.0 error:nil];
        }
        if ([session respondsToSelector:@selector(setPreferredIOBufferDuration:error:)]) {
            [session setPreferredIOBufferDuration:0.005 error:nil];
        }

        success = [session setActive:YES error:error];
        if (!success) {
            NSLog(@"[AudioEngine] Failed to activate AVAudioSession: %@", error ? *error : nil);
            return NO;
        }
        NSLog(@"[AudioEngine] AVAudioSession configured (Category: Playback, SampleRate: 48kHz)");
        return YES;
    } else {
        // Fallback for iOS 2.x / 3.x C-API AudioSession
        UInt32 category = kAudioSessionCategory_MediaPlayback;
        AudioSessionInitialize(NULL, NULL, NULL, NULL);
        AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
        AudioSessionSetActive(true);
        NSLog(@"[AudioEngine] Legacy C AudioSession configured (Category: MediaPlayback)");
        return YES;
    }
}

- (BOOL)initAudioUnit {
    if (_audioUnit) {
        return YES;
    }

    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        NSLog(@"[AudioEngine] RemoteIO component not found!");
        return NO;
    }

    OSStatus status = AudioComponentInstanceNew(comp, &_audioUnit);
    if (status != noErr) {
        NSLog(@"[AudioEngine] AudioComponentInstanceNew failed: %d", (int)status);
        return NO;
    }

    UInt32 enableIO = 1;
    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        0,
        &enableIO,
        sizeof(enableIO));
    if (status != noErr) {
        NSLog(@"[AudioEngine] Failed to enable output: %d", (int)status);
        return NO;
    }

    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate = _sampleRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = _channels;
    audioFormat.mBitsPerChannel = _bitDepth;
    audioFormat.mBytesPerPacket = (_bitDepth / 8) * _channels;
    audioFormat.mBytesPerFrame = (_bitDepth / 8) * _channels;

    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0,
        &audioFormat,
        sizeof(audioFormat));
    if (status != noErr) {
        NSLog(@"[AudioEngine] Failed to set stream format: %d", (int)status);
        return NO;
    }

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = CoreAudioRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self;

    status = AudioUnitSetProperty(
        _audioUnit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callbackStruct,
        sizeof(callbackStruct));
    if (status != noErr) {
        NSLog(@"[AudioEngine] Failed to set render callback: %d", (int)status);
        return NO;
    }

    status = AudioUnitInitialize(_audioUnit);
    if (status != noErr) {
        NSLog(@"[AudioEngine] AudioUnitInitialize failed: %d", (int)status);
        return NO;
    }

    NSLog(@"[AudioEngine] RemoteIO AudioUnit initialized successfully (%u Hz, %d ch)", _sampleRate, _channels);
    return YES;
}

- (BOOL)start {
    if (_isRunning.load()) {
        return YES;
    }

    if (!_audioUnit) {
        if (![self initAudioUnit]) return NO;
    }

    OSStatus status = AudioOutputUnitStart(_audioUnit);
    if (status == noErr) {
        _isRunning = true;
        NSLog(@"[AudioEngine] AudioUnit output started");
        return YES;
    } else {
        NSLog(@"[AudioEngine] AudioOutputUnitStart failed: %d", (int)status);
        return NO;
    }
}

- (void)stop {
    if (!_isRunning.load()) return;

    if (_keepAliveEnabled.load()) {
        [self clearBuffer];
        return;
    }

    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }

    _isRunning = false;
    [self clearBuffer];
    NSLog(@"[AudioEngine] AudioUnit stopped");
}

- (void)configureSampleRate:(uint32_t)sampleRate channels:(uint8_t)channels bitDepth:(uint8_t)bitDepth {
    if (sampleRate == 0) sampleRate = 48000;
    if (channels == 0) channels = 2;
    if (bitDepth == 0) bitDepth = 16;

    if (_sampleRate == sampleRate && _channels == channels && _bitDepth == bitDepth && _audioUnit) {
        return;
    }

    NSLog(@"[AudioEngine] Reconfiguring Audio Unit -> %u Hz, %d ch, %d bit", sampleRate, channels, bitDepth);
    BOOL wasRunning = _isRunning.load();

    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }

    _sampleRate = sampleRate;
    _channels = channels;
    _bitDepth = bitDepth;

    [self initAudioUnit];

    if (wasRunning || _keepAliveEnabled.load()) {
        [self start];
    }
}

- (size_t)writeAudioData:(const uint8_t *)data length:(size_t)length {
    static uint32_t s_writeCount = 0;
    if ((++s_writeCount % 200) == 1) {
        NSLog(@"[AudioEngine] writeAudioData received %zu bytes (ringAvail=%zu)", length, _ringBuffer.available_read());
    }
    if (!_isRunning.load()) {
        [self start];
    }
    return _ringBuffer.write(data, length);
}

- (void)clearBuffer {
    _ringBuffer.clear();
}

#ifdef __cplusplus
- (void)setPlayerRole:(sendspin::PlayerRole *)playerRole {
    _playerRole = playerRole;
}
#endif

#pragma mark - Properties

- (BOOL)isRunning {
    return _isRunning.load();
}

- (float)volume {
    return _volume.load();
}

- (void)setVolume:(float)volume {
    _volume = std::max(0.0f, std::min(1.0f, volume));
}

- (BOOL)isMuted {
    return _muted.load();
}

- (void)setIsMuted:(BOOL)isMuted {
    _muted = isMuted;
}

- (int32_t)pioneerDelayMs {
    return _pioneerDelayMs.load();
}

- (void)setPioneerDelayMs:(int32_t)pioneerDelayMs {
    _pioneerDelayMs = pioneerDelayMs;
}

- (BOOL)keepAliveEnabled {
    return _keepAliveEnabled.load();
}

- (void)setKeepAliveEnabled:(BOOL)keepAliveEnabled {
    _keepAliveEnabled = keepAliveEnabled;
    if (keepAliveEnabled && !_isRunning.load()) {
        [self start];
    }
}

#pragma mark - Notifications

- (void)handleRouteChange:(NSNotification *)notification {
    NSString *outputName = @"Default Output";
    if (NSClassFromString(@"AVAudioSession")) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if ([session respondsToSelector:@selector(currentRoute)]) {
            AVAudioSessionRouteDescription *currentRoute = session.currentRoute;
            if (currentRoute.outputs.count > 0) {
                outputName = currentRoute.outputs[0].portName;
            }
        }
    }
    NSLog(@"[AudioEngine] Route changed -> Output: %@", outputName);

    if ([self.delegate respondsToSelector:@selector(audioEngineRouteChanged:)]) {
        [self.delegate audioEngineRouteChanged:outputName];
    }
}

@end
