// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace vibestation {

struct RuntimeRunResult {
    std::uint64_t instruction_count = 0;
    std::uint64_t total_instruction_count = 0;
    std::uint64_t instruction_pointer = 0;
    std::uint64_t return_value = 0;
    std::uint64_t intercepted_imports = 0;
    std::uint64_t gpu_submissions = 0;
    std::uint64_t gpu_draws = 0;
    std::uint64_t gpu_flips = 0;
    std::uint64_t video_sequence = 0;
    std::uint64_t frame_hash = 0;
    std::uint64_t shader_cache_misses = 0;
    std::uint64_t texture_refreshes = 0;
    std::uint64_t event_queue_depth = 0;
    std::string last_import;
    bool terminal = false;
    std::string reason;
    std::vector<std::string> recent_instructions;
    std::vector<std::string> recent_imports;
    std::vector<std::string> observed_imports;
    std::vector<std::string> thread_diagnostics;

    [[nodiscard]] std::string json() const;
};

struct GuestVideoFrame {
    std::vector<std::uint8_t> bgra8888;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint64_t sequence = 0;
};

class GuestRuntime final {
public:
    explicit GuestRuntime(std::vector<std::uint8_t> executable, std::string content_root = {});
    ~GuestRuntime();

    GuestRuntime(const GuestRuntime&) = delete;
    GuestRuntime& operator=(const GuestRuntime&) = delete;

    [[nodiscard]] RuntimeRunResult run(std::uint64_t instruction_budget);
    void set_input(std::uint64_t buttons, float left_x, float left_y, float right_x, float right_y);
    [[nodiscard]] std::vector<std::uint8_t> drain_audio();
    [[nodiscard]] std::uint32_t audio_sample_rate() const;
    [[nodiscard]] GuestVideoFrame latest_video_frame(std::uint64_t after_sequence) const;
    [[nodiscard]] std::string dump_gpu_capture(const std::string& directory) const;
    [[nodiscard]] std::string description() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vibestation
