// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <jni.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr std::uint32_t kElfMagic = 0x7F454C46U;
constexpr std::uint32_t kPs4SelfMagic = 0x4F153D1DU;
constexpr std::uint32_t kPs5SelfMagic = 0x5414F5EEU;
constexpr std::size_t kElfHeaderSize = 64;
constexpr std::size_t kProgramHeaderSize = 56;
constexpr std::size_t kSelfHeaderSize = 32;
constexpr std::size_t kSelfSegmentSize = 32;
constexpr std::uint16_t kAmd64Machine = 0x3E;
constexpr std::uint32_t kLoadSegment = 1;
constexpr std::size_t kMaximumTableEntries = 4096;

constexpr std::array<std::uint8_t, 12> kPs4Identifier = {
    0x4F, 0x15, 0x3D, 0x1D, 0x00, 0x01, 0x01, 0x12, 0x01, 0x01, 0x00, 0x00,
};
constexpr std::array<std::uint8_t, 12> kPs5Identifier = {
    0x54, 0x14, 0xF5, 0xEE, 0x10, 0x01, 0x01, 0x32, 0x01, 0x03, 0x00, 0x10,
};

struct Report {
    std::int64_t format = 0;
    std::uint64_t entry_point = 0;
    std::uint64_t program_header_count = 0;
    std::uint64_t loadable_segment_count = 0;
    std::uint64_t reserved_memory_bytes = 0;
    std::uint64_t encrypted_segment_count = 0;
    std::uint64_t compressed_segment_count = 0;
    std::uint64_t abi_version = 0;
};

class Reader {
public:
    explicit Reader(const std::vector<std::uint8_t>& bytes) : bytes_(bytes) {}

    void require_range(std::size_t offset, std::size_t count, const char* context) const {
        if (offset > bytes_.size() || count > bytes_.size() - offset) {
            throw std::invalid_argument(std::string(context) + " is truncated.");
        }
    }

    std::uint8_t u8(std::size_t offset) const {
        require_range(offset, 1, "Binary field");
        return bytes_[offset];
    }

    std::uint16_t u16le(std::size_t offset) const {
        require_range(offset, 2, "16-bit field");
        return static_cast<std::uint16_t>(bytes_[offset]) |
            static_cast<std::uint16_t>(bytes_[offset + 1] << 8U);
    }

    std::uint32_t u32le(std::size_t offset) const {
        require_range(offset, 4, "32-bit field");
        std::uint32_t value = 0;
        for (std::size_t index = 0; index < 4; ++index) {
            value |= static_cast<std::uint32_t>(bytes_[offset + index]) << (index * 8U);
        }
        return value;
    }

    std::uint32_t u32be(std::size_t offset) const {
        require_range(offset, 4, "32-bit field");
        std::uint32_t value = 0;
        for (std::size_t index = 0; index < 4; ++index) {
            value = (value << 8U) | bytes_[offset + index];
        }
        return value;
    }

    std::uint64_t u64le(std::size_t offset) const {
        require_range(offset, 8, "64-bit field");
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < 8; ++index) {
            value |= static_cast<std::uint64_t>(bytes_[offset + index]) << (index * 8U);
        }
        return value;
    }

    template <std::size_t Size>
    bool equals(std::size_t offset, const std::array<std::uint8_t, Size>& expected) const {
        require_range(offset, Size, "Identifier");
        return std::equal(expected.begin(), expected.end(), bytes_.begin() + static_cast<std::ptrdiff_t>(offset));
    }

private:
    const std::vector<std::uint8_t>& bytes_;
};

std::size_t checked_add(std::size_t left, std::size_t right, const char* context) {
    if (right > std::numeric_limits<std::size_t>::max() - left) {
        throw std::invalid_argument(std::string(context) + " overflowed.");
    }
    return left + right;
}

std::size_t checked_multiply(std::size_t left, std::size_t right, const char* context) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) {
        throw std::invalid_argument(std::string(context) + " overflowed.");
    }
    return left * right;
}

