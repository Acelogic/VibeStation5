// Copyright (C) 2026 VibeStation5 contributors
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace vibestation {

struct GuestGpuDraw {
    std::uint64_t export_shader = 0;
    std::uint64_t pixel_shader = 0;
    std::uint64_t target_address = 0;
    std::uint32_t target_width = 0;
    std::uint32_t target_height = 0;
    std::uint32_t target_format = 0;
    std::uint32_t target_number_type = 0;
    std::uint32_t vertex_count = 0;
    std::uint32_t instance_count = 1;
    std::uint32_t primitive_type = 4;
    std::uint32_t blend_control = 0;
    std::uint32_t color_write_mask = 0xFU;
    float viewport_x = 0.0F;
    float viewport_y = 0.0F;
    float viewport_width = 0.0F;
    float viewport_height = 0.0F;
    bool has_viewport = false;
    std::array<std::uint32_t, 256> pixel_scalar_registers{};
    std::array<std::uint32_t, 256> export_scalar_registers{};
};

class VulkanGuestRenderer final {
public:
    using MemoryReader = std::function<std::vector<std::uint8_t>(std::uint64_t, std::size_t)>;
    using MemoryRevision = std::function<std::uint64_t(std::uint64_t, std::size_t)>;

    explicit VulkanGuestRenderer(std::string package_path);
    ~VulkanGuestRenderer();

    VulkanGuestRenderer(const VulkanGuestRenderer&) = delete;
    VulkanGuestRenderer& operator=(const VulkanGuestRenderer&) = delete;

    [[nodiscard]] bool available() const;
    [[nodiscard]] const std::string& status() const;
    [[nodiscard]] std::uint64_t shader_cache_misses() const;
    [[nodiscard]] std::uint64_t texture_refreshes() const;
    bool submit(
        const GuestGpuDraw& draw,
        const MemoryReader& read_memory,
        const MemoryRevision& memory_revision);
    bool present(
        std::uint64_t target_address,
        std::uint32_t maximum_width,
        std::uint32_t maximum_height,
        std::vector<std::uint8_t>& bgra,
        std::uint32_t& width,
        std::uint32_t& height);

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vibestation
