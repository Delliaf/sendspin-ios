//
//  test_audio_dsp_and_timing.cpp
//  Comprehensive Unit Tests for Audio DSP, Volume Scaling, Delay Offsets, and Timebase Calculations
//

#include <iostream>
#include <vector>
#include <cstdint>
#include <cassert>
#include <cmath>
#include <algorithm>
#include <chrono>

// Test DSP Volume Scaling & Clamping Function (exact mirror of AudioEngine.mm)
void apply_volume(int16_t* buffer, size_t num_samples, float volume, bool is_muted) {
    if (is_muted || volume <= 0.001f) {
        std::fill(buffer, buffer + num_samples, 0);
        return;
    }
    if (std::abs(volume - 1.0f) <= 0.005f) {
        return; // Unity gain (100%)
    }

    for (size_t i = 0; i < num_samples; ++i) {
        int32_t sample = static_cast<int32_t>(buffer[i] * volume);
        buffer[i] = static_cast<int16_t>(std::max(-32768, std::min(32767, sample)));
    }
}

// Test Delay Offset Math
int64_t compute_adjusted_playback_time(uint64_t host_us, int32_t delay_ms) {
    int64_t adjusted = static_cast<int64_t>(host_us) + (static_cast<int64_t>(delay_ms) * 1000LL);
    return adjusted < 0 ? 0 : adjusted;
}

// Test Time Formatter
std::string format_time_ms(uint32_t ms) {
    uint32_t total_sec = ms / 1000;
    uint32_t min = total_sec / 60;
    uint32_t sec = total_sec % 60;
    char buf[32];
    snprintf(buf, sizeof(buf), "%u:%02u", min, sec);
    return std::string(buf);
}

int main() {
    std::cout << "=== Running DSP & Volume Math Unit Tests ===" << std::endl;
    {
        // 1. Mute Test
        std::vector<int16_t> samples = { 1000, -1000, 32767, -32768, 0 };
        apply_volume(samples.data(), samples.size(), 1.0f, true);
        for (int16_t s : samples) assert(s == 0);
        std::cout << " [PASS] DSP Mute produces exact zero silence" << std::endl;

        // 2. Zero Volume Test
        samples = { 500, -500, 12000, -12000 };
        apply_volume(samples.data(), samples.size(), 0.0f, false);
        for (int16_t s : samples) assert(s == 0);
        std::cout << " [PASS] DSP Zero Volume produces exact zero silence" << std::endl;

        // 3. Unity Gain Test (100% volume)
        samples = { 100, -200, 30000, -30000 };
        std::vector<int16_t> orig = samples;
        apply_volume(samples.data(), samples.size(), 1.0f, false);
        assert(samples == orig);
        std::cout << " [PASS] DSP 100% Volume preserves bit-exact waveform" << std::endl;

        // 4. 50% Scaling Test
        samples = { 1000, -2000, 20000, -20000 };
        apply_volume(samples.data(), samples.size(), 0.5f, false);
        assert(samples[0] == 500);
        assert(samples[1] == -1000);
        assert(samples[2] == 10000);
        assert(samples[3] == -10000);
        std::cout << " [PASS] DSP 50% Volume scales linearly with zero distortion" << std::endl;

        // 5. Clamping & Anti-Overflow Test
        samples = { 30000, -30000 };
        apply_volume(samples.data(), samples.size(), 2.0f, false);
        assert(samples[0] == 32767);
        assert(samples[1] == -32768);
        std::cout << " [PASS] DSP Anti-Clipping clamping prevents 16-bit integer overflow" << std::endl;
    }

    std::cout << "=== Running Delay & Timebase Offset Unit Tests ===" << std::endl;
    {
        uint64_t base_us = 10000000ULL; // 10 seconds in microseconds

        // Positive delay (+25ms)
        assert(compute_adjusted_playback_time(base_us, 25) == 10025000LL);

        // Negative delay (-10ms)
        assert(compute_adjusted_playback_time(base_us, -10) == 9990000LL);

        // Zero delay
        assert(compute_adjusted_playback_time(base_us, 0) == 10000000LL);

        // Negative delay clamping (should never return negative timestamp)
        assert(compute_adjusted_playback_time(5000ULL, -100) == 0LL);

        std::cout << " [PASS] Delay offset microseconds math verified" << std::endl;
    }

    std::cout << "=== Running Time String Formatting Tests ===" << std::endl;
    {
        assert(format_time_ms(0) == "0:00");
        assert(format_time_ms(5000) == "0:05");
        assert(format_time_ms(65000) == "1:05");
        assert(format_time_ms(174000) == "2:54");
        assert(format_time_ms(3661000) == "61:01");
        std::cout << " [PASS] Time string formatting verified" << std::endl;
    }

    std::cout << "\n>>> ALL AUDIO DSP & TIMING UNIT TESTS PASSED (100%) <<<" << std::endl;
    return 0;
}
