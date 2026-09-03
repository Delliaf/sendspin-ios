//
//  test_lockfree_ring_buffer.cpp
//  Comprehensive Unit & Stress Test for SPSC Lock-Free Audio Ring Buffer
//

#include <iostream>
#include <vector>
#include <thread>
#include <atomic>
#include <cstdint>
#include <cassert>
#include <chrono>
#include <cstring>
#include <algorithm>

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

int main() {
    std::cout << "=== Running Test 1: Basic Read/Write & Wrap-around ===" << std::endl;
    {
        LockFreeAudioRingBuffer rb(1024);
        std::vector<uint8_t> test_data(500);
        for (size_t i = 0; i < test_data.size(); ++i) test_data[i] = static_cast<uint8_t>(i & 0xFF);

        size_t written = rb.write(test_data.data(), test_data.size());
        assert(written == 500);
        assert(rb.available_read() == 500);

        std::vector<uint8_t> read_buf(500);
        size_t read_bytes = rb.read(read_buf.data(), read_buf.size());
        assert(read_bytes == 500);
        assert(read_buf == test_data);
        assert(rb.available_read() == 0);

        // Test wrap-around
        std::vector<uint8_t> wrap_data(800);
        for (size_t i = 0; i < wrap_data.size(); ++i) wrap_data[i] = static_cast<uint8_t>((i * 3) & 0xFF);
        written = rb.write(wrap_data.data(), wrap_data.size());
        assert(written == 800);

        std::vector<uint8_t> wrap_read(800);
        read_bytes = rb.read(wrap_read.data(), wrap_read.size());
        assert(read_bytes == 800);
        assert(wrap_read == wrap_data);

        std::cout << " [PASS] Basic Read/Write & Wrap-around OK" << std::endl;
    }

    std::cout << "=== Running Test 2: Concurrent Multi-Threaded Stress (10,000,000 Samples) ===" << std::endl;
    {
        LockFreeAudioRingBuffer rb(65536);
        const size_t TOTAL_SAMPLES = 10000000;
        std::atomic<bool> producer_done{false};

        // Producer Thread (Simulating FLAC / Opus decoding & WebSocket reception)
        std::thread producer([&]() {
            std::vector<uint8_t> chunk(512);
            size_t written_total = 0;
            while (written_total < TOTAL_SAMPLES) {
                size_t to_send = std::min(chunk.size(), TOTAL_SAMPLES - written_total);
                for (size_t i = 0; i < to_send; ++i) {
                    chunk[i] = static_cast<uint8_t>((written_total + i) & 0xFF);
                }

                size_t n = rb.write(chunk.data(), to_send);
                written_total += n;
                if (n == 0) {
                    std::this_thread::yield();
                }
            }
            producer_done.store(true, std::memory_order_release);
        });

        // Consumer Thread (Simulating CoreAudio Render Callback)
        size_t read_total = 0;
        bool error = false;
        std::vector<uint8_t> out_chunk(512);

        while (!producer_done.load(std::memory_order_acquire) || rb.available_read() > 0) {
            size_t n = rb.read(out_chunk.data(), out_chunk.size());
            if (n > 0) {
                for (size_t i = 0; i < n; ++i) {
                    uint8_t expected = static_cast<uint8_t>((read_total + i) & 0xFF);
                    if (out_chunk[i] != expected) {
                        std::cerr << "Data mismatch at sample " << (read_total + i) 
                                  << ": expected " << (int)expected << " got " << (int)out_chunk[i] << std::endl;
                        error = true;
                        break;
                    }
                }
                read_total += n;
            } else {
                std::this_thread::yield();
            }
        }

        producer.join();
        assert(!error);
        assert(read_total == TOTAL_SAMPLES);
        std::cout << " [PASS] 10,000,000 samples processed lock-free with 0 errors!" << std::endl;
    }

    std::cout << "\n>>> ALL LOCK-FREE AUDIO TESTS PASSED! <<<" << std::endl;
    return 0;
}
