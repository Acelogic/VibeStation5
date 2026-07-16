// Copyright (C) 2026 VibeStation5 contributors
// SPDX-License-Identifier: GPL-2.0-or-later

#include "gpu-vulkan.h"

#include <vulkan/vulkan.h>
#include <android/log.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <utility>

namespace vibestation {
namespace {

constexpr const char* kLogTag = "VibeStation5GPU";

void require(VkResult result, const char* operation) {
    if (result != VK_SUCCESS) {
        throw std::runtime_error(std::string(operation) + " failed with VkResult " + std::to_string(result));
    }
}

class PackageReader {
public:
    explicit PackageReader(const std::string& path) : stream_(path, std::ios::binary) {
        if (!stream_) throw std::runtime_error("GPU package is unavailable: " + path);
    }

    template <typename T>
    T value() {
        T output{};
        stream_.read(reinterpret_cast<char*>(&output), static_cast<std::streamsize>(sizeof(output)));
        if (!stream_) throw std::runtime_error("GPU package is truncated");
        return output;
    }

    std::vector<std::uint8_t> bytes() {
        const std::uint32_t size = value<std::uint32_t>();
        if (size > 512U * 1024U * 1024U) throw std::runtime_error("GPU package field is too large");
        std::vector<std::uint8_t> output(size);
        stream_.read(reinterpret_cast<char*>(output.data()), static_cast<std::streamsize>(output.size()));
        if (!stream_) throw std::runtime_error("GPU package byte field is truncated");
        return output;
    }

    std::array<char, 8> magic() {
        std::array<char, 8> output{};
        stream_.read(output.data(), static_cast<std::streamsize>(output.size()));
        if (!stream_) throw std::runtime_error("GPU package header is truncated");
        return output;
    }

private:
    std::ifstream stream_;
};

struct BufferPackage {
    std::uint64_t address = 0;
    std::vector<std::uint8_t> initial;
};

struct TexturePackage {
    std::uint64_t address = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t format = 0;
    std::uint32_t number_type = 0;
    std::uint32_t tile_mode = 0;
    std::uint32_t type = 0;
    std::uint32_t base_level = 0;
    std::uint32_t last_level = 0;
    std::uint32_t pitch = 0;
    std::uint32_t dst_select = 0;
    std::uint32_t mip_level = 0;
    bool storage = false;
    std::array<std::uint32_t, 4> sampler{};
    std::uint32_t descriptor_buffer_index = std::numeric_limits<std::uint32_t>::max();
    std::uint32_t descriptor_byte_offset = std::numeric_limits<std::uint32_t>::max();
    std::vector<std::uint8_t> pixels;
};

struct VertexPackage {
    std::uint32_t location = 0;
    std::uint32_t component_count = 0;
    std::uint32_t data_format = 0;
    std::uint32_t number_format = 0;
    std::uint64_t address = 0;
    std::uint32_t stride = 0;
    std::uint32_t offset = 0;
    std::vector<std::uint8_t> initial;
};

struct BufferAllocation {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize size = 0;
};

struct TextureResource {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    std::uint64_t fingerprint = 0;
    std::uint64_t guest_revision = std::numeric_limits<std::uint64_t>::max();
    std::uint64_t address = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t format = 0;
    std::uint32_t tile_mode = 0;
};

struct DrawPackage {
    std::uint64_t export_shader = 0;
    std::uint64_t pixel_shader = 0;
    std::vector<std::uint8_t> vertex_spirv;
    std::vector<std::uint8_t> pixel_spirv;
    std::vector<BufferPackage> buffers;
    std::vector<TexturePackage> textures;
    std::vector<VertexPackage> vertices;
    std::vector<TextureResource> texture_resources;
    std::vector<BufferAllocation> buffer_allocations;
    std::vector<BufferAllocation> vertex_allocations;
    VkDescriptorSetLayout descriptor_layout = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    std::uint64_t pipeline_key = std::numeric_limits<std::uint64_t>::max();
};

struct TargetResource {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
};

VkPrimitiveTopology primitive_topology(std::uint32_t type) {
    switch (type) {
        case 1: return VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
        case 2: return VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
        case 3: return VK_PRIMITIVE_TOPOLOGY_LINE_STRIP;
        case 5: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;
        case 6:
        case 0x11: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
        default: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    }
}

std::uint64_t byte_fingerprint(const std::vector<std::uint8_t>& bytes) {
    std::uint64_t hash = 1469598103934665603ULL;
    for (const std::uint8_t byte : bytes) {
        hash ^= byte;
        hash *= 1099511628211ULL;
    }
    return hash;
}

VkBlendFactor blend_factor(std::uint32_t factor) {
    switch (factor) {
        case 0: return VK_BLEND_FACTOR_ZERO;
        case 1: return VK_BLEND_FACTOR_ONE;
        case 2: return VK_BLEND_FACTOR_SRC_COLOR;
        case 3: return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR;
        case 4: return VK_BLEND_FACTOR_SRC_ALPHA;
        case 5: return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        case 6: return VK_BLEND_FACTOR_DST_ALPHA;
        case 7: return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
        case 8: return VK_BLEND_FACTOR_DST_COLOR;
        case 9: return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
        case 10: return VK_BLEND_FACTOR_SRC_ALPHA_SATURATE;
        case 13: return VK_BLEND_FACTOR_CONSTANT_COLOR;
        case 14: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR;
        case 15: return VK_BLEND_FACTOR_SRC1_COLOR;
        case 16: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR;
        case 17: return VK_BLEND_FACTOR_SRC1_ALPHA;
        case 18: return VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA;
        case 19: return VK_BLEND_FACTOR_CONSTANT_ALPHA;
        case 20: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA;
        default: return VK_BLEND_FACTOR_ONE;
    }
}

VkBlendOp blend_operation(std::uint32_t function) {
    switch (function) {
        case 1: return VK_BLEND_OP_SUBTRACT;
        case 2: return VK_BLEND_OP_MIN;
        case 3: return VK_BLEND_OP_MAX;
        case 4: return VK_BLEND_OP_REVERSE_SUBTRACT;
        default: return VK_BLEND_OP_ADD;
    }
}

VkFormat vertex_format(const VertexPackage& vertex) {
    if (vertex.data_format == 11 && vertex.number_format == 7) return VK_FORMAT_R32G32_SFLOAT;
    if (vertex.data_format == 14 && vertex.number_format == 7) return VK_FORMAT_R32G32B32A32_SFLOAT;
    if (vertex.data_format == 13 && vertex.number_format == 7) return VK_FORMAT_R32G32B32_SFLOAT;
    switch (vertex.component_count) {
        case 2: return VK_FORMAT_R32G32_SFLOAT;
        case 3: return VK_FORMAT_R32G32B32_SFLOAT;
        case 4: return VK_FORMAT_R32G32B32A32_SFLOAT;
        default: return VK_FORMAT_R32_SFLOAT;
    }
}

}  // namespace

class VulkanGuestRenderer::Impl {
public:
    explicit Impl(const std::string& package_path) {
        try {
            load_packages(package_path);
            initialize_vulkan();
            status_ = "Android Vulkan shader backend ready (" + std::to_string(packages_.size()) + " shader pairs)";
            available_ = true;
            __android_log_print(ANDROID_LOG_INFO, kLogTag, "%s", status_.c_str());
        } catch (const std::exception& error) {
            status_ = error.what();
            __android_log_print(ANDROID_LOG_ERROR, kLogTag, "%s", status_.c_str());
            destroy();
        }
    }