Report inspect(const std::vector<std::uint8_t>& data) {
    Reader reader(data);
    reader.require_range(0, 4, "Executable magic");
    const auto magic = reader.u32be(0);
    Report report;
    std::size_t elf_offset = 0;

    if (magic == kElfMagic) {
        report.format = 0;
    } else if (magic == kPs4SelfMagic || magic == kPs5SelfMagic) {
        const bool ps5 = magic == kPs5SelfMagic;
        reader.require_range(0, kSelfHeaderSize, "SELF header");
        if (!(ps5 ? reader.equals(0, kPs5Identifier) : reader.equals(0, kPs4Identifier))) {
            throw std::invalid_argument("The SELF header signature is not recognized.");
        }
        const auto segment_count = reader.u16le(24);
        const auto layout = reader.u16le(26);
        if (layout != (ps5 ? 0x52 : 0x22)) {
            throw std::invalid_argument("The SELF layout identifier is not recognized.");
        }
        if (segment_count > kMaximumTableEntries) {
            throw std::invalid_argument("The SELF segment table is unreasonably large.");
        }
        elf_offset = checked_add(
            kSelfHeaderSize,
            checked_multiply(segment_count, kSelfSegmentSize, "SELF segment table"),
            "SELF table offset"
        );
        reader.require_range(0, checked_add(elf_offset, kElfHeaderSize, "SELF tables"), "SELF tables");
        for (std::size_t index = 0; index < segment_count; ++index) {
            const auto type = reader.u64le(kSelfHeaderSize + index * kSelfSegmentSize);
            report.encrypted_segment_count += (type & 0x2U) != 0U ? 1U : 0U;
            report.compressed_segment_count += (type & 0x8U) != 0U ? 1U : 0U;
        }
        report.format = ps5 ? 2 : 1;
    } else {
        throw std::invalid_argument("The file is neither a decrypted ELF nor a recognized PS4/PS5 SELF image.");
    }

    reader.require_range(elf_offset, kElfHeaderSize, "ELF header");
    if (reader.u32be(elf_offset) != kElfMagic) {
        throw std::invalid_argument("The executable does not have an ELF signature.");
    }
    if (reader.u8(elf_offset + 4) != 2) {
        throw std::invalid_argument("Only 64-bit ELF images are supported.");
    }
    if (reader.u8(elf_offset + 5) != 1) {
        throw std::invalid_argument("Only little-endian ELF images are supported.");
    }
    if (reader.u16le(elf_offset + 18) != kAmd64Machine) {
        throw std::invalid_argument("The ELF image is not the PS4/PS5 x86-64 architecture.");
    }

    report.abi_version = reader.u8(elf_offset + 8);
    report.entry_point = reader.u64le(elf_offset + 24);
    const auto program_header_offset = reader.u64le(elf_offset + 32);
    const auto header_size = reader.u16le(elf_offset + 52);
    const auto entry_size = reader.u16le(elf_offset + 54);
    const auto entry_count = reader.u16le(elf_offset + 56);
    if (header_size < kElfHeaderSize) {
        throw std::invalid_argument("The ELF header size is invalid.");
    }
    if (entry_count > kMaximumTableEntries || (entry_count > 0 && entry_size < kProgramHeaderSize)) {
        throw std::invalid_argument("The ELF program-header table is invalid.");
    }
    if (program_header_offset > std::numeric_limits<std::size_t>::max()) {
        throw std::invalid_argument("The program-header offset cannot be represented on this host.");
    }
    const auto table_start = checked_add(elf_offset, static_cast<std::size_t>(program_header_offset), "Program-header table");
    report.program_header_count = entry_count;
    for (std::size_t index = 0; index < entry_count; ++index) {
        const auto offset = checked_add(table_start, checked_multiply(index, entry_size, "Program-header table"), "Program-header table");
        reader.require_range(offset, kProgramHeaderSize, "ELF program header");
        if (reader.u32le(offset) != kLoadSegment) continue;
        const auto file_size = reader.u64le(offset + 32);
        const auto memory_size = reader.u64le(offset + 40);
        if (file_size > memory_size) {
            throw std::invalid_argument("A loadable ELF segment is larger on disk than in memory.");
        }
        ++report.loadable_segment_count;
        report.reserved_memory_bytes =
            memory_size > std::numeric_limits<std::uint64_t>::max() - report.reserved_memory_bytes
                ? std::numeric_limits<std::uint64_t>::max()
                : report.reserved_memory_bytes + memory_size;
    }
    return report;
}

void throw_java(JNIEnv* environment, const char* class_name, const std::string& message) {
    if (jclass error_class = environment->FindClass(class_name); error_class != nullptr) {
        environment->ThrowNew(error_class, message.c_str());
    }
}

}  // namespace

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeInspect(
    JNIEnv* environment,
    jobject,
    jbyteArray input
) {
    if (input == nullptr) {
        throw_java(environment, "java/lang/IllegalArgumentException", "The executable data is null.");
        return nullptr;
    }
    const auto length = environment->GetArrayLength(input);
    std::vector<std::uint8_t> data(static_cast<std::size_t>(length));
    environment->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte*>(data.data()));
    if (environment->ExceptionCheck()) return nullptr;

    try {
        const auto report = inspect(data);
        const std::array<jlong, 8> values = {
            report.format,
            static_cast<jlong>(report.entry_point),
            static_cast<jlong>(report.program_header_count),
            static_cast<jlong>(report.loadable_segment_count),
            static_cast<jlong>(report.reserved_memory_bytes),
            static_cast<jlong>(report.encrypted_segment_count),
            static_cast<jlong>(report.compressed_segment_count),
            static_cast<jlong>(report.abi_version),
        };
        jlongArray result = environment->NewLongArray(values.size());
        if (result != nullptr) {
            environment->SetLongArrayRegion(result, 0, values.size(), values.data());
        }
        return result;
    } catch (const std::exception& error) {
        throw_java(environment, "java/lang/IllegalArgumentException", error.what());
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mcruz_vibestation5_core_NativeBridge_nativeBackendInfo(
    JNIEnv* environment,
    jobject
) {
    const long page_size = sysconf(_SC_PAGESIZE);
    bool executable_memory = false;
    if (page_size > 0) {
        void* memory = mmap(nullptr, static_cast<std::size_t>(page_size), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (memory != MAP_FAILED) {
            executable_memory = mprotect(memory, static_cast<std::size_t>(page_size), PROT_READ | PROT_EXEC) == 0;
            munmap(memory, static_cast<std::size_t>(page_size));
        }
    }

    std::ostringstream description;
#if defined(__aarch64__)
    description << "arm64-v8a";
#elif defined(__x86_64__)
    description << "x86_64";
#else
    description << "unknown-abi";
#endif
    description << ", page=" << page_size << ", executable-memory=" << (executable_memory ? "ready" : "blocked");
    return environment->NewStringUTF(description.str().c_str());
}