    ~Impl() { destroy(); }

    bool submit(
        const GuestGpuDraw& draw,
        const MemoryReader& read_memory,
        const MemoryRevision& memory_revision) {
        if (!available_) return false;
        try {
            DrawPackage* package = find_package(draw.export_shader, draw.pixel_shader);
            if (package == nullptr || draw.target_address == 0 || draw.target_width == 0 || draw.target_height == 0) {
                if (missed_draws_++ < 8) {
                    __android_log_print(
                        ANDROID_LOG_WARN, kLogTag,
                        "draw cache miss es=0x%llx ps=0x%llx target=0x%llx %ux%u",
                        static_cast<unsigned long long>(draw.export_shader),
                        static_cast<unsigned long long>(draw.pixel_shader),
                        static_cast<unsigned long long>(draw.target_address),
                        draw.target_width, draw.target_height);
                }
                return false;
            }
            if (draw.target_format != 10 || draw.target_number_type > 7) {
                status_ = "unsupported Android Vulkan target format " + std::to_string(draw.target_format);
                return false;
            }

            ensure_package_resources(*package, draw);
            TargetResource& target = ensure_target(draw);
            std::vector<std::vector<std::uint8_t>> global_bytes;
            std::vector<std::vector<std::uint8_t>> vertex_bytes;
            global_bytes.reserve(package->buffers.size());
            vertex_bytes.reserve(package->vertices.size());

            std::size_t scalar_buffer_index = 0;
            for (const BufferPackage& buffer : package->buffers) {
                std::vector<std::uint8_t> bytes;
                if (buffer.address != 0) {
                    bytes = read_memory(buffer.address, buffer.initial.size());
                } else {
                    bytes.resize(buffer.initial.size(), 0);
                    const auto& registers = scalar_buffer_index++ == 0
                        ? draw.pixel_scalar_registers
                        : draw.export_scalar_registers;
                    std::memcpy(
                        bytes.data(), registers.data(),
                        std::min(bytes.size(), registers.size() * sizeof(std::uint32_t)));
                }
                global_bytes.push_back(bytes);
            }
            for (const VertexPackage& vertex : package->vertices) {
                std::vector<std::uint8_t> bytes = vertex.address == 0
                    ? vertex.initial
                    : read_memory(vertex.address, vertex.initial.size());
                vertex_bytes.push_back(bytes);
            }

            refresh_textures(*package, global_bytes, read_memory, memory_revision);
            const std::uint64_t draw_fingerprint = fingerprint_draw(
                *package, draw, global_bytes, vertex_bytes);
            const bool deterministic_overwrite = ((draw.blend_control >> 30U) & 1U) == 0 &&
                (draw.color_write_mask & 0xFU) == 0xFU;
            const auto previous_fingerprint = target_fingerprints_.find(draw.target_address);
            const bool repeated = deterministic_overwrite &&
                previous_fingerprint != target_fingerprints_.end() &&
                previous_fingerprint->second == draw_fingerprint;
            if (repeated) {
                ++elided_draws_;
            } else {
                package->buffer_allocations.resize(global_bytes.size());
                for (std::size_t index = 0; index < global_bytes.size(); ++index) {
                    upload_host_buffer(
                        package->buffer_allocations[index], global_bytes[index],
                        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
                }
                package->vertex_allocations.resize(vertex_bytes.size());
                for (std::size_t index = 0; index < vertex_bytes.size(); ++index) {
                    upload_host_buffer(
                        package->vertex_allocations[index], vertex_bytes[index],
                        VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                }
                update_descriptors(*package, package->buffer_allocations);
                record_draw(*package, target, draw, package->vertex_allocations);
                target_fingerprints_[draw.target_address] = draw_fingerprint;
            }

            ++submitted_draws_;
            status_ = "Android Vulkan submitted " + std::to_string(submitted_draws_) + " translated guest draws";
            if (submitted_draws_ <= 8 || (submitted_draws_ % 64) == 0) {
                __android_log_print(
                    ANDROID_LOG_INFO, kLogTag,
                    "submitted=%llu elided=%llu es=0x%llx ps=0x%llx target=0x%llx count=%u prim=0x%x",
                    static_cast<unsigned long long>(submitted_draws_),
                    static_cast<unsigned long long>(elided_draws_),
                    static_cast<unsigned long long>(draw.export_shader),
                    static_cast<unsigned long long>(draw.pixel_shader),
                    static_cast<unsigned long long>(draw.target_address),
                    draw.vertex_count, draw.primitive_type);
            }
            return true;
        } catch (const std::exception& error) {
            status_ = error.what();
            if (submit_errors_++ < 16) __android_log_print(ANDROID_LOG_ERROR, kLogTag, "%s", status_.c_str());
            return false;
        }
    }

    bool present(
        std::uint64_t address,
        std::uint32_t maximum_width,
        std::uint32_t maximum_height,
        std::vector<std::uint8_t>& bgra,
        std::uint32_t& width,
        std::uint32_t& height) {
        if (!available_) return false;
        const auto found = targets_.find(address);
        if (found == targets_.end()) return false;
        try {
            TargetResource& target = found->second;
            const VkDeviceSize byte_count = static_cast<VkDeviceSize>(target.width) * target.height * 4ULL;
            BufferAllocation readback = create_empty_host_buffer(byte_count, VK_BUFFER_USAGE_TRANSFER_DST_BIT);

            begin_commands();
            image_barrier(
                target.image,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_ACCESS_TRANSFER_READ_BIT,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT);
            VkBufferImageCopy copy{};
            copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copy.imageSubresource.layerCount = 1;
            copy.imageExtent = {target.width, target.height, 1};
            vkCmdCopyImageToBuffer(
                command_buffer_, target.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                readback.buffer, 1, &copy);
            image_barrier(
                target.image,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                VK_ACCESS_TRANSFER_READ_BIT,
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
            end_submit_wait();

            void* mapped = nullptr;
            require(vkMapMemory(device_, readback.memory, 0, byte_count, 0, &mapped), "vkMapMemory(readback)");
            const auto* source = static_cast<const std::uint8_t*>(mapped);
            if (presented_frames_ < 8) {
                std::uint8_t minimum = 255;
                std::uint8_t maximum = 0;
                std::uint32_t sampled_nonzero = 0;
                const std::size_t source_size = static_cast<std::size_t>(byte_count);
                const std::size_t step = std::max<std::size_t>(source_size / 4096U, 1U);
                for (std::size_t offset = 0; offset < source_size; offset += step) {
                    minimum = std::min(minimum, source[offset]);
                    maximum = std::max(maximum, source[offset]);
                    if (source[offset] != 0) ++sampled_nonzero;
                }
                __android_log_print(
                    ANDROID_LOG_INFO, kLogTag,
                    "readback target=0x%llx sample_nonzero=%u min=%u max=%u first=%02x%02x%02x%02x",
                    static_cast<unsigned long long>(address), sampled_nonzero,
                    static_cast<unsigned int>(minimum), static_cast<unsigned int>(maximum),
                    source[0], source[1], source[2], source[3]);
            }
            const std::uint32_t scale = std::max<std::uint32_t>(1, std::max(
                (target.width + std::max(maximum_width, 1U) - 1U) / std::max(maximum_width, 1U),
                (target.height + std::max(maximum_height, 1U) - 1U) / std::max(maximum_height, 1U)));
            width = (target.width + scale - 1U) / scale;
            height = (target.height + scale - 1U) / scale;
            bgra.resize(static_cast<std::size_t>(width) * height * 4ULL);
            for (std::uint32_t y = 0; y < height; ++y) {
                const std::uint32_t source_y = std::min(y * scale, target.height - 1U);
                for (std::uint32_t x = 0; x < width; ++x) {
                    const std::uint32_t source_x = std::min(x * scale, target.width - 1U);
                    const std::size_t source_offset =
                        (static_cast<std::size_t>(source_y) * target.width + source_x) * 4ULL;
                    const std::size_t destination_offset =
                        (static_cast<std::size_t>(y) * width + x) * 4ULL;
                    bgra[destination_offset] = source[source_offset + 2];
                    bgra[destination_offset + 1] = source[source_offset + 1];
                    bgra[destination_offset + 2] = source[source_offset];
                    bgra[destination_offset + 3] = source[source_offset + 3];
                }
            }
            vkUnmapMemory(device_, readback.memory);
            destroy_buffer(readback);
            if (presented_frames_++ < 8) {
                __android_log_print(
                    ANDROID_LOG_INFO, kLogTag, "present target=0x%llx output=%ux%u",
                    static_cast<unsigned long long>(address), width, height);
            }
            return true;
        } catch (const std::exception& error) {
            status_ = error.what();
            __android_log_print(ANDROID_LOG_ERROR, kLogTag, "present: %s", status_.c_str());
            return false;
        }
    }

    [[nodiscard]] bool available() const { return available_; }
    [[nodiscard]] const std::string& status() const { return status_; }
    [[nodiscard]] std::uint64_t shader_cache_misses() const { return missed_draws_; }
    [[nodiscard]] std::uint64_t texture_refreshes() const { return texture_refreshes_; }

private:
    void load_packages(const std::string& path) {
        PackageReader reader(path);
        static constexpr std::array<char, 8> expected = {'V', 'S', '5', 'G', 'P', 'U', '1', '\0'};
        if (reader.magic() != expected) {
            throw std::runtime_error("unsupported VibeStation5 GPU package");
        }
        const std::uint32_t package_version = reader.value<std::uint32_t>();
        if (package_version != 1U && package_version != 2U) {
            throw std::runtime_error("unsupported VibeStation5 GPU package version");
        }
        const std::uint32_t package_count = reader.value<std::uint32_t>();
        if (package_count == 0 || package_count > 1024) throw std::runtime_error("invalid GPU package count");
        packages_.reserve(package_count);
        for (std::uint32_t package_index = 0; package_index < package_count; ++package_index) {
            DrawPackage package;
            package.export_shader = reader.value<std::uint64_t>();
            package.pixel_shader = reader.value<std::uint64_t>();
            package.vertex_spirv = reader.bytes();
            package.pixel_spirv = reader.bytes();
            const std::uint32_t buffer_count = reader.value<std::uint32_t>();
            package.buffers.reserve(buffer_count);
            for (std::uint32_t index = 0; index < buffer_count; ++index) {
                package.buffers.push_back({reader.value<std::uint64_t>(), reader.bytes()});
            }
            const std::uint32_t texture_count = reader.value<std::uint32_t>();
            package.textures.reserve(texture_count);
            for (std::uint32_t index = 0; index < texture_count; ++index) {
                TexturePackage texture;
                texture.address = reader.value<std::uint64_t>();
                texture.width = reader.value<std::uint32_t>();
                texture.height = reader.value<std::uint32_t>();
                texture.format = reader.value<std::uint32_t>();
                texture.number_type = reader.value<std::uint32_t>();
                texture.tile_mode = reader.value<std::uint32_t>();
                texture.type = reader.value<std::uint32_t>();
                texture.base_level = reader.value<std::uint32_t>();
                texture.last_level = reader.value<std::uint32_t>();
                texture.pitch = reader.value<std::uint32_t>();
                texture.dst_select = reader.value<std::uint32_t>();
                texture.mip_level = reader.value<std::uint32_t>();
                texture.storage = reader.value<std::uint32_t>() != 0;
                for (std::uint32_t& word : texture.sampler) word = reader.value<std::uint32_t>();
                if (package_version >= 2U) {
                    texture.descriptor_buffer_index = reader.value<std::uint32_t>();
                    texture.descriptor_byte_offset = reader.value<std::uint32_t>();
                }
                texture.pixels = reader.bytes();
                package.textures.push_back(std::move(texture));
            }
            const std::uint32_t vertex_count = reader.value<std::uint32_t>();
            package.vertices.reserve(vertex_count);
            for (std::uint32_t index = 0; index < vertex_count; ++index) {
                VertexPackage vertex;
                vertex.location = reader.value<std::uint32_t>();
                vertex.component_count = reader.value<std::uint32_t>();
                vertex.data_format = reader.value<std::uint32_t>();
                vertex.number_format = reader.value<std::uint32_t>();
                vertex.address = reader.value<std::uint64_t>();
                vertex.stride = reader.value<std::uint32_t>();
                vertex.offset = reader.value<std::uint32_t>();
                vertex.initial = reader.bytes();
                package.vertices.push_back(std::move(vertex));
            }
            packages_.push_back(std::move(package));
        }
    }

    void initialize_vulkan() {
        VkApplicationInfo application{};
        application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application.pApplicationName = "VibeStation5";
        application.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
        application.pEngineName = "VibeStation5 Gen5";
        application.engineVersion = VK_MAKE_VERSION(1, 0, 0);
        application.apiVersion = VK_API_VERSION_1_1;
        VkInstanceCreateInfo instance_info{};
        instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        instance_info.pApplicationInfo = &application;
        require(vkCreateInstance(&instance_info, nullptr, &instance_), "vkCreateInstance");

        std::uint32_t physical_count = 0;
        require(vkEnumeratePhysicalDevices(instance_, &physical_count, nullptr), "vkEnumeratePhysicalDevices(count)");
        if (physical_count == 0) throw std::runtime_error("Android device exposes no Vulkan GPU");
        std::vector<VkPhysicalDevice> physical_devices(physical_count);
        require(vkEnumeratePhysicalDevices(instance_, &physical_count, physical_devices.data()), "vkEnumeratePhysicalDevices");
        physical_device_ = physical_devices.front();
        vkGetPhysicalDeviceMemoryProperties(physical_device_, &memory_properties_);

        std::uint32_t queue_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_device_, &queue_count, nullptr);
        std::vector<VkQueueFamilyProperties> queues(queue_count);
        vkGetPhysicalDeviceQueueFamilyProperties(physical_device_, &queue_count, queues.data());
        bool found_queue = false;
        for (std::uint32_t index = 0; index < queue_count; ++index) {
            if ((queues[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                queue_family_ = index;
                found_queue = true;
                break;
            }
        }
        if (!found_queue) throw std::runtime_error("Android Vulkan GPU exposes no graphics queue");
        const float priority = 1.0F;
        VkDeviceQueueCreateInfo queue_info{};
        queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = queue_family_;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;
        VkDeviceCreateInfo device_info{};
        device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        require(vkCreateDevice(physical_device_, &device_info, nullptr, &device_), "vkCreateDevice");
        vkGetDeviceQueue(device_, queue_family_, 0, &queue_);

        VkCommandPoolCreateInfo pool_info{};
        pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool_info.queueFamilyIndex = queue_family_;
        require(vkCreateCommandPool(device_, &pool_info, nullptr, &command_pool_), "vkCreateCommandPool");
        VkCommandBufferAllocateInfo command_info{};
        command_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        command_info.commandPool = command_pool_;
        command_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        command_info.commandBufferCount = 1;
        require(vkAllocateCommandBuffers(device_, &command_info, &command_buffer_), "vkAllocateCommandBuffers");

        VkAttachmentDescription attachment{};
        attachment.format = VK_FORMAT_R8G8B8A8_UNORM;
        attachment.samples = VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        attachment.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkAttachmentReference color_reference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{};
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_reference;
        VkSubpassDependency dependency{};
        dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        VkRenderPassCreateInfo render_pass_info{};
        render_pass_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount = 1;
        render_pass_info.pAttachments = &attachment;
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;
        require(vkCreateRenderPass(device_, &render_pass_info, nullptr, &render_pass_), "vkCreateRenderPass");
    }

    std::uint32_t memory_type(std::uint32_t bits, VkMemoryPropertyFlags flags) const {
        for (std::uint32_t index = 0; index < memory_properties_.memoryTypeCount; ++index) {
            if ((bits & (1U << index)) != 0 &&
                (memory_properties_.memoryTypes[index].propertyFlags & flags) == flags) return index;
        }
        throw std::runtime_error("Android Vulkan memory type is unavailable");
    }

    BufferAllocation create_empty_host_buffer(VkDeviceSize size, VkBufferUsageFlags usage) {
        BufferAllocation output;
        output.size = std::max<VkDeviceSize>(size, 4);
        VkBufferCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = output.size;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        require(vkCreateBuffer(device_, &info, nullptr, &output.buffer), "vkCreateBuffer");
        VkMemoryRequirements requirements{};
        vkGetBufferMemoryRequirements(device_, output.buffer, &requirements);
        VkMemoryAllocateInfo allocation{};
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memory_type(
            requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        require(vkAllocateMemory(device_, &allocation, nullptr, &output.memory), "vkAllocateMemory(buffer)");
        require(vkBindBufferMemory(device_, output.buffer, output.memory, 0), "vkBindBufferMemory");
        return output;
    }

    BufferAllocation create_host_buffer(const std::vector<std::uint8_t>& bytes, VkBufferUsageFlags usage) {
        BufferAllocation output = create_empty_host_buffer(bytes.size(), usage);
        void* mapped = nullptr;
        require(vkMapMemory(device_, output.memory, 0, output.size, 0, &mapped), "vkMapMemory(buffer)");
        std::memset(mapped, 0, static_cast<std::size_t>(output.size));
        if (!bytes.empty()) std::memcpy(mapped, bytes.data(), bytes.size());
        vkUnmapMemory(device_, output.memory);
        return output;
    }

    void upload_host_buffer(
        BufferAllocation& buffer,
        const std::vector<std::uint8_t>& bytes,
        VkBufferUsageFlags usage) {
        const VkDeviceSize required_size = std::max<VkDeviceSize>(bytes.size(), 4);
        if (buffer.buffer == VK_NULL_HANDLE || buffer.size < required_size) {
            destroy_buffer(buffer);
            buffer = create_empty_host_buffer(required_size, usage);
        }
        void* mapped = nullptr;
        require(vkMapMemory(device_, buffer.memory, 0, buffer.size, 0, &mapped), "vkMapMemory(buffer upload)");
        std::memset(mapped, 0, static_cast<std::size_t>(buffer.size));
        if (!bytes.empty()) std::memcpy(mapped, bytes.data(), bytes.size());
        vkUnmapMemory(device_, buffer.memory);
    }

    void destroy_buffer(BufferAllocation& buffer) {
        if (buffer.buffer != VK_NULL_HANDLE) vkDestroyBuffer(device_, buffer.buffer, nullptr);
        if (buffer.memory != VK_NULL_HANDLE) vkFreeMemory(device_, buffer.memory, nullptr);
        buffer = {};
    }

    void create_image(
        std::uint32_t width,
        std::uint32_t height,
        VkImageUsageFlags usage,
        VkImage& image,
        VkDeviceMemory& memory) {
        VkImageCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        info.imageType = VK_IMAGE_TYPE_2D;
        info.format = VK_FORMAT_R8G8B8A8_UNORM;
        info.extent = {width, height, 1};
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.samples = VK_SAMPLE_COUNT_1_BIT;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        require(vkCreateImage(device_, &info, nullptr, &image), "vkCreateImage");
        VkMemoryRequirements requirements{};
        vkGetImageMemoryRequirements(device_, image, &requirements);
        VkMemoryAllocateInfo allocation{};
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memory_type(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        require(vkAllocateMemory(device_, &allocation, nullptr, &memory), "vkAllocateMemory(image)");
        require(vkBindImageMemory(device_, image, memory, 0), "vkBindImageMemory");
    }

    VkImageView create_view(VkImage image) {
        VkImageViewCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        info.image = image;
        info.viewType = VK_IMAGE_VIEW_TYPE_2D;
        info.format = VK_FORMAT_R8G8B8A8_UNORM;
        info.components = {
            VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY};
        info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        info.subresourceRange.levelCount = 1;
        info.subresourceRange.layerCount = 1;
        VkImageView view = VK_NULL_HANDLE;
        require(vkCreateImageView(device_, &info, nullptr, &view), "vkCreateImageView");
        return view;
    }

    void begin_commands() {
        require(vkResetCommandBuffer(command_buffer_, 0), "vkResetCommandBuffer");
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        require(vkBeginCommandBuffer(command_buffer_, &begin), "vkBeginCommandBuffer");
    }

    void end_submit_wait() {
        require(vkEndCommandBuffer(command_buffer_), "vkEndCommandBuffer");
        VkSubmitInfo submit{};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command_buffer_;
        require(vkQueueSubmit(queue_, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");
        require(vkQueueWaitIdle(queue_), "vkQueueWaitIdle");
    }

    void image_barrier(
        VkImage image,
        VkImageLayout old_layout,
        VkImageLayout new_layout,
        VkAccessFlags source_access,
        VkAccessFlags destination_access,
        VkPipelineStageFlags source_stage,
        VkPipelineStageFlags destination_stage) {
        VkImageMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = old_layout;
        barrier.newLayout = new_layout;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = source_access;
        barrier.dstAccessMask = destination_access;
        vkCmdPipelineBarrier(
            command_buffer_, source_stage, destination_stage, 0,
            0, nullptr, 0, nullptr, 1, &barrier);
    }

    TextureResource create_texture(const TexturePackage& texture) {
        if (texture.width == 0 || texture.height == 0 || texture.format != 56 || texture.storage) {
            throw std::runtime_error("unsupported sampled Dreaming Sarah texture descriptor");
        }
        const std::uint32_t source_width = texture.tile_mode == 0
            ? std::max(texture.pitch, texture.width)
            : texture.width;
        const VkDeviceSize expected = static_cast<VkDeviceSize>(source_width) * texture.height * 4ULL;
        if (texture.pixels.size() != expected) throw std::runtime_error("captured texture byte count is invalid");
        BufferAllocation staging = create_host_buffer(texture.pixels, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        TextureResource output;
        create_image(
            texture.width, texture.height,
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            output.image, output.memory);
        begin_commands();
        image_barrier(
            output.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkBufferImageCopy copy{};
        copy.bufferRowLength = source_width;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = {texture.width, texture.height, 1};
        vkCmdCopyBufferToImage(
            command_buffer_, staging.buffer, output.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        image_barrier(
            output.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        end_submit_wait();
        destroy_buffer(staging);
        output.view = create_view(output.image);
        VkSamplerCreateInfo sampler{};
        sampler.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler.magFilter = VK_FILTER_LINEAR;
        sampler.minFilter = VK_FILTER_LINEAR;
        sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.maxAnisotropy = 1.0F;
        sampler.minLod = 0.0F;
        sampler.maxLod = 0.0F;
        require(vkCreateSampler(device_, &sampler, nullptr, &output.sampler), "vkCreateSampler");
        output.fingerprint = byte_fingerprint(texture.pixels);
        output.address = texture.address;
        output.width = texture.width;
        output.height = texture.height;
        output.format = texture.format;
        output.tile_mode = texture.tile_mode;
        return output;
    }

    void upload_texture(
        TextureResource& resource,
        const TexturePackage& texture,
        const std::vector<std::uint8_t>& pixels) {
        const std::uint32_t source_width = texture.tile_mode == 0
            ? std::max(texture.pitch, texture.width)
            : texture.width;
        const VkDeviceSize expected = static_cast<VkDeviceSize>(source_width) * texture.height * 4ULL;
        if (pixels.size() != expected) throw std::runtime_error("live guest texture byte count is invalid");
        BufferAllocation staging = create_host_buffer(pixels, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        begin_commands();
        image_barrier(
            resource.image, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkBufferImageCopy copy{};
        copy.bufferRowLength = source_width;
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = {texture.width, texture.height, 1};
        vkCmdCopyBufferToImage(
            command_buffer_, staging.buffer, resource.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        image_barrier(
            resource.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
        end_submit_wait();
        destroy_buffer(staging);
    }

    static std::uint32_t buffer_word(const std::vector<std::uint8_t>& bytes, std::size_t offset) {
        if (offset + sizeof(std::uint32_t) > bytes.size()) {
            throw std::runtime_error("live texture descriptor is truncated");
        }
        return static_cast<std::uint32_t>(bytes[offset]) |
            static_cast<std::uint32_t>(bytes[offset + 1]) << 8U |
            static_cast<std::uint32_t>(bytes[offset + 2]) << 16U |
            static_cast<std::uint32_t>(bytes[offset + 3]) << 24U;
    }

    std::uint64_t fingerprint_draw(
        const DrawPackage& package,
        const GuestGpuDraw& draw,
        const std::vector<std::vector<std::uint8_t>>& global_bytes,
        const std::vector<std::vector<std::uint8_t>>& vertex_bytes) const {
        std::uint64_t hash = 1469598103934665603ULL;
        auto mix_byte = [&](std::uint8_t byte) {
            hash ^= byte;
            hash *= 1099511628211ULL;
        };
        auto mix_value = [&](std::uint64_t value) {
            for (std::uint32_t shift = 0; shift < 64U; shift += 8U) {
                mix_byte(static_cast<std::uint8_t>(value >> shift));
            }
        };
        mix_value(package.export_shader);
        mix_value(package.pixel_shader);
        mix_value(draw.vertex_count);
        mix_value(draw.instance_count);
        mix_value(draw.primitive_type);
        mix_value(draw.blend_control);
        mix_value(draw.color_write_mask);
        mix_value(std::bit_cast<std::uint32_t>(draw.viewport_x));
        mix_value(std::bit_cast<std::uint32_t>(draw.viewport_y));
        mix_value(std::bit_cast<std::uint32_t>(draw.viewport_width));
        mix_value(std::bit_cast<std::uint32_t>(draw.viewport_height));
        for (const auto& bytes : global_bytes) {
            for (const std::uint8_t byte : bytes) mix_byte(byte);
        }
        for (const auto& bytes : vertex_bytes) {
            for (const std::uint8_t byte : bytes) mix_byte(byte);
        }
        for (const TextureResource& texture : package.texture_resources) {
            mix_value(texture.address);
            mix_value(texture.fingerprint);
            mix_value(texture.width);
            mix_value(texture.height);
        }
        return hash;
    }

    TexturePackage resolve_live_texture(
        const TexturePackage& captured,
        const std::vector<std::vector<std::uint8_t>>& global_bytes) {
        if (captured.descriptor_buffer_index >= global_bytes.size() ||
            captured.descriptor_byte_offset == std::numeric_limits<std::uint32_t>::max()) {
            return captured;
        }
        const auto& source = global_bytes[captured.descriptor_buffer_index];
        std::array<std::uint32_t, 5> fields{};
        for (std::size_t index = 0; index < fields.size(); ++index) {
            fields[index] = buffer_word(source, captured.descriptor_byte_offset + index * sizeof(std::uint32_t));
        }
        const std::uint64_t combined = static_cast<std::uint64_t>(fields[1]) << 32U | fields[0];
        TexturePackage live = captured;
        live.address = static_cast<std::uint64_t>(static_cast<std::uint32_t>(combined & 0x3FFFFFFFFFULL)) << 8U;
        live.width = (((fields[1] >> 30U) & 3U) | ((fields[2] & 0xFFFU) << 2U)) + 1U;
        live.height = ((fields[2] >> 14U) & 0x3FFFU) + 1U;
        live.format = (fields[1] >> 20U) & 0x1FFU;
        live.number_type = (fields[1] >> 26U) & 0xFU;
        live.tile_mode = (fields[3] >> 20U) & 0x1FU;
        live.type = (fields[3] >> 28U) & 0xFU;
        live.base_level = (fields[3] >> 12U) & 0xFU;
        live.last_level = (fields[3] >> 16U) & 0xFU;
        live.dst_select = fields[3] & 0xFFFU;
        live.pitch = (((live.width - 1U) & 0x1FFFU) | (((fields[4] >> 13U) & 1U) << 13U)) + 1U;
        if (live.address == 0 || live.width > 16384U || live.height > 16384U) return captured;
        const std::uint32_t source_width = live.tile_mode == 0
            ? std::max(live.pitch, live.width)
            : live.width;
        const std::uint64_t byte_count = static_cast<std::uint64_t>(source_width) * live.height * 4ULL;
        if (byte_count == 0 || byte_count > 512ULL * 1024ULL * 1024ULL) return captured;
        live.pixels.resize(static_cast<std::size_t>(byte_count));
        return live;
    }

    void refresh_textures(
        DrawPackage& package,
        const std::vector<std::vector<std::uint8_t>>& global_bytes,
        const MemoryReader& read_memory,
        const MemoryRevision& memory_revision) {
        for (std::size_t index = 0; index < package.textures.size(); ++index) {
            TexturePackage texture = resolve_live_texture(package.textures[index], global_bytes);
            if (texture.address == 0) continue;
            TextureResource& resource = package.texture_resources[index];
            const std::uint64_t guest_revision = memory_revision(texture.address, texture.pixels.size());
            const bool descriptor_changed = resource.address != texture.address ||
                resource.width != texture.width || resource.height != texture.height ||
                resource.format != texture.format || resource.tile_mode != texture.tile_mode;
            if (!descriptor_changed && resource.guest_revision == guest_revision) continue;
            const std::vector<std::uint8_t> pixels = read_memory(texture.address, texture.pixels.size());
            const std::uint64_t fingerprint = byte_fingerprint(pixels);
            if (descriptor_changed) {
                texture.pixels = pixels;
                destroy_texture(resource);
                resource = create_texture(texture);
                resource.guest_revision = guest_revision;
            } else if (resource.fingerprint != fingerprint) {
                upload_texture(resource, texture, pixels);
                resource.fingerprint = fingerprint;
                resource.guest_revision = guest_revision;
            } else {
                resource.guest_revision = guest_revision;
                continue;
            }
            ++texture_refreshes_;
            if (texture_refreshes_ <= 8 || (texture_refreshes_ % 64) == 0) {
                __android_log_print(
                    ANDROID_LOG_INFO, kLogTag,
                    "texture refresh=%llu address=0x%llx %ux%u tile=%u",
                    static_cast<unsigned long long>(texture_refreshes_),
                    static_cast<unsigned long long>(texture.address),
                    texture.width, texture.height, texture.tile_mode);
            }
        }
    }

    TargetResource& ensure_target(const GuestGpuDraw& draw) {
        const auto existing = targets_.find(draw.target_address);
        if (existing != targets_.end()) {
            if (existing->second.width != draw.target_width || existing->second.height != draw.target_height) {
                throw std::runtime_error("guest render-target dimensions changed");
            }
            return existing->second;
        }
        TargetResource target;
        target.width = draw.target_width;
        target.height = draw.target_height;
        create_image(
            target.width, target.height,
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                VK_IMAGE_USAGE_SAMPLED_BIT,
            target.image, target.memory);
        target.view = create_view(target.image);
        VkFramebufferCreateInfo framebuffer{};
        framebuffer.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer.renderPass = render_pass_;
        framebuffer.attachmentCount = 1;
        framebuffer.pAttachments = &target.view;
        framebuffer.width = target.width;
        framebuffer.height = target.height;
        framebuffer.layers = 1;
        require(vkCreateFramebuffer(device_, &framebuffer, nullptr, &target.framebuffer), "vkCreateFramebuffer");
        begin_commands();
        image_barrier(
            target.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
        VkClearColorValue clear{};
        VkImageSubresourceRange range{};
        range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        range.levelCount = 1;
        range.layerCount = 1;
        vkCmdClearColorImage(command_buffer_, target.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);
        image_barrier(
            target.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
        end_submit_wait();
        return targets_.emplace(draw.target_address, target).first->second;
    }

    DrawPackage* find_package(std::uint64_t export_shader, std::uint64_t pixel_shader) {
        const auto found = std::find_if(packages_.begin(), packages_.end(), [&](const DrawPackage& package) {
            return package.export_shader == export_shader && package.pixel_shader == pixel_shader;
        });
        return found == packages_.end() ? nullptr : &*found;
    }

    VkShaderModule shader_module(const std::vector<std::uint8_t>& spirv) {
        if (spirv.empty() || (spirv.size() % sizeof(std::uint32_t)) != 0) {
            throw std::runtime_error("invalid cached SPIR-V shader");
        }
        std::vector<std::uint32_t> words(spirv.size() / sizeof(std::uint32_t));
        std::memcpy(words.data(), spirv.data(), spirv.size());
        VkShaderModuleCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = spirv.size();
        info.pCode = words.data();
        VkShaderModule module = VK_NULL_HANDLE;
        require(vkCreateShaderModule(device_, &info, nullptr, &module), "vkCreateShaderModule");
        return module;
    }

    void ensure_package_resources(DrawPackage& package, const GuestGpuDraw& draw) {
        if (package.descriptor_layout == VK_NULL_HANDLE) {
            std::vector<VkDescriptorSetLayoutBinding> bindings;
            VkDescriptorSetLayoutBinding buffers{};
            buffers.binding = 0;
            buffers.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            buffers.descriptorCount = static_cast<std::uint32_t>(package.buffers.size());
            buffers.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
            bindings.push_back(buffers);
            if (!package.textures.empty()) {
                VkDescriptorSetLayoutBinding textures{};
                textures.binding = 1;
                textures.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                textures.descriptorCount = static_cast<std::uint32_t>(package.textures.size());
                textures.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
                bindings.push_back(textures);
            }
            VkDescriptorSetLayoutCreateInfo layout{};
            layout.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layout.bindingCount = static_cast<std::uint32_t>(bindings.size());
            layout.pBindings = bindings.data();
            require(vkCreateDescriptorSetLayout(device_, &layout, nullptr, &package.descriptor_layout), "vkCreateDescriptorSetLayout");
            std::vector<VkDescriptorPoolSize> sizes;
            sizes.push_back({VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, static_cast<std::uint32_t>(package.buffers.size())});
            if (!package.textures.empty()) {
                sizes.push_back({
                    VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    static_cast<std::uint32_t>(package.textures.size())});
            }
            VkDescriptorPoolCreateInfo pool{};
            pool.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
            pool.maxSets = 1;
            pool.poolSizeCount = static_cast<std::uint32_t>(sizes.size());
            pool.pPoolSizes = sizes.data();
            require(vkCreateDescriptorPool(device_, &pool, nullptr, &package.descriptor_pool), "vkCreateDescriptorPool");
            VkDescriptorSetAllocateInfo allocation{};
            allocation.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            allocation.descriptorPool = package.descriptor_pool;
            allocation.descriptorSetCount = 1;
            allocation.pSetLayouts = &package.descriptor_layout;
            require(vkAllocateDescriptorSets(device_, &allocation, &package.descriptor_set), "vkAllocateDescriptorSets");
            VkPipelineLayoutCreateInfo pipeline_layout{};
            pipeline_layout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            pipeline_layout.setLayoutCount = 1;
            pipeline_layout.pSetLayouts = &package.descriptor_layout;
            require(vkCreatePipelineLayout(device_, &pipeline_layout, nullptr, &package.pipeline_layout), "vkCreatePipelineLayout");
            package.texture_resources.reserve(package.textures.size());
            for (const TexturePackage& texture : package.textures) {
                package.texture_resources.push_back(create_texture(texture));
            }
        }

        const std::uint64_t key = static_cast<std::uint64_t>(draw.primitive_type) |
            static_cast<std::uint64_t>(draw.blend_control) << 8U |
            static_cast<std::uint64_t>(draw.color_write_mask & 0xFU) << 40U;
        if (package.pipeline != VK_NULL_HANDLE && package.pipeline_key == key) return;
        if (package.pipeline != VK_NULL_HANDLE) {
            require(vkDeviceWaitIdle(device_), "vkDeviceWaitIdle(pipeline)");
            vkDestroyPipeline(device_, package.pipeline, nullptr);
            package.pipeline = VK_NULL_HANDLE;
        }

        VkShaderModule vertex = shader_module(package.vertex_spirv);
        VkShaderModule pixel = shader_module(package.pixel_spirv);
        try {
            std::array<VkPipelineShaderStageCreateInfo, 2> stages{};
            stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
            stages[0].module = vertex;
            stages[0].pName = "main";
            stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
            stages[1].module = pixel;
            stages[1].pName = "main";
            std::vector<VkVertexInputBindingDescription> vertex_bindings(package.vertices.size());
            std::vector<VkVertexInputAttributeDescription> vertex_attributes(package.vertices.size());
            for (std::size_t index = 0; index < package.vertices.size(); ++index) {
                const VertexPackage& input = package.vertices[index];
                vertex_bindings[index] = {
                    static_cast<std::uint32_t>(index),
                    input.stride == 0 ? std::max(input.component_count, 1U) * 4U : input.stride,
                    VK_VERTEX_INPUT_RATE_VERTEX};
                vertex_attributes[index] = {
                    input.location,
                    static_cast<std::uint32_t>(index),
                    vertex_format(input),
                    0};
            }
            VkPipelineVertexInputStateCreateInfo vertex_input{};
            vertex_input.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
            vertex_input.vertexBindingDescriptionCount = static_cast<std::uint32_t>(vertex_bindings.size());
            vertex_input.pVertexBindingDescriptions = vertex_bindings.data();
            vertex_input.vertexAttributeDescriptionCount = static_cast<std::uint32_t>(vertex_attributes.size());
            vertex_input.pVertexAttributeDescriptions = vertex_attributes.data();
            VkPipelineInputAssemblyStateCreateInfo assembly{};
            assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
            assembly.topology = primitive_topology(draw.primitive_type);
            VkPipelineViewportStateCreateInfo viewport{};
            viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
            viewport.viewportCount = 1;
            viewport.scissorCount = 1;
            VkPipelineRasterizationStateCreateInfo raster{};
            raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
            raster.polygonMode = VK_POLYGON_MODE_FILL;
            raster.cullMode = VK_CULL_MODE_NONE;
            raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
            raster.lineWidth = 1.0F;
            VkPipelineMultisampleStateCreateInfo multisample{};
            multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
            multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
            const std::uint32_t control = draw.blend_control;
            const bool separate_alpha = ((control >> 29U) & 1U) != 0;
            VkPipelineColorBlendAttachmentState attachment{};
            attachment.blendEnable = ((control >> 30U) & 1U) != 0 ? VK_TRUE : VK_FALSE;
            attachment.srcColorBlendFactor = blend_factor(control & 0x1FU);
            attachment.dstColorBlendFactor = blend_factor((control >> 8U) & 0x1FU);
            attachment.colorBlendOp = blend_operation((control >> 5U) & 7U);
            attachment.srcAlphaBlendFactor = separate_alpha
                ? blend_factor((control >> 16U) & 0x1FU)
                : attachment.srcColorBlendFactor;
            attachment.dstAlphaBlendFactor = separate_alpha
                ? blend_factor((control >> 24U) & 0x1FU)
                : attachment.dstColorBlendFactor;
            attachment.alphaBlendOp = separate_alpha
                ? blend_operation((control >> 21U) & 7U)
                : attachment.colorBlendOp;
            attachment.colorWriteMask = 0;
            if ((draw.color_write_mask & 1U) != 0) attachment.colorWriteMask |= VK_COLOR_COMPONENT_R_BIT;
            if ((draw.color_write_mask & 2U) != 0) attachment.colorWriteMask |= VK_COLOR_COMPONENT_G_BIT;
            if ((draw.color_write_mask & 4U) != 0) attachment.colorWriteMask |= VK_COLOR_COMPONENT_B_BIT;
            if ((draw.color_write_mask & 8U) != 0) attachment.colorWriteMask |= VK_COLOR_COMPONENT_A_BIT;
            VkPipelineColorBlendStateCreateInfo blend{};
            blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
            blend.attachmentCount = 1;
            blend.pAttachments = &attachment;
            std::array<VkDynamicState, 2> dynamics = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
            VkPipelineDynamicStateCreateInfo dynamic{};
            dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
            dynamic.dynamicStateCount = static_cast<std::uint32_t>(dynamics.size());
            dynamic.pDynamicStates = dynamics.data();
            VkGraphicsPipelineCreateInfo pipeline{};
            pipeline.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
            pipeline.stageCount = static_cast<std::uint32_t>(stages.size());
            pipeline.pStages = stages.data();
            pipeline.pVertexInputState = &vertex_input;
            pipeline.pInputAssemblyState = &assembly;
            pipeline.pViewportState = &viewport;
            pipeline.pRasterizationState = &raster;
            pipeline.pMultisampleState = &multisample;
            pipeline.pColorBlendState = &blend;
            pipeline.pDynamicState = &dynamic;
            pipeline.layout = package.pipeline_layout;
            pipeline.renderPass = render_pass_;
            pipeline.subpass = 0;
            require(vkCreateGraphicsPipelines(
                device_, VK_NULL_HANDLE, 1, &pipeline, nullptr, &package.pipeline), "vkCreateGraphicsPipelines");
            package.pipeline_key = key;
        } catch (...) {
            vkDestroyShaderModule(device_, pixel, nullptr);
            vkDestroyShaderModule(device_, vertex, nullptr);
            throw;
        }
        vkDestroyShaderModule(device_, pixel, nullptr);
        vkDestroyShaderModule(device_, vertex, nullptr);
    }

    void update_descriptors(DrawPackage& package, const std::vector<BufferAllocation>& buffers) {
        std::vector<VkDescriptorBufferInfo> buffer_infos(buffers.size());
        for (std::size_t index = 0; index < buffers.size(); ++index) {
            buffer_infos[index] = {buffers[index].buffer, 0, buffers[index].size};
        }
        std::vector<VkDescriptorImageInfo> image_infos(package.texture_resources.size());
        for (std::size_t index = 0; index < package.texture_resources.size(); ++index) {
            const TextureResource& texture = package.texture_resources[index];
            image_infos[index] = {texture.sampler, texture.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
        }
        std::vector<VkWriteDescriptorSet> writes;
        VkWriteDescriptorSet buffer_write{};
        buffer_write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        buffer_write.dstSet = package.descriptor_set;
        buffer_write.dstBinding = 0;
        buffer_write.descriptorCount = static_cast<std::uint32_t>(buffer_infos.size());
        buffer_write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        buffer_write.pBufferInfo = buffer_infos.data();
        writes.push_back(buffer_write);
        if (!image_infos.empty()) {
            VkWriteDescriptorSet image_write{};
            image_write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            image_write.dstSet = package.descriptor_set;
            image_write.dstBinding = 1;
            image_write.descriptorCount = static_cast<std::uint32_t>(image_infos.size());
            image_write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            image_write.pImageInfo = image_infos.data();
            writes.push_back(image_write);
        }
        vkUpdateDescriptorSets(device_, static_cast<std::uint32_t>(writes.size()), writes.data(), 0, nullptr);
    }

    void record_draw(
        DrawPackage& package,
        TargetResource& target,
        const GuestGpuDraw& draw,
        const std::vector<BufferAllocation>& vertices) {
        begin_commands();
        VkRenderPassBeginInfo render{};
        render.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render.renderPass = render_pass_;
        render.framebuffer = target.framebuffer;
        render.renderArea.extent = {target.width, target.height};
        vkCmdBeginRenderPass(command_buffer_, &render, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(command_buffer_, VK_PIPELINE_BIND_POINT_GRAPHICS, package.pipeline);
        vkCmdBindDescriptorSets(
            command_buffer_, VK_PIPELINE_BIND_POINT_GRAPHICS, package.pipeline_layout,
            0, 1, &package.descriptor_set, 0, nullptr);
        VkViewport viewport{};
        viewport.x = draw.has_viewport ? draw.viewport_x : 0.0F;
        viewport.y = draw.has_viewport ? draw.viewport_y : 0.0F;
        viewport.width = draw.has_viewport ? draw.viewport_width : static_cast<float>(target.width);
        viewport.height = draw.has_viewport ? draw.viewport_height : static_cast<float>(target.height);
        viewport.maxDepth = 1.0F;
        vkCmdSetViewport(command_buffer_, 0, 1, &viewport);
        VkRect2D scissor{{0, 0}, {target.width, target.height}};
        vkCmdSetScissor(command_buffer_, 0, 1, &scissor);
        if (!vertices.empty()) {
            std::vector<VkBuffer> buffers(vertices.size());
            std::vector<VkDeviceSize> offsets(vertices.size());
            for (std::size_t index = 0; index < vertices.size(); ++index) {
                buffers[index] = vertices[index].buffer;
                offsets[index] = package.vertices[index].offset < vertices[index].size
                    ? package.vertices[index].offset
                    : 0;
            }
            vkCmdBindVertexBuffers(
                command_buffer_, 0, static_cast<std::uint32_t>(buffers.size()), buffers.data(), offsets.data());
        }
        const std::uint32_t vertex_count = draw.primitive_type == 0x11 ? 4U : draw.vertex_count;
        vkCmdDraw(command_buffer_, vertex_count, std::max(draw.instance_count, 1U), 0, 0);
        vkCmdEndRenderPass(command_buffer_);
        end_submit_wait();
    }

    void destroy_texture(TextureResource& texture) {
        if (texture.sampler != VK_NULL_HANDLE) vkDestroySampler(device_, texture.sampler, nullptr);
        if (texture.view != VK_NULL_HANDLE) vkDestroyImageView(device_, texture.view, nullptr);
        if (texture.image != VK_NULL_HANDLE) vkDestroyImage(device_, texture.image, nullptr);
        if (texture.memory != VK_NULL_HANDLE) vkFreeMemory(device_, texture.memory, nullptr);
        texture = {};
    }

    void destroy() {
        if (device_ != VK_NULL_HANDLE) vkDeviceWaitIdle(device_);
        if (device_ != VK_NULL_HANDLE) {
            for (auto& [address, target] : targets_) {
                static_cast<void>(address);
                if (target.framebuffer != VK_NULL_HANDLE) vkDestroyFramebuffer(device_, target.framebuffer, nullptr);
                if (target.view != VK_NULL_HANDLE) vkDestroyImageView(device_, target.view, nullptr);
                if (target.image != VK_NULL_HANDLE) vkDestroyImage(device_, target.image, nullptr);
                if (target.memory != VK_NULL_HANDLE) vkFreeMemory(device_, target.memory, nullptr);
            }
            for (DrawPackage& package : packages_) {
                for (BufferAllocation& buffer : package.vertex_allocations) destroy_buffer(buffer);
                for (BufferAllocation& buffer : package.buffer_allocations) destroy_buffer(buffer);
                if (package.pipeline != VK_NULL_HANDLE) vkDestroyPipeline(device_, package.pipeline, nullptr);
                if (package.pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(device_, package.pipeline_layout, nullptr);
                if (package.descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(device_, package.descriptor_pool, nullptr);
                if (package.descriptor_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(device_, package.descriptor_layout, nullptr);
                for (TextureResource& texture : package.texture_resources) destroy_texture(texture);
            }
            if (render_pass_ != VK_NULL_HANDLE) vkDestroyRenderPass(device_, render_pass_, nullptr);
            if (command_pool_ != VK_NULL_HANDLE) vkDestroyCommandPool(device_, command_pool_, nullptr);
            vkDestroyDevice(device_, nullptr);
        }
        if (instance_ != VK_NULL_HANDLE) vkDestroyInstance(instance_, nullptr);
        device_ = VK_NULL_HANDLE;
        instance_ = VK_NULL_HANDLE;
        available_ = false;
    }

    std::vector<DrawPackage> packages_;
    std::unordered_map<std::uint64_t, TargetResource> targets_;
    std::unordered_map<std::uint64_t, std::uint64_t> target_fingerprints_;
    VkInstance instance_ = VK_NULL_HANDLE;
    VkPhysicalDevice physical_device_ = VK_NULL_HANDLE;
    VkPhysicalDeviceMemoryProperties memory_properties_{};
    VkDevice device_ = VK_NULL_HANDLE;
    VkQueue queue_ = VK_NULL_HANDLE;
    std::uint32_t queue_family_ = 0;
    VkCommandPool command_pool_ = VK_NULL_HANDLE;
    VkCommandBuffer command_buffer_ = VK_NULL_HANDLE;
    VkRenderPass render_pass_ = VK_NULL_HANDLE;
    std::uint64_t submitted_draws_ = 0;
    std::uint64_t missed_draws_ = 0;
    std::uint64_t texture_refreshes_ = 0;
    std::uint64_t elided_draws_ = 0;
    std::uint64_t submit_errors_ = 0;
    std::uint64_t presented_frames_ = 0;
    bool available_ = false;
    std::string status_ = "Android Vulkan shader backend unavailable";
};

VulkanGuestRenderer::VulkanGuestRenderer(std::string package_path)
    : impl_(std::make_unique<Impl>(std::move(package_path))) {}

VulkanGuestRenderer::~VulkanGuestRenderer() = default;

bool VulkanGuestRenderer::available() const { return impl_->available(); }
const std::string& VulkanGuestRenderer::status() const { return impl_->status(); }
std::uint64_t VulkanGuestRenderer::shader_cache_misses() const { return impl_->shader_cache_misses(); }
std::uint64_t VulkanGuestRenderer::texture_refreshes() const { return impl_->texture_refreshes(); }
bool VulkanGuestRenderer::submit(
    const GuestGpuDraw& draw,
    const MemoryReader& read_memory,
    const MemoryRevision& memory_revision) {
    return impl_->submit(draw, read_memory, memory_revision);
}
bool VulkanGuestRenderer::present(
    std::uint64_t target_address,
    std::uint32_t maximum_width,
    std::uint32_t maximum_height,
    std::vector<std::uint8_t>& bgra,
    std::uint32_t& width,
    std::uint32_t& height) {
    return impl_->present(target_address, maximum_width, maximum_height, bgra, width, height);
}

}  // namespace vibestation
