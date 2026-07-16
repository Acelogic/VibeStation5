// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "runtime-core.h"
#include "agc-register-defaults.h"
#include "gpu-vulkan.h"

#include <capstone/vibestation_capstone.h>
#include <android/log.h>

#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>

namespace vibestation {
namespace {

constexpr std::uint32_t kElfMagic = 0x7F454C46U;
constexpr std::uint32_t kPs4SelfMagic = 0x4F153D1DU;
constexpr std::uint32_t kPs5SelfMagic = 0x5414F5EEU;
constexpr std::uint64_t kPs4MainImageBase = 0x0000000000400000ULL;
constexpr std::uint64_t kPs5MainImageBase = 0x0000000800000000ULL;
constexpr std::uint64_t kStackBase = 0x00007FFF00000000ULL;
constexpr std::uint64_t kStackSize = 256ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t kHeapBase = 0x0000000A00000000ULL;
constexpr std::uint64_t kHeapSize = 2ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t kTlsBase = 0x0000000C00000000ULL;
constexpr std::uint64_t kTlsSize = 16ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t kReturnSentinel = 0xFFFFFFFFFFFFFFF0ULL;
constexpr std::uint64_t kImportedDataSize = 64ULL * 1024ULL * 1024ULL;
constexpr std::size_t kPageSize = 4096;
constexpr std::size_t kKernelEventSize = 0x20;
constexpr std::uint64_t kVideoOutFlipEventIdent = 0x6;
constexpr std::int16_t kKernelEventFilterVideoOut = -13;
constexpr std::uint64_t kOrbisErrorNotFound = 0x80020002ULL;
constexpr std::uint64_t kOrbisErrorInvalidArgument = 0x80020003ULL;
constexpr std::uint64_t kOrbisErrorTimedOut = 0x8002003CULL;
constexpr std::uint64_t kOrbisErrorMemoryFault = 0x80020101ULL;

std::string hexadecimal(std::uint64_t value) {
    std::ostringstream stream;
    stream << "0x" << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << value;
    return stream.str();
}

std::string json_escape(std::string_view input) {
    std::ostringstream stream;
    for (const unsigned char character : input) {
        switch (character) {
            case '\"': stream << "\\\""; break;
            case '\\': stream << "\\\\"; break;
            case '\b': stream << "\\b"; break;
            case '\f': stream << "\\f"; break;
            case '\n': stream << "\\n"; break;
            case '\r': stream << "\\r"; break;
            case '\t': stream << "\\t"; break;
            default:
                if (character < 0x20) {
                    stream << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                           << static_cast<unsigned int>(character) << std::dec;
                } else {
                    stream << static_cast<char>(character);
                }
        }
    }
    return stream.str();
}

class Reader {
public:
    explicit Reader(const std::vector<std::uint8_t>& bytes) : bytes_(bytes) {}

    void require(std::size_t offset, std::size_t count, std::string_view context) const {
        if (offset > bytes_.size() || count > bytes_.size() - offset) {
            throw std::invalid_argument(std::string(context) + " is truncated");
        }
    }

    std::uint8_t u8(std::size_t offset) const {
        require(offset, 1, "byte");
        return bytes_[offset];
    }

    std::uint16_t u16(std::size_t offset) const {
        require(offset, 2, "uint16");
        return static_cast<std::uint16_t>(bytes_[offset]) |
               static_cast<std::uint16_t>(bytes_[offset + 1]) << 8U;
    }

    std::uint32_t u32(std::size_t offset) const {
        require(offset, 4, "uint32");
        std::uint32_t value = 0;
        for (std::size_t index = 0; index < 4; ++index) {
            value |= static_cast<std::uint32_t>(bytes_[offset + index]) << (index * 8U);
        }
        return value;
    }

    std::uint32_t u32be(std::size_t offset) const {
        require(offset, 4, "big-endian uint32");
        return static_cast<std::uint32_t>(bytes_[offset]) << 24U |
               static_cast<std::uint32_t>(bytes_[offset + 1]) << 16U |
               static_cast<std::uint32_t>(bytes_[offset + 2]) << 8U |
               static_cast<std::uint32_t>(bytes_[offset + 3]);
    }

    std::uint64_t u64(std::size_t offset) const {
        require(offset, 8, "uint64");
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < 8; ++index) {
            value |= static_cast<std::uint64_t>(bytes_[offset + index]) << (index * 8U);
        }
        return value;
    }

private:
    const std::vector<std::uint8_t>& bytes_;
};

enum Protection : std::uint8_t {
    kRead = 1U << 0U,
    kWrite = 1U << 1U,
    kExecute = 1U << 2U,
    kGpuRead = 1U << 4U,
    kGpuWrite = 1U << 5U,
};

struct Region {
    std::uint64_t base = 0;
    std::uint64_t size = 0;
    std::uint8_t protection = 0;
    std::string label;

    [[nodiscard]] std::uint64_t end() const { return base + size; }
};

class SparseMemory {
public:
    void map(std::uint64_t base, std::uint64_t size, std::uint8_t protection, std::string label) {
        if (size == 0 || base > std::numeric_limits<std::uint64_t>::max() - size) {
            throw std::invalid_argument("invalid virtual-memory mapping for " + label);
        }
        const std::uint64_t end = base + size;
        for (const Region& region : regions_) {
            if (base < region.end() && end > region.base) {
                throw std::invalid_argument("overlapping virtual-memory mapping: " + label + " and " + region.label);
            }
        }
        regions_.push_back({base, size, protection, std::move(label)});
        std::sort(regions_.begin(), regions_.end(), [](const Region& lhs, const Region& rhs) {
            return lhs.base < rhs.base;
        });
    }

    [[nodiscard]] std::optional<Region> query(std::uint64_t address, bool find_next) const {
        for (const Region& region : regions_) {
            if (address >= region.base && address < region.end()) return region;
            if (find_next && region.base > address) return region;
        }
        return std::nullopt;
    }

    bool protect(std::uint64_t address, std::uint64_t size, std::uint8_t protection) {
        if (size == 0 || address > std::numeric_limits<std::uint64_t>::max() - size) return false;
        const std::uint64_t end = address + size;
        const auto found = std::find_if(regions_.begin(), regions_.end(), [&](const Region& region) {
            return address >= region.base && end <= region.end();
        });
        if (found == regions_.end()) return false;

        const Region original = *found;
        const auto position = regions_.erase(found);
        std::vector<Region> replacement;
        if (original.base < address) {
            replacement.push_back({original.base, address - original.base, original.protection, original.label});
        }
        replacement.push_back({address, size, protection, original.label});
        if (end < original.end()) {
            replacement.push_back({end, original.end() - end, original.protection, original.label});
        }
        regions_.insert(position, replacement.begin(), replacement.end());
        return true;
    }

    [[nodiscard]] std::vector<std::uint8_t> read(
        std::uint64_t address,
        std::size_t length,
        std::optional<std::uint8_t> required = kRead
    ) const {
        if (length == 0) return {};
        validate_access(address, length, required);
        std::vector<std::uint8_t> output(length, 0);
        std::size_t destination = 0;
        std::uint64_t cursor = address;
        while (destination < length) {
            const std::uint64_t page_base = cursor & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
            const std::size_t page_offset = static_cast<std::size_t>(cursor - page_base);
            const std::size_t count = std::min(length - destination, kPageSize - page_offset);
            if (const auto page = pages_.find(page_base); page != pages_.end()) {
                std::copy_n(page->second.begin() + static_cast<std::ptrdiff_t>(page_offset), count,
                            output.begin() + static_cast<std::ptrdiff_t>(destination));
            }
            destination += count;
            cursor += count;
        }
        return output;
    }

    [[nodiscard]] std::vector<std::uint8_t> fetch(std::uint64_t address, std::size_t length) const {
        return read(address, length, kExecute);
    }

    void write(
        std::uint64_t address,
        const std::uint8_t* bytes,
        std::size_t length,
        bool bypass_protection = false
    ) {
        if (length == 0) return;
        validate_access(address, length, bypass_protection ? std::nullopt : std::optional<std::uint8_t>(kWrite));
        std::size_t source = 0;
        std::uint64_t cursor = address;
        const std::uint64_t revision = next_revision_++;
        while (source < length) {
            const std::uint64_t page_base = cursor & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
            const std::size_t page_offset = static_cast<std::size_t>(cursor - page_base);
            const std::size_t count = std::min(length - source, kPageSize - page_offset);
            auto& page = pages_[page_base];
            std::copy_n(bytes + source, count, page.begin() + static_cast<std::ptrdiff_t>(page_offset));
            page_revisions_[page_base] = revision;
            source += count;
            cursor += count;
        }
    }

    void write(std::uint64_t address, const std::vector<std::uint8_t>& bytes, bool bypass = false) {
        write(address, bytes.data(), bytes.size(), bypass);
    }

    [[nodiscard]] std::uint64_t read_integer(std::uint64_t address, std::size_t size) const {
        if (size == 0 || size > 8) throw std::invalid_argument("unsupported integer width");
        validate_access(address, size, kRead);
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < size; ++index) {
            const std::uint64_t cursor = address + index;
            const std::uint64_t page_base = cursor & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
            if (const auto page = pages_.find(page_base); page != pages_.end()) {
                value |= static_cast<std::uint64_t>(page->second[static_cast<std::size_t>(cursor - page_base)]) << (index * 8U);
            }
        }
        return value;
    }

    void write_integer(std::uint64_t address, std::size_t size, std::uint64_t value, bool bypass = false) {
        if (size == 0 || size > 8) throw std::invalid_argument("unsupported integer width");
        validate_access(address, size, bypass ? std::nullopt : std::optional<std::uint8_t>(kWrite));
        const std::uint64_t revision = next_revision_++;
        for (std::size_t index = 0; index < size; ++index) {
            const std::uint64_t cursor = address + index;
            const std::uint64_t page_base = cursor & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
            pages_[page_base][static_cast<std::size_t>(cursor - page_base)] = static_cast<std::uint8_t>(value >> (index * 8U));
            page_revisions_[page_base] = revision;
        }
    }

    [[nodiscard]] std::uint64_t revision(std::uint64_t address, std::size_t length) const {
        if (length == 0) return 0;
        validate_access(address, length, std::nullopt);
        const std::uint64_t final_address = address + length - 1;
        std::uint64_t result = 0;
        for (std::uint64_t page = address & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
             page <= (final_address & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL));
             page += kPageSize) {
            if (const auto found = page_revisions_.find(page); found != page_revisions_.end()) {
                result = std::max(result, found->second);
            }
        }
        return result;
    }

    [[nodiscard]] std::size_t materialized_page_count() const { return pages_.size(); }

    void dump_materialized_pages(std::ostream& stream) const {
        static constexpr std::array<char, 8> magic = {'V', 'S', '5', 'M', 'E', 'M', '1', '\0'};
        stream.write(magic.data(), static_cast<std::streamsize>(magic.size()));
        const std::uint64_t page_size = kPageSize;
        const std::uint64_t page_count = pages_.size();
        stream.write(reinterpret_cast<const char*>(&page_size), sizeof(page_size));
        stream.write(reinterpret_cast<const char*>(&page_count), sizeof(page_count));
        std::vector<std::uint64_t> addresses;
        addresses.reserve(pages_.size());
        for (const auto& entry : pages_) addresses.push_back(entry.first);
        std::sort(addresses.begin(), addresses.end());
        for (const std::uint64_t address : addresses) {
            const auto& page = pages_.at(address);
            stream.write(reinterpret_cast<const char*>(&address), sizeof(address));
            stream.write(reinterpret_cast<const char*>(page.data()), static_cast<std::streamsize>(page.size()));
        }
        if (!stream) throw std::runtime_error("failed to write guest-memory capture");
    }

private:
    void validate_access(
        std::uint64_t address,
        std::size_t length,
        std::optional<std::uint8_t> required) const {
        if (address > std::numeric_limits<std::uint64_t>::max() - length) {
            throw std::invalid_argument("virtual-memory range overflow");
        }
        const std::uint64_t end = address + length;
        std::uint64_t cursor = address;
        while (cursor < end) {
            const auto found = std::find_if(regions_.begin(), regions_.end(), [&](const Region& region) {
                return cursor >= region.base && cursor < region.end();
            });
            if (found == regions_.end()) {
                throw std::invalid_argument("unmapped guest address " + hexadecimal(cursor));
            }
            if (required.has_value()) {
                bool allowed = (found->protection & *required) != 0;
                if (*required == kRead) {
                    allowed = (found->protection & (kRead | kExecute | kGpuRead)) != 0;
                } else if (*required == kWrite) {
                    allowed = (found->protection & (kWrite | kGpuWrite)) != 0;
                }
                if (!allowed) {
                    throw std::invalid_argument("memory protection fault at " + hexadecimal(cursor));
                }
            }
            cursor = std::min(end, found->end());
        }
    }

    [[nodiscard]] const Region& containing(std::uint64_t address, std::size_t length) const {
        if (address > std::numeric_limits<std::uint64_t>::max() - length) {
            throw std::invalid_argument("virtual-memory range overflow");
        }
        const std::uint64_t end = address + length;
        const auto found = std::find_if(regions_.begin(), regions_.end(), [&](const Region& region) {
            return address >= region.base && end <= region.end();
        });
        if (found == regions_.end()) {
            throw std::invalid_argument("unmapped guest address " + hexadecimal(address));
        }
        return *found;
    }

    std::vector<Region> regions_;
    std::unordered_map<std::uint64_t, std::array<std::uint8_t, kPageSize>> pages_;
    std::unordered_map<std::uint64_t, std::uint64_t> page_revisions_;
    std::uint64_t next_revision_ = 1;
};

struct ProgramHeader {
    std::uint32_t type = 0;
    std::uint32_t flags = 0;
    std::uint64_t offset = 0;
    std::uint64_t virtual_address = 0;
    std::uint64_t file_size = 0;
    std::uint64_t memory_size = 0;
};

struct SelfSegment {
    std::uint64_t type = 0;
    std::uint64_t offset = 0;
    std::uint64_t compressed_size = 0;
    std::uint64_t decompressed_size = 0;

    [[nodiscard]] bool blocked() const { return (type & 0x800ULL) != 0; }
    [[nodiscard]] std::uint64_t program_header_id() const { return (type >> 20U) & 0xFFFULL; }
    [[nodiscard]] bool encrypted() const { return (type & 0x2ULL) != 0; }
    [[nodiscard]] bool compressed() const { return (type & 0x8ULL) != 0; }
};

struct ExecutableImage {
    bool self = false;
    bool ps5_self = false;
    std::size_t elf_offset = 0;
    std::uint8_t abi_version = 0;
    std::uint64_t entry_point = 0;
    std::vector<ProgramHeader> program_headers;
    std::vector<SelfSegment> self_segments;
};

ExecutableImage parse_image(const std::vector<std::uint8_t>& bytes) {
    Reader reader(bytes);
    reader.require(0, 4, "executable magic");
    ExecutableImage image;
    const std::uint32_t magic = reader.u32be(0);
    if (magic == kElfMagic) {
        image.elf_offset = 0;
    } else if (magic == kPs4SelfMagic || magic == kPs5SelfMagic) {
        image.self = true;
        image.ps5_self = magic == kPs5SelfMagic;
        reader.require(0, 32, "SELF header");
        const std::uint16_t segment_count = reader.u16(24);
        const std::uint16_t layout = reader.u16(26);
        if (layout != (image.ps5_self ? 0x52U : 0x22U)) {
            throw std::invalid_argument("unrecognized SELF layout");
        }
        if (segment_count > 4096) throw std::invalid_argument("SELF segment count is unreasonable");
        image.elf_offset = 32U + static_cast<std::size_t>(segment_count) * 32U;
        reader.require(0, image.elf_offset + 64U, "SELF tables");
        for (std::size_t index = 0; index < segment_count; ++index) {
            const std::size_t offset = 32U + index * 32U;
            image.self_segments.push_back({
                reader.u64(offset),
                reader.u64(offset + 8U),
                reader.u64(offset + 16U),
                reader.u64(offset + 24U),
            });
        }
    } else {
        throw std::invalid_argument("file is neither an ELF nor a recognized SELF image");
    }

    const std::size_t elf = image.elf_offset;
    reader.require(elf, 64, "ELF header");
    if (reader.u32be(elf) != kElfMagic || reader.u8(elf + 4U) != 2 || reader.u8(elf + 5U) != 1) {
        throw std::invalid_argument("only little-endian ELF64 images are supported");
    }
    if (reader.u16(elf + 18U) != 0x3EU) throw std::invalid_argument("ELF image is not x86-64");
    image.abi_version = reader.u8(elf + 8U);
    image.entry_point = reader.u64(elf + 24U);
    const std::uint64_t table_offset = reader.u64(elf + 32U);
    const std::uint16_t entry_size = reader.u16(elf + 54U);
    const std::uint16_t entry_count = reader.u16(elf + 56U);
    if (entry_count > 4096 || (entry_count > 0 && entry_size < 56)) {
        throw std::invalid_argument("invalid ELF program-header table");
    }
    if (table_offset > std::numeric_limits<std::size_t>::max() - elf) {
        throw std::invalid_argument("ELF program-header offset overflow");
    }
    const std::size_t table = elf + static_cast<std::size_t>(table_offset);
    for (std::size_t index = 0; index < entry_count; ++index) {
        const std::size_t offset = table + index * entry_size;
        reader.require(offset, 56, "ELF program header");
        ProgramHeader header{
            reader.u32(offset),
            reader.u32(offset + 4U),
            reader.u64(offset + 8U),
            reader.u64(offset + 16U),
            reader.u64(offset + 32U),
            reader.u64(offset + 40U),
        };
        if (header.type == 1 && header.file_size > header.memory_size) {
            throw std::invalid_argument("ELF load segment is larger on disk than in memory");
        }
        image.program_headers.push_back(header);
    }
    return image;
}

std::uint64_t source_offset_for(
    const ExecutableImage& image,
    const ProgramHeader& header,
    std::size_t header_index
) {
    if (!image.self) return image.elf_offset + header.offset;
    const auto segment = std::find_if(image.self_segments.begin(), image.self_segments.end(), [&](const SelfSegment& item) {
        return item.blocked() && item.program_header_id() == header_index;
    });
    if (segment == image.self_segments.end()) return image.elf_offset + header.offset;
    if (segment->encrypted()) throw std::invalid_argument("SELF load segment is encrypted");
    if (segment->compressed()) throw std::invalid_argument("SELF load segment is compressed");
    return segment->offset;
}

std::uint64_t mask_for(std::size_t size) {
    if (size >= 8) return std::numeric_limits<std::uint64_t>::max();
    return (1ULL << (size * 8U)) - 1ULL;
}

std::uint64_t sign_extend(std::uint64_t value, std::size_t size) {
    if (size >= 8) return value;
    const unsigned bits = static_cast<unsigned>(size * 8U);
    const std::uint64_t sign = 1ULL << (bits - 1U);
    const std::uint64_t mask = (1ULL << bits) - 1ULL;
    value &= mask;
    return (value ^ sign) - sign;
}

template <typename T>
T scalar_at(const std::vector<std::uint8_t>& bytes, std::size_t offset = 0) {
    T value{};
    if (offset < bytes.size()) {
        std::memcpy(&value, bytes.data() + offset, std::min(sizeof(T), bytes.size() - offset));
    }
    return value;
}

template <typename T>
void put_scalar(std::vector<std::uint8_t>& bytes, std::size_t offset, T value) {
    if (offset + sizeof(T) > bytes.size()) throw std::out_of_range("SIMD scalar write exceeds destination");
    std::memcpy(bytes.data() + offset, &value, sizeof(T));
}

enum class OperandKind : std::uint8_t { Invalid, Register, Immediate, Memory };

struct RegisterReference {
    std::size_t index = 0;
    std::size_t width = 8;
    std::size_t shift = 0;
    bool zero_extend = false;
};

std::optional<RegisterReference> gpr_reference(std::string_view name);
std::optional<std::pair<std::size_t, std::size_t>> vector_reference(std::string_view name);

struct MemoryOperand {
    std::string segment;
    std::string base;
    std::string index;
    std::optional<RegisterReference> base_reference;
    std::optional<RegisterReference> index_reference;
    bool base_is_instruction_pointer = false;
    std::int32_t scale = 0;
    std::int64_t displacement = 0;
};

struct Operand {
    OperandKind kind = OperandKind::Invalid;
    std::size_t size = 0;
    std::string register_name;
    std::optional<RegisterReference> register_reference;
    std::optional<std::pair<std::size_t, std::size_t>> vector_register_reference;
    std::uint64_t immediate = 0;
    MemoryOperand memory;
};

struct Instruction {
    std::uint64_t address = 0;
    std::size_t size = 0;
    std::string mnemonic;
    std::string operand_text;
    std::vector<Operand> operands;

    [[nodiscard]] std::uint64_t next_address() const { return address + size; }
    [[nodiscard]] std::string text() const {
        return operand_text.empty() ? mnemonic : mnemonic + " " + operand_text;
    }
};

class Decoder {
public:
    Decoder() : decoder_(vs_decoder_create()) {
        if (decoder_ == nullptr) throw std::runtime_error("Capstone x86-64 decoder initialization failed");
    }
    ~Decoder() { vs_decoder_destroy(decoder_); }

    Instruction decode(const SparseMemory& memory, std::uint64_t address) const {
        const auto bytes = memory.fetch(address, 15);
        vs_instruction raw{};
        if (!vs_decode_one(decoder_, bytes.data(), bytes.size(), address, &raw)) {
            throw std::runtime_error(
                "x86-64 decode failed at " + hexadecimal(address) + ": " + vs_decoder_error(decoder_)
            );
        }
        Instruction instruction;
        instruction.address = raw.address;
        instruction.size = raw.size;
        instruction.mnemonic = vs_decoder_mnemonic(decoder_);
        instruction.operand_text = vs_decoder_operand_text(decoder_);
        for (std::size_t index = 0; index < raw.operand_count; ++index) {
            const vs_operand& source = raw.operands[index];
            Operand operand;
            operand.size = source.size;
            if (source.kind == VS_OPERAND_REGISTER) {
                operand.kind = OperandKind::Register;
                operand.register_name = vs_decoder_register_name(decoder_, source.register_id);
                operand.register_reference = gpr_reference(operand.register_name);
                operand.vector_register_reference = vector_reference(operand.register_name);
            } else if (source.kind == VS_OPERAND_IMMEDIATE) {
                operand.kind = OperandKind::Immediate;
                operand.immediate = source.immediate;
            } else if (source.kind == VS_OPERAND_MEMORY) {
                operand.kind = OperandKind::Memory;
                operand.memory.segment = vs_decoder_register_name(decoder_, source.memory.segment);
                operand.memory.base = vs_decoder_register_name(decoder_, source.memory.base);
                operand.memory.index = vs_decoder_register_name(decoder_, source.memory.index);
                operand.memory.base_reference = gpr_reference(operand.memory.base);
                operand.memory.index_reference = gpr_reference(operand.memory.index);
                operand.memory.base_is_instruction_pointer =
                    operand.memory.base == "rip" || operand.memory.base == "eip";
                operand.memory.scale = source.memory.scale;
                operand.memory.displacement = source.memory.displacement;
            }
            instruction.operands.push_back(std::move(operand));
        }
        return instruction;
    }

private:
    vs_decoder* decoder_;
};

std::optional<unsigned> decimal_suffix(std::string_view name, std::size_t prefix) {
    unsigned value = 0;
    const char* begin = name.data() + static_cast<std::ptrdiff_t>(prefix);
    const char* end = name.data() + static_cast<std::ptrdiff_t>(name.size());
    const auto parsed = std::from_chars(begin, end, value);
    if (parsed.ec != std::errc{} || parsed.ptr != end) return std::nullopt;
    return value;
}

std::optional<RegisterReference> gpr_reference(std::string_view name) {
    static constexpr std::array<std::string_view, 8> full = {"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp"};
    static constexpr std::array<std::string_view, 8> dword = {"eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp"};
    static constexpr std::array<std::string_view, 8> word = {"ax", "bx", "cx", "dx", "si", "di", "bp", "sp"};
    static constexpr std::array<std::string_view, 8> low = {"al", "bl", "cl", "dl", "sil", "dil", "bpl", "spl"};
    for (std::size_t index = 0; index < full.size(); ++index) {
        if (name == full[index]) return RegisterReference{index, 8, 0, false};
        if (name == dword[index]) return RegisterReference{index, 4, 0, true};
        if (name == word[index]) return RegisterReference{index, 2, 0, false};
        if (name == low[index]) return RegisterReference{index, 1, 0, false};
    }
    static constexpr std::array<std::string_view, 4> high = {"ah", "bh", "ch", "dh"};
    for (std::size_t index = 0; index < high.size(); ++index) {
        if (name == high[index]) return RegisterReference{index, 1, 8, false};
    }
    if (name.starts_with('r') && name.size() >= 2) {
        std::string_view digits = name.substr(1);
        std::size_t width = 8;
        bool zero_extend = false;
        if (const char suffix = digits.back(); suffix == 'b' || suffix == 'w' || suffix == 'd') {
            digits.remove_suffix(1);
            width = suffix == 'b' ? 1 : suffix == 'w' ? 2 : 4;
            zero_extend = suffix == 'd';
        }
        if (const auto number = decimal_suffix(digits, 0); number.has_value() && *number >= 8 && *number <= 15) {
            return RegisterReference{*number, width, 0, zero_extend};
        }
    }
    return std::nullopt;
}

struct CpuState {
    std::array<std::uint64_t, 16> gpr{};
    std::array<std::array<std::uint8_t, 32>, 16> vectors{};
    std::uint64_t rip = 0;
    std::uint64_t flags = 0x2;
    std::uint64_t fs_base = 0;
    std::uint64_t gs_base = 0;

    std::uint64_t read_register(const RegisterReference& reference) const {
        return (gpr[reference.index] >> reference.shift) & mask_for(reference.width);
    }

    std::uint64_t read_register(std::string_view name) const {
        if (name == "rip" || name == "eip") return rip;
        if (const auto reference = gpr_reference(name)) {
            return read_register(*reference);
        }
        throw std::invalid_argument("unknown x86-64 register " + std::string(name));
    }

    void write_register(const RegisterReference& reference, std::uint64_t value) {
        if (reference.zero_extend) {
            gpr[reference.index] = value & mask_for(reference.width);
            return;
        }
        const std::uint64_t field_mask = mask_for(reference.width) << reference.shift;
        gpr[reference.index] = (gpr[reference.index] & ~field_mask) |
                               ((value << reference.shift) & field_mask);
    }

    void write_register(std::string_view name, std::uint64_t value) {
        if (name == "rip" || name == "eip") {
            rip = name == "eip" ? value & 0xFFFFFFFFULL : value;
            return;
        }
        const auto reference = gpr_reference(name);
        if (!reference.has_value()) throw std::invalid_argument("unknown x86-64 register " + std::string(name));
        write_register(*reference, value);
    }
};

std::optional<std::pair<std::size_t, std::size_t>> vector_reference(std::string_view name) {
    std::size_t width = 0;
    std::size_t prefix = 0;
    if (name.starts_with("xmm")) { width = 16; prefix = 3; }
    else if (name.starts_with("ymm")) { width = 32; prefix = 3; }
    else return std::nullopt;
    const auto index = decimal_suffix(name, prefix);
    if (!index.has_value() || *index >= 16) return std::nullopt;
    return std::pair<std::size_t, std::size_t>{*index, width};
}

bool flag(const CpuState& state, unsigned bit) { return (state.flags & (1ULL << bit)) != 0; }
void set_flag(CpuState& state, unsigned bit, bool value) {
    if (value) state.flags |= 1ULL << bit;
    else state.flags &= ~(1ULL << bit);
}

void update_common_flags(CpuState& state, std::uint64_t result, std::size_t size) {
    const std::uint64_t masked = result & mask_for(size);
    const unsigned sign_bit = static_cast<unsigned>(size * 8U - 1U);
    set_flag(state, 6, masked == 0);
    set_flag(state, 7, ((masked >> sign_bit) & 1U) != 0);
    set_flag(state, 2, (std::popcount(static_cast<std::uint8_t>(masked)) & 1) == 0);
}

void update_add_flags(CpuState& state, std::uint64_t lhs, std::uint64_t rhs, std::uint64_t result, std::size_t size) {
    const std::uint64_t mask = mask_for(size);
    const std::uint64_t sign = 1ULL << (size * 8U - 1U);
    lhs &= mask;
    rhs &= mask;
    result &= mask;
    set_flag(state, 0, result < lhs);
    set_flag(state, 4, ((lhs ^ rhs ^ result) & 0x10U) != 0);
    set_flag(state, 11, ((~(lhs ^ rhs) & (lhs ^ result)) & sign) != 0);
    update_common_flags(state, result, size);
}

void update_sub_flags(CpuState& state, std::uint64_t lhs, std::uint64_t rhs, std::uint64_t result, std::size_t size) {
    const std::uint64_t mask = mask_for(size);
    const std::uint64_t sign = 1ULL << (size * 8U - 1U);
    lhs &= mask;
    rhs &= mask;
    result &= mask;
    set_flag(state, 0, lhs < rhs);
    set_flag(state, 4, ((lhs ^ rhs ^ result) & 0x10U) != 0);
    set_flag(state, 11, (((lhs ^ rhs) & (lhs ^ result)) & sign) != 0);
    update_common_flags(state, result, size);
}

bool condition(std::string_view suffix, const CpuState& state) {
    const bool carry = flag(state, 0);
    const bool parity = flag(state, 2);
    const bool zero = flag(state, 6);
    const bool sign = flag(state, 7);
    const bool overflow = flag(state, 11);
    if (suffix == "e" || suffix == "z") return zero;
    if (suffix == "ne" || suffix == "nz") return !zero;
    if (suffix == "a" || suffix == "nbe") return !carry && !zero;
    if (suffix == "ae" || suffix == "nb" || suffix == "nc") return !carry;
    if (suffix == "b" || suffix == "c" || suffix == "nae") return carry;
    if (suffix == "be" || suffix == "na") return carry || zero;
    if (suffix == "g" || suffix == "nle") return !zero && sign == overflow;
    if (suffix == "ge" || suffix == "nl") return sign == overflow;
    if (suffix == "l" || suffix == "nge") return sign != overflow;
    if (suffix == "le" || suffix == "ng") return zero || sign != overflow;
    if (suffix == "s") return sign;
    if (suffix == "ns") return !sign;
    if (suffix == "o") return overflow;
    if (suffix == "no") return !overflow;
    if (suffix == "p" || suffix == "pe") return parity;
    if (suffix == "np" || suffix == "po") return !parity;
    throw std::invalid_argument("unsupported x86 condition " + std::string(suffix));
}

bool environment_flag_enabled(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && std::strcmp(value, "1") == 0;
}

}  // namespace

class GuestRuntime::Impl {
    struct KernelEvent;
    struct EventQueueState;
    struct VideoPort;
    struct RunnableContext;

public:
    explicit Impl(std::vector<std::uint8_t> executable, std::string content_root)
        : executable_(std::move(executable)),
          image_(parse_image(executable_)),
          content_root_(std::move(content_root)),
          fast_forward_waits_(environment_flag_enabled("VS5_FAST_FORWARD_WAITS")) {
        load();
        initialize_cpu();
        const std::filesystem::path content_path(content_root_);
        const std::filesystem::path package_path =
            content_path.parent_path() / "gpu-cache" / "dreaming-sarah.vs5gpu";
        if (!environment_flag_enabled("VS5_DISABLE_VULKAN")) {
            gpu_renderer_ = std::make_unique<VulkanGuestRenderer>(package_path.string());
        }
        if (fast_forward_waits_ || !gpu_renderer_) {
            __android_log_print(
                ANDROID_LOG_INFO,
                "VibeStation5Runtime",
                "diagnostic runtime flags fastForwardWaits=%s vulkan=%s",
                fast_forward_waits_ ? "true" : "false",
                gpu_renderer_ ? "enabled" : "disabled");
        }
    }

    RuntimeRunResult run(std::uint64_t budget) {
        RuntimeRunResult result;
        result.total_instruction_count = total_instruction_count_;
        result.instruction_pointer = state_.rip;
        result.return_value = state_.read_register("rax");
        result.intercepted_imports = intercepted_imports_;
        result.gpu_submissions = gpu_submit_count_;
        result.gpu_draws = gpu_draw_count_;
        result.gpu_flips = gpu_flip_count_;
        result.video_sequence = video_sequence_;
        populate_result_diagnostics(result);
        if (terminal_) {
            result.terminal = true;
            result.reason = stop_reason_;
            result.recent_instructions = recent_instruction_trace();
            result.recent_imports = recent_imports_;
            result.observed_imports = observed_imports_;
            result.thread_diagnostics = thread_diagnostics();
            return result;
        }
        for (std::uint64_t count = 0; count < budget; ++count) {
            try {
                const std::uint64_t scheduler_before = total_instruction_count_ + count;
                executing_instruction_count_ = scheduler_before + 1ULL;
                const Instruction& instruction = decode(state_.rip);
                recent_instruction_addresses_[recent_instruction_cursor_] = instruction.address;
                recent_instruction_cursor_ = (recent_instruction_cursor_ + 1) % recent_instruction_addresses_.size();
                recent_instruction_count_ = std::min(recent_instruction_count_ + 1, recent_instruction_addresses_.size());
                state_.rip = instruction.next_address();
                if (const auto reason = execute(instruction); reason.has_value()) {
                    stop_reason_ = *reason;
                    terminal_ = *reason != "instruction budget";
                    result.reason = *reason;
                    result.terminal = terminal_;
                    result.instruction_count = count + 1;
                    total_instruction_count_ += count + 1;
                    break;
                }
                const std::uint64_t retired = std::min<std::uint64_t>(
                    1ULL + fused_instruction_credit_,
                    budget - count);
                fused_instruction_credit_ = 0;
                count += retired - 1ULL;
                if (((total_instruction_count_ + count + 1) & 0x3FFULL) == 0) {
                    ++instruction_samples_[state_.rip];
                    if (active_thread_handle_ == content_loader_thread_) {
                        ++content_instruction_samples_[state_.rip];
                    }
                }
                if ((scheduler_before / 10'000ULL) !=
                    ((total_instruction_count_ + count + 1) / 10'000ULL)) {
                    service_event_queue_timeouts();
                    service_sleep_timeouts();
                    service_condition_timeouts(total_instruction_count_ + count + 1ULL);
                    if (!ready_contexts_.empty()) {
                        ready_contexts_.push_back({state_, active_thread_handle_});
                        RunnableContext next = dequeue_ready_context(true);
                        state_ = std::move(next.state);
                        active_thread_handle_ = next.handle;
                    }
                }
            } catch (const std::exception& error) {
                stop_reason_ = error.what();
                terminal_ = true;
                result.reason = stop_reason_;
                result.terminal = true;
                result.instruction_count = count;
                total_instruction_count_ += count;
                break;
            }
            if (count + 1 == budget) {
                result.instruction_count = budget;
                total_instruction_count_ += budget;
                result.reason = "instruction budget";
            }
        }
        result.total_instruction_count = total_instruction_count_;
        result.instruction_pointer = state_.rip;
        result.return_value = state_.read_register("rax");
        result.intercepted_imports = intercepted_imports_;
        result.gpu_submissions = gpu_submit_count_;
        result.gpu_draws = gpu_draw_count_;
        result.gpu_flips = gpu_flip_count_;
        result.video_sequence = video_sequence_;
        populate_result_diagnostics(result);
        result.recent_instructions = recent_instruction_trace();
        result.recent_imports = recent_imports_;
        result.observed_imports = observed_imports_;
        result.thread_diagnostics = thread_diagnostics();
        return result;
    }

    void set_input(std::uint64_t buttons, float left_x, float left_y, float right_x, float right_y) {
        input_buttons_ = buttons;
        left_x_ = std::clamp(left_x, -1.0F, 1.0F);
        left_y_ = std::clamp(left_y, -1.0F, 1.0F);
        right_x_ = std::clamp(right_x, -1.0F, 1.0F);
        right_y_ = std::clamp(right_y, -1.0F, 1.0F);
    }

    std::vector<std::uint8_t> drain_audio() {
        std::vector<std::uint8_t> output;
        output.swap(audio_queue_);
        return output;
    }

    [[nodiscard]] std::uint32_t audio_sample_rate() const { return audio_sample_rate_; }

    [[nodiscard]] GuestVideoFrame latest_video_frame(std::uint64_t after_sequence) const {
        if (video_sequence_ <= after_sequence || latest_video_frame_.empty()) return {};
        return {latest_video_frame_, video_width_, video_height_, video_sequence_};
    }

    [[nodiscard]] std::string dump_gpu_capture(const std::string& directory) const {
        if (directory.empty()) throw std::invalid_argument("GPU capture directory is empty");
        const std::filesystem::path root(directory);
        std::filesystem::create_directories(root);

        const std::filesystem::path memory_path = root / "memory.vs5";
        {
            std::ofstream memory_stream(memory_path, std::ios::binary | std::ios::trunc);
            if (!memory_stream) throw std::runtime_error("failed to create guest-memory capture");
            memory_.dump_materialized_pages(memory_stream);
        }

        const auto gpu_register = [](const auto& registers, std::uint32_t index) {
            const auto found = registers.find(index);
            return found == registers.end() ? 0U : found->second;
        };
        const auto shader_address = [&](const SubmittedGpuState& state, std::uint32_t low, std::uint32_t high) {
            return static_cast<std::uint64_t>(gpu_register(state.sh_registers, high)) << 40U |
                static_cast<std::uint64_t>(gpu_register(state.sh_registers, low)) << 8U;
        };
        std::vector<std::uint64_t> shader_addresses;
        for (const CapturedGpuDraw& capture : gpu_draw_captures_) {
            for (const std::uint64_t address : {
                    shader_address(capture.state, 0xC8, 0xC9),
                    shader_address(capture.state, 0x08, 0x09)}) {
                if (address != 0 && std::find(shader_addresses.begin(), shader_addresses.end(), address) == shader_addresses.end()) {
                    shader_addresses.push_back(address);
                }
            }
        }
        std::sort(shader_addresses.begin(), shader_addresses.end());
        for (const std::uint64_t address : shader_addresses) {
            std::ostringstream filename;
            filename << "shader-" << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << address << ".bin";
            const std::vector<std::uint8_t> bytes = memory_.read(address, 64U * 1024U, std::nullopt);
            std::ofstream shader_stream(root / filename.str(), std::ios::binary | std::ios::trunc);
            if (!shader_stream) throw std::runtime_error("failed to create guest-shader capture");
            shader_stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
            if (!shader_stream) throw std::runtime_error("failed to write guest-shader capture");
        }

        const auto write_registers = [](std::ostream& stream, const auto& registers) {
            std::vector<std::pair<std::uint32_t, std::uint32_t>> sorted(registers.begin(), registers.end());
            std::sort(sorted.begin(), sorted.end());
            stream << '[';
            for (std::size_t index = 0; index < sorted.size(); ++index) {
                if (index != 0) stream << ',';
                stream << '[' << sorted[index].first << ',' << sorted[index].second << ']';
            }
            stream << ']';
        };

        const std::filesystem::path manifest_path = root / "capture.json";
        std::ofstream manifest(manifest_path, std::ios::trunc);
        if (!manifest) throw std::runtime_error("failed to create GPU capture manifest");
        manifest << "{\n  \"version\":1,\n"
                 << "  \"totalInstructions\":" << total_instruction_count_ << ",\n"
                 << "  \"gpuSubmissions\":" << gpu_submit_count_ << ",\n"
                 << "  \"gpuDraws\":" << gpu_draw_count_ << ",\n"
                 << "  \"gpuFlips\":" << gpu_flip_count_ << ",\n"
                 << "  \"materializedPages\":" << memory_.materialized_page_count() << ",\n"
                 << "  \"memoryFile\":\"memory.vs5\",\n"
                 << "  \"shaders\":[";
        for (std::size_t index = 0; index < shader_addresses.size(); ++index) {
            if (index != 0) manifest << ',';
            const std::uint64_t address = shader_addresses[index];
            std::ostringstream filename;
            filename << "shader-" << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << address << ".bin";
            const auto header = shader_headers_by_code_.find(address);
            manifest << "{\"address\":\"" << hexadecimal(address) << "\",\"header\":\""
                     << hexadecimal(header == shader_headers_by_code_.end() ? 0 : header->second)
                     << "\",\"file\":\"" << filename.str() << "\"}";
        }
        manifest << "],\n  \"draws\":[\n";
        for (std::size_t index = 0; index < gpu_draw_captures_.size(); ++index) {
            if (index != 0) manifest << ",\n";
            const CapturedGpuDraw& capture = gpu_draw_captures_[index];
            manifest << "    {\"drawIndex\":" << capture.draw_index
                     << ",\"count\":" << capture.vertex_or_index_count
                     << ",\"instanceCount\":" << capture.state.instance_count
                     << ",\"indexAddress\":\"" << hexadecimal(capture.state.index_buffer)
                     << "\",\"indexCount\":" << capture.state.index_count
                     << ",\"indexSize\":" << capture.state.index_size
                     << ",\"exportShader\":\"" << hexadecimal(shader_address(capture.state, 0xC8, 0xC9))
                     << "\",\"pixelShader\":\"" << hexadecimal(shader_address(capture.state, 0x08, 0x09))
                     << "\",\"cx\":";
            write_registers(manifest, capture.state.cx_registers);
            manifest << ",\"sh\":";
            write_registers(manifest, capture.state.sh_registers);
            manifest << ",\"uc\":";
            write_registers(manifest, capture.state.uc_registers);
            manifest << '}';
        }
        manifest << "\n  ]\n}\n";
        if (!manifest) throw std::runtime_error("failed to write GPU capture manifest");
        return manifest_path.string();
    }

    const Instruction& decode(std::uint64_t address) {
        if (const auto found = decoded_instructions_.find(address); found != decoded_instructions_.end()) return found->second;
        return decoded_instructions_.emplace(address, decoder_.decode(memory_, address)).first->second;
    }

    [[nodiscard]] std::string description() const {
        std::ostringstream stream;
        const bool is_ps5 = image_.ps5_self || image_.abi_version == 2;
        stream << (image_.self ? (is_ps5 ? "PS5 SELF" : "PS4 SELF") : "Decrypted ELF")
               << ", image-base=" << hexadecimal(image_base_)
               << ", entry=" << hexadecimal(entry_point_)
               << ", load-segments=" << load_segment_count_
               << ", relocations=" << relocation_count_
               << ", imports=" << imports_.size();
        if (gpu_renderer_) stream << ", gpu=" << gpu_renderer_->status();
        return stream.str();
    }

private:
    void populate_result_diagnostics(RuntimeRunResult& result) const {
        std::uint64_t frame_hash = 1469598103934665603ULL;
        for (const std::uint8_t byte : latest_video_frame_) {
            frame_hash ^= byte;
            frame_hash *= 1099511628211ULL;
        }
        result.frame_hash = latest_video_frame_.empty() ? 0 : frame_hash;
        if (gpu_renderer_) {
            result.shader_cache_misses = gpu_renderer_->shader_cache_misses();
            result.texture_refreshes = gpu_renderer_->texture_refreshes();
        }
        for (const auto& [handle, queue] : event_queues_) {
            static_cast<void>(handle);
            result.event_queue_depth += queue.pending.size();
        }
        if (const auto found = last_import_by_thread_.find(active_thread_handle_);
            found != last_import_by_thread_.end()) {
            result.last_import = found->second;
        }
    }

    void load() {
        std::uint64_t minimum = std::numeric_limits<std::uint64_t>::max();
        for (const ProgramHeader& header : image_.program_headers) {
            if (header.type == 1) minimum = std::min(minimum, header.virtual_address);
        }
        if (minimum < 0x10000ULL) {
            image_base_ = image_.abi_version == 2 || image_.ps5_self ? kPs5MainImageBase : kPs4MainImageBase;
        }
        Reader reader(executable_);
        for (std::size_t index = 0; index < image_.program_headers.size(); ++index) {
            const ProgramHeader& header = image_.program_headers[index];
            if (header.type != 1 || header.memory_size == 0) continue;
            std::uint8_t protection = 0;
            if ((header.flags & 4U) != 0) protection |= kRead;
            if ((header.flags & 2U) != 0) protection |= kWrite;
            if ((header.flags & 1U) != 0) protection |= kExecute;
            const std::uint64_t address = image_base_ + header.virtual_address;
            memory_.map(address, header.memory_size, protection, "ELF LOAD " + std::to_string(index));
            const std::uint64_t source = source_offset_for(image_, header, index);
            if (source > std::numeric_limits<std::size_t>::max() ||
                header.file_size > std::numeric_limits<std::size_t>::max()) {
                throw std::invalid_argument("load segment cannot be represented on Android");
            }
            reader.require(static_cast<std::size_t>(source), static_cast<std::size_t>(header.file_size), "load segment");
            memory_.write(
                address,
                executable_.data() + static_cast<std::size_t>(source),
                static_cast<std::size_t>(header.file_size),
                true
            );
            ++load_segment_count_;
        }
        apply_relocations();
        load_import_symbols();
        entry_point_ = image_base_ + image_.entry_point;
    }

    std::unordered_map<std::uint64_t, std::uint64_t> dynamic_tags() const {
        const auto header = std::find_if(image_.program_headers.begin(), image_.program_headers.end(), [](const ProgramHeader& item) {
            return item.type == 2;
        });
        if (header == image_.program_headers.end() || header->file_size == 0) return {};
        const auto bytes = memory_.read(image_base_ + header->virtual_address, static_cast<std::size_t>(header->file_size), std::nullopt);
        Reader reader(bytes);
        std::unordered_map<std::uint64_t, std::uint64_t> tags;
        for (std::size_t cursor = 0; cursor + 16 <= bytes.size(); cursor += 16) {
            const std::uint64_t tag = reader.u64(cursor);
            if (tag == 0) break;
            tags.try_emplace(tag, reader.u64(cursor + 8));
        }
        return tags;
    }

    static std::uint64_t tag_value(
        const std::unordered_map<std::uint64_t, std::uint64_t>& tags,
        std::initializer_list<std::uint64_t> candidates
    ) {
        for (const std::uint64_t tag : candidates) {
            if (const auto value = tags.find(tag); value != tags.end()) return value->second;
        }
        return 0;
    }

    void apply_relocations() {
        const auto tags = dynamic_tags();
        const std::uint64_t imported_data_base = image_base_ + 0x100000000ULL;
        bool imported_mapped = false;
        std::unordered_map<std::uint32_t, std::uint64_t> imported_slots;
        const auto apply_table = [&](std::uint64_t offset, std::uint64_t size) {
            if (size == 0) return;
            const auto table = memory_.read(image_base_ + offset, static_cast<std::size_t>(size), std::nullopt);
            Reader reader(table);
            for (std::size_t cursor = 0; cursor + 24 <= table.size(); cursor += 24) {
                const std::uint64_t relocation_offset = reader.u64(cursor);
                const std::uint64_t info = reader.u64(cursor + 8);
                const std::uint64_t addend = reader.u64(cursor + 16);
                const std::uint32_t type = static_cast<std::uint32_t>(info);
                const std::uint32_t symbol = static_cast<std::uint32_t>(info >> 32U);
                std::optional<std::uint64_t> value;
                if (type == 8) value = image_base_ + addend;
                else if (type == 16) value = 1;
                else if (type == 6) {
                    if (!imported_mapped) {
                        memory_.map(imported_data_base, kImportedDataSize, kRead | kWrite, "imported data objects");
                        imported_mapped = true;
                    }
                    if (const auto existing = imported_slots.find(symbol); existing != imported_slots.end()) {
                        value = existing->second;
                    } else {
                        value = imported_data_base + imported_slots.size() * 64ULL;
                        imported_slots.emplace(symbol, *value);
                    }
                }
                if (value.has_value()) {
                    memory_.write_integer(image_base_ + relocation_offset, 8, *value, true);
                    ++relocation_count_;
                }
            }
        };
        apply_table(tag_value(tags, {0x07, 0x6100002FULL}), tag_value(tags, {0x08, 0x61000031ULL}));
        apply_table(tag_value(tags, {0x17, 0x61000029ULL}), tag_value(tags, {0x02, 0x6100002DULL}));
    }

    void load_import_symbols() {
        const auto tags = dynamic_tags();
        const std::uint64_t string_offset = tag_value(tags, {0x05, 0x61000035ULL});
        const std::uint64_t string_size = tag_value(tags, {0x0A, 0x61000037ULL});
        const std::uint64_t symbol_offset = tag_value(tags, {0x06, 0x61000039ULL});
        const std::uint64_t symbol_size = tag_value(tags, {0x6100003FULL});
        const std::uint64_t jump_offset = tag_value(tags, {0x17, 0x61000029ULL});
        const std::uint64_t jump_size = tag_value(tags, {0x02, 0x6100002DULL});
        if (string_size == 0 || symbol_size == 0 || jump_size == 0) return;
        const auto strings = memory_.read(image_base_ + string_offset, static_cast<std::size_t>(string_size), std::nullopt);
        const auto symbols = memory_.read(image_base_ + symbol_offset, static_cast<std::size_t>(symbol_size), std::nullopt);
        const auto jumps = memory_.read(image_base_ + jump_offset, static_cast<std::size_t>(jump_size), std::nullopt);
        Reader jump_reader(jumps);
        Reader symbol_reader(symbols);
        std::size_t import_index = 0;
        for (std::size_t cursor = 0; cursor + 24 <= jumps.size(); cursor += 24, ++import_index) {
            const std::size_t symbol_index = static_cast<std::size_t>(jump_reader.u64(cursor + 8) >> 32U);
            const std::size_t entry = symbol_index * 24U;
            if (entry + 24U > symbols.size()) continue;
            const std::size_t name_offset = symbol_reader.u32(entry);
            if (name_offset >= strings.size()) continue;
            const auto end = std::find(strings.begin() + static_cast<std::ptrdiff_t>(name_offset), strings.end(), 0);
            std::string name(strings.begin() + static_cast<std::ptrdiff_t>(name_offset), end);
            if (const std::size_t separator = name.find('#'); separator != std::string::npos) name.resize(separator);
            imports_[import_index] = std::move(name);
        }
    }

    void initialize_cpu() {
        memory_.map(kStackBase, kStackSize, kRead | kWrite, "guest stack");
        memory_.map(kHeapBase, kHeapSize, kRead | kWrite, "guest heap");
        memory_.map(kTlsBase, kTlsSize, kRead | kWrite, "guest TLS");
        state_.rip = entry_point_;
        state_.fs_base = kTlsBase + 32ULL * 1024ULL;
        state_.gs_base = state_.fs_base;
        memory_.write_integer(state_.fs_base, 8, state_.fs_base);
        const std::uint64_t process_arguments = kStackBase + 0x1000ULL;
        state_.write_register("rdi", process_arguments);
        state_.write_register("rsi", 0);
        state_.write_register("rsp", kStackBase + kStackSize - 0x100ULL);
        memory_.write_integer(process_arguments, 8, 1);
        memory_.write_integer(process_arguments + 8, 8, process_arguments + 0x100ULL);
        memory_.write_integer(process_arguments + 16, 8, 0);
        static constexpr std::array<std::uint8_t, 10> executable_name = {'e','b','o','o','t','.','b','i','n',0};
        memory_.write(process_arguments + 0x100ULL, executable_name.data(), executable_name.size());
        push(kReturnSentinel);
        heap_cursor_ = kHeapBase;
    }

    std::uint64_t effective_address(const MemoryOperand& operand, const Instruction& instruction) const {
        std::uint64_t address = 0;
        if (!operand.segment.empty()) {
            if (operand.segment == "fs") address += state_.fs_base;
            else if (operand.segment == "gs") address += state_.gs_base;
        }
        if (!operand.base.empty()) {
            if (operand.base_is_instruction_pointer) address += instruction.next_address();
            else if (operand.base_reference.has_value()) address += state_.read_register(*operand.base_reference);
            else address += state_.read_register(operand.base);
        }
        if (!operand.index.empty()) {
            const std::uint64_t index = operand.index_reference.has_value()
                ? state_.read_register(*operand.index_reference)
                : state_.read_register(operand.index);
            address += index * static_cast<std::uint64_t>(operand.scale);
        }
        address += static_cast<std::uint64_t>(operand.displacement);
        return address;
    }

    std::vector<std::uint8_t> read_bytes(const Operand& operand, const Instruction& instruction) const {
        if (operand.kind == OperandKind::Register) {
            if (const auto& vector = operand.vector_register_reference; vector.has_value()) {
                return std::vector<std::uint8_t>(
                    state_.vectors[vector->first].begin(),
                    state_.vectors[vector->first].begin() + static_cast<std::ptrdiff_t>(operand.size)
                );
            }
            const std::uint64_t value = operand.register_reference.has_value()
                ? state_.read_register(*operand.register_reference)
                : state_.read_register(operand.register_name);
            std::vector<std::uint8_t> bytes(operand.size);
            for (std::size_t index = 0; index < bytes.size(); ++index) bytes[index] = static_cast<std::uint8_t>(value >> (index * 8U));
            return bytes;
        }
        if (operand.kind == OperandKind::Immediate) {
            std::vector<std::uint8_t> bytes(operand.size);
            for (std::size_t index = 0; index < bytes.size(); ++index) bytes[index] = static_cast<std::uint8_t>(operand.immediate >> (index * 8U));
            return bytes;
        }
        if (operand.kind == OperandKind::Memory) {
            return memory_.read(effective_address(operand.memory, instruction), operand.size);
        }
        throw std::invalid_argument("invalid source operand: " + instruction.text());
    }

    std::uint64_t read_operand(const Operand& operand, const Instruction& instruction) const {
        if (operand.size > 8) throw std::invalid_argument("wide operand requires SIMD path: " + instruction.text());
        if (operand.kind == OperandKind::Register && operand.register_reference.has_value()) {
            return state_.read_register(*operand.register_reference);
        }
        if (operand.kind == OperandKind::Immediate) return operand.immediate & mask_for(operand.size);
        if (operand.kind == OperandKind::Memory) {
            return memory_.read_integer(effective_address(operand.memory, instruction), operand.size);
        }
        const auto bytes = read_bytes(operand, instruction);
        return scalar_at<std::uint64_t>(bytes);
    }

    void write_bytes(const Operand& operand, const Instruction& instruction, const std::vector<std::uint8_t>& bytes) {
        if (operand.kind == OperandKind::Register) {
            if (const auto& vector = operand.vector_register_reference; vector.has_value()) {
                auto& target = state_.vectors[vector->first];
                std::fill(target.begin(), target.end(), 0);
                std::copy_n(bytes.begin(), std::min(bytes.size(), operand.size), target.begin());
                return;
            }
            std::uint64_t value = 0;
            for (std::size_t index = 0; index < std::min<std::size_t>(bytes.size(), 8); ++index) {
                value |= static_cast<std::uint64_t>(bytes[index]) << (index * 8U);
            }
            if (operand.register_reference.has_value()) state_.write_register(*operand.register_reference, value);
            else state_.write_register(operand.register_name, value);
            return;
        }
        if (operand.kind == OperandKind::Memory) {
            memory_.write(effective_address(operand.memory, instruction), bytes.data(), std::min(bytes.size(), operand.size));
            return;
        }
        throw std::invalid_argument("invalid destination operand: " + instruction.text());
    }

    void write_operand(const Operand& operand, const Instruction& instruction, std::uint64_t value) {
        if (operand.size > 8) throw std::invalid_argument("wide operand requires SIMD path: " + instruction.text());
        if (operand.kind == OperandKind::Register && operand.register_reference.has_value()) {
            state_.write_register(*operand.register_reference, value);
            return;
        }
        if (operand.kind == OperandKind::Memory) {
            memory_.write_integer(effective_address(operand.memory, instruction), operand.size, value);
            return;
        }
        std::vector<std::uint8_t> bytes(operand.size);
        for (std::size_t index = 0; index < bytes.size(); ++index) bytes[index] = static_cast<std::uint8_t>(value >> (index * 8U));
        write_bytes(operand, instruction, bytes);
    }

    void push(std::uint64_t value) {
        push(state_, value);
    }

    void push(CpuState& state, std::uint64_t value) {
        const std::uint64_t stack = state.read_register("rsp") - 8ULL;
        state.write_register("rsp", stack);
        memory_.write_integer(stack, 8, value);
    }

    std::uint64_t pop() {
        const std::uint64_t stack = state_.read_register("rsp");
        const std::uint64_t value = memory_.read_integer(stack, 8);
        state_.write_register("rsp", stack + 8ULL);
        return value;
    }

    std::optional<std::uint32_t> import_stub_index(std::uint64_t address) const {
        try {
            const auto bytes = memory_.fetch(address, 15);
            if (bytes[0] != 0xFF || bytes[1] != 0x25 || bytes[6] != 0x68 || bytes[11] != 0xE9) return std::nullopt;
            std::uint32_t index = 0;
            for (std::size_t offset = 0; offset < 4; ++offset) index |= static_cast<std::uint32_t>(bytes[7 + offset]) << (offset * 8U);
            return index;
        } catch (...) {
            return std::nullopt;
        }
    }

    std::uint64_t allocate(std::uint64_t size, std::uint64_t alignment = 16) {
        alignment = std::max<std::uint64_t>(alignment, 1);
        const std::uint64_t aligned = (heap_cursor_ + alignment - 1ULL) & ~(alignment - 1ULL);
        if (aligned < kHeapBase || size > kHeapBase + kHeapSize - aligned) {
            throw std::runtime_error("guest heap exhausted");
        }
        heap_cursor_ = aligned + std::max<std::uint64_t>(size, 1);
        allocations_[aligned] = size;
        return aligned;
    }

    bool finish_active_thread(std::uint64_t return_value) {
        thread_return_values_[active_thread_handle_] = return_value;
        if (const auto waiters = join_waiters_.find(active_thread_handle_); waiters != join_waiters_.end()) {
            for (JoinWaiter& waiter : waiters->second) {
                if (waiter.result_address != 0) memory_.write_integer(waiter.result_address, 8, return_value);
                waiter.context.state.write_register("rax", 0);
                ready_contexts_.push_back(std::move(waiter.context));
            }
            join_waiters_.erase(waiters);
        }
        if (ready_contexts_.empty()) return false;
        state_ = ready_contexts_.front().state;
        active_thread_handle_ = ready_contexts_.front().handle;
        ready_contexts_.erase(ready_contexts_.begin());
        context_switched_in_import_ = true;
        return true;
    }

    std::uint64_t resolve_pthread_attribute(std::uint64_t address) {
        if (pthread_attributes_.contains(address)) {
            const std::uint64_t candidate = memory_.read_integer(address, 8);
            if (pthread_attributes_.contains(candidate)) return candidate;
            return address;
        }
        const std::uint64_t candidate = memory_.read_integer(address, 8);
        return pthread_attributes_.contains(candidate) ? candidate : address;
    }

    std::string guest_string(std::uint64_t address) const {
        std::string value;
        for (std::uint64_t offset = 0; offset < 64ULL * 1024ULL * 1024ULL; ++offset) {
            const char character = static_cast<char>(memory_.read_integer(address + offset, 1));
            if (character == '\0') return value;
            value.push_back(character);
        }
        throw std::runtime_error("unterminated guest string");
    }

    std::string guest_format(
        std::string_view format,
        const std::function<std::uint64_t(bool floating)>& next_argument
    ) {
        std::string output;
        for (std::size_t cursor = 0; cursor < format.size();) {
            if (format[cursor] != '%') {
                output.push_back(format[cursor++]);
                continue;
            }
            if (++cursor < format.size() && format[cursor] == '%') {
                output.push_back('%');
                ++cursor;
                continue;
            }

            bool left = false;
            bool plus = false;
            bool alternate = false;
            bool zero = false;
            while (cursor < format.size()) {
                const char flag = format[cursor];
                if (flag == '-') left = true;
                else if (flag == '+') plus = true;
                else if (flag == '#') alternate = true;
                else if (flag == '0') zero = true;
                else if (flag != ' ') break;
                ++cursor;
            }
            std::size_t width = 0;
            if (cursor < format.size() && format[cursor] == '*') {
                width = static_cast<std::uint32_t>(next_argument(false));
                ++cursor;
            } else {
                while (cursor < format.size() && format[cursor] >= '0' && format[cursor] <= '9') {
                    width = width * 10U + static_cast<std::size_t>(format[cursor++] - '0');
                }
            }
            std::optional<std::size_t> precision;
            if (cursor < format.size() && format[cursor] == '.') {
                ++cursor;
                precision = 0;
                if (cursor < format.size() && format[cursor] == '*') {
                    precision = static_cast<std::uint32_t>(next_argument(false));
                    ++cursor;
                } else {
                    while (cursor < format.size() && format[cursor] >= '0' && format[cursor] <= '9') {
                        *precision = *precision * 10U + static_cast<std::size_t>(format[cursor++] - '0');
                    }
                }
            }
            bool long_value = false;
            if (cursor < format.size() && (format[cursor] == 'l' || format[cursor] == 'z' ||
                                           format[cursor] == 'j' || format[cursor] == 't')) {
                long_value = true;
                const char length = format[cursor++];
                if (length == 'l' && cursor < format.size() && format[cursor] == 'l') ++cursor;
            } else if (cursor < format.size() && format[cursor] == 'h') {
                ++cursor;
                if (cursor < format.size() && format[cursor] == 'h') ++cursor;
            }
            if (cursor >= format.size()) break;
            const char conversion = format[cursor++];
            std::ostringstream value;
            if (conversion == 's') {
                const std::uint64_t address = next_argument(false);
                std::string text = address == 0 ? "(null)" : guest_string(address);
                if (precision.has_value() && text.size() > *precision) text.resize(*precision);
                value << text;
            } else if (conversion == 'c') {
                value << static_cast<char>(next_argument(false));
            } else if (conversion == 'd' || conversion == 'i') {
                const std::uint64_t raw = next_argument(false);
                const std::int64_t number = long_value
                    ? static_cast<std::int64_t>(raw)
                    : static_cast<std::int32_t>(raw);
                if (plus && number >= 0) value << '+';
                value << number;
            } else if (conversion == 'u' || conversion == 'x' || conversion == 'X' || conversion == 'o') {
                const std::uint64_t raw = next_argument(false);
                const std::uint64_t number = long_value ? raw : static_cast<std::uint32_t>(raw);
                if (alternate && number != 0) value << (conversion == 'o' ? "0" : conversion == 'X' ? "0X" : "0x");
                if (conversion == 'x' || conversion == 'X') value << std::hex;
                else if (conversion == 'o') value << std::oct;
                if (conversion == 'X') value << std::uppercase;
                value << number;
            } else if (conversion == 'p') {
                value << hexadecimal(next_argument(false));
            } else if (conversion == 'f' || conversion == 'F' || conversion == 'e' || conversion == 'E' ||
                       conversion == 'g' || conversion == 'G') {
                const std::uint64_t bits = next_argument(true);
                double number = 0;
                std::memcpy(&number, &bits, sizeof(number));
                if (precision.has_value()) value << std::setprecision(static_cast<int>(*precision));
                if (conversion == 'f' || conversion == 'F') value << std::fixed;
                else if (conversion == 'e' || conversion == 'E') value << std::scientific;
                if (conversion == 'E' || conversion == 'F' || conversion == 'G') value << std::uppercase;
                value << number;
            } else if (conversion == 'n') {
                const std::uint64_t address = next_argument(false);
                if (address != 0) memory_.write_integer(address, long_value ? 8 : 4, output.size());
                continue;
            } else {
                value << '%' << conversion;
            }
            std::string text = value.str();
            if (width > text.size()) {
                const std::size_t padding = width - text.size();
                if (left) text.append(padding, ' ');
                else text.insert(0, padding, zero ? '0' : ' ');
            }
            output += text;
        }
        return output;
    }

    std::optional<std::vector<std::uint8_t>> read_title_file(std::string guest_path) const {
        if (content_root_.empty() || guest_path.empty()) return std::nullopt;
        std::replace(guest_path.begin(), guest_path.end(), '\\', '/');
        if (guest_path.starts_with("app0:/")) guest_path.erase(0, 6);
        else if (const std::size_t app0 = guest_path.find("/app0/"); app0 != std::string::npos) {
            guest_path.erase(0, app0 + 6);
        }
        while (guest_path.starts_with("./")) guest_path.erase(0, 2);
        while (guest_path.starts_with('/')) guest_path.erase(0, 1);
        if (guest_path.empty()) return std::nullopt;

        const std::filesystem::path root = std::filesystem::weakly_canonical(content_root_);
        const std::filesystem::path file = std::filesystem::weakly_canonical(root / guest_path);
        const std::string root_path = root.string() + '/';
        const std::string file_path = file.string();
        if (file != root && !file_path.starts_with(root_path)) return std::nullopt;
        std::ifstream stream(file, std::ios::binary | std::ios::ate);
        if (!stream) return std::nullopt;
        const std::streamoff length = stream.tellg();
        if (length < 0 || static_cast<std::uint64_t>(length) > std::numeric_limits<std::size_t>::max()) return std::nullopt;
        std::vector<std::uint8_t> data(static_cast<std::size_t>(length));
        stream.seekg(0, std::ios::beg);
        if (!data.empty() && !stream.read(reinterpret_cast<char*>(data.data()), length)) return std::nullopt;
        return data;
    }

    static constexpr std::uint32_t agc_pm4(
        std::uint32_t length_dwords,
        std::uint32_t operation,
        std::uint32_t packet_register
    ) {
        return 0xC0000000U |
               ((((length_dwords - 2U) & 0x3FFFU) << 16U)) |
               ((operation & 0xFFU) << 8U) |
               ((packet_register & 0x3FU) << 2U);
    }

    bool agc_allocate_command(
        std::uint64_t command_buffer,
        std::uint32_t dword_count,
        std::uint64_t& command_address
    ) {
        command_address = 0;
        if (command_buffer == 0 || dword_count == 0) return false;
        const std::uint64_t cursor_up = memory_.read_integer(command_buffer + 0x10, 8);
        const std::uint64_t cursor_down = memory_.read_integer(command_buffer + 0x18, 8);
        const std::uint64_t reserved = memory_.read_integer(command_buffer + 0x30, 4);
        const std::uint64_t available = cursor_down >= cursor_up ? (cursor_down - cursor_up) / 4ULL : 0;
        const std::uint64_t capacity = std::max(available, reserved);
        if (dword_count > capacity - reserved) return false;
        const std::uint64_t next = cursor_up + static_cast<std::uint64_t>(dword_count) * 4ULL;
        memory_.write_integer(command_buffer + 0x10, 8, next);
        command_address = cursor_up;
        return true;
    }

    std::uint64_t agc_emit(std::uint64_t command_buffer, std::initializer_list<std::uint32_t> words) {
        std::uint64_t command = 0;
        if (!agc_allocate_command(command_buffer, static_cast<std::uint32_t>(words.size()), command)) return 0;
        std::size_t index = 0;
        for (const std::uint32_t word : words) {
            memory_.write_integer(command + index * 4ULL, 4, word);
            ++index;
        }
        return command;
    }

    std::uint64_t agc_emit_registers_indirect(std::uint32_t packet_register) {
        const std::uint64_t command_buffer = state_.read_register("rdi");
        const std::uint64_t registers = state_.read_register("rsi");
        const std::uint32_t count = static_cast<std::uint32_t>(state_.read_register("rdx"));
        return agc_emit(command_buffer, {
            agc_pm4(4, 0x10, packet_register),
            count,
            static_cast<std::uint32_t>(registers),
            static_cast<std::uint32_t>(registers >> 32U),
        });
    }

    void agc_copy_registers(
        std::unordered_map<std::uint32_t, std::uint32_t>& destination,
        std::uint64_t registers,
        std::uint32_t count
    ) {
        if (registers == 0 || count > 65536U) return;
        for (std::uint32_t index = 0; index < count; ++index) {
            const std::uint64_t entry = registers + static_cast<std::uint64_t>(index) * 8ULL;
            destination[static_cast<std::uint32_t>(memory_.read_integer(entry, 4))] =
                static_cast<std::uint32_t>(memory_.read_integer(entry + 4, 4));
        }
    }

    void write_kernel_event(std::uint64_t address, const KernelEvent& event) {
        memory_.write_integer(address + 0x00, 8, event.ident);
        memory_.write_integer(address + 0x08, 2, static_cast<std::uint16_t>(event.filter));
        memory_.write_integer(address + 0x0A, 2, event.flags);
        memory_.write_integer(address + 0x0C, 4, event.fflags);
        memory_.write_integer(address + 0x10, 8, event.data);
        memory_.write_integer(address + 0x18, 8, event.user_data);
    }

    bool dequeue_event_queue(
        EventQueueState& queue,
        std::uint64_t events_address,
        std::uint32_t capacity,
        std::uint64_t out_count_address,
        std::size_t& delivered) {
        delivered = std::min<std::size_t>(capacity, queue.pending.size());
        try {
            for (std::size_t index = 0; index < delivered; ++index) {
                write_kernel_event(events_address + index * kKernelEventSize, queue.pending[index]);
            }
            if (out_count_address != 0) memory_.write_integer(out_count_address, 4, delivered);
        } catch (const std::exception&) {
            delivered = 0;
            return false;
        }
        queue.pending.erase(queue.pending.begin(), queue.pending.begin() + static_cast<std::ptrdiff_t>(delivered));
        return true;
    }

    void deliver_event_queue_waiters(std::uint64_t handle) {
        auto found = event_queues_.find(handle);
        if (found == event_queues_.end()) return;
        EventQueueState& queue = found->second;
        while (!queue.pending.empty() && !queue.waiters.empty()) {
            EventQueueWaiter waiter = std::move(queue.waiters.front());
            queue.waiters.erase(queue.waiters.begin());
            std::size_t delivered = 0;
            const bool success = dequeue_event_queue(
                queue, waiter.events_address, waiter.capacity, waiter.out_count_address, delivered);
            waiter.context.state.write_register("rax", success && delivered > 0 ? 0 : kOrbisErrorMemoryFault);
            ready_contexts_.push_back(std::move(waiter.context));
        }
    }

    void trigger_flip_events(VideoPort& port, std::uint64_t flip_argument) {
        const std::uint64_t event_hint = kVideoOutFlipEventIdent |
            ((flip_argument & 0x0000FFFFFFFFFFFFULL) << 16U);
        const std::uint64_t time_bits = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count()) & 0xFFFULL;
        for (const FlipEventRegistration& registration : port.flip_events) {
            auto found = event_queues_.find(registration.event_queue);
            if (found == event_queues_.end()) continue;
            EventQueueState& queue = found->second;
            auto pending = std::find_if(queue.pending.begin(), queue.pending.end(), [](const KernelEvent& event) {
                return event.ident == kVideoOutFlipEventIdent && event.filter == kKernelEventFilterVideoOut;
            });
            std::uint64_t count = 1;
            if (pending != queue.pending.end()) {
                count = std::min(((pending->data >> 12U) & 0xFULL) + 1ULL, 0xFULL);
            }
            const KernelEvent event{
                kVideoOutFlipEventIdent,
                kKernelEventFilterVideoOut,
                0x20,
                0,
                time_bits | (count << 12U) | (event_hint & 0xFFFFFFFFFFFF0000ULL),
                registration.user_data};
            if (pending == queue.pending.end()) queue.pending.push_back(event);
            else *pending = event;
            deliver_event_queue_waiters(registration.event_queue);
        }
    }

    void service_event_queue_timeouts() {
        const auto now = std::chrono::steady_clock::now();
        for (auto& [handle, queue] : event_queues_) {
            static_cast<void>(handle);
            for (auto waiter = queue.waiters.begin(); waiter != queue.waiters.end();) {
                if (!waiter->timed || waiter->deadline > now) {
                    ++waiter;
                    continue;
                }
                try {
                    if (waiter->out_count_address != 0) memory_.write_integer(waiter->out_count_address, 4, 0);
                    waiter->context.state.write_register("rax", kOrbisErrorTimedOut);
                } catch (const std::exception&) {
                    waiter->context.state.write_register("rax", kOrbisErrorMemoryFault);
                }
                ready_contexts_.push_back(std::move(waiter->context));
                waiter = queue.waiters.erase(waiter);
            }
        }
    }

    void service_sleep_timeouts() {
        const auto now = std::chrono::steady_clock::now();
        for (auto waiter = sleep_waiters_.begin(); waiter != sleep_waiters_.end();) {
            if (waiter->deadline > now) {
                ++waiter;
                continue;
            }
            waiter->context.state.write_register("rax", 0);
            ready_contexts_.push_back(std::move(waiter->context));
            waiter = sleep_waiters_.erase(waiter);
        }
    }

    void service_condition_timeouts(std::uint64_t instruction_count) {
        const auto now = std::chrono::steady_clock::now();
        for (auto& [condition, waiters] : condition_waiters_) {
            static_cast<void>(condition);
            for (auto waiter = waiters.begin(); waiter != waiters.end();) {
                const bool expired = waiter->timed && (fast_forward_waits_
                    ? waiter->instruction_deadline <= instruction_count
                    : waiter->deadline <= now);
                if (!expired) {
                    ++waiter;
                    continue;
                }
                waiter->context.state.write_register("rax", waiter->timeout_result);
                ++condition_timeout_count_;
                if (condition_timeout_count_ <= 16 || (condition_timeout_count_ % 256ULL) == 0) {
                    __android_log_print(
                        ANDROID_LOG_INFO,
                        "VibeStation5Runtime",
                        "condition timeout wake=%llu cond=0x%llx mutex=0x%llx",
                        static_cast<unsigned long long>(condition_timeout_count_),
                        static_cast<unsigned long long>(condition),
                        static_cast<unsigned long long>(waiter->mutex_address));
                }
                MutexState& mutex = mutexes_[waiter->mutex_address];
                if (mutex.owner == 0) {
                    mutex.owner = waiter->context.handle;
                    mutex.recursion = 1;
                    ready_contexts_.push_back(std::move(waiter->context));
                } else {
                    mutex.waiters.push_back(std::move(waiter->context));
                }
                waiter = waiters.erase(waiter);
            }
        }
    }

    RunnableContext dequeue_ready_context(bool prefer_content_loader) {
        if (ready_contexts_.empty()) throw std::runtime_error("no runnable guest context");
        if (prefer_content_loader && !layouts_loaded_ && content_loader_thread_ != 0) {
            const auto preferred = std::find_if(
                ready_contexts_.begin(),
                ready_contexts_.end(),
                [&](const RunnableContext& context) { return context.handle == content_loader_thread_; });
            if (preferred != ready_contexts_.end() && content_priority_streak_ < 3) {
                ++content_priority_streak_;
                RunnableContext next = std::move(*preferred);
                ready_contexts_.erase(preferred);
                return next;
            }
            if (preferred != ready_contexts_.end()) {
                const auto worker = std::find_if(
                    ready_contexts_.begin(),
                    ready_contexts_.end(),
                    [&](const RunnableContext& context) { return context.handle != content_loader_thread_; });
                if (worker != ready_contexts_.end()) {
                    content_priority_streak_ = 0;
                    RunnableContext next = std::move(*worker);
                    ready_contexts_.erase(worker);
                    return next;
                }
                ++content_priority_streak_;
                RunnableContext next = std::move(*preferred);
                ready_contexts_.erase(preferred);
                return next;
            }
        }
        content_priority_streak_ = 0;
        RunnableContext next = std::move(ready_contexts_.front());
        ready_contexts_.erase(ready_contexts_.begin());
        return next;
    }

    void schedule_guest_sleep(std::uint64_t microseconds) {
        state_.write_register("rax", 0);
        if (microseconds == 0) return;
        const std::uint64_t clamped = fast_forward_waits_
            ? std::min<std::uint64_t>(microseconds, 1'000ULL)
            : std::min<std::uint64_t>(
                  microseconds,
                  static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
        const auto duration = std::chrono::microseconds(static_cast<std::int64_t>(clamped));
        if (ready_contexts_.empty()) {
            std::this_thread::sleep_for(duration);
            return;
        }
        sleep_waiters_.push_back({
            {state_, active_thread_handle_},
            std::chrono::steady_clock::now() + duration});
        state_ = ready_contexts_.front().state;
        active_thread_handle_ = ready_contexts_.front().handle;
        ready_contexts_.erase(ready_contexts_.begin());
        context_switched_in_import_ = true;
    }

    bool submit_video_flip(std::uint64_t handle, std::int64_t index, std::uint64_t flip_argument = 0) {
        auto port = video_ports_.find(handle);
        if (port == video_ports_.end() || index < -1 || index >= 16) return false;
        port->second.current_buffer = static_cast<std::int32_t>(index);
        ++port->second.flip_count;
        ++gpu_flip_count_;
        trigger_flip_events(port->second, flip_argument);
        if (index < 0) return true;
        const bool should_present = gpu_flip_count_ <= 8 || (gpu_flip_count_ % 4ULL) == 0;
        if (!should_present) return true;

        const VideoBuffer& buffer = port->second.buffers[static_cast<std::size_t>(index)];
        if (buffer.address == 0 || buffer.width == 0 || buffer.height == 0 ||
            buffer.width > 8192 || buffer.height > 8192 || buffer.pitch < buffer.width) return true;
        if (gpu_renderer_ && gpu_renderer_->present(
                buffer.address,
                1280,
                720,
                latest_video_frame_,
                video_width_,
                video_height_)) {
            ++video_sequence_;
            return true;
        }
        const std::uint64_t byte_count = static_cast<std::uint64_t>(buffer.pitch) * buffer.height * 4ULL;
        if (byte_count > 256ULL * 1024ULL * 1024ULL) return true;

        const std::vector<std::uint8_t> source = memory_.read(buffer.address, static_cast<std::size_t>(byte_count));
        const std::uint32_t scale = std::max<std::uint32_t>(1, std::max(
            (buffer.width + 1279U) / 1280U,
            (buffer.height + 719U) / 720U));
        const std::uint32_t output_width = (buffer.width + scale - 1U) / scale;
        const std::uint32_t output_height = (buffer.height + scale - 1U) / scale;
        latest_video_frame_.resize(static_cast<std::size_t>(output_width) * output_height * 4ULL);
        for (std::uint32_t y = 0; y < output_height; ++y) {
            const std::uint32_t source_y = std::min(y * scale, buffer.height - 1U);
            for (std::uint32_t x = 0; x < output_width; ++x) {
                const std::uint32_t source_x = std::min(x * scale, buffer.width - 1U);
                const std::size_t source_offset =
                    (static_cast<std::size_t>(source_y) * buffer.pitch + source_x) * 4ULL;
                const std::size_t destination_offset =
                    (static_cast<std::size_t>(y) * output_width + x) * 4ULL;
                std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(source_offset), 4,
                            latest_video_frame_.begin() + static_cast<std::ptrdiff_t>(destination_offset));
            }
        }
        video_width_ = output_width;
        video_height_ = output_height;
        ++video_sequence_;
        return true;
    }

    void agc_apply_direct_register_packet(
        std::unordered_map<std::uint32_t, std::uint32_t>& registers,
        std::uint64_t packet,
        std::uint32_t length
    ) {
        if (length < 2) return;
        const std::uint32_t first = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
        for (std::uint32_t index = 0; index + 2 <= length; ++index) {
            registers[first + index] = static_cast<std::uint32_t>(memory_.read_integer(packet + 8ULL + index * 4ULL, 4));
        }
    }

    void agc_note_draw(std::uint32_t vertex_or_index_count) {
        ++gpu_draw_count_;
        gpu_last_draw_count_ = vertex_or_index_count;
        const auto gpu_register = [](const auto& registers, std::uint32_t index) {
            const auto found = registers.find(index);
            return found == registers.end() ? 0U : found->second;
        };
        const auto shader_address = [&](const SubmittedGpuState& state, std::uint32_t low, std::uint32_t high) {
            return static_cast<std::uint64_t>(gpu_register(state.sh_registers, high)) << 40U |
                static_cast<std::uint64_t>(gpu_register(state.sh_registers, low)) << 8U;
        };
        if (gpu_renderer_ && gpu_renderer_->available()) {
            const std::uint32_t target_mask = gpu_register(gpu_state_.cx_registers, 0x8E);
            const std::uint32_t target_base = gpu_register(gpu_state_.cx_registers, 0x318);
            const std::uint32_t target_base_ext = gpu_register(gpu_state_.cx_registers, 0x390);
            const std::uint32_t target_attrib2 = gpu_register(gpu_state_.cx_registers, 0x3B0);
            const std::uint32_t target_info = gpu_register(gpu_state_.cx_registers, 0x31C);
            GuestGpuDraw draw;
            draw.export_shader = shader_address(gpu_state_, 0xC8, 0xC9);
            draw.pixel_shader = shader_address(gpu_state_, 0x08, 0x09);
            draw.target_address = static_cast<std::uint64_t>(target_base_ext & 0xFFU) << 40U |
                static_cast<std::uint64_t>(target_base) << 8U;
            draw.target_width = ((target_attrib2 >> 14U) & 0x3FFFU) + 1U;
            draw.target_height = (target_attrib2 & 0x3FFFU) + 1U;
            draw.target_format = (target_info >> 2U) & 0x1FU;
            draw.target_number_type = (target_info >> 8U) & 7U;
            draw.vertex_count = vertex_or_index_count;
            draw.instance_count = gpu_state_.instance_count;
            draw.primitive_type = gpu_register(gpu_state_.uc_registers, 0x242);
            draw.blend_control = gpu_register(gpu_state_.cx_registers, 0x1E0);
            draw.color_write_mask = target_mask & 0xFU;
            for (std::uint32_t index = 0;
                 index < static_cast<std::uint32_t>(draw.pixel_scalar_registers.size()); ++index) {
                draw.pixel_scalar_registers[index] = gpu_register(gpu_state_.sh_registers, 0x0CU + index);
            }
            for (std::uint32_t index = 0;
                 index + 8U < static_cast<std::uint32_t>(draw.export_scalar_registers.size()); ++index) {
                draw.export_scalar_registers[index + 8U] = gpu_register(gpu_state_.sh_registers, 0x8CU + index);
            }
            draw.pixel_scalar_registers[126] = 0xFFFFFFFFU;
            draw.export_scalar_registers[126] = 0xFFFFFFFFU;
            const float viewport_x_scale = std::bit_cast<float>(gpu_register(gpu_state_.cx_registers, 0x10F));
            const float viewport_x_offset = std::bit_cast<float>(gpu_register(gpu_state_.cx_registers, 0x110));
            const float viewport_y_scale = std::bit_cast<float>(gpu_register(gpu_state_.cx_registers, 0x111));
            const float viewport_y_offset = std::bit_cast<float>(gpu_register(gpu_state_.cx_registers, 0x112));
            if (std::isfinite(viewport_x_scale) && std::isfinite(viewport_x_offset) &&
                std::isfinite(viewport_y_scale) && std::isfinite(viewport_y_offset) &&
                viewport_x_scale > 0.0F && viewport_y_scale != 0.0F) {
                draw.viewport_x = viewport_x_offset - viewport_x_scale;
                draw.viewport_y = viewport_y_offset - viewport_y_scale;
                draw.viewport_width = viewport_x_scale * 2.0F;
                draw.viewport_height = viewport_y_scale * 2.0F;
                draw.has_viewport = true;
            }
            gpu_renderer_->submit(
                draw,
                [&](std::uint64_t address, std::size_t length) {
                    return memory_.read(address, length, std::nullopt);
                },
                [&](std::uint64_t address, std::size_t length) {
                    return memory_.revision(address, length);
                });
        }
        if (gpu_draw_captures_.size() >= 2048) return;
        const auto signature = [&](const SubmittedGpuState& state) {
            return std::array<std::uint64_t, 9>{
                shader_address(state, 0xC8, 0xC9),
                shader_address(state, 0x08, 0x09),
                gpu_register(state.uc_registers, 0x242),
                gpu_register(state.cx_registers, 0x8E),
                static_cast<std::uint64_t>(gpu_register(state.cx_registers, 0x390) & 0xFFU) << 40U |
                    static_cast<std::uint64_t>(gpu_register(state.cx_registers, 0x318)) << 8U,
                gpu_register(state.cx_registers, 0x31C),
                gpu_register(state.cx_registers, 0x3B0),
                gpu_register(state.cx_registers, 0x3B8),
                state.index_size,
            };
        };
        const auto current_signature = signature(gpu_state_);
        const bool already_captured = std::any_of(
            gpu_draw_captures_.begin(),
            gpu_draw_captures_.end(),
            [&](const CapturedGpuDraw& capture) { return signature(capture.state) == current_signature; }
        );
        if (!already_captured) {
            gpu_draw_captures_.push_back({gpu_draw_count_, vertex_or_index_count, gpu_state_});
        }
    }

    static std::uint32_t agc_modifier_base(std::uint64_t modifier) {
        const std::uint32_t mode = static_cast<std::uint32_t>(modifier >> 29U);
        return ((((mode - 3U) & 0xFFFFFFFDU) == 0U) ? 0x80U : 0U) + 0x8CU;
    }

    static std::uint64_t agc_encode_draw_modifier(std::uint64_t modifier, bool indexed_multi) {
        const std::uint32_t base = agc_modifier_base(modifier);
        std::uint64_t encoded = (modifier & 1U) != 0
            ? base + static_cast<std::uint32_t>((modifier >> 9U) & 0x1FU)
            : 0x280ULL;
        encoded |= (modifier & 4U) != 0
            ? static_cast<std::uint64_t>(base + static_cast<std::uint32_t>((modifier >> 19U) & 0x1FU)) << 32U
            : 0x28000000000ULL;
        if (indexed_multi && (modifier & 2U) != 0) {
            encoded |= static_cast<std::uint64_t>(base + static_cast<std::uint32_t>((modifier >> 14U) & 0x1FU)) << 16U;
            encoded |= 0x0800000000000000ULL;
        }
        return encoded;
    }

    static std::uint32_t agc_draw_modifier_word(std::uint64_t modifier) {
        return ((modifier & 0x100000000ULL) == 0
            ? static_cast<std::uint32_t>(modifier >> 3U) & 0x20U
            : 0U) | 2U;
    }

    bool agc_compare_branch(
        std::uint32_t function,
        std::uint64_t address,
        std::uint64_t mask,
        std::uint64_t reference
    ) {
        if (function == 0) return true;
        const std::uint64_t value = memory_.read_integer(address, 8) & mask;
        reference &= mask;
        switch (function & 7U) {
            case 1: return value < reference;
            case 2: return value <= reference;
            case 3: return value == reference;
            case 4: return value != reference;
            case 5: return value >= reference;
            case 6: return value > reference;
            default: return true;
        }
    }

    void agc_parse_dcb(std::uint64_t command_address, std::uint32_t dword_count, std::uint32_t depth = 0) {
        if (command_address == 0 || dword_count == 0 || dword_count > 16U * 1024U * 1024U || depth > 8) return;
        std::uint32_t offset = 0;
        while (offset < dword_count) {
            const std::uint64_t packet = command_address + static_cast<std::uint64_t>(offset) * 4ULL;
            const std::uint32_t header = static_cast<std::uint32_t>(memory_.read_integer(packet, 4));
            if ((header >> 30U) != 3U) {
                ++offset;
                continue;
            }
            const std::uint32_t length = ((header >> 16U) & 0x3FFFU) + 2U;
            if (length < 2 || length > dword_count - offset) break;
            const std::uint32_t operation = (header >> 8U) & 0xFFU;
            const std::uint32_t packet_register = (header >> 2U) & 0x3FU;
            ++agc_packet_counts_[(operation << 8U) | packet_register];

            if (operation == 0x10U) {
                if ((packet_register == 0x11U || packet_register == 0x12U || packet_register == 0x13U) && length >= 4) {
                    const std::uint32_t count = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
                    const std::uint64_t registers = memory_.read_integer(packet + 8, 8);
                    auto& destination = packet_register == 0x11U ? gpu_state_.sh_registers
                        : packet_register == 0x12U ? gpu_state_.cx_registers
                        : gpu_state_.uc_registers;
                    agc_copy_registers(destination, registers, count);
                } else if (packet_register == 0x17U && length >= 6) {
                    const std::uint64_t handle = memory_.read_integer(packet + 4, 4);
                    const std::int64_t buffer_index = static_cast<std::int32_t>(memory_.read_integer(packet + 8, 4));
                    submit_video_flip(handle, buffer_index);
                } else if (packet_register == 0x04U && length >= 2) {
                    agc_note_draw(static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4)));
                } else if (packet_register == 0x05U) {
                    gpu_state_ = {};
                }
            } else if (operation == 0x69U) {
                agc_apply_direct_register_packet(gpu_state_.cx_registers, packet, length);
            } else if (operation == 0x76U) {
                agc_apply_direct_register_packet(gpu_state_.sh_registers, packet, length);
            } else if (operation == 0x79U) {
                agc_apply_direct_register_packet(gpu_state_.uc_registers, packet, length);
            } else if (operation == 0x26U && length >= 3) {
                gpu_state_.index_buffer = memory_.read_integer(packet + 4, 8);
            } else if (operation == 0x13U && length >= 2) {
                gpu_state_.index_count = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
            } else if (operation == 0x2AU && length >= 2) {
                gpu_state_.index_size = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
            } else if (operation == 0x2FU && length >= 2) {
                gpu_state_.instance_count = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
            } else if (operation == 0x2DU && length >= 2) {
                agc_note_draw(static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4)));
            } else if ((operation == 0x27U || operation == 0x35U) && length >= 2) {
                agc_note_draw(static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4)));
            } else if (operation == 0x3AU && length >= 9) {
                agc_note_draw(static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4)));
                gpu_state_.index_buffer = memory_.read_integer(packet + 8, 8);
                gpu_state_.instance_count = static_cast<std::uint32_t>(memory_.read_integer(packet + 16, 4));
            } else if (operation == 0x38U && length >= 10) {
                agc_note_draw(static_cast<std::uint32_t>(memory_.read_integer(packet + 20, 4)));
            } else if (operation == 0x40U && length >= 6) {
                const std::uint32_t control = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
                const std::uint32_t source_selector = ((control & 0xFU) << 1U) | ((control >> 30U) & 1U);
                const std::uint32_t destination_selector = ((control >> 8U) & 0xFU) << 1U;
                const std::uint64_t source = memory_.read_integer(packet + 8, 8);
                const std::uint64_t destination = memory_.read_integer(packet + 16, 8);
                const std::size_t bytes = ((control >> 25U) & 3U) == 0 ? 4U : 8U;
                if (destination != 0 && (destination_selector == 2U || destination_selector == 4U)) {
                    if (source_selector == 5U) {
                        memory_.write_integer(destination, bytes, source);
                    } else if (source != 0 && (source_selector == 2U || source_selector == 4U)) {
                        memory_.write(destination, memory_.read(source, bytes));
                    }
                }
            } else if (operation == 0x24U) {
                // DRAW_INDIRECT. The vertex count lives in the indirect argument buffer,
                // whose base is configured separately; still account for the submitted draw.
                agc_note_draw(0);
            } else if (operation == 0x22U && length >= 5) {
                // COND_EXEC skips the following packet words while the guest predicate is zero.
                const std::uint64_t predicate = memory_.read_integer(packet + 4, 8) & 0x0000FFFFFFFFFFFFULL;
                const std::uint32_t conditional_count =
                    static_cast<std::uint32_t>(memory_.read_integer(packet + 16, 4) & 0x3FFFU);
                if (predicate != 0 && memory_.read_integer(predicate, 4) == 0) {
                    offset += std::min(conditional_count, dword_count - offset - length);
                }
            } else if (operation == 0x3FU && length == 4) {
                const std::uint64_t nested = memory_.read_integer(packet + 4, 8) & 0x0000FFFFFFFFFFFFULL;
                const std::uint32_t nested_count = static_cast<std::uint32_t>(memory_.read_integer(packet + 12, 4) & 0xFFFFFU);
                agc_parse_dcb(nested, nested_count, depth + 1);
            } else if (operation == 0x3FU && length >= 14) {
                const std::uint32_t control = static_cast<std::uint32_t>(memory_.read_integer(packet + 4, 4));
                const bool first = agc_compare_branch(
                    (control >> 8U) & 7U, memory_.read_integer(packet + 8, 8),
                    memory_.read_integer(packet + 16, 8), memory_.read_integer(packet + 24, 8));
                const std::uint64_t nested = memory_.read_integer(packet + (first ? 32ULL : 44ULL), 8);
                const std::uint32_t nested_count = static_cast<std::uint32_t>(
                    memory_.read_integer(packet + (first ? 40ULL : 52ULL), 4) & 0xFFFFFU);
                agc_parse_dcb(nested, nested_count, depth + 1);
            }
            offset += length;
        }
    }

    bool agc_submit_direct(std::uint64_t commands, std::uint32_t dword_count) {
        if (commands == 0 || dword_count == 0 || dword_count > 16U * 1024U * 1024U) return false;
        agc_parse_dcb(commands, dword_count);
        ++gpu_submit_count_;
        return true;
    }

    void handle_import(std::uint32_t index) {
        ++intercepted_imports_;
        const auto found = imports_.find(index);
        const std::string symbol = found == imports_.end() ? "<unknown:#" + std::to_string(index) + ">" : found->second;
        last_import_by_thread_[active_thread_handle_] = symbol;
        remember(recent_imports_, "#" + std::to_string(index) + " " + symbol, 128);
        if (std::find(observed_imports_.begin(), observed_imports_.end(), symbol) == observed_imports_.end()) {
            observed_imports_.push_back(symbol);
        }

        // Core C/C++ runtime services needed before platform HLE starts.
        if (symbol == "cfAXurvfl5o") {  // __cxa_allocate_exception
            state_.write_register("rax", allocate(state_.read_register("rdi"), 16));
        } else if (symbol == "gQX+4GDQjpM" || symbol == "fJnpuVVBbKk" ||
                   symbol == "hdm0YfMa7TQ" || symbol == "ryUxD-60bKM") {
            state_.write_register("rax", allocate(state_.read_register("rdi"), 16));
        } else if (symbol == "2Btkg8k24Zg" || symbol == "Ujf3KzMvRmI") {
            state_.write_register("rax", allocate(state_.read_register("rsi"), state_.read_register("rdi")));
        } else if (symbol == "OJjm-QOIHlI") {
            state_.write_register("rax", allocate(state_.read_register("rsi"), 16));
        } else if (symbol == "iF1iQHzxBJU") {
            state_.write_register("rax", allocate(state_.read_register("rdx"), state_.read_register("rsi")));
        } else if (symbol == "LYo3GhIlB38") {
            state_.write_register("rax", allocate(state_.read_register("rsi") * state_.read_register("rdx"), 16));
        } else if (symbol == "2X5agFjKxMc") {
            state_.write_register("rax", allocate(state_.read_register("rdi") * state_.read_register("rsi"), 16));
        } else if (symbol == "Y7aJ1uydPMo" || symbol == "gigoVHZvVPE" || symbol == "OGybVuPAhAY") {
            const std::uint64_t old_pointer = symbol == "gigoVHZvVPE" ? state_.read_register("rsi") : state_.read_register("rdi");
            const std::uint64_t new_size = symbol == "gigoVHZvVPE" ? state_.read_register("rdx") : state_.read_register("rsi");
            const std::uint64_t pointer = allocate(new_size, 16);
            if (const auto old = allocations_.find(old_pointer); old_pointer != 0 && old != allocations_.end()) {
                const std::size_t copy_size = static_cast<std::size_t>(std::min(old->second, new_size));
                memory_.write(pointer, memory_.read(old_pointer, copy_size));
            }
            state_.write_register("rax", pointer);
        } else if (symbol == "cVSk9y8URbc") {
            const std::uint64_t pointer = allocate(state_.read_register("rdx"), state_.read_register("rsi"));
            memory_.write_integer(state_.read_register("rdi"), 8, pointer);
            state_.write_register("rax", 0);
        } else if (symbol == "pO96TwzOm5E") {  // sceKernelGetDirectMemorySize
            state_.write_register("rax", 16ULL * 1024ULL * 1024ULL * 1024ULL);
        } else if (symbol == "rTXw65xmLIA") {  // sceKernelAllocateDirectMemory
            const std::uint64_t output = state_.read_register("r9");
            if (output != 0) {
                memory_.write_integer(output, 8, 0);
                state_.write_register("rax", 0);
            } else state_.write_register("rax", ~0ULL);
        } else if (symbol == "L-Q3LEjIbgA" || symbol == "NcaWUxfMNIQ") {  // sceKernelMapDirectMemory
            const std::uint64_t output = state_.read_register("rdi");
            const std::uint64_t length = state_.read_register("rsi");
            if (output != 0 && length > 0) {
                const std::uint64_t pointer = allocate(length, std::max<std::uint64_t>(state_.read_register("r9"), kPageSize));
                memory_.write_integer(output, 8, pointer);
                state_.write_register("rax", 0);
            } else state_.write_register("rax", ~0ULL);
        } else if (symbol == "CdWp0oHWGr0") {  // sceUserServiceGetInitialUser
            const std::uint64_t output = state_.read_register("rdi");
            if (output == 0) state_.write_register("rax", ~0ULL);
            else {
                memory_.write_integer(output, 4, 1000);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "fPhymKNvK-A") {  // sceUserServiceGetLoginUserIdList
            const std::uint64_t output = state_.read_register("rdi");
            if (output == 0) state_.write_register("rax", ~0ULL);
            else {
                memory_.write_integer(output + 0, 4, 1000);
                memory_.write_integer(output + 4, 4, 0xFFFFFFFFU);
                memory_.write_integer(output + 8, 4, 0xFFFFFFFFU);
                memory_.write_integer(output + 12, 4, 0xFFFFFFFFU);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "dyIhnXq-0SM") {  // sceSaveDataDirNameSearch
            const std::uint64_t result = state_.read_register("rsi");
            if (result == 0) state_.write_register("rax", ~0ULL);
            else {
                // Preserve the caller-owned pointer fields while reporting an empty search.
                memory_.write_integer(result + 0x00, 4, 0);
                memory_.write_integer(result + 0x14, 4, 0);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "ZP4e7rlzOUk") {  // sceSaveDataMount3
            const std::uint64_t result = state_.read_register("rsi");
            if (result == 0) state_.write_register("rax", ~0ULL);
            else {
                memory_.write(result, std::vector<std::uint8_t>(0x40, 0));
                static constexpr char kMountPoint[] = "/savedata0";
                memory_.write(result, reinterpret_cast<const std::uint8_t*>(kMountPoint), sizeof(kMountPoint));
                memory_.write_integer(result + 0x1C, 4, 1);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "gjRZNnw0JPE") {  // sceSaveDataCreateTransactionResource
            state_.write_register("rax", next_transaction_resource_++);
        } else if (symbol == "TywrFKCoLGY" || symbol == "lJUQuaKqoKY" ||
                   symbol == "sDCBrmc61XU" || symbol == "ie7qhZ4X0Cc" ||
                   symbol == "uW4vfTwMQVo" || symbol == "BMR4F-Uek3E" ||
                   symbol == "85zul--eGXs" || symbol == "c88Yy54Mx0w") {
            // Initialization, transaction cleanup, prepare/commit, unmount,
            // parameter, and icon writes have no output required by the title.
            state_.write_register("rax", 0);
        } else if (symbol == "D0OdFMjp46I") {  // sceKernelCreateEqueue
            const std::uint64_t output = state_.read_register("rdi");
            if (output == 0) state_.write_register("rax", kOrbisErrorInvalidArgument);
            else {
                try {
                    const std::uint64_t handle = next_event_queue_handle_++;
                    event_queues_[handle] = {};
                    memory_.write_integer(output, 8, handle);
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "fzyMKs9kim0") {  // sceKernelWaitEqueue
            const std::uint64_t handle = state_.read_register("rdi");
            const std::uint64_t events_address = state_.read_register("rsi");
            const std::uint64_t capacity_raw = state_.read_register("rdx");
            const std::uint64_t out_count_address = state_.read_register("rcx");
            const std::uint64_t timeout_address = state_.read_register("r8");
            auto queue = event_queues_.find(handle);
            if (queue == event_queues_.end()) {
                state_.write_register("rax", kOrbisErrorNotFound);
            } else if (events_address == 0 || capacity_raw == 0 || capacity_raw > 0x1000ULL) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else {
                std::size_t delivered = 0;
                if (!dequeue_event_queue(
                        queue->second,
                        events_address,
                        static_cast<std::uint32_t>(capacity_raw),
                        out_count_address,
                        delivered)) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                } else if (delivered > 0) {
                    state_.write_register("rax", 0);
                } else {
                    std::uint64_t timeout_microseconds = 0;
                    if (timeout_address != 0) {
                        try {
                            timeout_microseconds = memory_.read_integer(timeout_address, 8);
                        } catch (const std::exception&) {
                            state_.write_register("rax", kOrbisErrorMemoryFault);
                            return;
                        }
                    }
                    if (timeout_address != 0 && timeout_microseconds == 0) {
                        state_.write_register("rax", kOrbisErrorTimedOut);
                    } else if (ready_contexts_.empty()) {
                        state_.write_register("rax", kOrbisErrorTimedOut);
                    } else {
                        state_.write_register("rax", 0);
                        EventQueueWaiter waiter;
                        waiter.context = {state_, active_thread_handle_};
                        waiter.events_address = events_address;
                        waiter.capacity = static_cast<std::uint32_t>(capacity_raw);
                        waiter.out_count_address = out_count_address;
                        waiter.timed = timeout_address != 0;
                        if (waiter.timed) {
                            const std::uint64_t clamped = std::min<std::uint64_t>(
                                timeout_microseconds,
                                static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()));
                            waiter.deadline = std::chrono::steady_clock::now() +
                                std::chrono::microseconds(static_cast<std::int64_t>(clamped));
                        }
                        queue->second.waiters.push_back(std::move(waiter));
                        state_ = ready_contexts_.front().state;
                        active_thread_handle_ = ready_contexts_.front().handle;
                        ready_contexts_.erase(ready_contexts_.begin());
                        context_switched_in_import_ = true;
                    }
                }
            }
        } else if (symbol == "Up36PTk687E") {  // sceVideoOutOpen
            const std::uint64_t handle = next_video_handle_++;
            video_ports_[handle] = {};
            state_.write_register("rax", handle);
        } else if (symbol == "uquVH4-Du78") {  // sceVideoOutClose
            video_ports_.erase(state_.read_register("rdi"));
            state_.write_register("rax", 0);
        } else if (symbol == "HXzjK9yI30k") {  // sceVideoOutAddFlipEvent
            const std::uint64_t event_queue = state_.read_register("rdi");
            const std::uint64_t handle = state_.read_register("rsi");
            const std::uint64_t user_data = state_.read_register("rdx");
            auto port = video_ports_.find(handle);
            if (port == video_ports_.end() || !event_queues_.contains(event_queue)) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else {
                auto registration = std::find_if(
                    port->second.flip_events.begin(), port->second.flip_events.end(),
                    [event_queue](const FlipEventRegistration& item) {
                        return item.event_queue == event_queue;
                    });
                if (registration == port->second.flip_events.end()) {
                    port->second.flip_events.push_back({event_queue, user_data});
                } else {
                    registration->user_data = user_data;
                }
                state_.write_register("rax", 0);
            }
        } else if (symbol == "CBiu4mCE1DA" || symbol == "+I4K03i3EL0" || symbol == "w0hLuNarQxY" ||
                   symbol == "DYhhWbJSeRg" || symbol == "pv9CI5VC+R0" || symbol == "MTxxrOCeSig") {
            state_.write_register("rax", 0);
        } else if (symbol == "PjS5uASwcV8") {  // sceVideoOutSetBufferAttribute2
            const std::uint64_t attribute = state_.read_register("rdi");
            if (attribute == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                memory_.write(attribute, std::vector<std::uint8_t>(0x50, 0));
                memory_.write_integer(attribute + 0x04, 4, state_.read_register("rdx"));
                memory_.write_integer(attribute + 0x0C, 4, state_.read_register("rcx"));
                memory_.write_integer(attribute + 0x10, 4, state_.read_register("r8"));
                memory_.write_integer(attribute + 0x18, 8, state_.read_register("r9"));
                memory_.write_integer(attribute + 0x20, 8, state_.read_register("rsi"));
                memory_.write_integer(attribute + 0x28, 8, memory_.read_integer(state_.read_register("rsp") + 0x08, 8));
                memory_.write_integer(attribute + 0x30, 4, memory_.read_integer(state_.read_register("rsp"), 4));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "i6-sR91Wt-4") {  // sceVideoOutSetBufferAttribute
            const std::uint64_t attribute = state_.read_register("rdi");
            if (attribute == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                memory_.write(attribute, std::vector<std::uint8_t>(0x28, 0));
                memory_.write_integer(attribute + 0x00, 4, state_.read_register("rsi"));
                memory_.write_integer(attribute + 0x04, 4, state_.read_register("rdx"));
                memory_.write_integer(attribute + 0x08, 4, state_.read_register("rcx"));
                memory_.write_integer(attribute + 0x0C, 4, state_.read_register("r8"));
                memory_.write_integer(attribute + 0x10, 4, state_.read_register("r9"));
                memory_.write_integer(attribute + 0x14, 4, memory_.read_integer(state_.read_register("rsp"), 4));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "rKBUtgRrtbk" || symbol == "w3BY+tAEiQY") {  // register display buffers
            const std::uint64_t handle = state_.read_register("rdi");
            auto port = video_ports_.find(handle);
            const bool extended = symbol == "rKBUtgRrtbk";
            const std::uint64_t first = extended ? state_.read_register("rdx") : state_.read_register("rsi");
            const std::uint64_t addresses = extended ? state_.read_register("rcx") : state_.read_register("rdx");
            const std::uint64_t count = extended ? state_.read_register("r8") : state_.read_register("rcx");
            const std::uint64_t attribute = extended ? state_.read_register("r9") : state_.read_register("r8");
            if (port == video_ports_.end() || addresses == 0 || attribute == 0 || count == 0 || first + count > 16) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint32_t tiling = static_cast<std::uint32_t>(memory_.read_integer(attribute + 0x04, 4));
                const std::uint32_t width = static_cast<std::uint32_t>(memory_.read_integer(attribute + 0x0C, 4));
                const std::uint32_t height = static_cast<std::uint32_t>(memory_.read_integer(attribute + 0x10, 4));
                const std::uint64_t pixel_format = memory_.read_integer(attribute + (extended ? 0x20 : 0x00), extended ? 8 : 4);
                const std::uint32_t pitch = extended ? width : static_cast<std::uint32_t>(memory_.read_integer(attribute + 0x14, 4));
                for (std::uint64_t index = 0; index < count; ++index) {
                    const std::uint64_t entry = addresses + index * (extended ? 0x20ULL : 8ULL);
                    port->second.buffers[first + index] = {
                        memory_.read_integer(entry, 8), pixel_format, tiling, width, height, pitch == 0 ? width : pitch};
                }
                state_.write_register("rax", extended ? state_.read_register("rsi") : 0);
            }
        } else if (symbol == "N5KDtkIjjJ4") {  // sceVideoOutUnregisterBuffers
            auto port = video_ports_.find(state_.read_register("rdi"));
            const std::uint64_t first = state_.read_register("rsi");
            const std::uint64_t count = state_.read_register("rdx");
            if (port != video_ports_.end() && first + count <= 16) {
                for (std::uint64_t index = 0; index < count; ++index) port->second.buffers[first + index] = {};
            }
            state_.write_register("rax", 0);
        } else if (symbol == "U46NwOiJpys") {  // sceVideoOutSubmitFlip
            const std::int64_t index = static_cast<std::int64_t>(state_.read_register("rsi"));
            state_.write_register("rax", submit_video_flip(
                state_.read_register("rdi"), index, state_.read_register("rcx")) ? 0 : ~0ULL);
        } else if (symbol == "SbU3dwp80lQ") {  // sceVideoOutGetFlipStatus
            auto port = video_ports_.find(state_.read_register("rdi"));
            const std::uint64_t output = state_.read_register("rsi");
            if (port == video_ports_.end() || output == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                memory_.write(output, std::vector<std::uint8_t>(40, 0));
                memory_.write_integer(output + 0x00, 8, port->second.flip_count);
                memory_.write_integer(output + 0x20, 8, static_cast<std::uint32_t>(port->second.current_buffer));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "zgXifHT9ErY") {  // sceVideoOutIsFlipPending
            state_.write_register("rax", 0);
        } else if (symbol == "188x57JYp0g") {  // sceKernelCreateSema
            const std::uint64_t output = state_.read_register("rdi");
            const std::int64_t initial = static_cast<std::int64_t>(state_.read_register("rcx"));
            const std::int64_t maximum = static_cast<std::int64_t>(state_.read_register("r8"));
            if (output == 0 || initial < 0 || maximum <= 0 || initial > maximum) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t handle = next_semaphore_handle_++;
                semaphores_[handle] = {initial, maximum};
                memory_.write_integer(output, 4, handle);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "Zxa0VhQVTsk" || symbol == "12wOHk8ywb0") {  // wait / poll semaphore
            const std::uint64_t handle = state_.read_register("rdi");
            const std::int64_t need = static_cast<std::int64_t>(state_.read_register("rsi"));
            const auto semaphore = semaphores_.find(handle);
            if (semaphore == semaphores_.end() || need <= 0 || need > semaphore->second.maximum) {
                state_.write_register("rax", ~0ULL);
            } else if (semaphore->second.count >= need) {
                semaphore->second.count -= need;
                state_.write_register("rax", 0);
            } else if (symbol == "12wOHk8ywb0" || ready_contexts_.empty()) {
                state_.write_register("rax", ~0ULL);
            } else {
                state_.write_register("rax", 0);
                semaphore_waiters_[handle].push_back({{state_, active_thread_handle_}, need});
                state_ = ready_contexts_.front().state;
                active_thread_handle_ = ready_contexts_.front().handle;
                ready_contexts_.erase(ready_contexts_.begin());
                context_switched_in_import_ = true;
            }
        } else if (symbol == "4czppHBiriw") {  // sceKernelSignalSema
            const std::uint64_t handle = state_.read_register("rdi");
            const std::int64_t signal = static_cast<std::int64_t>(state_.read_register("rsi"));
            const auto semaphore = semaphores_.find(handle);
            if (semaphore == semaphores_.end() || signal <= 0 || semaphore->second.count > semaphore->second.maximum - signal) {
                state_.write_register("rax", ~0ULL);
            } else {
                semaphore->second.count += signal;
                if (auto waiters = semaphore_waiters_.find(handle); waiters != semaphore_waiters_.end()) {
                    for (auto waiter = waiters->second.begin(); waiter != waiters->second.end();) {
                        if (semaphore->second.count < waiter->need) {
                            ++waiter;
                            continue;
                        }
                        semaphore->second.count -= waiter->need;
                        ready_contexts_.push_back(std::move(waiter->context));
                        waiter = waiters->second.erase(waiter);
                    }
                    if (waiters->second.empty()) semaphore_waiters_.erase(waiters);
                }
                state_.write_register("rax", 0);
            }
        } else if (symbol == "4DM06U2BNEY" || symbol == "R1Jvn8bSCW8") {  // cancel / delete semaphore
            const std::uint64_t handle = state_.read_register("rdi");
            if (auto waiters = semaphore_waiters_.find(handle); waiters != semaphore_waiters_.end()) {
                for (SemaphoreWaiter& waiter : waiters->second) {
                    waiter.context.state.write_register("rax", ~0ULL);
                    ready_contexts_.push_back(std::move(waiter.context));
                }
                semaphore_waiters_.erase(waiters);
            }
            if (symbol == "R1Jvn8bSCW8") semaphores_.erase(handle);
            state_.write_register("rax", 0);
        } else if (symbol == "nsYoNRywwNg") {  // scePthreadAttrInit
            const std::uint64_t address = state_.read_register("rdi");
            if (address == 0) state_.write_register("rax", ~0ULL);
            else {
                const std::uint64_t handle = allocate(0x40, 16);
                memory_.write_integer(address, 8, handle);
                pthread_attributes_[address] = {};
                pthread_attributes_[handle] = {};
                state_.write_register("rax", 0);
            }
        } else if (symbol == "62KCwEMmzcM") {  // scePthreadAttrDestroy
            const std::uint64_t address = state_.read_register("rdi");
            if (address == 0) state_.write_register("rax", ~0ULL);
            else {
                const std::uint64_t resolved = resolve_pthread_attribute(address);
                pthread_attributes_.erase(address);
                pthread_attributes_.erase(resolved);
                memory_.write_integer(address, 8, 0);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "x1X76arYMxU") {  // scePthreadAttrGet
            const std::uint64_t output = state_.read_register("rsi");
            if (state_.read_register("rdi") == 0 || output == 0) state_.write_register("rax", ~0ULL);
            else {
                pthread_attributes_[output] = {};
                state_.write_register("rax", 0);
            }
        } else if (symbol == "-Wreprtu0Qs") {  // scePthreadAttrSetdetachstate
            const std::uint64_t address = state_.read_register("rdi");
            if (address == 0) state_.write_register("rax", ~0ULL);
            else {
                pthread_attributes_[resolve_pthread_attribute(address)].detach_state =
                    static_cast<std::int32_t>(state_.read_register("rsi"));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "UTXzJbWhhTE") {  // scePthreadAttrSetstacksize
            const std::uint64_t address = state_.read_register("rdi");
            if (address == 0) state_.write_register("rax", ~0ULL);
            else {
                pthread_attributes_[resolve_pthread_attribute(address)].stack_size = state_.read_register("rsi");
                state_.write_register("rax", 0);
            }
        } else if (symbol == "DzES9hQF4f4") {  // scePthreadAttrSetschedparam
            const std::uint64_t address = state_.read_register("rdi");
            const std::uint64_t parameter = state_.read_register("rsi");
            if (address == 0 || parameter == 0) state_.write_register("rax", ~0ULL);
            else {
                pthread_attributes_[resolve_pthread_attribute(address)].schedule_priority =
                    static_cast<std::int32_t>(memory_.read_integer(parameter, 4));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "-quPa4SEJUw") {  // scePthreadAttrGetstack
            const std::uint64_t address = state_.read_register("rdi");
            const std::uint64_t stack_output = state_.read_register("rsi");
            const std::uint64_t size_output = state_.read_register("rdx");
            if (address == 0 || stack_output == 0 || size_output == 0) state_.write_register("rax", ~0ULL);
            else {
                const PthreadAttribute& attribute = pthread_attributes_[resolve_pthread_attribute(address)];
                memory_.write_integer(stack_output, 8, attribute.stack_address);
                memory_.write_integer(size_output, 8, attribute.stack_size);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "cmo1RIYva9o" || symbol == "ttHNfU+qDBU") {  // pthread mutex init
            const std::uint64_t address = state_.read_register("rdi");
            mutexes_[address] = {};
            state_.write_register("rax", 0);
        } else if (symbol == "2Of0f+3mhhE" || symbol == "ltCfaGr2JGE") {  // pthread mutex destroy
            mutexes_.erase(state_.read_register("rdi"));
            state_.write_register("rax", 0);
        } else if (symbol == "9UK1vLZQft4" || symbol == "7H0iTOciTLo" ||
                   symbol == "upoVrzMHFeE" || symbol == "K-jXhbt2gn4") {  // pthread mutex lock / trylock
            const std::uint64_t address = state_.read_register("rdi");
            MutexState& mutex = mutexes_[address];
            if (mutex.owner == 0 || mutex.owner == active_thread_handle_) {
                mutex.owner = active_thread_handle_;
                ++mutex.recursion;
                state_.write_register("rax", 0);
            } else if (symbol == "upoVrzMHFeE" || symbol == "K-jXhbt2gn4" || ready_contexts_.empty()) {
                state_.write_register("rax", ~0ULL);
            } else {
                state_.write_register("rax", 0);
                mutex.waiters.push_back({state_, active_thread_handle_});
                state_ = ready_contexts_.front().state;
                active_thread_handle_ = ready_contexts_.front().handle;
                ready_contexts_.erase(ready_contexts_.begin());
                context_switched_in_import_ = true;
            }
        } else if (symbol == "tn3VlD0hG60" || symbol == "2Z+PpY6CaJg") {  // pthread mutex unlock
            const std::uint64_t address = state_.read_register("rdi");
            MutexState& mutex = mutexes_[address];
            if (mutex.owner == active_thread_handle_ && mutex.recursion > 0) {
                if (--mutex.recursion == 0) {
                    mutex.owner = 0;
                    if (!mutex.waiters.empty()) {
                        RunnableContext waiter = std::move(mutex.waiters.front());
                        mutex.waiters.erase(mutex.waiters.begin());
                        mutex.owner = waiter.handle;
                        mutex.recursion = 1;
                        ready_contexts_.push_back(std::move(waiter));
                    }
                }
            }
            state_.write_register("rax", 0);
        } else if (symbol == "F8bUHwAG284" || symbol == "smWEktiyyG0" ||
                   symbol == "iMp8QpE+XO4" || symbol == "1FGvU0i9saQ" ||
                   symbol == "dQHWEsJtoE4" || symbol == "HF7lK46xzjY" ||
                   symbol == "mDmgMOGVUqg" || symbol == "5txKfcMUAok") {
            state_.write_register("rax", 0);
        } else if (symbol == "2Tb92quprl0" || symbol == "0TyVk4MSLt0") {  // pthread condition init
            condition_waiters_[state_.read_register("rdi")];
            state_.write_register("rax", 0);
        } else if (symbol == "g+PZd2hiacg") {  // pthread condition destroy
            condition_waiters_.erase(state_.read_register("rdi"));
            state_.write_register("rax", 0);
        } else if (symbol == "WKAXJ4XBPQ4" || symbol == "BmMjYxmew1w" ||
                   symbol == "27bAgiJmOh0" || symbol == "Op8TBGY5KHg") {  // pthread condition wait
            const std::uint64_t condition = state_.read_register("rdi");
            const std::uint64_t mutex_address = state_.read_register("rsi");
            const bool timed = symbol == "BmMjYxmew1w" || symbol == "27bAgiJmOh0";
            const std::uint64_t raw_timeout = timed ? state_.read_register("rdx") : 0;
            const std::int64_t signed_timeout = static_cast<std::int32_t>(raw_timeout & 0xFFFFFFFFULL);
            const bool bounded_spurious_wait = timed && signed_timeout < 0;
            const std::uint64_t timeout_microseconds = bounded_spurious_wait
                ? 1'000'000ULL
                : raw_timeout;
            if (timed) {
                ++condition_timed_wait_count_;
                if (condition_timed_wait_count_ <= 32) {
                    __android_log_print(
                        ANDROID_LOG_INFO,
                        "VibeStation5Runtime",
                        "condition timed wait=%llu cond=0x%llx mutex=0x%llx rawTimeout=%lld timeoutUsec=%llu",
                        static_cast<unsigned long long>(condition_timed_wait_count_),
                        static_cast<unsigned long long>(condition),
                        static_cast<unsigned long long>(mutex_address),
                        static_cast<long long>(signed_timeout),
                        static_cast<unsigned long long>(timeout_microseconds));
                }
            }
            MutexState& mutex = mutexes_[mutex_address];
            if (mutex.owner == active_thread_handle_) {
                mutex.owner = 0;
                mutex.recursion = 0;
                if (!mutex.waiters.empty()) {
                    RunnableContext waiter = std::move(mutex.waiters.front());
                    mutex.waiters.erase(mutex.waiters.begin());
                    mutex.owner = waiter.handle;
                    mutex.recursion = 1;
                    ready_contexts_.push_back(std::move(waiter));
                }
            }
            if (timed && timeout_microseconds == 0) {
                if (mutex.owner == 0) {
                    mutex.owner = active_thread_handle_;
                    mutex.recursion = 1;
                }
                state_.write_register("rax", kOrbisErrorTimedOut);
            } else if (ready_contexts_.empty()) {
                if (timed) {
                    if (mutex.owner == 0) {
                        mutex.owner = active_thread_handle_;
                        mutex.recursion = 1;
                    }
                    state_.write_register("rax", bounded_spurious_wait ? 0 : kOrbisErrorTimedOut);
                } else {
                    state_.write_register("rax", ~0ULL);
                }
            } else {
                state_.write_register("rax", 0);
                const std::uint64_t instruction_delay = bounded_spurious_wait
                    ? 1'000'000ULL
                    : std::min(
                          timeout_microseconds,
                          std::numeric_limits<std::uint64_t>::max() - executing_instruction_count_);
                condition_waiters_[condition].push_back({
                    {state_, active_thread_handle_},
                    mutex_address,
                    timed,
                    std::chrono::steady_clock::now() + std::chrono::microseconds(timeout_microseconds),
                    executing_instruction_count_ + instruction_delay,
                    bounded_spurious_wait ? 0 : kOrbisErrorTimedOut});
                state_ = ready_contexts_.front().state;
                active_thread_handle_ = ready_contexts_.front().handle;
                ready_contexts_.erase(ready_contexts_.begin());
                context_switched_in_import_ = true;
            }
        } else if (symbol == "kDh-NfxgMtE" || symbol == "2MOy+rUfuhQ" ||
                   symbol == "JGgj7Uvrl+A" || symbol == "mkx2fVhNMsg") {  // pthread condition signal / broadcast
            const std::uint64_t condition = state_.read_register("rdi");
            ++condition_signal_count_;
            std::uint64_t woken = 0;
            if (auto waiters = condition_waiters_.find(condition);
                waiters != condition_waiters_.end() && !waiters->second.empty()) {
                const bool broadcast = symbol == "JGgj7Uvrl+A" || symbol == "mkx2fVhNMsg";
                do {
                    ConditionWaiter waiter = std::move(waiters->second.front());
                    waiters->second.erase(waiters->second.begin());
                    MutexState& mutex = mutexes_[waiter.mutex_address];
                    if (mutex.owner == 0) {
                        mutex.owner = waiter.context.handle;
                        mutex.recursion = 1;
                        ready_contexts_.push_back(std::move(waiter.context));
                    } else {
                        mutex.waiters.push_back(std::move(waiter.context));
                    }
                    ++woken;
                } while (broadcast && !waiters->second.empty());
            }
            condition_signal_wake_count_ += woken;
            if (condition_signal_count_ <= 24) {
                __android_log_print(
                    ANDROID_LOG_INFO,
                    "VibeStation5Runtime",
                    "condition signal=%llu cond=0x%llx woken=%llu totalWoken=%llu",
                    static_cast<unsigned long long>(condition_signal_count_),
                    static_cast<unsigned long long>(condition),
                    static_cast<unsigned long long>(woken),
                    static_cast<unsigned long long>(condition_signal_wake_count_));
            }
            state_.write_register("rax", 0);
        } else if (symbol == "m5-2bsNfv7s" || symbol == "waPcxYiR3WA" || symbol == "4qGrR6eoP9Y") {
            state_.write_register("rax", 0);
        } else if (symbol == "1jfXLRVzisc" || symbol == "QcteRwbsnV0") {  // sceKernelUsleep
            schedule_guest_sleep(state_.read_register("rdi"));
        } else if (symbol == "QvsZxomvUHs") {  // sceKernelNanosleep
            const std::uint64_t request = state_.read_register("rdi");
            const std::uint64_t remaining = state_.read_register("rsi");
            if (request == 0) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else {
                try {
                    const std::int64_t seconds = static_cast<std::int64_t>(memory_.read_integer(request, 8));
                    const std::int64_t nanoseconds = static_cast<std::int64_t>(memory_.read_integer(request + 8, 8));
                    if (seconds < 0 || nanoseconds < 0 || nanoseconds >= 1'000'000'000LL) {
                        state_.write_register("rax", kOrbisErrorInvalidArgument);
                    } else {
                        if (remaining != 0) {
                            memory_.write_integer(remaining, 8, 0);
                            memory_.write_integer(remaining + 8, 8, 0);
                        }
                        const std::uint64_t seconds_microseconds = static_cast<std::uint64_t>(seconds) >
                            std::numeric_limits<std::uint64_t>::max() / 1'000'000ULL
                            ? std::numeric_limits<std::uint64_t>::max()
                            : static_cast<std::uint64_t>(seconds) * 1'000'000ULL;
                        const std::uint64_t subsecond_microseconds =
                            static_cast<std::uint64_t>(nanoseconds + 999LL) / 1'000ULL;
                        schedule_guest_sleep(seconds_microseconds >
                            std::numeric_limits<std::uint64_t>::max() - subsecond_microseconds
                            ? std::numeric_limits<std::uint64_t>::max()
                            : seconds_microseconds + subsecond_microseconds);
                    }
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "T72hz6ffq08" || symbol == "yS8U2TGCe1A") {  // pthread yield
            state_.write_register("rax", 0);
            if (!ready_contexts_.empty()) {
                ready_contexts_.push_back({state_, active_thread_handle_});
                state_ = ready_contexts_.front().state;
                active_thread_handle_ = ready_contexts_.front().handle;
                ready_contexts_.erase(ready_contexts_.begin());
                context_switched_in_import_ = true;
            }
        } else if (symbol == "6UgtwV+0zb4" || symbol == "OxhIB8LB-PQ" || symbol == "Jmi+9w9u0E4") {
            const std::uint64_t output = state_.read_register("rdi");
            const std::uint64_t entry = state_.read_register("rdx");
            const std::uint64_t argument = state_.read_register("rcx");
            if (output == 0 || entry == 0 || next_thread_stack_top_ <= kStackBase + 0x1000ULL ||
                next_thread_tls_block_ + 64ULL * 1024ULL > kTlsBase + kTlsSize) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t handle = allocate(0x1000, 16);
                memory_.write_integer(output, 8, handle);
                state_.write_register("rax", 0);
                ready_contexts_.push_back({state_, active_thread_handle_});

                CpuState thread_state;
                thread_state.rip = entry;
                thread_state.write_register("rdi", argument);
                thread_state.write_register("rsp", next_thread_stack_top_);
                thread_state.fs_base = next_thread_tls_block_ + 32ULL * 1024ULL;
                thread_state.gs_base = thread_state.fs_base;
                memory_.write_integer(thread_state.fs_base, 8, thread_state.fs_base);
                push(thread_state, kReturnSentinel);
                next_thread_stack_top_ -= 2ULL * 1024ULL * 1024ULL;
                next_thread_tls_block_ += 64ULL * 1024ULL;
                active_thread_handle_ = handle;
                state_ = thread_state;
                context_switched_in_import_ = true;
            }
        } else if (symbol == "onNY9Byn-W8") {
            const std::uint64_t handle = state_.read_register("rdi");
            const std::uint64_t output = state_.read_register("rsi");
            if (const auto value = thread_return_values_.find(handle); value != thread_return_values_.end()) {
                if (output != 0) memory_.write_integer(output, 8, value->second);
                state_.write_register("rax", 0);
            } else if (!ready_contexts_.empty()) {
                join_waiters_[handle].push_back({{state_, active_thread_handle_}, output});
                state_ = ready_contexts_.front().state;
                active_thread_handle_ = ready_contexts_.front().handle;
                ready_contexts_.erase(ready_contexts_.begin());
                context_switched_in_import_ = true;
            } else state_.write_register("rax", 0);
        } else if (symbol == "3kg7rT0NQIs" || symbol == "FJrT5LuUBAU") {
            const std::uint64_t return_value = state_.read_register("rdi");
            if (!finish_active_thread(return_value)) pending_stop_ = "guest pthread_exit(" + std::to_string(return_value) + ")";
        } else if (symbol == "dolOmWH+huQ") {  // fused shader storage requirements
            const std::uint64_t output = state_.read_register("rdi");
            const std::uint64_t front = state_.read_register("rsi");
            const std::uint64_t back = state_.read_register("rdx");
            if (output == 0 || front == 0 || back == 0) {
                state_.write_register("rax", 0x8A6C0008ULL);
            } else {
            const std::uint8_t front_type = static_cast<std::uint8_t>(memory_.read_integer(front + 0x5A, 1));
            const std::uint8_t back_type = static_cast<std::uint8_t>(memory_.read_integer(back + 0x5A, 1));
            if ((front_type == 4 && back_type == 6) || (front_type == 5 && back_type == 7)) {
                memory_.write_integer(output, 8, memory_.read_integer(back + 0x5C, 1) << 3U);
                memory_.write_integer(output + 8, 8, 4);
                state_.write_register("rax", 0);
            } else {
                state_.write_register("rax", 0x8A6C0008ULL);
            }
            }
        } else if (symbol == "fd5Bp5tGTgo") {  // fuse shader halves
            const std::uint64_t output = state_.read_register("rdi");
            const std::uint64_t front = state_.read_register("rsi");
            const std::uint64_t back = state_.read_register("rdx");
            const std::uint64_t scratch = state_.read_register("rcx");
            if (output == 0 || front == 0 || back == 0) {
                state_.write_register("rax", 0x8A6C0008ULL);
            } else {
            const std::uint8_t front_type = static_cast<std::uint8_t>(memory_.read_integer(front + 0x5A, 1));
            const std::uint8_t back_type = static_cast<std::uint8_t>(memory_.read_integer(back + 0x5A, 1));
            if (!((front_type == 4 && back_type == 6) || (front_type == 5 && back_type == 7))) {
                state_.write_register("rax", 0x8A6C0008ULL);
            } else {
                memory_.write(output, memory_.read(back, 0x60));
                memory_.write_integer(output + 0x5A, 1, front_type == 4 ? 2 : 3);
                const std::uint64_t back_specials = memory_.read_integer(back + 0x20, 8);
                const std::uint64_t special_count = memory_.read_integer(back + 0x5C, 1);
                if (scratch != 0 && back_specials != 0 && special_count != 0) {
                    memory_.write(scratch, memory_.read(back_specials, static_cast<std::size_t>(special_count) * 8U));
                    memory_.write_integer(output + 0x20, 8, scratch);
                }
                state_.write_register("rax", 0);
            }
            }
        } else if (symbol == "Y3ymLfZ1384") {  // sceAgcUpdatePrimState
            static constexpr std::array<std::uint32_t, 18> kPrimitiveClass = {
                0, 1, 1, 2, 2, 2, 3, 2, 2, 1, 1, 2, 2, 2, 2, 2, 4, 1,
            };
            const std::uint64_t cx = state_.read_register("rdi");
            const std::uint64_t uc = state_.read_register("rsi");
            const std::uint32_t primitive = static_cast<std::uint32_t>(state_.read_register("rdx"));
            if (cx != 0 && (memory_.read_integer(cx + 4, 1) & 0x24U) == 0) {
                const std::uint32_t old = static_cast<std::uint32_t>(memory_.read_integer(cx + 0x0C, 4));
                const std::uint32_t primitive_class = primitive >= 1 && primitive <= kPrimitiveClass.size()
                    ? kPrimitiveClass[primitive - 1] : 2U;
                memory_.write_integer(cx + 0x0C, 4, primitive_class | (old & 0xFFFFFFF8U));
            }
            if (uc != 0) {
                const std::uint32_t old = static_cast<std::uint32_t>(memory_.read_integer(uc + 0x14, 4));
                memory_.write_integer(uc + 0x14, 4, (old & 0xFFFFFFE0U) | (primitive & 0x1FU));
            }
            state_.write_register("rax", 0);
        } else if (symbol == "23LRUSvYu1M") {  // sceAgcInit
            const std::uint64_t version = state_.read_register("rsi") & 0xFFFFFFFFULL;
            state_.write_register(
                "rax",
                state_.read_register("rdi") != 0 &&
                        (version == 7 || version == 8 || version == 10 || version == 13)
                    ? 0
                    : ~0ULL);
        } else if (symbol == "f3dg2CSgRKY") {  // sceAgcCreateShader
            const std::uint64_t destination = state_.read_register("rdi");
            const std::uint64_t header = state_.read_register("rsi");
            const std::uint64_t code = state_.read_register("rdx");
            const auto relocate = [&](std::uint64_t field) {
                const std::uint64_t relative = memory_.read_integer(field, 8);
                if (relative != 0) memory_.write_integer(field, 8, field + relative);
            };
            if (header == 0 || code == 0 || memory_.read_integer(header, 4) != 0x34333231ULL ||
                memory_.read_integer(header + 4, 4) != 0x18ULL) {
                state_.write_register("rax", ~0ULL);
            } else {
                for (const std::uint64_t offset : {0x18ULL, 0x20ULL, 0x08ULL, 0x28ULL, 0x30ULL, 0x38ULL}) {
                    relocate(header + offset);
                }
                memory_.write_integer(header + 0x10, 8, code);
                const std::uint64_t user_data = memory_.read_integer(header + 0x08, 8);
                if (user_data != 0) {
                    for (const std::uint64_t offset : {0ULL, 0x08ULL, 0x10ULL, 0x18ULL, 0x20ULL}) relocate(user_data + offset);
                }
                const std::uint64_t sh_registers = memory_.read_integer(header + 0x20, 8);
                const std::uint8_t shader_type = static_cast<std::uint8_t>(memory_.read_integer(header + 0x5A, 1));
                const std::uint8_t register_count = static_cast<std::uint8_t>(memory_.read_integer(header + 0x5C, 1));
                std::uint32_t expected_low = 0;
                std::uint32_t expected_high = 0;
                if (shader_type == 0) { expected_low = 0x20C; expected_high = 0x20D; }
                else if (shader_type == 1) { expected_low = 0x08; expected_high = 0x09; }
                else if (shader_type == 2 || shader_type == 6) { expected_low = 0xC8; expected_high = 0xC9; }
                else if (shader_type == 4) { expected_low = 0x8A; expected_high = 0x8B; }
                else if (shader_type == 7) { expected_low = 0x148; expected_high = 0x149; }
                if (sh_registers == 0 || register_count < 2 || expected_low == 0 ||
                    memory_.read_integer(sh_registers, 4) != expected_low ||
                    memory_.read_integer(sh_registers + 8, 4) != expected_high) {
                    state_.write_register("rax", ~0ULL);
                } else {
                    memory_.write_integer(sh_registers + 4, 4, (code >> 8U) & 0xFFFFFFFFULL);
                    memory_.write_integer(sh_registers + 12, 4, (code >> 40U) & 0xFFULL);
                    if (destination != 0) memory_.write_integer(destination, 8, header);
                    shader_headers_by_code_[code] = header;
                    state_.write_register("rax", 0);
                }
            }
        } else if (symbol == "vcmNN+AAXnY" || symbol == "Qrj4c+61z4A" || symbol == "6lNcCp+fxi4") {
            // sceAgcSet{Cx,Sh,Uc}RegIndirectPatchSetAddress
            const std::uint64_t command = state_.read_register("rdi");
            const std::uint64_t registers = state_.read_register("rsi");
            if (command == 0 || registers == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                memory_.write_integer(command + 8, 4, registers);
                memory_.write_integer(command + 12, 4, registers >> 32U);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "d-6uF9sZDIU" || symbol == "z2duB-hHQSM" || symbol == "vRoArM9zaIk") {
            // sceAgcSet{Cx,Sh,Uc}RegIndirectPatchAddRegisters
            const std::uint64_t command = state_.read_register("rdi");
            if (command == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t count = memory_.read_integer(command + 4, 4) + state_.read_register("rsi");
                memory_.write_integer(command + 4, 4, count);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "D9sr1xGUriE") {  // sceAgcCreatePrimState
            const std::uint64_t cx = state_.read_register("rdi");
            const std::uint64_t uc = state_.read_register("rsi");
            const std::uint64_t hull = state_.read_register("rdx");
            const std::uint64_t geometry = state_.read_register("rcx");
            const std::uint32_t primitive = static_cast<std::uint32_t>(state_.read_register("r8"));
            const auto copy_register = [&](std::uint64_t source, std::uint64_t destination) {
                memory_.write_integer(destination, 4, memory_.read_integer(source, 4));
                memory_.write_integer(destination + 4, 4, memory_.read_integer(source + 4, 4));
            };
            if (cx == 0 || uc == 0 || hull != 0 || geometry == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint8_t shader_type = static_cast<std::uint8_t>(memory_.read_integer(geometry + 0x5A, 1));
                const std::uint64_t specials = memory_.read_integer(geometry + 0x28, 8);
                if ((shader_type != 2 && shader_type != 4 && shader_type != 6) || specials == 0) {
                    state_.write_register("rax", ~0ULL);
                } else {
                    copy_register(specials + 0x08, cx);
                    copy_register(specials + 0x20, cx + 8);
                    copy_register(specials + 0x00, uc);
                    copy_register(specials + 0x28, uc + 8);
                    memory_.write_integer(uc + 16, 4, 0x242);
                    memory_.write_integer(uc + 20, 4, primitive);
                    state_.write_register("rax", 0);
                }
            }
        } else if (symbol == "HV4j+E0MBHE") {  // sceAgcCreateInterpolantMapping
            const std::uint64_t registers = state_.read_register("rdi");
            const std::uint64_t geometry = state_.read_register("rsi");
            const std::uint64_t pixel = state_.read_register("rdx");
            if (registers == 0 || geometry == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t output_semantics = memory_.read_integer(geometry + 0x38, 8);
                const std::uint32_t output_count = static_cast<std::uint32_t>(memory_.read_integer(geometry + 0x56, 4));
                const std::uint64_t input_semantics = pixel == 0 ? 0 : memory_.read_integer(pixel + 0x30, 8);
                for (std::uint32_t index = 0; index < 32; ++index) {
                    std::uint32_t value = 0;
                    if (index < output_count && output_semantics != 0) {
                        bool flat = false;
                        if (input_semantics != 0) {
                            flat = ((memory_.read_integer(input_semantics + index * 4ULL, 4) >> 22U) & 1U) != 0;
                        }
                        value = index | (flat ? 0x400U : 0U);
                    }
                    memory_.write_integer(registers + index * 8ULL, 4, 0x191U + index);
                    memory_.write_integer(registers + index * 8ULL + 4, 4, value);
                }
                state_.write_register("rax", 0);
            }
        } else if (symbol == "V++UgBtQhn0") {  // sceAgcGetDataPacketPayloadAddress
            const std::uint64_t output = state_.read_register("rdi");
            const std::uint64_t command = state_.read_register("rsi");
            const std::int32_t type = static_cast<std::int32_t>(state_.read_register("rdx"));
            last_import_by_thread_[active_thread_handle_] = symbol +
                "(out=" + hexadecimal(output) + ",cmd=" + hexadecimal(command) +
                ",type=" + std::to_string(type) + ")";
            if (output == 0 || command == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                std::uint64_t payload = command + 8;
                if (type == 0) {
                    const std::uint32_t header = static_cast<std::uint32_t>(memory_.read_integer(command, 4));
                    payload = (header & 0x3FFF0000U) == 0x3FFF0000U ? 0 : command + 4;
                }
                memory_.write_integer(output, 8, payload);
                last_import_by_thread_[active_thread_handle_] = symbol +
                    "(out=" + hexadecimal(output) + ",cmd=" + hexadecimal(command) +
                    ",type=" + std::to_string(type) + ",payload=" + hexadecimal(payload) + ")";
                state_.write_register("rax", 0);
            }
        } else if (symbol == "qj7QZpgr9Uw") {  // observed AGC command-buffer marker
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {0x80000000U}));
        } else if (symbol == "n2fD4A+pb+g") {  // sceAgcCbSetShRegisterRangeDirect
            const std::uint64_t command_buffer = state_.read_register("rdi");
            const std::uint32_t first = static_cast<std::uint32_t>(state_.read_register("rsi"));
            const std::uint64_t values = state_.read_register("rdx");
            const std::uint32_t count = static_cast<std::uint32_t>(state_.read_register("rcx"));
            std::uint64_t marker = 0;
            std::uint64_t command = 0;
            if (command_buffer == 0 || first == 0 || first > 0x3FF || count == 0 ||
                !agc_allocate_command(command_buffer, 2, marker) ||
                !agc_allocate_command(command_buffer, count + 2, command)) {
                state_.write_register("rax", 0);
            } else {
                memory_.write_integer(marker, 4, agc_pm4(2, 0x10, 0));
                memory_.write_integer(marker + 4, 4, 0x6875000D);
                memory_.write_integer(command, 4, agc_pm4(count + 2, 0x76, 0));
                memory_.write_integer(command + 4, 4, first);
                for (std::uint32_t index = 0; index < count; ++index) {
                    const std::uint32_t value = values == 0 ? 0U
                        : static_cast<std::uint32_t>(memory_.read_integer(values + index * 4ULL, 4));
                    memory_.write_integer(command + 8ULL + index * 4ULL, 4, value);
                }
                state_.write_register("rax", command);
            }
        } else if (symbol == "w1KFAHVqpaU") {  // sceAgcCbBranch
            const std::uint64_t stack = state_.read_register("rsp");
            const std::uint64_t compare_address = state_.read_register("rcx");
            const std::uint64_t mask = state_.read_register("r8");
            const std::uint64_t reference = state_.read_register("r9");
            const std::uint64_t first_buffer = memory_.read_integer(stack + 8, 8);
            const std::uint32_t first_size = static_cast<std::uint32_t>(memory_.read_integer(stack + 16, 4));
            const std::uint64_t second_buffer = memory_.read_integer(stack + 32, 8);
            const std::uint32_t second_size = static_cast<std::uint32_t>(memory_.read_integer(stack + 40, 4));
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(14, 0x3F, 0),
                (static_cast<std::uint32_t>(state_.read_register("rdx")) & 7U) << 8U |
                    (static_cast<std::uint32_t>(state_.read_register("rsi")) & 3U),
                static_cast<std::uint32_t>(compare_address), static_cast<std::uint32_t>(compare_address >> 32U),
                static_cast<std::uint32_t>(mask), static_cast<std::uint32_t>(mask >> 32U),
                static_cast<std::uint32_t>(reference), static_cast<std::uint32_t>(reference >> 32U),
                static_cast<std::uint32_t>(first_buffer) & 0xFFFFFFFCU, static_cast<std::uint32_t>(first_buffer >> 32U),
                (static_cast<std::uint32_t>(memory_.read_integer(stack, 1)) & 3U) << 28U | (first_size & 0xFFFFFU),
                static_cast<std::uint32_t>(second_buffer) & 0xFFFFFFFCU, static_cast<std::uint32_t>(second_buffer >> 32U),
                (static_cast<std::uint32_t>(memory_.read_integer(stack + 24, 1)) & 3U) << 28U | (second_size & 0xFFFFFU),
            }));
        } else if (symbol == "Rlx+bykm0r0") {  // sceAgcDcbDrawIndexMultiInstanced
            const std::uint64_t index_address = state_.read_register("rdx");
            const std::uint64_t object_ids = state_.read_register("r8");
            const std::uint32_t instances = static_cast<std::uint32_t>(state_.read_register("rcx"));
            const std::uint64_t modifier = state_.read_register("r9");
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(9, 0x3A, 0), static_cast<std::uint32_t>(state_.read_register("rsi")),
                static_cast<std::uint32_t>(index_address), static_cast<std::uint32_t>(index_address >> 32U),
                instances + static_cast<std::uint32_t>(instances == 0),
                static_cast<std::uint32_t>(object_ids), static_cast<std::uint32_t>(object_ids >> 32U),
                instances,
                (((modifier & 0x100000000ULL) == 0)
                    ? static_cast<std::uint32_t>(modifier >> 3U) & 0x20U : 0U) | 0x80U,
            }));
        } else if (symbol == "1q1titRBL6o") {  // sceAgcDcbDrawIndirect
            const std::uint64_t encoded = agc_encode_draw_modifier(state_.read_register("rdx"), false);
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(5, 0x24, 0), static_cast<std::uint32_t>(state_.read_register("rsi")),
                static_cast<std::uint32_t>(encoded), static_cast<std::uint32_t>(encoded >> 32U),
                agc_draw_modifier_word(state_.read_register("rdx")),
            }));
        } else if (symbol == "ypVBz4uPKcQ") {  // sceAgcDcbDrawIndexIndirectMulti
            const std::uint64_t modifier = memory_.read_integer(state_.read_register("rsp"), 8);
            const std::uint64_t encoded = agc_encode_draw_modifier(modifier, true);
            const std::uint64_t count_address = state_.read_register("r8");
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(10, 0x38, 0), static_cast<std::uint32_t>(state_.read_register("rsi")),
                static_cast<std::uint32_t>(encoded), static_cast<std::uint32_t>(encoded >> 32U),
                (static_cast<std::uint32_t>(state_.read_register("rdx")) & 1U) << 30U,
                static_cast<std::uint32_t>(state_.read_register("rcx")),
                static_cast<std::uint32_t>(count_address) & 0xFFFFFFFCU,
                static_cast<std::uint32_t>(count_address >> 32U),
                static_cast<std::uint32_t>(state_.read_register("r9")),
                agc_draw_modifier_word(modifier),
            }));
        } else if (symbol == "1rZSWUv1IRc") {  // sceAgcDcbCopyData
            const std::uint64_t stack = state_.read_register("rsp");
            const std::uint32_t destination = static_cast<std::uint32_t>(state_.read_register("rsi"));
            const std::uint32_t item_size = static_cast<std::uint32_t>(state_.read_register("rdx"));
            const std::uint32_t source = static_cast<std::uint32_t>(state_.read_register("r8"));
            const std::uint32_t control =
                ((source & 1U) << 30U) | ((item_size & 3U) << 25U) |
                ((static_cast<std::uint32_t>(memory_.read_integer(stack + 16, 1)) & 1U) << 20U) |
                ((static_cast<std::uint32_t>(memory_.read_integer(stack + 8, 1)) & 1U) << 16U) |
                ((static_cast<std::uint32_t>(state_.read_register("r9")) & 3U) << 13U) |
                (((destination >> 1U) & 0xFU) << 8U) | ((source >> 1U) & 0xFU);
            const std::uint64_t source_value = memory_.read_integer(stack, 8);
            const std::uint64_t destination_address = state_.read_register("rcx");
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(6, 0x40, 0), control,
                static_cast<std::uint32_t>(source_value), static_cast<std::uint32_t>(source_value >> 32U),
                static_cast<std::uint32_t>(destination_address), static_cast<std::uint32_t>(destination_address >> 32U),
            }));
        } else if (symbol == "xSAR0LTcRKM") {  // sceAgcDcbJump
            const std::uint64_t target = state_.read_register("rcx");
            const std::uint32_t control = 0x0F200000U |
                ((static_cast<std::uint32_t>(state_.read_register("rsi")) & 1U) << 20U) |
                ((static_cast<std::uint32_t>(state_.read_register("rdx")) & 3U) << 28U) |
                (static_cast<std::uint32_t>(state_.read_register("r8")) & 0xFFFFFU);
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(4, 0x3F, 0),
                static_cast<std::uint32_t>(target) & 0xFFFFFFFCU,
                static_cast<std::uint32_t>(target >> 32U), control,
            }));
        } else if (symbol == "BIPexNBSGog") {  // sceAgcDcbCondExec
            const std::uint64_t predicate = state_.read_register("rsi");
            const std::uint32_t count = static_cast<std::uint32_t>(state_.read_register("rdx"));
            state_.write_register("rax", predicate != 0 && (predicate & 3U) == 0 && count < 0x4000U
                ? agc_emit(state_.read_register("rdi"), {
                    agc_pm4(5, 0x22, 0), static_cast<std::uint32_t>(predicate),
                    static_cast<std::uint32_t>(predicate >> 32U), 0, count})
                : 0);
        } else if (symbol == "bbFueFP+J4k") {  // sceAgcDcbSetPredication
            const std::uint64_t address = state_.read_register("r8");
            const std::uint32_t control =
                (static_cast<std::uint32_t>(state_.read_register("rsi")) & 1U) << 8U |
                (static_cast<std::uint32_t>(state_.read_register("rcx")) & 1U) << 12U |
                (static_cast<std::uint32_t>(state_.read_register("rdx")) & 7U) << 16U;
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(4, 0x20, 0), control, static_cast<std::uint32_t>(address) & 0xFFFFFFF0U,
                static_cast<std::uint32_t>(address >> 32U)}));
        } else if (symbol == "TRO721eVt4g") {  // sceAgcDcbResetQueue
            const bool valid = state_.read_register("rsi") == 0x3FF && state_.read_register("rdx") == 0;
            state_.write_register("rax", valid
                ? agc_emit(state_.read_register("rdi"), {agc_pm4(2, 0x10, 0x05), 0})
                : 0);
        } else if (symbol == "ZvwO9euwYzc" || symbol == "-HOOCn0JY48" || symbol == "hvUfkUIQcOE") {
            const std::uint32_t packet_register = symbol == "ZvwO9euwYzc" ? 0x12U
                : symbol == "-HOOCn0JY48" ? 0x11U : 0x13U;
            state_.write_register("rax", agc_emit_registers_indirect(packet_register));
        } else if (symbol == "GIIW2J37e70") {  // sceAgcDcbSetIndexSize
            const std::uint32_t size = static_cast<std::uint32_t>(state_.read_register("rsi") & 0xFFU);
            const std::uint32_t policy = static_cast<std::uint32_t>(state_.read_register("rdx") & 0xFFU);
            state_.write_register("rax", policy == 0
                ? agc_emit(state_.read_register("rdi"), {agc_pm4(2, 0x2A, 0), size})
                : 0);
        } else if (symbol == "tSBxhAPyytQ") {  // sceAgcDcbSetNumInstances
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(2, 0x2F, 0), static_cast<std::uint32_t>(state_.read_register("rsi"))}));
        } else if (symbol == "Yw0jKSqop+E") {  // sceAgcDcbDrawIndexAuto
            if (state_.read_register("rdx") != 0x40000000ULL) {
                state_.write_register("rax", 0);
            } else {
                state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                    agc_pm4(7, 0x10, 0x04), static_cast<std::uint32_t>(state_.read_register("rsi")),
                    0, 0, 0, 0, 0}));
            }
        } else if (symbol == "aJf+j5yntiU") {  // sceAgcDcbEventWrite
            const std::uint32_t event = static_cast<std::uint32_t>(state_.read_register("rsi") & 0xFFU);
            state_.write_register("rax", event <= 0x3F && state_.read_register("rdx") == 0
                ? agc_emit(state_.read_register("rdi"), {agc_pm4(2, 0x46, 0), event})
                : 0);
        } else if (symbol == "57labkp+rSQ") {  // sceAgcDcbAcquireMem
            const std::uint32_t engine = static_cast<std::uint32_t>(state_.read_register("rsi") & 0xFFU);
            const std::uint32_t cb_db = static_cast<std::uint32_t>(state_.read_register("rdx"));
            const std::uint32_t gcr = static_cast<std::uint32_t>(state_.read_register("rcx"));
            const std::uint64_t base = state_.read_register("r8");
            const std::uint64_t size = state_.read_register("r9");
            const std::uint32_t poll_cycles = static_cast<std::uint32_t>(memory_.read_integer(state_.read_register("rsp"), 4));
            const bool no_size = size == std::numeric_limits<std::uint64_t>::max();
            const bool valid = engine <= 1 && (base & 0xFFU) == 0 && (base >> 40U) == 0 &&
                (no_size || ((size & 0xFFU) == 0 && (size >> 40U) == 0));
            state_.write_register("rax", valid ? agc_emit(state_.read_register("rdi"), {
                agc_pm4(8, 0x10, 0x14), (engine << 31U) | cb_db,
                no_size ? 0U : static_cast<std::uint32_t>(size >> 8U), 0,
                static_cast<std::uint32_t>(base >> 8U), 0, poll_cycles / 40U, gcr}) : 0);
        } else if (symbol == "l4fM9K-Lyks") {  // sceAgcDcbSetIndexBuffer
            const std::uint64_t address = state_.read_register("rsi");
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(3, 0x26, 0), static_cast<std::uint32_t>(address), static_cast<std::uint32_t>(address >> 32U),
                agc_pm4(2, 0x13, 0), static_cast<std::uint32_t>(state_.read_register("rdx"))}));
        } else if (symbol == "B+aG9DUnTKA") {  // sceAgcDcbDrawIndexOffset
            const std::uint32_t count = static_cast<std::uint32_t>(state_.read_register("rdx"));
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(5, 0x35, 0), count, static_cast<std::uint32_t>(state_.read_register("rsi")), count,
                static_cast<std::uint32_t>(state_.read_register("rcx")) & 0xE0000001U}));
        } else if (symbol == "YUeqkyT7mEQ") {  // sceAgcDcbSetFlip
            const std::uint64_t flip_argument = state_.read_register("r8");
            state_.write_register("rax", agc_emit(state_.read_register("rdi"), {
                agc_pm4(6, 0x10, 0x17), static_cast<std::uint32_t>(state_.read_register("rsi")),
                static_cast<std::uint32_t>(state_.read_register("rdx")),
                static_cast<std::uint32_t>(state_.read_register("rcx")),
                static_cast<std::uint32_t>(flip_argument), static_cast<std::uint32_t>(flip_argument >> 32U)}));
        } else if (symbol == "UglJIZjGssM") {  // sceAgcDriverSubmitDcb
            const std::uint64_t submission = state_.read_register("rdi");
            if (submission == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t commands = memory_.read_integer(submission, 8);
                const std::uint32_t count = static_cast<std::uint32_t>(memory_.read_integer(submission + 8, 4));
                state_.write_register("rax", agc_submit_direct(commands, count) ? 0 : ~0ULL);
            }
        } else if (symbol == "b4fpgH5ZXxQ") {  // sceAgcDriverSubmitCommandBuffer
            agc_submit_direct(
                state_.read_register("rsi"), static_cast<std::uint32_t>(state_.read_register("rdx")));
            state_.write_register("rax", 0);
        } else if (symbol == "Fj7r9EHzF38" || symbol == "HF3YllT3mXU") {
            // sceAgcDriverSubmitMultiCommandBuffers / sceAgcDriverSubmitMultiAcbs
            const std::uint32_t count = static_cast<std::uint32_t>(state_.read_register("rdi"));
            const std::uint64_t addresses = state_.read_register("rsi");
            const std::uint64_t sizes = state_.read_register("rdx");
            bool valid = count <= 1024U && (count == 0 || (addresses != 0 && sizes != 0));
            for (std::uint32_t index = 0; valid && index < count; ++index) {
                agc_submit_direct(
                    memory_.read_integer(addresses + index * 8ULL, 8),
                    static_cast<std::uint32_t>(memory_.read_integer(sizes + index * 4ULL, 4)));
            }
            state_.write_register("rax", valid ? 0 : 0x80020016ULL);
        } else if (symbol == "h9z6+0hEydk") {  // sceAgcSuspendPoint
            state_.write_register("rax", 0);
        } else if (symbol == "hv1luiJrqQM") {  // scePadInit
            state_.write_register("rax", 0);
        } else if (symbol == "xk0AcarP3V4" || symbol == "WFIiSfXGUq8") {  // scePadOpen / scePadOpenExt
            state_.write_register("rax", 1);
        } else if (symbol == "6ncge5+l5Qs" || symbol == "clVvL4ZDntw" ||
                   symbol == "W2G-yoyMF5U" || symbol == "2JgFB2n9oUM" || symbol == "yFVnOdGxvZY") {
            state_.write_register("rax", 0);
        } else if (symbol == "RR4novUEENY" || symbol == "DscD1i9HX1w") {  // pad light bar
            state_.write_register("rax", 0);
        } else if (symbol == "YndgXqQVV7c" || symbol == "q1cHNfGycLI") {  // scePadReadState / scePadRead
            const std::uint64_t output = state_.read_register("rsi");
            if (output == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                std::vector<std::uint8_t> data(0x78, 0);
                const auto axis = [](float value) {
                    return static_cast<std::uint8_t>(std::lround((std::clamp(value, -1.0F, 1.0F) + 1.0F) * 127.5F));
                };
                const auto put = [&](std::size_t offset, std::uint64_t value, std::size_t size) {
                    for (std::size_t byte = 0; byte < size; ++byte) {
                        data[offset + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
                    }
                };
                put(0x00, input_buttons_ & 0xFFFFFFFFULL, 4);
                data[0x04] = axis(left_x_);
                data[0x05] = axis(left_y_);
                data[0x06] = axis(right_x_);
                data[0x07] = axis(right_y_);
                data[0x08] = (input_buttons_ & 0x400ULL) != 0 ? 0xFF : 0;
                data[0x09] = (input_buttons_ & 0x800ULL) != 0 ? 0xFF : 0;
                const float identity = 1.0F;
                std::memcpy(data.data() + 0x18, &identity, sizeof(identity));
                data[0x4C] = 1;
                const auto now = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count();
                put(0x50, static_cast<std::uint64_t>(now), 8);
                data[0x68] = 1;
                memory_.write(output, data);
                state_.write_register("rax", symbol == "q1cHNfGycLI" ? 1 : 0);
            }
        } else if (symbol == "gjP9-KQzoUk" || symbol == "hGbf2QTBmqc") {  // controller information
            const std::uint64_t output = state_.read_register("rsi");
            if (output == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                std::vector<std::uint8_t> info(0x1C, 0);
                const float touch_scale = 44.86F;
                std::memcpy(info.data(), &touch_scale, sizeof(touch_scale));
                info[0x04] = 0x80;
                info[0x05] = 0x07;
                info[0x06] = 0xAF;
                info[0x07] = 0x03;
                info[0x08] = 30;
                info[0x0C] = 1;
                memory_.write(output, info);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "JfEPXVxhFqA") {  // sceAudioOutInit
            state_.write_register("rax", 0);
        } else if (symbol == "ekNvsT22rsY") {  // sceAudioOutOpen
            const std::uint32_t buffer_length = static_cast<std::uint32_t>(state_.read_register("rcx"));
            const std::uint32_t frequency = static_cast<std::uint32_t>(state_.read_register("r8"));
            const std::uint32_t format = static_cast<std::uint32_t>(state_.read_register("r9")) & 0xFFU;
            const std::uint32_t channels = format == 0 || format == 3 ? 1U : format == 1 || format == 4 ? 2U : 8U;
            if (buffer_length == 0 || frequency == 0 || format > 7) {
                state_.write_register("rax", ~0ULL);
            } else {
                const std::uint64_t handle = next_audio_handle_++;
                audio_ports_[handle] = {buffer_length, frequency, format, channels};
                audio_sample_rate_ = frequency;
                state_.write_register("rax", handle);
            }
        } else if (symbol == "s1--uE9mBFw") {  // sceAudioOutClose
            audio_ports_.erase(state_.read_register("rdi"));
            state_.write_register("rax", 0);
        } else if (symbol == "b+uAV89IlxE") {  // sceAudioOutSetVolume
            state_.write_register("rax", 0);
        } else if (symbol == "QOQtbeDqsT4") {  // sceAudioOutOutput
            const auto port = audio_ports_.find(state_.read_register("rdi"));
            const std::uint64_t source = state_.read_register("rsi");
            if (port == audio_ports_.end() || source == 0) {
                state_.write_register("rax", port == audio_ports_.end() ? ~0ULL : 0);
            } else {
                const bool floating = (port->second.format >= 3 && port->second.format <= 5) || port->second.format == 7;
                const std::size_t sample_size = floating ? sizeof(float) : sizeof(std::int16_t);
                const std::size_t sample_count = static_cast<std::size_t>(port->second.buffer_length) * port->second.channels;
                const std::vector<std::uint8_t> samples = memory_.read(source, sample_count * sample_size);
                const auto append_sample = [&](std::int16_t sample) {
                    audio_queue_.push_back(static_cast<std::uint8_t>(sample));
                    audio_queue_.push_back(static_cast<std::uint8_t>(static_cast<std::uint16_t>(sample) >> 8U));
                };
                const auto sample_at = [&](std::size_t index) {
                    if (!floating) {
                        std::int16_t value = 0;
                        std::memcpy(&value, samples.data() + index * sizeof(value), sizeof(value));
                        return value;
                    }
                    float value = 0;
                    std::memcpy(&value, samples.data() + index * sizeof(value), sizeof(value));
                    value = std::clamp(std::isfinite(value) ? value : 0.0F, -1.0F, 1.0F);
                    return static_cast<std::int16_t>(std::lround(value * 32767.0F));
                };
                for (std::size_t frame = 0; frame < port->second.buffer_length; ++frame) {
                    const std::size_t base = frame * port->second.channels;
                    append_sample(sample_at(base));
                    append_sample(sample_at(base + (port->second.channels == 1 ? 0 : 1)));
                }
                constexpr std::size_t kMaximumQueuedAudio = 48000ULL * 2ULL * sizeof(std::int16_t) * 5ULL;
                if (audio_queue_.size() > kMaximumQueuedAudio) {
                    audio_queue_.erase(audio_queue_.begin(), audio_queue_.begin() +
                        static_cast<std::ptrdiff_t>(audio_queue_.size() - kMaximumQueuedAudio));
                }
                audio_sample_rate_ = port->second.frequency;
                state_.write_register("rax", 0);
            }
        } else if (symbol == "2JtWUUiYBXs" || symbol == "wRbq6ZjNop4") {
            const std::uint64_t version = state_.read_register("rdi") & 0xFFFFFFFFULL;
            if (version != 7 && version != 8 && version != 10 && version != 13) {
                state_.write_register("rax", 0);
            } else {
                const std::string key = symbol == "2JtWUUiYBXs" ? "agc.primaryRegisterDefaults" : "agc.internalRegisterDefaults";
                if (const auto cached = runtime_objects_.find(key); cached != runtime_objects_.end()) {
                    state_.write_register("rax", cached->second);
                } else {
                    const bool internal = symbol == "wRbq6ZjNop4";
                    const auto& groups = internal
                        ? agc::internal_register_defaults()
                        : agc::primary_register_defaults();
                    const std::size_t cx_table_length = internal ? 4 : 78;
                    const std::size_t sh_table_length = internal ? 15 : 29;
                    const std::size_t uc_table_length = internal ? 3 : 20;
                    constexpr std::size_t kDefaultsSize = 0x40;
                    constexpr std::size_t kRegisterBlockSize = 16 * 8;
                    const auto align_up = [](std::size_t value, std::size_t alignment) {
                        return (value + alignment - 1) & ~(alignment - 1);
                    };
                    const std::size_t cx_table_offset = align_up(kDefaultsSize, sizeof(std::uint64_t));
                    const std::size_t sh_table_offset = cx_table_offset + cx_table_length * sizeof(std::uint64_t);
                    const std::size_t uc_table_offset = sh_table_offset + sh_table_length * sizeof(std::uint64_t);
                    const std::size_t types_offset = align_up(
                        uc_table_offset + uc_table_length * sizeof(std::uint64_t), sizeof(std::uint32_t));
                    const std::size_t register_blocks_offset = align_up(
                        types_offset + groups.size() * 3 * sizeof(std::uint32_t), sizeof(std::uint64_t));
                    const std::size_t blob_length = register_blocks_offset + groups.size() * kRegisterBlockSize;
                    const std::uint64_t defaults = allocate(blob_length, kPageSize);
                    std::vector<std::uint8_t> blob(blob_length, 0);
                    const auto write_u32 = [&](std::size_t offset, std::uint32_t value) {
                        for (std::size_t byte = 0; byte < sizeof(value); ++byte) {
                            blob[offset + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
                        }
                    };
                    const auto write_u64 = [&](std::size_t offset, std::uint64_t value) {
                        for (std::size_t byte = 0; byte < sizeof(value); ++byte) {
                            blob[offset + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
                        }
                    };
                    write_u64(0x00, defaults + cx_table_offset);
                    write_u64(0x08, defaults + sh_table_offset);
                    write_u64(0x10, defaults + uc_table_offset);
                    write_u64(0x30, defaults + types_offset);
                    write_u32(0x38, static_cast<std::uint32_t>(groups.size()));
                    for (std::size_t group_index = 0; group_index < groups.size(); ++group_index) {
                        const agc::RegisterDefaultGroup& group = groups[group_index];
                        if (group.registers.size() > 16) throw std::runtime_error("invalid AGC register-default group");
                        const std::size_t table_offset = group.space == 0 ? cx_table_offset
                            : group.space == 1 ? sh_table_offset : uc_table_offset;
                        const std::size_t table_length = group.space == 0 ? cx_table_length
                            : group.space == 1 ? sh_table_length : uc_table_length;
                        if (group.space > 2 || group.index >= table_length) {
                            throw std::runtime_error("invalid AGC register-default table index");
                        }
                        const std::size_t block_offset = register_blocks_offset + group_index * kRegisterBlockSize;
                        write_u64(table_offset + group.index * sizeof(std::uint64_t), defaults + block_offset);
                        const std::size_t type_offset = types_offset + group_index * 3 * sizeof(std::uint32_t);
                        write_u32(type_offset, group.type);
                        write_u32(type_offset + sizeof(std::uint32_t), group.index * 4U + group.space);
                        for (std::size_t register_index = 0; register_index < group.registers.size(); ++register_index) {
                            const std::size_t register_offset = block_offset + register_index * 2 * sizeof(std::uint32_t);
                            write_u32(register_offset, group.registers[register_index].offset);
                            write_u32(register_offset + sizeof(std::uint32_t), group.registers[register_index].value);
                        }
                    }
                    memory_.write(defaults, blob);
                    runtime_objects_[key] = defaults;
                    state_.write_register("rax", defaults);
                }
            }
        } else if (symbol == "tcVi5SivF7Q" || symbol == "eLdDw6l0-bU") {  // sprintf / snprintf
            const bool bounded = symbol == "eLdDw6l0-bU";
            const std::uint64_t destination = state_.read_register("rdi");
            const std::uint64_t capacity = bounded ? state_.read_register("rsi") : 32ULL * 1024ULL * 1024ULL;
            const std::uint64_t format_address = state_.read_register(bounded ? "rdx" : "rsi");
            const std::array<std::uint64_t, 4> registers = bounded
                ? std::array<std::uint64_t, 4>{state_.read_register("rcx"), state_.read_register("r8"), state_.read_register("r9"), 0}
                : std::array<std::uint64_t, 4>{state_.read_register("rdx"), state_.read_register("rcx"), state_.read_register("r8"), state_.read_register("r9")};
            const std::size_t register_count = bounded ? 3 : 4;
            std::size_t integer_index = 0;
            std::size_t vector_index = 0;
            std::uint64_t stack = state_.read_register("rsp");
            const auto next = [&](bool floating) mutable {
                if (floating && vector_index < state_.vectors.size()) {
                    std::uint64_t value = 0;
                    std::memcpy(&value, state_.vectors[vector_index++].data(), sizeof(value));
                    return value;
                }
                if (integer_index < register_count) return registers[integer_index++];
                const std::uint64_t value = memory_.read_integer(stack, 8);
                stack += 8;
                return value;
            };
            const std::string formatted = guest_format(guest_string(format_address), next);
            note_guest_text(formatted);
            if (destination != 0 && capacity != 0) {
                const std::size_t count = static_cast<std::size_t>(std::min<std::uint64_t>(formatted.size(), capacity - 1));
                if (count != 0) memory_.write(destination, reinterpret_cast<const std::uint8_t*>(formatted.data()), count);
                memory_.write_integer(destination + count, 1, 0);
            }
            state_.write_register("rax", formatted.size());
        } else if (symbol == "Q2V+iqvjgC0") {  // vsnprintf
            const std::uint64_t destination = state_.read_register("rdi");
            const std::uint64_t capacity = state_.read_register("rsi");
            const std::uint64_t argument_list = state_.read_register("rcx");
            std::uint32_t gp_offset = static_cast<std::uint32_t>(memory_.read_integer(argument_list, 4));
            std::uint32_t fp_offset = static_cast<std::uint32_t>(memory_.read_integer(argument_list + 4, 4));
            std::uint64_t overflow = memory_.read_integer(argument_list + 8, 8);
            const std::uint64_t save_area = memory_.read_integer(argument_list + 16, 8);
            const auto next = [&](bool floating) mutable {
                if (floating && fp_offset <= 304U - 16U) {
                    const std::uint64_t value = memory_.read_integer(save_area + fp_offset, 8);
                    fp_offset += 16;
                    return value;
                }
                if (!floating && gp_offset <= 48U - 8U) {
                    const std::uint64_t value = memory_.read_integer(save_area + gp_offset, 8);
                    gp_offset += 8;
                    return value;
                }
                const std::uint64_t value = memory_.read_integer(overflow, 8);
                overflow += 8;
                return value;
            };
            const std::string formatted = guest_format(guest_string(state_.read_register("rdx")), next);
            if (destination != 0 && capacity != 0) {
                const std::size_t count = static_cast<std::size_t>(std::min<std::uint64_t>(formatted.size(), capacity - 1));
                if (count != 0) memory_.write(destination, reinterpret_cast<const std::uint8_t*>(formatted.data()), count);
                memory_.write_integer(destination + count, 1, 0);
            }
            state_.write_register("rax", formatted.size());
        } else if (symbol == "hcuQgD53UxM") {  // printf
            const std::array<std::uint64_t, 5> registers = {
                state_.read_register("rsi"), state_.read_register("rdx"), state_.read_register("rcx"),
                state_.read_register("r8"), state_.read_register("r9")};
            std::size_t integer_index = 0;
            std::size_t vector_index = 0;
            std::uint64_t stack = state_.read_register("rsp");
            const auto next = [&](bool floating) mutable {
                if (floating && vector_index < state_.vectors.size()) {
                    std::uint64_t value = 0;
                    std::memcpy(&value, state_.vectors[vector_index++].data(), sizeof(value));
                    return value;
                }
                if (integer_index < registers.size()) return registers[integer_index++];
                const std::uint64_t value = memory_.read_integer(stack, 8);
                stack += 8;
                return value;
            };
            const std::string formatted = guest_format(guest_string(state_.read_register("rdi")), next);
            note_guest_text(formatted);
            remember(recent_imports_, "guest printf: " + formatted, 128);
            state_.write_register("rax", formatted.size());
        } else if (symbol == "YQ0navp+YIc") {  // puts-compatible guest log
            const std::string text = guest_string(state_.read_register("rdi"));
            note_guest_text(text);
            remember(recent_imports_, "guest puts: " + text, 128);
            state_.write_register("rax", text.size());
        } else if (symbol == "QrZZdJ8XsX0") {  // fputs
            const std::string text = guest_string(state_.read_register("rdi"));
            note_guest_text(text);
            remember(recent_imports_, "guest fputs: " + text, 128);
            state_.write_register("rax", text.size());
        } else if (symbol == "j4ViWNHEgww") {  // strlen
            const std::uint64_t pointer = state_.read_register("rdi");
            std::uint64_t length = 0;
            while (memory_.read_integer(pointer + length, 1) != 0) {
                if (++length > 64ULL * 1024ULL * 1024ULL) throw std::runtime_error("unterminated guest string");
            }
            state_.write_register("rax", length);
        } else if (symbol == "SfQIZcqvvms") {  // strlcpy
            const std::uint64_t destination = state_.read_register("rdi");
            const std::string source = guest_string(state_.read_register("rsi"));
            const std::size_t capacity = static_cast<std::size_t>(state_.read_register("rdx"));
            if (destination != 0 && capacity != 0) {
                const std::size_t count = std::min(source.size(), capacity - 1);
                if (count != 0) {
                    memory_.write(destination, reinterpret_cast<const std::uint8_t*>(source.data()), count);
                }
                memory_.write_integer(destination + count, 1, 0);
            }
            state_.write_register("rax", source.size());
        } else if (symbol == "viiwFMaNamA") {  // strstr
            const std::uint64_t haystack_address = state_.read_register("rdi");
            const std::string haystack = guest_string(haystack_address);
            const std::string needle = guest_string(state_.read_register("rsi"));
            const std::size_t position = haystack.find(needle);
            state_.write_register(
                "rax",
                position == std::string::npos ? 0 : haystack_address + position);
        } else if (symbol == "8u8lPzUEq+U") {  // memchr
            const std::uint64_t address = state_.read_register("rdi");
            const std::uint8_t value = static_cast<std::uint8_t>(state_.read_register("rsi"));
            const std::size_t count = static_cast<std::size_t>(state_.read_register("rdx"));
            const std::vector<std::uint8_t> bytes = memory_.read(address, count);
            const auto found = std::find(bytes.begin(), bytes.end(), value);
            state_.write_register(
                "rax",
                found == bytes.end() ? 0 : address + static_cast<std::uint64_t>(found - bytes.begin()));
        } else if (symbol == "5OqszGpy7Mg" || symbol == "VOBg+iNwB-4" || symbol == "2vDqwBlpF-o") {
            const std::uint64_t input_address = state_.read_register("rdi");
            const std::uint64_t end_pointer_address = state_.read_register("rsi");
            const std::string input = guest_string(input_address);
            char* end = nullptr;
            if (symbol == "2vDqwBlpF-o") {  // strtod
                const double value = std::strtod(input.c_str(), &end);
                std::fill(state_.vectors[0].begin(), state_.vectors[0].end(), 0);
                std::memcpy(state_.vectors[0].data(), &value, sizeof(value));
            } else if (symbol == "5OqszGpy7Mg") {  // strtoull
                const unsigned long long value = std::strtoull(
                    input.c_str(), &end, static_cast<int>(state_.read_register("rdx")));
                state_.write_register("rax", static_cast<std::uint64_t>(value));
            } else {  // strtoll
                const long long value = std::strtoll(
                    input.c_str(), &end, static_cast<int>(state_.read_register("rdx")));
                state_.write_register("rax", static_cast<std::uint64_t>(value));
            }
            if (end_pointer_address != 0) {
                const std::uint64_t consumed = end == nullptr
                    ? 0
                    : static_cast<std::uint64_t>(end - input.c_str());
                memory_.write_integer(end_pointer_address, 8, input_address + consumed);
            }
        } else if (symbol == "wLlFkwG9UcQ") {  // time
            const auto now = std::chrono::system_clock::now().time_since_epoch();
            const std::int64_t seconds = std::chrono::duration_cast<std::chrono::seconds>(now).count();
            const std::uint64_t output = state_.read_register("rdi");
            if (output != 0) memory_.write_integer(output, 8, static_cast<std::uint64_t>(seconds));
            state_.write_register("rax", static_cast<std::uint64_t>(seconds));
        } else if (symbol == "lLMT9vJAck0") {  // clock_gettime
            const std::uint64_t output = state_.read_register("rsi");
            if (output == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const auto now = std::chrono::steady_clock::now().time_since_epoch();
                const std::int64_t nanoseconds =
                    std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
                memory_.write_integer(output, 8, static_cast<std::uint64_t>(nanoseconds / 1'000'000'000LL));
                memory_.write_integer(output + 8, 8, static_cast<std::uint64_t>(nanoseconds % 1'000'000'000LL));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "n88vx3C5nW8") {  // gettimeofday
            const std::uint64_t output = state_.read_register("rdi");
            if (output == 0) {
                state_.write_register("rax", ~0ULL);
            } else {
                const auto now = std::chrono::system_clock::now().time_since_epoch();
                const std::int64_t microseconds =
                    std::chrono::duration_cast<std::chrono::microseconds>(now).count();
                memory_.write_integer(output, 8, static_cast<std::uint64_t>(microseconds / 1'000'000LL));
                memory_.write_integer(output + 8, 8, static_cast<std::uint64_t>(microseconds % 1'000'000LL));
                state_.write_register("rax", 0);
            }
        } else if (symbol == "8zTFvBIAIN8") {  // memset
            const std::uint64_t destination = state_.read_register("rdi");
            const std::size_t count = static_cast<std::size_t>(state_.read_register("rdx"));
            memory_.write(destination, std::vector<std::uint8_t>(count, static_cast<std::uint8_t>(state_.read_register("rsi"))));
            state_.write_register("rax", destination);
        } else if (symbol == "Q3VBxCXhUHs" || symbol == "+P6FRGH4LfA") {  // memcpy / memmove
            const std::uint64_t destination = state_.read_register("rdi");
            const std::size_t count = static_cast<std::size_t>(state_.read_register("rdx"));
            memory_.write(destination, memory_.read(state_.read_register("rsi"), count));
            state_.write_register("rax", destination);
        } else if (symbol == "DfivPArhucg") {  // memcmp
            const std::size_t count = static_cast<std::size_t>(state_.read_register("rdx"));
            const auto lhs = memory_.read(state_.read_register("rdi"), count);
            const auto rhs = memory_.read(state_.read_register("rsi"), count);
            std::int64_t comparison = 0;
            for (std::size_t position = 0; position < count; ++position) {
                if (lhs[position] != rhs[position]) {
                    comparison = static_cast<std::int64_t>(lhs[position]) - rhs[position];
                    break;
                }
            }
            state_.write_register("rax", static_cast<std::uint64_t>(comparison));
        } else if (symbol == "kiZSXIWd9vg") {  // strcpy
            const std::uint64_t destination = state_.read_register("rdi");
            const std::string source = guest_string(state_.read_register("rsi"));
            memory_.write(destination, reinterpret_cast<const std::uint8_t*>(source.c_str()), source.size() + 1);
            state_.write_register("rax", destination);
        } else if (symbol == "Ls4tzzhimqQ") {  // strcat
            const std::uint64_t destination = state_.read_register("rdi");
            const std::string existing = guest_string(destination);
            const std::string source = guest_string(state_.read_register("rsi"));
            memory_.write(destination + existing.size(), reinterpret_cast<const std::uint8_t*>(source.c_str()), source.size() + 1);
            state_.write_register("rax", destination);
        } else if (symbol == "6sJWiWSRuqk") {  // strncpy
            const std::uint64_t destination = state_.read_register("rdi");
            const std::string source = guest_string(state_.read_register("rsi"));
            const std::size_t count = static_cast<std::size_t>(state_.read_register("rdx"));
            std::vector<std::uint8_t> copied(count, 0);
            const std::size_t copied_count = std::min(count, source.size());
            std::copy_n(reinterpret_cast<const std::uint8_t*>(source.data()), copied_count, copied.begin());
            if (!copied.empty()) memory_.write(destination, copied);
            state_.write_register("rax", destination);
        } else if (symbol == "Ovb2dSJOAuE" || symbol == "aesyjrHVWy4" ||
                   symbol == "AV6ipCNa4Rw" || symbol == "pXvbDfchu6k") {
            const std::string left = guest_string(state_.read_register("rdi"));
            const std::string right = guest_string(state_.read_register("rsi"));
            const std::size_t count = symbol == "aesyjrHVWy4" || symbol == "pXvbDfchu6k"
                ? static_cast<std::size_t>(state_.read_register("rdx"))
                : std::max(left.size(), right.size()) + 1;
            const bool ignore_case = symbol == "AV6ipCNa4Rw" || symbol == "pXvbDfchu6k";
            std::int64_t comparison = 0;
            for (std::size_t position = 0; position < count; ++position) {
                unsigned char a = position < left.size() ? static_cast<unsigned char>(left[position]) : 0;
                unsigned char b = position < right.size() ? static_cast<unsigned char>(right[position]) : 0;
                if (ignore_case) {
                    if (a >= 'A' && a <= 'Z') a = static_cast<unsigned char>(a + ('a' - 'A'));
                    if (b >= 'A' && b <= 'Z') b = static_cast<unsigned char>(b + ('a' - 'A'));
                }
                if (a != b) {
                    comparison = static_cast<std::int64_t>(a) - static_cast<std::int64_t>(b);
                    break;
                }
                if (a == 0) break;
            }
            state_.write_register("rax", static_cast<std::uint64_t>(comparison));
            if (ignore_case) {
                last_import_by_thread_[active_thread_handle_] = symbol + "(\"" + left + "\",\"" + right + "\")=" +
                    std::to_string(comparison);
            }
        } else if (symbol == "dhK16CKwhQg") {  // isfinite(double)
            double value = 0.0;
            std::memcpy(&value, state_.vectors[0].data(), sizeof(value));
            ++isfinite_call_count_;
            const bool finite = std::isfinite(value);
            if (!finite) ++isfinite_reject_count_;
            state_.write_register("rax", finite ? 1 : 0);
        } else if (symbol == "9BcDykPmo1I") {  // libKernel __error
            // errno is thread-local. Each cooperative guest thread already has
            // a private TLS block, so expose a stable writable slot within it.
            state_.write_register("rax", state_.fs_base + 0x100);
        } else if (symbol == "3GPpjQdAMTw") {  // __cxa_guard_acquire
            const std::uint64_t guard = state_.read_register("rdi");
            const std::uint64_t initialized = memory_.read_integer(guard, 1);
            if (initialized == 0) {
                memory_.write_integer(guard, 1, 1);
                state_.write_register("rax", 1);
            } else state_.write_register("rax", 0);
        } else if (symbol == "9rAeANT2tyE") {  // __cxa_guard_release
            state_.write_register("rax", 0);
        } else if (symbol == "xeYO4u7uyJ0") {  // fopen
            const std::string path = guest_string(state_.read_register("rdi"));
            const auto data = read_title_file(path);
            remember(recent_imports_, "fopen " + path + (data.has_value() ? " OK" : " MISSING"), 128);
            if (!data.has_value()) state_.write_register("rax", 0);
            else {
                const std::uint64_t handle = allocate(16, 16);
                open_files_[handle] = {*data, 0, path};
                if (path == "data.js" || path.ends_with("/data.js")) {
                    content_loader_thread_ = active_thread_handle_;
                    content_data_size_ = data->size();
                    content_data_bytes_read_ = 0;
                }
                state_.write_register("rax", handle);
            }
        } else if (symbol == "lbB+UlZqVG0") {  // fread
            const std::uint64_t destination = state_.read_register("rdi");
            const std::uint64_t element_size = state_.read_register("rsi");
            const std::uint64_t element_count = state_.read_register("rdx");
            const std::uint64_t handle = state_.read_register("rcx");
            const auto found = open_files_.find(handle);
            if (destination == 0 || element_size == 0 || found == open_files_.end() ||
                element_count > std::numeric_limits<std::uint64_t>::max() / element_size) {
                state_.write_register("rax", 0);
            } else {
                OpenFile& file = found->second;
                const std::uint64_t requested = element_size * element_count;
                const std::size_t remaining = file.data.size() - std::min(file.offset, file.data.size());
                const std::size_t count = static_cast<std::size_t>(std::min<std::uint64_t>(requested, remaining));
                if (count != 0) {
                    memory_.write(destination, file.data.data() + file.offset, count);
                    file.offset += count;
                }
                if (file.path == "data.js" || file.path.ends_with("/data.js")) {
                    content_data_bytes_read_ = file.offset;
                }
                state_.write_register("rax", count / element_size);
            }
        } else if (symbol == "rQFVBXp-Cxg") {  // fseek
            const auto found = open_files_.find(state_.read_register("rdi"));
            const std::int64_t offset = static_cast<std::int64_t>(state_.read_register("rsi"));
            const std::uint64_t origin = state_.read_register("rdx");
            if (found == open_files_.end() || origin > 2) state_.write_register("rax", ~0ULL);
            else {
                OpenFile& file = found->second;
                const std::int64_t base = origin == 0 ? 0 : origin == 1
                    ? static_cast<std::int64_t>(file.offset)
                    : static_cast<std::int64_t>(file.data.size());
                const bool overflow = (offset > 0 && base > std::numeric_limits<std::int64_t>::max() - offset) ||
                                      (offset < 0 && base < std::numeric_limits<std::int64_t>::min() - offset);
                const std::int64_t target = overflow ? -1 : base + offset;
                if (target < 0 || static_cast<std::uint64_t>(target) > file.data.size()) state_.write_register("rax", ~0ULL);
                else {
                    file.offset = static_cast<std::size_t>(target);
                    state_.write_register("rax", 0);
                }
            }
        } else if (symbol == "Qazy8LmXTvw") {  // ftell
            const auto found = open_files_.find(state_.read_register("rdi"));
            state_.write_register("rax", found == open_files_.end() ? ~0ULL : found->second.offset);
        } else if (symbol == "3QIPIh-GDjw") {  // rewind
            if (const auto found = open_files_.find(state_.read_register("rdi")); found != open_files_.end()) found->second.offset = 0;
            state_.write_register("rax", 0);
        } else if (symbol == "LxcEU+ICu8U") {  // feof
            const auto found = open_files_.find(state_.read_register("rdi"));
            state_.write_register("rax", found == open_files_.end() || found->second.offset >= found->second.data.size() ? 1 : 0);
        } else if (symbol == "AHxyhN96dy4") {  // clearerr
            state_.write_register("rax", 0);
        } else if (symbol == "uodLYyUip20") {  // fclose
            open_files_.erase(state_.read_register("rdi"));
            state_.write_register("rax", 0);
        } else if (symbol == "1uJgoVq3bQU" || symbol == "rcQCUr0EaRU") {
            if (const auto cached = runtime_objects_.find(symbol); cached != runtime_objects_.end()) {
                state_.write_register("rax", cached->second);
            } else {
                const bool lower = symbol == "1uJgoVq3bQU";
                const std::uint64_t storage = allocate(384 * 2, 16);
                for (int character = -128; character <= 255; ++character) {
                    int mapped = character;
                    if (lower && character >= 'A' && character <= 'Z') mapped += 'a' - 'A';
                    else if (!lower && character >= 'a' && character <= 'z') mapped -= 'a' - 'A';
                    const auto value = static_cast<std::uint16_t>(static_cast<std::int16_t>(mapped));
                    memory_.write_integer(storage + static_cast<std::uint64_t>(character + 128) * 2ULL, 2, value);
                }
                const std::uint64_t holder = allocate(8, 8);
                memory_.write_integer(holder, 8, storage + 128ULL * 2ULL);
                runtime_objects_[symbol] = holder;
                state_.write_register("rax", holder);
            }
        } else if (symbol == "uMei1W9uyNo") {
            const std::uint64_t exit_code = state_.read_register("rdi");
            if (!finish_active_thread(exit_code)) pending_stop_ = "guest exit(" + std::to_string(exit_code) + ")";
            state_.write_register("rax", 0);
        } else if (symbol == "rPo6tV8D9bM") {  // sceSystemServiceGetStatus
            const std::uint64_t status_address = state_.read_register("rdi");
            if (status_address == 0) {
                state_.write_register("rax", 0x80A10003ULL);
            } else {
                std::vector<std::uint8_t> status(0x0C, 0);
                status[0x06] = 1;
                memory_.write(status_address, status);
                state_.write_register("rax", 0);
            }
        } else if (symbol == "sjaobBgqeB4") {  // sceNpUniversalDataSystemInitialize
            const std::uint64_t parameters = state_.read_register("rdi");
            if (parameters == 0) {
                state_.write_register("rax", 0x80553102ULL);
            } else {
                try {
                    static_cast<void>(memory_.read(parameters, 16));
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "5zBnau1uIEo") {  // sceNpUniversalDataSystemCreateContext
            const std::uint64_t context = state_.read_register("rdi");
            if (context == 0) {
                state_.write_register("rax", 0);
            } else {
                try {
                    memory_.write_integer(context, 4, 1);
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "hT0IAEvN+M0") {  // sceNpUniversalDataSystemCreateHandle
            const std::uint64_t primary = state_.read_register("rdi");
            const std::uint64_t secondary = state_.read_register("rsi");
            const std::uint64_t output = primary != 0 ? primary : secondary;
            if (output == 0) {
                state_.write_register("rax", kOrbisErrorMemoryFault);
            } else {
                try {
                    memory_.write_integer(output, 4, next_np_universal_handle_++);
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "Bagshr7OQ6Q") {  // sceNpTrophy2CreateContext
            const std::uint64_t output = state_.read_register("rdi");
            if (output == 0) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else {
                try {
                    memory_.write_integer(output, 4, next_trophy_context_++);
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "ERKzksauAJA") {  // sceSaveDataDialogGetStatus
            state_.write_register("rax", save_data_dialog_status_);
        } else if (symbol == "8G2LB+A3rzg" || symbol == "bzQExy189ZI" ||
                   symbol == "cQke9UuBQOk" || symbol == "g8cM39EUZ6o" ||
                   symbol == "hZIg1EWGsHM" || symbol == "j3YMu1MVNNo" ||
                   symbol == "m87BHxt-H60" || symbol == "sUXGfNMalIo" ||
                   symbol == "tpFJ8LIKvPw" || symbol == "tsvEmnenz48" ||
                   symbol == "uoUpLGNkygk" || symbol == "MBuItvba6z8" ||
                   symbol == "Vo5V8KAwCmk" || symbol == "AUIHb7jUX3I") {
            // Reached initialization, registration, teardown, and visibility
            // services whose current SharpEmu HLE completes synchronously.
            state_.write_register("rax", 0);
        } else if (symbol == "rVjRvHJ0X6c") {  // sceKernelVirtualQuery
            const std::uint64_t query_address = state_.read_register("rdi");
            const bool find_next = (state_.read_register("rsi") & 1ULL) != 0;
            const std::uint64_t info_address = state_.read_register("rdx");
            const std::uint64_t info_size = state_.read_register("rcx");
            if (info_address == 0 || info_size < 72) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else if (const auto region = memory_.query(query_address, find_next); !region.has_value()) {
                state_.write_register("rax", kOrbisErrorNotFound);
            } else {
                try {
                    memory_.write(info_address, std::vector<std::uint8_t>(72, 0));
                    memory_.write_integer(info_address + 0, 8, region->base);
                    memory_.write_integer(info_address + 8, 8, region->end());
                    memory_.write_integer(info_address + 16, 8, 0);
                    memory_.write_integer(info_address + 24, 4, region->protection);
                    memory_.write_integer(info_address + 28, 4, 0);
                    memory_.write_integer(info_address + 32, 1, 0x10);
                    const std::size_t label_size = std::min<std::size_t>(region->label.size(), 32);
                    memory_.write(
                        info_address + 33,
                        reinterpret_cast<const std::uint8_t*>(region->label.data()),
                        label_size);
                    state_.write_register("rax", 0);
                } catch (const std::exception&) {
                    state_.write_register("rax", kOrbisErrorMemoryFault);
                }
            }
        } else if (symbol == "vSMAm3cxYTY") {  // sceKernelMprotect
            const std::uint64_t address = state_.read_register("rdi");
            const std::uint64_t length = state_.read_register("rsi");
            const std::uint64_t protection = state_.read_register("rdx");
            __android_log_print(
                ANDROID_LOG_INFO,
                "VibeStation5Runtime",
                "sceKernelMprotect address=0x%llx length=0x%llx protection=0x%llx",
                static_cast<unsigned long long>(address),
                static_cast<unsigned long long>(length),
                static_cast<unsigned long long>(protection));
            if (address == 0 || length == 0 || address > std::numeric_limits<std::uint64_t>::max() - length) {
                state_.write_register("rax", kOrbisErrorInvalidArgument);
            } else {
                const std::uint64_t aligned_address = address & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
                const std::uint64_t unaligned_end = address + length;
                if (unaligned_end > std::numeric_limits<std::uint64_t>::max() - (kPageSize - 1ULL)) {
                    state_.write_register("rax", kOrbisErrorInvalidArgument);
                } else {
                    const std::uint64_t aligned_end =
                        (unaligned_end + kPageSize - 1ULL) & ~(static_cast<std::uint64_t>(kPageSize) - 1ULL);
                    state_.write_register(
                        "rax",
                        memory_.protect(
                            aligned_address,
                            aligned_end - aligned_address,
                            static_cast<std::uint8_t>(
                                protection & (kRead | kWrite | kExecute | kGpuRead | kGpuWrite)))
                            ? 0
                            : kOrbisErrorNotFound);
                }
            }
        } else if (symbol == "XKRegsFpEpk") {  // catchReturnFromMain
            const std::uint64_t exit_code = state_.read_register("rax");
            if (!finish_active_thread(exit_code)) pending_stop_ = "guest main returned " + std::to_string(exit_code);
        } else {
            // Unknown PS4/PS5 services are deterministic stubs during bring-up.
            // Returning zero mirrors the Apple core's safe default while every
            // implemented service below this layer remains observable by NID.
            std::uint64_t& calls = unhandled_import_counts_[symbol];
            ++calls;
            if (calls == 1) {
                __android_log_print(
                    ANDROID_LOG_WARN,
                    "VibeStation5Runtime",
                    "unhandled import %s reached by thread=0x%llx",
                    symbol.c_str(),
                    static_cast<unsigned long long>(active_thread_handle_));
            }
            state_.write_register("rax", 0);
        }
    }

    bool try_execute_circular_stereo_copy_loop(const Instruction& instruction) {
        static constexpr std::array<std::uint8_t, 52> signature{
            0x48, 0x63, 0xC6, 0x41, 0x8B, 0x34, 0x01, 0x83, 0xC0, 0x04, 0x44, 0x39, 0xD0,
            0x0F, 0x4D, 0xC1, 0x41, 0x89, 0x34, 0xD3, 0x48, 0x63, 0xF0, 0x41, 0x8B, 0x04,
            0x31, 0x83, 0xC6, 0x04, 0x44, 0x39, 0xD6, 0x0F, 0x4D, 0xF1, 0x41, 0x89, 0x44,
            0xD3, 0x04, 0x48, 0xFF, 0xC2, 0x81, 0xFA, 0x00, 0x01, 0x00, 0x00, 0x75, 0xCC,
        };
        const std::uint64_t loop_address = instruction.address;
        if (instruction.text() != "movsxd rax, esi") return false;
        try {
            const std::vector<std::uint8_t> bytes = memory_.fetch(loop_address, signature.size());
            if (!std::equal(signature.begin(), signature.end(), bytes.begin())) return false;
        } catch (const std::exception&) {
            return false;
        }

        const std::uint64_t source = state_.read_register("r9");
        const std::uint64_t destination = state_.read_register("r11");
        const std::int32_t limit = static_cast<std::int32_t>(state_.read_register("r10d"));
        const std::int32_t reset = static_cast<std::int32_t>(state_.read_register("ecx"));
        std::int32_t offset = static_cast<std::int32_t>(state_.read_register("esi"));
        const std::uint32_t start_frame = static_cast<std::uint32_t>(state_.read_register("edx"));
        if (limit <= 0 || offset < 0 || offset >= limit || reset < 0 || reset >= limit) return false;
        if (start_frame >= 256) return false;
        const std::uint64_t instructions_to_yield =
            10'000ULL - ((executing_instruction_count_ - 1ULL) % 10'000ULL);
        const std::uint32_t frame_count = std::min<std::uint32_t>(
            256U - start_frame,
            static_cast<std::uint32_t>(instructions_to_yield / 15ULL));
        if (frame_count == 0) return false;

        std::uint32_t last_sample = 0;
        for (std::uint32_t frame = start_frame; frame < start_frame + frame_count; ++frame) {
            const std::uint32_t first = static_cast<std::uint32_t>(
                memory_.read_integer(source + static_cast<std::uint32_t>(offset), 4));
            offset = static_cast<std::int32_t>(static_cast<std::uint32_t>(offset) + 4U);
            if (offset >= limit) offset = reset;
            const std::uint32_t second = static_cast<std::uint32_t>(
                memory_.read_integer(source + static_cast<std::uint32_t>(offset), 4));
            offset = static_cast<std::int32_t>(static_cast<std::uint32_t>(offset) + 4U);
            if (offset >= limit) offset = reset;
            memory_.write_integer(destination + static_cast<std::uint64_t>(frame) * 8ULL, 4, first);
            memory_.write_integer(destination + static_cast<std::uint64_t>(frame) * 8ULL + 4ULL, 4, second);
            last_sample = second;
        }
        state_.write_register("eax", last_sample);
        state_.write_register("esi", static_cast<std::uint32_t>(offset));
        const std::uint32_t next_frame = start_frame + frame_count;
        state_.write_register("edx", next_frame);
        update_sub_flags(state_, next_frame, 256, next_frame - 256U, 4);
        state_.rip = next_frame == 256 ? loop_address + signature.size() : loop_address;
        fused_instruction_credit_ = static_cast<std::uint64_t>(frame_count) * 15ULL - 1ULL;
        ++fused_circular_copy_count_;
        fused_circular_frame_count_ += frame_count;
        return true;
    }

    std::optional<std::string> execute(const Instruction& instruction) {
        const auto& operands = instruction.operands;
        std::string mnemonic = instruction.mnemonic;
        if (mnemonic.starts_with("lock ")) mnemonic.erase(0, 5);
        const auto require_operands = [&](std::size_t count) {
            if (operands.size() != count) throw std::invalid_argument("unexpected operands: " + instruction.text());
        };

        if (mnemonic == "movsxd" && try_execute_circular_stereo_copy_loop(instruction)) return std::nullopt;
        if (mnemonic == "nop" || mnemonic == "endbr64" || mnemonic == "pause" ||
            mnemonic == "lfence" || mnemonic == "mfence" || mnemonic == "sfence") return std::nullopt;
        if (mnemonic == "vzeroupper" || mnemonic == "vzeroall") {
            for (auto& vector : state_.vectors) {
                const std::size_t begin = mnemonic == "vzeroupper" ? 16 : 0;
                std::fill(vector.begin() + static_cast<std::ptrdiff_t>(begin), vector.end(), 0);
            }
            return std::nullopt;
        }
        if (mnemonic == "mov" || mnemonic == "movabs" || mnemonic == "movaps" || mnemonic == "movups" ||
            mnemonic == "movapd" || mnemonic == "movupd" || mnemonic == "movdqa" || mnemonic == "movdqu" ||
            mnemonic == "vmovaps" || mnemonic == "vmovups" || mnemonic == "vmovapd" || mnemonic == "vmovupd" ||
            mnemonic == "vmovdqa" || mnemonic == "vmovdqu" || mnemonic == "vmovdqa32" || mnemonic == "vmovdqa64" ||
            mnemonic == "vmovdqu8" || mnemonic == "vmovdqu16" || mnemonic == "vmovdqu32" || mnemonic == "vmovdqu64" ||
            mnemonic == "movd" || mnemonic == "movq" || mnemonic == "vmovd" || mnemonic == "vmovq" ||
            mnemonic == "movss" || mnemonic == "movsd" || mnemonic == "vmovss" || mnemonic == "vmovsd") {
            if (operands.size() < 2) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const auto scalar_integer = [](const Operand& operand) {
                return operand.size <= 8 &&
                    (operand.kind != OperandKind::Register || operand.register_reference.has_value());
            };
            if (scalar_integer(operands[0]) && scalar_integer(operands.back())) {
                write_operand(operands[0], instruction, read_operand(operands.back(), instruction));
            } else {
                write_bytes(operands[0], instruction, read_bytes(operands.back(), instruction));
            }
            return std::nullopt;
        }
        if (mnemonic == "bswap") {
            require_operands(1);
            const std::uint64_t value = read_operand(operands[0], instruction);
            std::uint64_t swapped = 0;
            for (std::size_t byte = 0; byte < operands[0].size; ++byte) {
                swapped = (swapped << 8U) | ((value >> (byte * 8U)) & 0xFFU);
            }
            write_operand(operands[0], instruction, swapped);
            return std::nullopt;
        }
        if (mnemonic == "movlps" || mnemonic == "movhps" || mnemonic == "vmovlps" || mnemonic == "vmovhps") {
            if (operands.size() < 2 || operands.size() > 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const bool high = mnemonic.ends_with("hps");
            if (operands[0].kind == OperandKind::Memory) {
                auto source = read_bytes(operands.back(), instruction);
                const std::size_t offset = high ? 8 : 0;
                std::vector<std::uint8_t> lane(8, 0);
                if (source.size() >= offset + 8) std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(offset), 8, lane.begin());
                write_bytes(operands[0], instruction, lane);
            } else {
                const std::size_t source_index = operands.size() == 3 ? 1 : 0;
                auto result = read_bytes(operands[source_index], instruction);
                result.resize(16, 0);
                const auto lane = read_bytes(operands.back(), instruction);
                const std::size_t offset = high ? 8 : 0;
                std::copy_n(lane.begin(), std::min<std::size_t>(lane.size(), 8), result.begin() + static_cast<std::ptrdiff_t>(offset));
                write_bytes(operands[0], instruction, result);
            }
            return std::nullopt;
        }
        if (mnemonic == "xorps" || mnemonic == "xorpd" || mnemonic == "pxor" || mnemonic == "vxorps" ||
            mnemonic == "vxorpd" || mnemonic == "vpxor" || mnemonic == "vpxord" || mnemonic == "vpxorq") {
            if (operands.size() < 2 || operands.size() > 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t lhs_index = operands.size() == 3 ? 1 : 0;
            auto lhs = read_bytes(operands[lhs_index], instruction);
            const auto rhs = read_bytes(operands.back(), instruction);
            lhs.resize(operands[0].size, 0);
            for (std::size_t index = 0; index < std::min(lhs.size(), rhs.size()); ++index) lhs[index] ^= rhs[index];
            write_bytes(operands[0], instruction, lhs);
            return std::nullopt;
        }
        if (mnemonic == "pand" || mnemonic == "por" || mnemonic == "pandn" || mnemonic == "vpand" ||
            mnemonic == "vpor" || mnemonic == "vpandn" || mnemonic == "vpandd" || mnemonic == "vpandq" ||
            mnemonic == "vpord" || mnemonic == "vporq" || mnemonic == "vpandnd" || mnemonic == "vpandnq" ||
            mnemonic == "andps" || mnemonic == "andpd" || mnemonic == "orps" || mnemonic == "orpd" ||
            mnemonic == "andnps" || mnemonic == "andnpd" || mnemonic == "vandps" || mnemonic == "vandpd" ||
            mnemonic == "vorps" || mnemonic == "vorpd" || mnemonic == "vandnps" || mnemonic == "vandnpd") {
            if (operands.size() < 2 || operands.size() > 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t lhs_index = operands.size() == 3 ? 1 : 0;
            auto lhs = read_bytes(operands[lhs_index], instruction);
            const auto rhs = read_bytes(operands.back(), instruction);
            lhs.resize(operands[0].size, 0);
            const bool invert = mnemonic.find("andn") != std::string::npos;
            const bool use_or = mnemonic.find("or") != std::string::npos && !invert;
            for (std::size_t index = 0; index < lhs.size(); ++index) {
                const std::uint8_t right = index < rhs.size() ? rhs[index] : 0;
                lhs[index] = invert ? static_cast<std::uint8_t>(~lhs[index]) & right :
                             use_or ? lhs[index] | right : lhs[index] & right;
            }
            write_bytes(operands[0], instruction, lhs);
            return std::nullopt;
        }
        if (mnemonic == "paddb" || mnemonic == "paddw" || mnemonic == "paddd" || mnemonic == "paddq" ||
            mnemonic == "vpaddb" || mnemonic == "vpaddw" || mnemonic == "vpaddd" || mnemonic == "vpaddq" ||
            mnemonic == "psubb" || mnemonic == "psubw" || mnemonic == "psubd" || mnemonic == "psubq" ||
            mnemonic == "vpsubb" || mnemonic == "vpsubw" || mnemonic == "vpsubd" || mnemonic == "vpsubq" ||
            mnemonic == "pmullw" || mnemonic == "pmulld" || mnemonic == "pmullq" ||
            mnemonic == "vpmullw" || mnemonic == "vpmulld" || mnemonic == "vpmullq") {
            if (operands.size() < 2 || operands.size() > 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t lhs_index = operands.size() == 3 ? 1 : 0;
            const auto lhs = read_bytes(operands[lhs_index], instruction);
            const auto rhs = read_bytes(operands.back(), instruction);
            const std::size_t lane_size = mnemonic.ends_with("b") ? 1 : mnemonic.ends_with("w") ? 2 :
                mnemonic.ends_with("d") ? 4 : 8;
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset + lane_size <= result.size(); offset += lane_size) {
                std::uint64_t left = 0;
                std::uint64_t right = 0;
                for (std::size_t byte = 0; byte < lane_size; ++byte) {
                    if (offset + byte < lhs.size()) left |= static_cast<std::uint64_t>(lhs[offset + byte]) << (byte * 8U);
                    if (offset + byte < rhs.size()) right |= static_cast<std::uint64_t>(rhs[offset + byte]) << (byte * 8U);
                }
                const std::uint64_t value = mnemonic.find("padd") != std::string::npos ? left + right :
                    mnemonic.find("psub") != std::string::npos ? left - right : left * right;
                for (std::size_t byte = 0; byte < lane_size; ++byte) {
                    result[offset + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pcmpeqb" || mnemonic == "pcmpeqw" || mnemonic == "pcmpeqd" || mnemonic == "pcmpeqq" ||
            mnemonic == "vpcmpeqb" || mnemonic == "vpcmpeqw" || mnemonic == "vpcmpeqd" || mnemonic == "vpcmpeqq" ||
            mnemonic == "pcmpgtb" || mnemonic == "pcmpgtw" || mnemonic == "pcmpgtd" || mnemonic == "pcmpgtq" ||
            mnemonic == "vpcmpgtb" || mnemonic == "vpcmpgtw" || mnemonic == "vpcmpgtd" || mnemonic == "vpcmpgtq") {
            if (operands.size() < 2 || operands.size() > 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t lhs_index = operands.size() == 3 ? 1 : 0;
            const auto lhs = read_bytes(operands[lhs_index], instruction);
            const auto rhs = read_bytes(operands.back(), instruction);
            const char suffix = mnemonic.back();
            const std::size_t element_size = suffix == 'b' ? 1 : suffix == 'w' ? 2 : suffix == 'd' ? 4 : 8;
            const bool greater = mnemonic.find("cmpgt") != std::string::npos;
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset + element_size <= result.size(); offset += element_size) {
                std::uint64_t left = 0;
                std::uint64_t right = 0;
                for (std::size_t byte = 0; byte < element_size; ++byte) {
                    if (offset + byte < lhs.size()) left |= static_cast<std::uint64_t>(lhs[offset + byte]) << (byte * 8U);
                    if (offset + byte < rhs.size()) right |= static_cast<std::uint64_t>(rhs[offset + byte]) << (byte * 8U);
                }
                const bool matched = greater
                    ? static_cast<std::int64_t>(sign_extend(left, element_size)) > static_cast<std::int64_t>(sign_extend(right, element_size))
                    : left == right;
                if (matched) std::fill_n(result.begin() + static_cast<std::ptrdiff_t>(offset), element_size, 0xFF);
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vpbroadcastb" || mnemonic == "vpbroadcastw" || mnemonic == "vpbroadcastd" ||
            mnemonic == "vpbroadcastq" || mnemonic == "vbroadcastss" || mnemonic == "vbroadcastsd" ||
            mnemonic == "vbroadcastf128" || mnemonic == "vbroadcasti128") {
            require_operands(2);
            const std::size_t element_size = mnemonic == "vpbroadcastb" ? 1 :
                                             mnemonic == "vpbroadcastw" ? 2 :
                                             (mnemonic == "vpbroadcastd" || mnemonic == "vbroadcastss") ? 4 :
                                             (mnemonic == "vpbroadcastq" || mnemonic == "vbroadcastsd") ? 8 : 16;
            auto element = read_bytes(operands[1], instruction);
            element.resize(element_size, 0);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset < result.size(); offset += element_size) {
                std::copy_n(element.begin(), std::min(element_size, result.size() - offset),
                            result.begin() + static_cast<std::ptrdiff_t>(offset));
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pextrb" || mnemonic == "pextrw" || mnemonic == "pextrd" || mnemonic == "pextrq" ||
            mnemonic == "vpextrb" || mnemonic == "vpextrw" || mnemonic == "vpextrd" || mnemonic == "vpextrq") {
            require_operands(3);
            const char suffix = mnemonic.back();
            const std::size_t element_size = suffix == 'b' ? 1 : suffix == 'w' ? 2 : suffix == 'd' ? 4 : 8;
            const auto source = read_bytes(operands[1], instruction);
            const std::size_t elements = std::max<std::size_t>(source.size() / element_size, 1);
            const std::size_t selected = static_cast<std::size_t>(read_operand(operands[2], instruction)) % elements;
            std::uint64_t value = 0;
            for (std::size_t byte = 0; byte < element_size; ++byte) {
                value |= static_cast<std::uint64_t>(source[selected * element_size + byte]) << (byte * 8U);
            }
            write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if (mnemonic == "pinsrb" || mnemonic == "pinsrw" || mnemonic == "pinsrd" || mnemonic == "pinsrq" ||
            mnemonic == "vpinsrb" || mnemonic == "vpinsrw" || mnemonic == "vpinsrd" || mnemonic == "vpinsrq") {
            if (operands.size() != 3 && operands.size() != 4) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const char suffix = mnemonic.back();
            const std::size_t element_size = suffix == 'b' ? 1 : suffix == 'w' ? 2 : suffix == 'd' ? 4 : 8;
            const std::size_t base_index = operands.size() == 4 ? 1 : 0;
            const std::size_t source_index = operands.size() == 4 ? 2 : 1;
            auto result = read_bytes(operands[base_index], instruction);
            result.resize(operands[0].size, 0);
            const std::uint64_t value = read_operand(operands[source_index], instruction);
            const std::size_t elements = std::max<std::size_t>(result.size() / element_size, 1);
            const std::size_t selected = static_cast<std::size_t>(read_operand(operands.back(), instruction)) % elements;
            for (std::size_t byte = 0; byte < element_size; ++byte) {
                result[selected * element_size + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vextractf128" || mnemonic == "vextracti128") {
            require_operands(3);
            const auto source = read_bytes(operands[1], instruction);
            const std::size_t lane = static_cast<std::size_t>(read_operand(operands[2], instruction) & 1U);
            std::vector<std::uint8_t> result(16, 0);
            if (source.size() >= (lane + 1) * 16) {
                std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(lane * 16), 16, result.begin());
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic.starts_with("vpmovzx") || mnemonic.starts_with("vpmovsx") ||
            mnemonic.starts_with("pmovzx") || mnemonic.starts_with("pmovsx")) {
            require_operands(2);
            const bool signed_extension = mnemonic.find("movsx") != std::string::npos;
            const std::string_view suffix(mnemonic.data() + static_cast<std::ptrdiff_t>(mnemonic.size() - 2), 2);
            const auto element_size = [](char kind) -> std::size_t {
                return kind == 'b' ? 1 : kind == 'w' ? 2 : kind == 'd' ? 4 : 8;
            };
            const std::size_t source_size = element_size(suffix[0]);
            const std::size_t destination_size = element_size(suffix[1]);
            const auto source = read_bytes(operands[1], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const std::size_t elements = result.size() / destination_size;
            for (std::size_t element = 0; element < elements; ++element) {
                std::uint64_t value = 0;
                const std::size_t source_offset = element * source_size;
                for (std::size_t byte = 0; byte < source_size && source_offset + byte < source.size(); ++byte) {
                    value |= static_cast<std::uint64_t>(source[source_offset + byte]) << (byte * 8U);
                }
                if (signed_extension) value = sign_extend(value, source_size);
                for (std::size_t byte = 0; byte < destination_size; ++byte) {
                    result[element * destination_size + byte] = static_cast<std::uint8_t>(value >> (byte * 8U));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vpsllvd" || mnemonic == "vpsllvq" || mnemonic == "vpsrlvd" ||
            mnemonic == "vpsrlvq" || mnemonic == "vpsravd" || mnemonic == "vpsravq") {
            require_operands(3);
            const std::size_t element_size = mnemonic.ends_with('d') ? 4 : 8;
            const unsigned bits = static_cast<unsigned>(element_size * 8U);
            const auto values = read_bytes(operands[1], instruction);
            const auto counts = read_bytes(operands[2], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset + element_size <= result.size(); offset += element_size) {
                std::uint64_t value = 0;
                std::uint64_t count = 0;
                for (std::size_t byte = 0; byte < element_size; ++byte) {
                    if (offset + byte < values.size()) value |= static_cast<std::uint64_t>(values[offset + byte]) << (byte * 8U);
                    if (offset + byte < counts.size()) count |= static_cast<std::uint64_t>(counts[offset + byte]) << (byte * 8U);
                }
                std::uint64_t shifted = 0;
                if (mnemonic.starts_with("vpsll")) shifted = count >= bits ? 0 : value << count;
                else if (mnemonic.starts_with("vpsrl")) shifted = count >= bits ? 0 : value >> count;
                else if (count >= bits) shifted = (value >> (bits - 1U)) != 0 ? mask_for(element_size) : 0;
                else shifted = static_cast<std::uint64_t>(static_cast<std::int64_t>(sign_extend(value, element_size)) >> count);
                for (std::size_t byte = 0; byte < element_size; ++byte) {
                    result[offset + byte] = static_cast<std::uint8_t>(shifted >> (byte * 8U));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "psllw" || mnemonic == "pslld" || mnemonic == "psllq" ||
            mnemonic == "vpsllw" || mnemonic == "vpslld" || mnemonic == "vpsllq" ||
            mnemonic == "psrlw" || mnemonic == "psrld" || mnemonic == "psrlq" ||
            mnemonic == "vpsrlw" || mnemonic == "vpsrld" || mnemonic == "vpsrlq" ||
            mnemonic == "psraw" || mnemonic == "psrad" || mnemonic == "psraq" ||
            mnemonic == "vpsraw" || mnemonic == "vpsrad" || mnemonic == "vpsraq") {
            if (operands.size() != 2 && operands.size() != 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t source_index = operands.size() == 3 ? 1 : 0;
            const char suffix = mnemonic.back();
            const std::size_t element_size = suffix == 'w' ? 2 : suffix == 'd' ? 4 : 8;
            const unsigned bits = static_cast<unsigned>(element_size * 8U);
            const std::uint64_t count = read_operand(operands.back(), instruction);
            const auto source = read_bytes(operands[source_index], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset + element_size <= result.size(); offset += element_size) {
                std::uint64_t value = 0;
                for (std::size_t byte = 0; byte < element_size && offset + byte < source.size(); ++byte) {
                    value |= static_cast<std::uint64_t>(source[offset + byte]) << (byte * 8U);
                }
                std::uint64_t shifted = 0;
                if (mnemonic.find("psll") != std::string::npos) shifted = count >= bits ? 0 : value << count;
                else if (mnemonic.find("psrl") != std::string::npos) shifted = count >= bits ? 0 : value >> count;
                else if (count >= bits) shifted = (value >> (bits - 1U)) != 0 ? mask_for(element_size) : 0;
                else shifted = static_cast<std::uint64_t>(static_cast<std::int64_t>(sign_extend(value, element_size)) >> count);
                for (std::size_t byte = 0; byte < element_size; ++byte) {
                    result[offset + byte] = static_cast<std::uint8_t>(shifted >> (byte * 8U));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pslldq" || mnemonic == "psrldq" || mnemonic == "vpslldq" || mnemonic == "vpsrldq") {
            if (operands.size() != 2 && operands.size() != 3) throw std::invalid_argument("unexpected operands: " + instruction.text());
            const std::size_t source_index = operands.size() == 3 ? 1 : 0;
            const auto source = read_bytes(operands[source_index], instruction);
            const std::size_t count = std::min<std::size_t>(static_cast<std::size_t>(read_operand(operands.back(), instruction)), 16);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                for (std::size_t byte = 0; byte < 16; ++byte) {
                    const std::size_t source_byte = mnemonic.find("psll") != std::string::npos
                        ? (byte >= count ? byte - count : 16)
                        : (byte + count < 16 ? byte + count : 16);
                    if (source_byte < 16 && lane + source_byte < source.size()) result[lane + byte] = source[lane + source_byte];
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vblendvpd" || mnemonic == "vblendvps") {
            require_operands(4);
            const auto first = read_bytes(operands[1], instruction);
            const auto second = read_bytes(operands[2], instruction);
            const auto mask = read_bytes(operands[3], instruction);
            const std::size_t lane_size = mnemonic.ends_with("pd") ? sizeof(double) : sizeof(float);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t offset = 0; offset + lane_size <= result.size(); offset += lane_size) {
                const bool select_second = offset + lane_size <= mask.size() &&
                    (mask[offset + lane_size - 1] & 0x80U) != 0;
                const auto& source = select_second ? second : first;
                if (offset + lane_size <= source.size()) {
                    std::copy_n(
                        source.begin() + static_cast<std::ptrdiff_t>(offset),
                        lane_size,
                        result.begin() + static_cast<std::ptrdiff_t>(offset));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pshufb" || mnemonic == "vpshufb") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            const auto source = read_bytes(operands[vex ? 1 : 0], instruction);
            const auto control = read_bytes(operands.back(), instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                for (std::size_t byte = 0; byte < 16 && lane + byte < result.size(); ++byte) {
                    const std::uint8_t selector = lane + byte < control.size() ? control[lane + byte] : 0x80;
                    if ((selector & 0x80U) == 0) {
                        const std::size_t source_index = lane + (selector & 0x0FU);
                        if (source_index < source.size()) result[lane + byte] = source[source_index];
                    }
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pshufd" || mnemonic == "vpshufd") {
            require_operands(3);
            const auto source = read_bytes(operands[1], instruction);
            const std::uint8_t control = static_cast<std::uint8_t>(read_operand(operands[2], instruction));
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                for (std::size_t destination = 0; destination < 4; ++destination) {
                    const std::size_t selected = (control >> (destination * 2U)) & 3U;
                    const std::size_t source_offset = lane + selected * 4;
                    const std::size_t target_offset = lane + destination * 4;
                    if (source_offset + 4 <= source.size()) {
                        std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(source_offset), 4,
                                    result.begin() + static_cast<std::ptrdiff_t>(target_offset));
                    }
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "pblendw" || mnemonic == "vpblendw" ||
            mnemonic == "pblendd" || mnemonic == "vpblendd") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 4 : 3);
            const auto left = read_bytes(operands[vex ? 1 : 0], instruction);
            const auto right = read_bytes(operands[vex ? 2 : 1], instruction);
            const std::uint8_t control = static_cast<std::uint8_t>(read_operand(operands.back(), instruction));
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const std::size_t element_size = mnemonic.ends_with("d") ? 4 : 2;
            for (std::size_t element = 0; element * element_size < result.size(); ++element) {
                const auto& source = ((control >> (element & 7U)) & 1U) != 0 ? right : left;
                const std::size_t offset = element * element_size;
                if (offset + element_size <= source.size()) {
                    std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(offset), element_size,
                                result.begin() + static_cast<std::ptrdiff_t>(offset));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "punpcklbw" || mnemonic == "vpunpcklbw" ||
            mnemonic == "punpcklwd" || mnemonic == "vpunpcklwd" ||
            mnemonic == "punpckldq" || mnemonic == "vpunpckldq" ||
            mnemonic == "punpcklqdq" || mnemonic == "vpunpcklqdq" ||
            mnemonic == "punpckhbw" || mnemonic == "vpunpckhbw" ||
            mnemonic == "punpckhwd" || mnemonic == "vpunpckhwd" ||
            mnemonic == "punpckhdq" || mnemonic == "vpunpckhdq" ||
            mnemonic == "punpckhqdq" || mnemonic == "vpunpckhqdq") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            const auto left = read_bytes(operands[vex ? 1 : 0], instruction);
            const auto right = read_bytes(operands.back(), instruction);
            const bool high = mnemonic.find("punpckh") != std::string::npos;
            const std::size_t element_size = mnemonic.ends_with("qdq") ? 8
                : mnemonic.ends_with("dq") ? 4
                : mnemonic.ends_with("wd") ? 2 : 1;
            const std::size_t elements_per_lane = 16 / element_size;
            const std::size_t source_element = high ? elements_per_lane / 2 : 0;
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                for (std::size_t element = 0; element < elements_per_lane / 2; ++element) {
                    const std::size_t source_offset = lane + (source_element + element) * element_size;
                    const std::size_t left_offset = lane + element * 2 * element_size;
                    const std::size_t right_offset = left_offset + element_size;
                    if (source_offset + element_size <= left.size()) {
                        std::copy_n(left.begin() + static_cast<std::ptrdiff_t>(source_offset), element_size,
                                    result.begin() + static_cast<std::ptrdiff_t>(left_offset));
                    }
                    if (source_offset + element_size <= right.size()) {
                        std::copy_n(right.begin() + static_cast<std::ptrdiff_t>(source_offset), element_size,
                                    result.begin() + static_cast<std::ptrdiff_t>(right_offset));
                    }
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vpermilps" || mnemonic == "vpermilpd") {
            require_operands(3);
            const auto source = read_bytes(operands[1], instruction);
            const std::size_t element_size = mnemonic.ends_with("pd") ? 8 : 4;
            const std::size_t elements_per_lane = 16 / element_size;
            const bool immediate = operands[2].kind == OperandKind::Immediate;
            const std::uint8_t immediate_control = immediate
                ? static_cast<std::uint8_t>(read_operand(operands[2], instruction)) : 0;
            const auto vector_control = immediate ? std::vector<std::uint8_t>() : read_bytes(operands[2], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                for (std::size_t element = 0; element < elements_per_lane; ++element) {
                    std::size_t selected = 0;
                    if (immediate) {
                        const std::size_t shift = element_size == 8 ? element : element * 2;
                        selected = (immediate_control >> shift) & (elements_per_lane - 1);
                    } else {
                        std::uint64_t control = 0;
                        const std::size_t control_offset = lane + element * element_size;
                        for (std::size_t byte = 0; byte < element_size && control_offset + byte < vector_control.size(); ++byte) {
                            control |= static_cast<std::uint64_t>(vector_control[control_offset + byte]) << (byte * 8U);
                        }
                        selected = element_size == 8 ? (control >> 1U) & 1U : control & 3U;
                    }
                    const std::size_t source_offset = lane + selected * element_size;
                    const std::size_t destination_offset = lane + element * element_size;
                    if (source_offset + element_size <= source.size()) {
                        std::copy_n(source.begin() + static_cast<std::ptrdiff_t>(source_offset), element_size,
                                    result.begin() + static_cast<std::ptrdiff_t>(destination_offset));
                    }
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "packsswb" || mnemonic == "vpacksswb" ||
            mnemonic == "packssdw" || mnemonic == "vpackssdw" ||
            mnemonic == "packuswb" || mnemonic == "vpackuswb" ||
            mnemonic == "packusdw" || mnemonic == "vpackusdw") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            const auto left = read_bytes(operands[vex ? 1 : 0], instruction);
            const auto right = read_bytes(operands.back(), instruction);
            const bool dword_source = mnemonic.ends_with("dw");
            const bool unsigned_destination = mnemonic.find("packus") != std::string::npos;
            const std::size_t source_size = dword_source ? 4 : 2;
            const std::size_t destination_size = source_size / 2;
            const std::size_t source_elements_per_lane = 16 / source_size;
            const unsigned destination_bits = static_cast<unsigned>(destination_size * 8U);
            const std::int64_t minimum = unsigned_destination ? 0 : -(1LL << (destination_bits - 1U));
            const std::int64_t maximum = unsigned_destination
                ? static_cast<std::int64_t>((1ULL << destination_bits) - 1ULL)
                : (1LL << (destination_bits - 1U)) - 1LL;
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const auto pack_source = [&](const std::vector<std::uint8_t>& source, std::size_t lane,
                                         std::size_t destination_element) {
                for (std::size_t element = 0; element < source_elements_per_lane; ++element) {
                    const std::size_t source_offset = lane + element * source_size;
                    std::uint64_t raw = 0;
                    for (std::size_t byte = 0; byte < source_size && source_offset + byte < source.size(); ++byte) {
                        raw |= static_cast<std::uint64_t>(source[source_offset + byte]) << (byte * 8U);
                    }
                    const std::int64_t value = static_cast<std::int64_t>(sign_extend(raw, source_size));
                    const std::uint64_t packed = static_cast<std::uint64_t>(std::clamp(value, minimum, maximum));
                    const std::size_t destination_offset = lane + (destination_element + element) * destination_size;
                    for (std::size_t byte = 0; byte < destination_size; ++byte) {
                        result[destination_offset + byte] = static_cast<std::uint8_t>(packed >> (byte * 8U));
                    }
                }
            };
            for (std::size_t lane = 0; lane < result.size(); lane += 16) {
                pack_source(left, lane, 0);
                pack_source(right, lane, source_elements_per_lane);
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "vinsertf128" || mnemonic == "vinserti128") {
            require_operands(4);
            auto result = read_bytes(operands[1], instruction);
            result.resize(operands[0].size, 0);
            const auto lane_value = read_bytes(operands[2], instruction);
            const std::size_t lane = static_cast<std::size_t>(read_operand(operands[3], instruction) & 1U);
            std::copy_n(lane_value.begin(), std::min<std::size_t>(lane_value.size(), 16),
                        result.begin() + static_cast<std::ptrdiff_t>(lane * 16));
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "cvtsi2ss" || mnemonic == "cvtsi2sd" ||
            mnemonic == "vcvtsi2ss" || mnemonic == "vcvtsi2sd" ||
            mnemonic == "cvtusi2ss" || mnemonic == "cvtusi2sd" ||
            mnemonic == "vcvtusi2ss" || mnemonic == "vcvtusi2sd") {
            const bool vex = mnemonic.starts_with("v");
            const std::size_t expected_operands = vex ? 3 : 2;
            require_operands(expected_operands);
            const std::size_t source_index = expected_operands - 1;
            const std::size_t passthrough_index = vex ? 1 : 0;
            auto result = read_bytes(operands[passthrough_index], instruction);
            result.resize(operands[0].size, 0);

            const std::uint64_t raw = read_operand(operands[source_index], instruction);
            const bool unsigned_source = mnemonic.find("cvtusi") != std::string::npos;
            const bool destination_is_double = mnemonic.ends_with("sd");
            if (destination_is_double) {
                const double converted = unsigned_source
                    ? static_cast<double>(raw)
                    : static_cast<double>(static_cast<std::int64_t>(sign_extend(raw, operands[source_index].size)));
                static_assert(sizeof(converted) == sizeof(std::uint64_t));
                std::uint64_t bits = 0;
                std::memcpy(&bits, &converted, sizeof(bits));
                for (std::size_t byte = 0; byte < sizeof(bits); ++byte) {
                    result[byte] = static_cast<std::uint8_t>(bits >> (byte * 8U));
                }
            } else {
                const float converted = unsigned_source
                    ? static_cast<float>(raw)
                    : static_cast<float>(static_cast<std::int64_t>(sign_extend(raw, operands[source_index].size)));
                static_assert(sizeof(converted) == sizeof(std::uint32_t));
                std::uint32_t bits = 0;
                std::memcpy(&bits, &converted, sizeof(bits));
                for (std::size_t byte = 0; byte < sizeof(bits); ++byte) {
                    result[byte] = static_cast<std::uint8_t>(bits >> (byte * 8U));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "cvtss2sd" || mnemonic == "cvtsd2ss" ||
            mnemonic == "vcvtss2sd" || mnemonic == "vcvtsd2ss") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            auto result = read_bytes(operands[vex ? 1 : 0], instruction);
            result.resize(operands[0].size, 0);
            const auto source = read_bytes(operands.back(), instruction);
            if (mnemonic.ends_with("2sd")) put_scalar(result, 0, static_cast<double>(scalar_at<float>(source)));
            else put_scalar(result, 0, static_cast<float>(scalar_at<double>(source)));
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "cvtpd2ps" || mnemonic == "vcvtpd2ps" ||
            mnemonic == "cvtps2pd" || mnemonic == "vcvtps2pd") {
            require_operands(2);
            const auto source = read_bytes(operands[1], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const bool doubles_to_floats = mnemonic.find("pd2ps") != std::string::npos;
            if (doubles_to_floats) {
                const std::size_t lane_count = std::min(source.size() / sizeof(double), result.size() / sizeof(float));
                for (std::size_t lane = 0; lane < lane_count; ++lane) {
                    put_scalar(result, lane * sizeof(float),
                               static_cast<float>(scalar_at<double>(source, lane * sizeof(double))));
                }
            } else {
                const std::size_t lane_count = std::min(source.size() / sizeof(float), result.size() / sizeof(double));
                for (std::size_t lane = 0; lane < lane_count; ++lane) {
                    put_scalar(result, lane * sizeof(double),
                               static_cast<double>(scalar_at<float>(source, lane * sizeof(float))));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "cvtdq2ps" || mnemonic == "vcvtdq2ps" ||
            mnemonic == "cvtps2dq" || mnemonic == "vcvtps2dq" ||
            mnemonic == "cvttps2dq" || mnemonic == "vcvttps2dq") {
            require_operands(2);
            const auto source = read_bytes(operands[1], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const std::size_t lane_count = std::min(source.size(), result.size()) / sizeof(std::uint32_t);
            const bool integers_to_floats = mnemonic.find("dq2ps") != std::string::npos;
            const bool truncate = mnemonic.find("cvttps") != std::string::npos;
            for (std::size_t lane = 0; lane < lane_count; ++lane) {
                const std::size_t offset = lane * sizeof(std::uint32_t);
                if (integers_to_floats) {
                    const auto value = static_cast<std::int32_t>(scalar_at<std::uint32_t>(source, offset));
                    put_scalar(result, offset, static_cast<float>(value));
                    continue;
                }
                const long double value = static_cast<long double>(scalar_at<float>(source, offset));
                const long double integral = truncate ? std::trunc(value) : std::nearbyint(value);
                const std::uint32_t converted = !std::isfinite(value) ||
                        integral < static_cast<long double>(std::numeric_limits<std::int32_t>::min()) ||
                        integral > static_cast<long double>(std::numeric_limits<std::int32_t>::max())
                    ? 0x80000000U
                    : static_cast<std::uint32_t>(static_cast<std::int32_t>(integral));
                put_scalar(result, offset, converted);
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "roundss" || mnemonic == "roundsd" ||
            mnemonic == "vroundss" || mnemonic == "vroundsd") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 4 : 3);
            auto result = read_bytes(operands[vex ? 1 : 0], instruction);
            result.resize(operands[0].size, 0);
            const auto source = read_bytes(operands[vex ? 2 : 1], instruction);
            const std::uint64_t mode = read_operand(operands.back(), instruction) & 3U;
            const auto rounded = [mode](long double value) {
                switch (mode) {
                case 1: return std::floor(value);
                case 2: return std::ceil(value);
                case 3: return std::trunc(value);
                default: return std::nearbyint(value);
                }
            };
            if (mnemonic.ends_with("ss")) {
                put_scalar(result, 0, static_cast<float>(rounded(scalar_at<float>(source))));
            } else {
                put_scalar(result, 0, static_cast<double>(rounded(scalar_at<double>(source))));
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "roundps" || mnemonic == "roundpd" ||
            mnemonic == "vroundps" || mnemonic == "vroundpd") {
            require_operands(3);
            const auto source = read_bytes(operands[1], instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const std::uint64_t mode = read_operand(operands[2], instruction) & 3U;
            const auto rounded = [mode](long double value) {
                switch (mode) {
                case 1: return std::floor(value);
                case 2: return std::ceil(value);
                case 3: return std::trunc(value);
                default: return std::nearbyint(value);
                }
            };
            const bool doubles = mnemonic.ends_with("pd");
            const std::size_t element_size = doubles ? sizeof(double) : sizeof(float);
            const std::size_t lane_count = std::min(source.size(), result.size()) / element_size;
            for (std::size_t lane = 0; lane < lane_count; ++lane) {
                const std::size_t offset = lane * element_size;
                if (doubles) {
                    put_scalar(result, offset, static_cast<double>(rounded(scalar_at<double>(source, offset))));
                } else {
                    put_scalar(result, offset, static_cast<float>(rounded(scalar_at<float>(source, offset))));
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "cvttss2si" || mnemonic == "cvttsd2si" ||
            mnemonic == "vcvttss2si" || mnemonic == "vcvttsd2si" ||
            mnemonic == "cvtss2si" || mnemonic == "cvtsd2si" ||
            mnemonic == "vcvtss2si" || mnemonic == "vcvtsd2si") {
            require_operands(2);
            const auto source = read_bytes(operands[1], instruction);
            const long double value = mnemonic.find("ss2si") != std::string::npos
                ? static_cast<long double>(scalar_at<float>(source))
                : static_cast<long double>(scalar_at<double>(source));
            const bool truncate = mnemonic.find("cvtt") != std::string::npos;
            const long double integral = truncate ? std::trunc(value) : std::nearbyint(value);
            const long double minimum = operands[0].size == 4
                ? static_cast<long double>(std::numeric_limits<std::int32_t>::min())
                : static_cast<long double>(std::numeric_limits<std::int64_t>::min());
            const long double maximum = operands[0].size == 4
                ? static_cast<long double>(std::numeric_limits<std::int32_t>::max())
                : static_cast<long double>(std::numeric_limits<std::int64_t>::max());
            const std::uint64_t converted = !std::isfinite(value) || integral < minimum || integral > maximum
                ? (operands[0].size == 4 ? 0x80000000ULL : 0x8000000000000000ULL)
                : static_cast<std::uint64_t>(static_cast<std::int64_t>(integral));
            write_operand(operands[0], instruction, converted);
            return std::nullopt;
        }
        if (mnemonic == "addss" || mnemonic == "addsd" || mnemonic == "subss" || mnemonic == "subsd" ||
            mnemonic == "mulss" || mnemonic == "mulsd" || mnemonic == "divss" || mnemonic == "divsd" ||
            mnemonic == "minss" || mnemonic == "minsd" || mnemonic == "maxss" || mnemonic == "maxsd" ||
            mnemonic == "vaddss" || mnemonic == "vaddsd" || mnemonic == "vsubss" || mnemonic == "vsubsd" ||
            mnemonic == "vmulss" || mnemonic == "vmulsd" || mnemonic == "vdivss" || mnemonic == "vdivsd" ||
            mnemonic == "vminss" || mnemonic == "vminsd" || mnemonic == "vmaxss" || mnemonic == "vmaxsd") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            const std::size_t left_index = vex ? 1 : 0;
            auto result = read_bytes(operands[left_index], instruction);
            result.resize(operands[0].size, 0);
            const auto right_bytes = read_bytes(operands.back(), instruction);
            const std::string_view operation = std::string_view(mnemonic).substr(vex ? 1 : 0, 3);
            if (mnemonic.ends_with("sd")) {
                const double left = scalar_at<double>(result);
                const double right = scalar_at<double>(right_bytes);
                double value = 0;
                if (operation == "add") value = left + right;
                else if (operation == "sub") value = left - right;
                else if (operation == "mul") value = left * right;
                else if (operation == "div") value = left / right;
                else if (operation == "min") value = (std::isnan(left) || std::isnan(right) || !(left < right)) ? right : left;
                else value = (std::isnan(left) || std::isnan(right) || !(left > right)) ? right : left;
                put_scalar(result, 0, value);
            } else {
                const float left = scalar_at<float>(result);
                const float right = scalar_at<float>(right_bytes);
                float value = 0;
                if (operation == "add") value = left + right;
                else if (operation == "sub") value = left - right;
                else if (operation == "mul") value = left * right;
                else if (operation == "div") value = left / right;
                else if (operation == "min") value = (std::isnan(left) || std::isnan(right) || !(left < right)) ? right : left;
                else value = (std::isnan(left) || std::isnan(right) || !(left > right)) ? right : left;
                put_scalar(result, 0, value);
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "addps" || mnemonic == "addpd" || mnemonic == "subps" || mnemonic == "subpd" ||
            mnemonic == "mulps" || mnemonic == "mulpd" || mnemonic == "divps" || mnemonic == "divpd" ||
            mnemonic == "minps" || mnemonic == "minpd" || mnemonic == "maxps" || mnemonic == "maxpd" ||
            mnemonic == "vaddps" || mnemonic == "vaddpd" || mnemonic == "vsubps" || mnemonic == "vsubpd" ||
            mnemonic == "vmulps" || mnemonic == "vmulpd" || mnemonic == "vdivps" || mnemonic == "vdivpd" ||
            mnemonic == "vminps" || mnemonic == "vminpd" || mnemonic == "vmaxps" || mnemonic == "vmaxpd") {
            const bool vex = mnemonic.starts_with("v");
            require_operands(vex ? 3 : 2);
            const auto left_bytes = read_bytes(operands[vex ? 1 : 0], instruction);
            const auto right_bytes = read_bytes(operands.back(), instruction);
            std::vector<std::uint8_t> result(operands[0].size, 0);
            const std::string_view operation = std::string_view(mnemonic).substr(vex ? 1 : 0, 3);
            if (mnemonic.ends_with("pd")) {
                for (std::size_t offset = 0; offset + sizeof(double) <= result.size(); offset += sizeof(double)) {
                    const double left = scalar_at<double>(left_bytes, offset);
                    const double right = scalar_at<double>(right_bytes, offset);
                    double value = 0;
                    if (operation == "add") value = left + right;
                    else if (operation == "sub") value = left - right;
                    else if (operation == "mul") value = left * right;
                    else if (operation == "div") value = left / right;
                    else if (operation == "min") value = (std::isnan(left) || std::isnan(right) || !(left < right)) ? right : left;
                    else value = (std::isnan(left) || std::isnan(right) || !(left > right)) ? right : left;
                    put_scalar(result, offset, value);
                }
            } else {
                for (std::size_t offset = 0; offset + sizeof(float) <= result.size(); offset += sizeof(float)) {
                    const float left = scalar_at<float>(left_bytes, offset);
                    const float right = scalar_at<float>(right_bytes, offset);
                    float value = 0;
                    if (operation == "add") value = left + right;
                    else if (operation == "sub") value = left - right;
                    else if (operation == "mul") value = left * right;
                    else if (operation == "div") value = left / right;
                    else if (operation == "min") value = (std::isnan(left) || std::isnan(right) || !(left < right)) ? right : left;
                    else value = (std::isnan(left) || std::isnan(right) || !(left > right)) ? right : left;
                    put_scalar(result, offset, value);
                }
            }
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "comiss" || mnemonic == "ucomiss" || mnemonic == "comisd" || mnemonic == "ucomisd" ||
            mnemonic == "vcomiss" || mnemonic == "vucomiss" || mnemonic == "vcomisd" || mnemonic == "vucomisd") {
            require_operands(2);
            const auto left_bytes = read_bytes(operands[0], instruction);
            const auto right_bytes = read_bytes(operands[1], instruction);
            const bool doubles = mnemonic.ends_with("sd");
            const long double left = doubles ? static_cast<long double>(scalar_at<double>(left_bytes))
                                             : static_cast<long double>(scalar_at<float>(left_bytes));
            const long double right = doubles ? static_cast<long double>(scalar_at<double>(right_bytes))
                                              : static_cast<long double>(scalar_at<float>(right_bytes));
            const bool unordered = std::isnan(left) || std::isnan(right);
            set_flag(state_, 0, unordered || left < right);
            set_flag(state_, 2, unordered);
            set_flag(state_, 6, unordered || left == right);
            set_flag(state_, 4, false);
            set_flag(state_, 7, false);
            set_flag(state_, 11, false);
            return std::nullopt;
        }
        const auto scalar_compare_predicate = [&]() -> std::optional<std::string_view> {
            const std::string_view name = mnemonic.starts_with("v")
                ? std::string_view(mnemonic).substr(1)
                : std::string_view(mnemonic);
            constexpr std::array predicates{
                std::string_view("eq"), std::string_view("lt"), std::string_view("le"),
                std::string_view("unord"), std::string_view("neq"), std::string_view("nlt"),
                std::string_view("nle"), std::string_view("ord")};
            for (const auto predicate : predicates) {
                const std::string expected_sd = "cmp" + std::string(predicate) + "sd";
                const std::string expected_ss = "cmp" + std::string(predicate) + "ss";
                if (name == expected_sd || name == expected_ss) return predicate;
            }
            return std::nullopt;
        }();
        if (scalar_compare_predicate.has_value()) {
            const bool vex = mnemonic.starts_with('v');
            if (operands.size() != (vex ? 3U : 2U)) {
                throw std::invalid_argument("unexpected operands: " + instruction.text());
            }
            const std::size_t scalar_size = mnemonic.ends_with("sd") ? sizeof(double) : sizeof(float);
            const std::size_t left_index = vex ? 1U : 0U;
            const auto left = read_bytes(operands[left_index], instruction);
            const auto right = read_bytes(operands.back(), instruction);
            std::vector<std::uint8_t> result = left;
            result.resize(operands[0].size, 0);
            const long double lhs = scalar_size == sizeof(double)
                ? static_cast<long double>(scalar_at<double>(left))
                : static_cast<long double>(scalar_at<float>(left));
            const long double rhs = scalar_size == sizeof(double)
                ? static_cast<long double>(scalar_at<double>(right))
                : static_cast<long double>(scalar_at<float>(right));
            const bool unordered = std::isnan(lhs) || std::isnan(rhs);
            const std::string_view predicate = *scalar_compare_predicate;
            const bool matches =
                (predicate == "eq" && !unordered && lhs == rhs) ||
                (predicate == "lt" && !unordered && lhs < rhs) ||
                (predicate == "le" && !unordered && lhs <= rhs) ||
                (predicate == "unord" && unordered) ||
                (predicate == "neq" && (unordered || lhs != rhs)) ||
                (predicate == "nlt" && (unordered || !(lhs < rhs))) ||
                (predicate == "nle" && (unordered || !(lhs <= rhs))) ||
                (predicate == "ord" && !unordered);
            std::fill_n(result.begin(), scalar_size, static_cast<std::uint8_t>(matches ? 0xFFU : 0U));
            write_bytes(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "lea") {
            require_operands(2);
            if (operands[1].kind != OperandKind::Memory) throw std::invalid_argument("invalid LEA: " + instruction.text());
            write_operand(operands[0], instruction, effective_address(operands[1].memory, instruction));
            return std::nullopt;
        }
        if (mnemonic == "movzx" || mnemonic == "movsx" || mnemonic == "movsxd") {
            require_operands(2);
            std::uint64_t value = read_operand(operands[1], instruction);
            if (mnemonic != "movzx") value = sign_extend(value, operands[1].size);
            write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if (mnemonic == "push") {
            require_operands(1);
            std::uint64_t value = read_operand(operands[0], instruction);
            if (operands[0].kind == OperandKind::Immediate && operands[0].size < 8) value = sign_extend(value, operands[0].size);
            push(value);
            return std::nullopt;
        }
        if (mnemonic == "pop") {
            require_operands(1);
            write_operand(operands[0], instruction, pop());
            return std::nullopt;
        }
        if (mnemonic == "pushfq") { push(state_.flags); return std::nullopt; }
        if (mnemonic == "popfq") { state_.flags = pop(); return std::nullopt; }
        if (mnemonic == "call") {
            require_operands(1);
            const std::uint64_t target = read_operand(operands[0], instruction);
            if (const auto import = import_stub_index(target)) {
                context_switched_in_import_ = false;
                handle_import(*import);
                if (pending_stop_.has_value()) return std::exchange(pending_stop_, std::nullopt);
            }
            else { push(instruction.next_address()); state_.rip = target; }
            return std::nullopt;
        }
        if (mnemonic == "ret" || mnemonic == "retf") {
            const std::uint64_t target = pop();
            if (target == kReturnSentinel) {
                const std::uint64_t return_value = state_.read_register("rax");
                if (finish_active_thread(return_value)) return std::nullopt;
                state_.rip = target;
                return "sentinel return";
            }
            state_.rip = target;
            if (!operands.empty()) state_.write_register("rsp", state_.read_register("rsp") + read_operand(operands[0], instruction));
            return std::nullopt;
        }
        if (mnemonic == "leave") {
            state_.write_register("rsp", state_.read_register("rbp"));
            state_.write_register("rbp", pop());
            return std::nullopt;
        }
        if (mnemonic == "jmp") {
            require_operands(1);
            const std::uint64_t target = read_operand(operands[0], instruction);
            if (const auto import = import_stub_index(target)) {
                context_switched_in_import_ = false;
                handle_import(*import);
                if (pending_stop_.has_value()) return std::exchange(pending_stop_, std::nullopt);
                if (context_switched_in_import_) return std::nullopt;
                const std::uint64_t return_address = pop();
                state_.rip = return_address;
                if (return_address == kReturnSentinel) return "sentinel return";
            } else state_.rip = target;
            return std::nullopt;
        }
        if (mnemonic.size() > 1 && mnemonic[0] == 'j') {
            require_operands(1);
            if (condition(std::string_view(mnemonic).substr(1), state_)) state_.rip = read_operand(operands[0], instruction);
            return std::nullopt;
        }
        if (mnemonic.starts_with("cmov")) {
            require_operands(2);
            if (condition(std::string_view(mnemonic).substr(4), state_)) {
                write_operand(operands[0], instruction, read_operand(operands[1], instruction));
            }
            return std::nullopt;
        }
        if (mnemonic.starts_with("set")) {
            require_operands(1);
            write_operand(operands[0], instruction, condition(std::string_view(mnemonic).substr(3), state_) ? 1 : 0);
            return std::nullopt;
        }
        if (mnemonic == "add" || mnemonic == "adc" || mnemonic == "sub" || mnemonic == "sbb" || mnemonic == "cmp") {
            require_operands(2);
            const std::uint64_t lhs = read_operand(operands[0], instruction);
            std::uint64_t rhs = read_operand(operands[1], instruction);
            if ((mnemonic == "adc" || mnemonic == "sbb") && flag(state_, 0)) ++rhs;
            const bool subtract = mnemonic == "sub" || mnemonic == "sbb" || mnemonic == "cmp";
            const std::uint64_t value = subtract ? lhs - rhs : lhs + rhs;
            if (subtract) update_sub_flags(state_, lhs, rhs, value, operands[0].size);
            else update_add_flags(state_, lhs, rhs, value, operands[0].size);
            if (mnemonic != "cmp") write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if (mnemonic == "xor" || mnemonic == "or" || mnemonic == "and" || mnemonic == "test") {
            require_operands(2);
            const std::uint64_t lhs = read_operand(operands[0], instruction);
            const std::uint64_t rhs = read_operand(operands[1], instruction);
            const std::uint64_t value = mnemonic == "xor" ? lhs ^ rhs : mnemonic == "or" ? lhs | rhs : lhs & rhs;
            set_flag(state_, 0, false);
            set_flag(state_, 11, false);
            update_common_flags(state_, value, operands[0].size);
            if (mnemonic != "test") write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if (mnemonic == "andn") {
            require_operands(3);
            const std::uint64_t value = ~read_operand(operands[1], instruction) & read_operand(operands[2], instruction);
            write_operand(operands[0], instruction, value);
            set_flag(state_, 0, false);
            set_flag(state_, 11, false);
            update_common_flags(state_, value, operands[0].size);
            return std::nullopt;
        }
        if (mnemonic == "inc" || mnemonic == "dec" || mnemonic == "not" || mnemonic == "neg") {
            require_operands(1);
            const std::uint64_t old = read_operand(operands[0], instruction);
            std::uint64_t value = old;
            if (mnemonic == "inc") {
                const bool old_carry = flag(state_, 0);
                value = old + 1;
                update_add_flags(state_, old, 1, value, operands[0].size);
                set_flag(state_, 0, old_carry);
            } else if (mnemonic == "dec") {
                const bool old_carry = flag(state_, 0);
                value = old - 1;
                update_sub_flags(state_, old, 1, value, operands[0].size);
                set_flag(state_, 0, old_carry);
            } else if (mnemonic == "not") value = ~old;
            else {
                value = 0 - old;
                update_sub_flags(state_, 0, old, value, operands[0].size);
            }
            write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if (mnemonic == "shl" || mnemonic == "sal" || mnemonic == "shr" || mnemonic == "sar") {
            require_operands(2);
            const std::uint64_t value = read_operand(operands[0], instruction);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            const unsigned count = static_cast<unsigned>(read_operand(operands[1], instruction) & (bits == 64 ? 0x3FU : 0x1FU));
            if (count == 0) return std::nullopt;
            std::uint64_t result = 0;
            if (mnemonic == "shl" || mnemonic == "sal") {
                set_flag(state_, 0, ((value >> (bits - count)) & 1U) != 0);
                result = value << count;
            } else if (mnemonic == "shr") {
                set_flag(state_, 0, ((value >> (count - 1U)) & 1U) != 0);
                result = value >> count;
            } else {
                set_flag(state_, 0, ((value >> (count - 1U)) & 1U) != 0);
                const std::int64_t signed_value = static_cast<std::int64_t>(sign_extend(value, operands[0].size));
                result = static_cast<std::uint64_t>(signed_value >> count);
            }
            update_common_flags(state_, result, operands[0].size);
            write_operand(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "shlx" || mnemonic == "shrx" || mnemonic == "sarx") {
            require_operands(3);
            const std::uint64_t value = read_operand(operands[1], instruction);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            const unsigned count = static_cast<unsigned>(read_operand(operands[2], instruction) & (bits - 1U));
            std::uint64_t result = 0;
            if (mnemonic == "shlx") result = value << count;
            else if (mnemonic == "shrx") result = value >> count;
            else result = static_cast<std::uint64_t>(static_cast<std::int64_t>(sign_extend(value, operands[1].size)) >> count);
            write_operand(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "rorx") {
            require_operands(3);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            const unsigned count = static_cast<unsigned>(read_operand(operands[2], instruction) % bits);
            const std::uint64_t value = read_operand(operands[1], instruction) & mask_for(operands[0].size);
            const std::uint64_t result = count == 0 ? value : (value >> count) | (value << (bits - count));
            write_operand(operands[0], instruction, result);
            return std::nullopt;
        }
        if (mnemonic == "lzcnt" || mnemonic == "tzcnt" || mnemonic == "popcnt") {
            require_operands(2);
            const unsigned bits = static_cast<unsigned>(operands[1].size * 8U);
            const std::uint64_t value = read_operand(operands[1], instruction) & mask_for(operands[1].size);
            std::uint64_t result = 0;
            if (mnemonic == "lzcnt") result = value == 0 ? bits : std::countl_zero(value) - (64U - bits);
            else if (mnemonic == "tzcnt") result = value == 0 ? bits : std::countr_zero(value);
            else result = std::popcount(value);
            write_operand(operands[0], instruction, result);
            set_flag(state_, 0, value == 0);
            set_flag(state_, 6, result == 0);
            return std::nullopt;
        }
        if (mnemonic == "bextr") {
            require_operands(3);
            const std::uint64_t source = read_operand(operands[1], instruction);
            const std::uint64_t control = read_operand(operands[2], instruction);
            const unsigned start = static_cast<unsigned>(control & 0xFFU);
            const unsigned length = static_cast<unsigned>((control >> 8U) & 0xFFU);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            std::uint64_t result = 0;
            if (start < bits && length > 0) {
                const unsigned available = std::min(length, bits - start);
                const std::uint64_t field_mask = available >= 64 ? ~0ULL : (1ULL << available) - 1ULL;
                result = (source >> start) & field_mask;
            }
            write_operand(operands[0], instruction, result);
            set_flag(state_, 0, false);
            set_flag(state_, 11, false);
            update_common_flags(state_, result, operands[0].size);
            return std::nullopt;
        }
        if (mnemonic == "bzhi") {
            require_operands(3);
            const std::uint64_t source = read_operand(operands[1], instruction);
            const unsigned index = static_cast<unsigned>(read_operand(operands[2], instruction) & 0xFFU);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            const bool out_of_range = index >= bits;
            const std::uint64_t result = out_of_range ? source : index == 0 ? 0 : source & ((1ULL << index) - 1ULL);
            write_operand(operands[0], instruction, result);
            set_flag(state_, 0, out_of_range);
            set_flag(state_, 11, false);
            update_common_flags(state_, result, operands[0].size);
            return std::nullopt;
        }
        if (mnemonic == "bt" || mnemonic == "bts" || mnemonic == "btr" || mnemonic == "btc") {
            require_operands(2);
            const unsigned bits = static_cast<unsigned>(operands[0].size * 8U);
            const unsigned index = static_cast<unsigned>(read_operand(operands[1], instruction) & (bits - 1U));
            const std::uint64_t value = read_operand(operands[0], instruction);
            const std::uint64_t bit_mask = 1ULL << index;
            set_flag(state_, 0, (value & bit_mask) != 0);
            if (mnemonic != "bt") {
                const std::uint64_t result = mnemonic == "bts" ? value | bit_mask :
                                             mnemonic == "btr" ? value & ~bit_mask : value ^ bit_mask;
                write_operand(operands[0], instruction, result);
            }
            return std::nullopt;
        }
        if (mnemonic == "imul" && (operands.size() == 2 || operands.size() == 3)) {
            const std::size_t destination_size = operands[0].size;
            const std::uint64_t lhs = sign_extend(read_operand(operands[operands.size() == 3 ? 1 : 0], instruction), destination_size);
            const std::uint64_t rhs = sign_extend(read_operand(operands.back(), instruction), operands.back().size);
            const std::uint64_t value = static_cast<std::uint64_t>(static_cast<std::int64_t>(lhs) * static_cast<std::int64_t>(rhs));
            write_operand(operands[0], instruction, value);
            return std::nullopt;
        }
        if ((mnemonic == "mul" || mnemonic == "imul") && operands.size() == 1) {
            const std::size_t size = operands[0].size;
            const char* accumulator = size == 1 ? "al" : size == 2 ? "ax" : size == 4 ? "eax" : "rax";
            const char* high_register = size == 1 ? "ah" : size == 2 ? "dx" : size == 4 ? "edx" : "rdx";
            const std::uint64_t lhs = state_.read_register(accumulator);
            const std::uint64_t rhs = read_operand(operands[0], instruction);
            unsigned __int128 product = 0;
            if (mnemonic == "imul") {
                const __int128 signed_product = static_cast<__int128>(static_cast<std::int64_t>(sign_extend(lhs, size))) *
                                                static_cast<__int128>(static_cast<std::int64_t>(sign_extend(rhs, size)));
                product = static_cast<unsigned __int128>(signed_product);
            } else {
                product = static_cast<unsigned __int128>(lhs) * rhs;
            }
            const unsigned bits = static_cast<unsigned>(size * 8U);
            const std::uint64_t low = static_cast<std::uint64_t>(product) & mask_for(size);
            const std::uint64_t high = static_cast<std::uint64_t>(product >> bits) & mask_for(size);
            if (size == 1) state_.write_register("ax", low | (high << 8U));
            else {
                state_.write_register(accumulator, low);
                state_.write_register(high_register, high);
            }
            const bool overflow = mnemonic == "mul" ? high != 0 :
                high != ((low >> (bits - 1U)) != 0 ? mask_for(size) : 0);
            set_flag(state_, 0, overflow);
            set_flag(state_, 11, overflow);
            return std::nullopt;
        }
        if ((mnemonic == "div" || mnemonic == "idiv") && operands.size() == 1) {
            const std::size_t size = operands[0].size;
            const unsigned bits = static_cast<unsigned>(size * 8U);
            const std::uint64_t divisor_bits = read_operand(operands[0], instruction) & mask_for(size);
            if (divisor_bits == 0) return "guest division by zero";
            std::uint64_t quotient = 0;
            std::uint64_t remainder = 0;
            if (size == 1) {
                const std::uint16_t dividend = static_cast<std::uint16_t>(state_.read_register("ax"));
                if (mnemonic == "div") {
                    quotient = dividend / divisor_bits;
                    remainder = dividend % divisor_bits;
                } else {
                    const std::int16_t signed_dividend = static_cast<std::int16_t>(dividend);
                    const std::int8_t divisor = static_cast<std::int8_t>(divisor_bits);
                    quotient = static_cast<std::uint8_t>(signed_dividend / divisor);
                    remainder = static_cast<std::uint8_t>(signed_dividend % divisor);
                }
                if (quotient > 0xFFU) return "guest division overflow";
                state_.write_register("ax", quotient | (remainder << 8U));
                return std::nullopt;
            }
            const char* low_register = size == 2 ? "ax" : size == 4 ? "eax" : "rax";
            const char* high_register = size == 2 ? "dx" : size == 4 ? "edx" : "rdx";
            const std::uint64_t low = state_.read_register(low_register) & mask_for(size);
            const std::uint64_t high = state_.read_register(high_register) & mask_for(size);
            if (mnemonic == "div") {
                const unsigned __int128 dividend = static_cast<unsigned __int128>(high) << bits | low;
                quotient = static_cast<std::uint64_t>(dividend / divisor_bits);
                remainder = static_cast<std::uint64_t>(dividend % divisor_bits);
                if (quotient > mask_for(size)) return "guest division overflow";
            } else {
                __int128 dividend = static_cast<__int128>(static_cast<std::int64_t>(sign_extend(high, size))) << bits;
                dividend |= low;
                const std::int64_t divisor = static_cast<std::int64_t>(sign_extend(divisor_bits, size));
                const __int128 signed_quotient = dividend / divisor;
                const __int128 signed_remainder = dividend % divisor;
                const __int128 minimum = -(static_cast<__int128>(1) << (bits - 1U));
                const __int128 maximum = (static_cast<__int128>(1) << (bits - 1U)) - 1;
                if (signed_quotient < minimum || signed_quotient > maximum) return "guest division overflow";
                quotient = static_cast<std::uint64_t>(signed_quotient);
                remainder = static_cast<std::uint64_t>(signed_remainder);
            }
            state_.write_register(low_register, quotient);
            state_.write_register(high_register, remainder);
            return std::nullopt;
        }
        if (mnemonic == "xchg") {
            require_operands(2);
            const std::uint64_t lhs = read_operand(operands[0], instruction);
            const std::uint64_t rhs = read_operand(operands[1], instruction);
            write_operand(operands[0], instruction, rhs);
            write_operand(operands[1], instruction, lhs);
            return std::nullopt;
        }
        if (mnemonic == "xadd") {
            require_operands(2);
            const std::uint64_t lhs = read_operand(operands[0], instruction);
            const std::uint64_t rhs = read_operand(operands[1], instruction);
            const std::uint64_t result = lhs + rhs;
            write_operand(operands[0], instruction, result);
            write_operand(operands[1], instruction, lhs);
            update_add_flags(state_, lhs, rhs, result, operands[0].size);
            return std::nullopt;
        }
        if (mnemonic == "cmpxchg") {
            require_operands(2);
            const char* accumulator = operands[0].size == 1 ? "al" : operands[0].size == 2 ? "ax" :
                                      operands[0].size == 4 ? "eax" : "rax";
            const std::uint64_t expected = state_.read_register(accumulator);
            const std::uint64_t destination = read_operand(operands[0], instruction);
            const std::uint64_t difference = expected - destination;
            update_sub_flags(state_, expected, destination, difference, operands[0].size);
            if (expected == destination) write_operand(operands[0], instruction, read_operand(operands[1], instruction));
            else state_.write_register(accumulator, destination);
            return std::nullopt;
        }
        if (mnemonic == "cbw") { state_.write_register("ax", sign_extend(state_.read_register("al"), 1)); return std::nullopt; }
        if (mnemonic == "cwde") { state_.write_register("eax", sign_extend(state_.read_register("ax"), 2)); return std::nullopt; }
        if (mnemonic == "cdqe") { state_.write_register("rax", sign_extend(state_.read_register("eax"), 4)); return std::nullopt; }
        if (mnemonic == "cwd") { state_.write_register("dx", (state_.read_register("ax") & 0x8000U) ? 0xFFFFU : 0); return std::nullopt; }
        if (mnemonic == "cdq") { state_.write_register("edx", (state_.read_register("eax") & 0x80000000U) ? 0xFFFFFFFFU : 0); return std::nullopt; }
        if (mnemonic == "cqo") { state_.write_register("rdx", (state_.read_register("rax") >> 63U) ? ~0ULL : 0); return std::nullopt; }
        if (mnemonic == "clc") { set_flag(state_, 0, false); return std::nullopt; }
        if (mnemonic == "stc") { set_flag(state_, 0, true); return std::nullopt; }
        if (mnemonic == "cld") { set_flag(state_, 10, false); return std::nullopt; }
        if (mnemonic == "std") { set_flag(state_, 10, true); return std::nullopt; }
        if (mnemonic == "cpuid") {
            const std::uint32_t leaf = static_cast<std::uint32_t>(state_.read_register("eax"));
            if (leaf == 0) {
                state_.write_register("eax", 7);
                state_.write_register("ebx", 0x756E6547U);
                state_.write_register("edx", 0x49656E69U);
                state_.write_register("ecx", 0x6C65746EU);
            } else {
                state_.write_register("eax", 0);
                state_.write_register("ebx", 0);
                state_.write_register("ecx", 0);
                state_.write_register("edx", 0);
            }
            return std::nullopt;
        }
        if (mnemonic == "syscall") {
            state_.write_register("rax", 0);
            return std::nullopt;
        }
        if (mnemonic == "hlt") return "guest halt";
        return "unsupported x86-64 instruction: " + instruction.text();
    }

    static void remember(std::vector<std::string>& values, std::string value, std::size_t maximum) {
        values.push_back(std::move(value));
        if (values.size() > maximum) values.erase(values.begin());
    }

    void note_guest_text(const std::string& text) {
        if (!layouts_loaded_ && text.find("Done loading event sheets & layouts") != std::string::npos) {
            layouts_loaded_ = true;
            __android_log_print(
                ANDROID_LOG_INFO,
                "VibeStation5Runtime",
                "Dreaming Sarah reported loaded event sheets and layouts at instruction=%llu",
                static_cast<unsigned long long>(total_instruction_count_));
        }
    }

    [[nodiscard]] std::vector<std::string> recent_instruction_trace() {
        std::vector<std::string> values;
        values.reserve(recent_instruction_count_);
        const std::size_t start = (recent_instruction_cursor_ + recent_instruction_addresses_.size() - recent_instruction_count_) %
            recent_instruction_addresses_.size();
        for (std::size_t index = 0; index < recent_instruction_count_; ++index) {
            const std::uint64_t address = recent_instruction_addresses_[(start + index) % recent_instruction_addresses_.size()];
            values.push_back(hexadecimal(address) + "  " + decode(address).text());
        }
        return values;
    }

    [[nodiscard]] std::vector<std::string> thread_diagnostics() {
        std::vector<std::string> values;
        const auto detail = [&](std::string_view status, std::uint64_t handle, const CpuState& thread_state) {
            std::string instruction;
            try { instruction = decode(thread_state.rip).text(); }
            catch (...) { instruction = "<decode failed>"; }
            const auto last_import = last_import_by_thread_.find(handle);
            return std::string(status) + " handle=" + hexadecimal(handle) +
                (handle == content_loader_thread_ ? " role=contentLoader" : "") +
                " rip=" + hexadecimal(thread_state.rip) +
                " next=" + instruction +
                " rax=" + hexadecimal(thread_state.read_register("rax")) +
                " rbx=" + hexadecimal(thread_state.read_register("rbx")) +
                " rdi=" + hexadecimal(thread_state.read_register("rdi")) +
                " rsi=" + hexadecimal(thread_state.read_register("rsi")) +
                " rdx=" + hexadecimal(thread_state.read_register("rdx")) +
                " r14=" + hexadecimal(thread_state.read_register("r14")) +
                " rsp=" + hexadecimal(thread_state.read_register("rsp")) +
                " lastImport=" + (last_import == last_import_by_thread_.end() ? "<none>" : last_import->second);
        };
        values.push_back(detail("active", active_thread_handle_, state_));
        values.push_back(
            std::string("content layoutsLoaded=") + (layouts_loaded_ ? "true" : "false") +
            " loader=" + hexadecimal(content_loader_thread_) +
            " dataRead=" + std::to_string(content_data_bytes_read_) +
            "/" + std::to_string(content_data_size_) +
            " priorityStreak=" + std::to_string(content_priority_streak_));
        values.push_back(
            "hle isfiniteCalls=" + std::to_string(isfinite_call_count_) +
            " nonfinite=" + std::to_string(isfinite_reject_count_));
        values.push_back(
            "fusion circularStereoCopies=" + std::to_string(fused_circular_copy_count_) +
            " frames=" + std::to_string(fused_circular_frame_count_));
        std::vector<std::pair<std::string, std::uint64_t>> unhandled(
            unhandled_import_counts_.begin(), unhandled_import_counts_.end());
        std::sort(unhandled.begin(), unhandled.end());
        for (const auto& [symbol, calls] : unhandled) {
            values.push_back("unhandled " + symbol + " calls=" + std::to_string(calls));
        }
        std::vector<std::pair<std::uint64_t, std::uint64_t>> hot_instructions(
            instruction_samples_.begin(), instruction_samples_.end());
        std::sort(hot_instructions.begin(), hot_instructions.end(), [](const auto& left, const auto& right) {
            return left.second > right.second;
        });
        if (hot_instructions.size() > 16) hot_instructions.resize(16);
        for (const auto& [address, samples] : hot_instructions) {
            values.push_back("hot " + hexadecimal(address) + " samples=" + std::to_string(samples));
        }
        std::vector<std::pair<std::uint64_t, std::uint64_t>> content_hot(
            content_instruction_samples_.begin(), content_instruction_samples_.end());
        std::sort(content_hot.begin(), content_hot.end(), [](const auto& left, const auto& right) {
            return left.second > right.second;
        });
        if (content_hot.size() > 16) content_hot.resize(16);
        for (const auto& [address, samples] : content_hot) {
            values.push_back("contentHot " + hexadecimal(address) + " samples=" + std::to_string(samples));
        }
        for (const RunnableContext& context : ready_contexts_) {
            values.push_back(detail("ready", context.handle, context.state));
        }
        for (const auto& [semaphore, waiters] : semaphore_waiters_) {
            for (const SemaphoreWaiter& waiter : waiters) {
                values.push_back("semaphore " + hexadecimal(semaphore) + " waiter=" + hexadecimal(waiter.context.handle) +
                    " rip=" + hexadecimal(waiter.context.state.rip) + " need=" + std::to_string(waiter.need));
            }
        }
        for (const auto& [address, mutex] : mutexes_) {
            for (const RunnableContext& waiter : mutex.waiters) {
                values.push_back("mutex " + hexadecimal(address) + " owner=" + hexadecimal(mutex.owner) +
                    " waiter=" + hexadecimal(waiter.handle) + " rip=" + hexadecimal(waiter.state.rip));
            }
        }
        for (const auto& [condition, waiters] : condition_waiters_) {
            for (const ConditionWaiter& waiter : waiters) {
                values.push_back("condition " + hexadecimal(condition) + " waiter=" + hexadecimal(waiter.context.handle) +
                    " rip=" + hexadecimal(waiter.context.state.rip) + " mutex=" + hexadecimal(waiter.mutex_address) +
                    " timed=" + (waiter.timed ? "true" : "false"));
            }
        }
        for (const auto& [thread, waiters] : join_waiters_) {
            for (const JoinWaiter& waiter : waiters) {
                values.push_back("join target=" + hexadecimal(thread) + " waiter=" + hexadecimal(waiter.context.handle) +
                    " rip=" + hexadecimal(waiter.context.state.rip));
            }
        }
        if (gpu_submit_count_ != 0 || !gpu_state_.cx_registers.empty() ||
            !gpu_state_.sh_registers.empty() || !gpu_state_.uc_registers.empty()) {
            const auto gpu_register = [](const auto& registers, std::uint32_t index) {
                const auto found = registers.find(index);
                return found == registers.end() ? 0U : found->second;
            };
            const auto shader_address = [&](std::uint32_t low, std::uint32_t high) {
                return static_cast<std::uint64_t>(gpu_register(gpu_state_.sh_registers, high)) << 40U |
                    static_cast<std::uint64_t>(gpu_register(gpu_state_.sh_registers, low)) << 8U;
            };
            values.push_back(
                "gpu submits=" + std::to_string(gpu_submit_count_) +
                " draws=" + std::to_string(gpu_draw_count_) +
                " flips=" + std::to_string(gpu_flip_count_) +
                " prim=" + std::to_string(gpu_register(gpu_state_.uc_registers, 0x242)) +
                " es=" + hexadecimal(shader_address(0xC8, 0xC9)) +
                " ps=" + hexadecimal(shader_address(0x08, 0x09)));
            const std::uint32_t target_mask = gpu_register(gpu_state_.cx_registers, 0x8E);
            for (std::uint32_t index = 0; index < 8; ++index) {
                if (((target_mask >> (index * 4U)) & 0xFU) == 0) continue;
                const std::uint32_t base_register = 0x318U + index * 15U;
                const std::uint64_t address =
                    static_cast<std::uint64_t>(gpu_register(gpu_state_.cx_registers, 0x390U + index) & 0xFFU) << 40U |
                    static_cast<std::uint64_t>(gpu_register(gpu_state_.cx_registers, base_register)) << 8U;
                const std::uint32_t info = gpu_register(gpu_state_.cx_registers, base_register + 4U);
                const std::uint32_t attribute2 = gpu_register(gpu_state_.cx_registers, 0x3B0U + index);
                const std::uint32_t attribute3 = gpu_register(gpu_state_.cx_registers, 0x3B8U + index);
                values.push_back(
                    "gpu cb" + std::to_string(index) + "=" + hexadecimal(address) +
                    " " + std::to_string(((attribute2 >> 14U) & 0x3FFFU) + 1U) + "x" +
                    std::to_string((attribute2 & 0x3FFFU) + 1U) +
                    " fmt=" + std::to_string((info >> 2U) & 0x1FU) +
                    " type=" + std::to_string((info >> 8U) & 7U) +
                    " tile=" + std::to_string((attribute3 >> 14U) & 0x1FU));
            }
        }
        if (!agc_packet_counts_.empty()) {
            std::vector<std::pair<std::uint32_t, std::uint64_t>> packets(
                agc_packet_counts_.begin(), agc_packet_counts_.end());
            std::sort(packets.begin(), packets.end(), [](const auto& lhs, const auto& rhs) {
                return lhs.second > rhs.second;
            });
            std::ostringstream stream;
            stream << "AGC packet counts";
            for (const auto& [key, count] : packets) {
                stream << " op=0x" << std::hex << ((key >> 8U) & 0xFFU)
                       << "/reg=0x" << (key & 0xFFU) << std::dec << ':' << count;
            }
            values.push_back(stream.str());
        }
        return values;
    }

    struct RunnableContext {
        CpuState state;
        std::uint64_t handle = 0;
    };

    struct KernelEvent {
        std::uint64_t ident = 0;
        std::int16_t filter = 0;
        std::uint16_t flags = 0;
        std::uint32_t fflags = 0;
        std::uint64_t data = 0;
        std::uint64_t user_data = 0;
    };

    struct EventQueueWaiter {
        RunnableContext context;
        std::uint64_t events_address = 0;
        std::uint32_t capacity = 0;
        std::uint64_t out_count_address = 0;
        bool timed = false;
        std::chrono::steady_clock::time_point deadline{};
    };

    struct EventQueueState {
        std::vector<KernelEvent> pending;
        std::vector<EventQueueWaiter> waiters;
    };

    struct SleepWaiter {
        RunnableContext context;
        std::chrono::steady_clock::time_point deadline{};
    };

    struct JoinWaiter {
        RunnableContext context;
        std::uint64_t result_address = 0;
    };

    struct OpenFile {
        std::vector<std::uint8_t> data;
        std::size_t offset = 0;
        std::string path;
    };

    struct SemaphoreState {
        std::int64_t count = 0;
        std::int64_t maximum = 0;
    };

    struct SemaphoreWaiter {
        RunnableContext context;
        std::int64_t need = 1;
    };

    struct MutexState {
        std::uint64_t owner = 0;
        std::uint32_t recursion = 0;
        std::vector<RunnableContext> waiters;
    };

    struct ConditionWaiter {
        RunnableContext context;
        std::uint64_t mutex_address = 0;
        bool timed = false;
        std::chrono::steady_clock::time_point deadline{};
        std::uint64_t instruction_deadline = 0;
        std::uint64_t timeout_result = kOrbisErrorTimedOut;
    };

    struct PthreadAttribute {
        std::uint64_t stack_address = 0;
        std::uint64_t stack_size = 2ULL * 1024ULL * 1024ULL;
        std::int32_t detach_state = 0;
        std::int32_t schedule_priority = 0;
    };

    struct AudioPort {
        std::uint32_t buffer_length = 0;
        std::uint32_t frequency = 48000;
        std::uint32_t format = 1;
        std::uint32_t channels = 2;
    };

    struct VideoBuffer {
        std::uint64_t address = 0;
        std::uint64_t pixel_format = 0;
        std::uint32_t tiling = 0;
        std::uint32_t width = 0;
        std::uint32_t height = 0;
        std::uint32_t pitch = 0;
    };

    struct FlipEventRegistration {
        std::uint64_t event_queue = 0;
        std::uint64_t user_data = 0;
    };

    struct VideoPort {
        std::array<VideoBuffer, 16> buffers{};
        std::vector<FlipEventRegistration> flip_events;
        std::uint64_t flip_count = 0;
        std::int32_t current_buffer = -1;
    };

    struct SubmittedGpuState {
        std::unordered_map<std::uint32_t, std::uint32_t> cx_registers;
        std::unordered_map<std::uint32_t, std::uint32_t> sh_registers;
        std::unordered_map<std::uint32_t, std::uint32_t> uc_registers;
        std::uint64_t index_buffer = 0;
        std::uint32_t index_count = 0;
        std::uint32_t index_size = 0;
        std::uint32_t instance_count = 1;
    };

    struct CapturedGpuDraw {
        std::uint64_t draw_index = 0;
        std::uint32_t vertex_or_index_count = 0;
        SubmittedGpuState state;
    };

    std::vector<std::uint8_t> executable_;
    ExecutableImage image_;
    std::string content_root_;
    bool fast_forward_waits_ = false;
    std::unique_ptr<VulkanGuestRenderer> gpu_renderer_;
    SparseMemory memory_;
    Decoder decoder_;
    std::unordered_map<std::uint64_t, Instruction> decoded_instructions_;
    std::unordered_map<std::uint64_t, std::uint64_t> instruction_samples_;
    std::unordered_map<std::uint64_t, std::uint64_t> content_instruction_samples_;
    CpuState state_;
    std::uint64_t image_base_ = 0;
    std::uint64_t entry_point_ = 0;
    std::size_t load_segment_count_ = 0;
    std::size_t relocation_count_ = 0;
    std::unordered_map<std::size_t, std::string> imports_;
    std::unordered_map<std::uint64_t, std::uint64_t> allocations_;
    std::unordered_map<std::uint32_t, std::uint64_t> agc_packet_counts_;
    std::unordered_map<std::string, std::uint64_t> runtime_objects_;
    std::unordered_map<std::uint64_t, std::uint64_t> shader_headers_by_code_;
    std::unordered_map<std::uint64_t, std::string> last_import_by_thread_;
    std::unordered_map<std::string, std::uint64_t> unhandled_import_counts_;
    std::unordered_map<std::uint64_t, OpenFile> open_files_;
    std::unordered_map<std::uint64_t, SemaphoreState> semaphores_;
    std::unordered_map<std::uint64_t, std::vector<SemaphoreWaiter>> semaphore_waiters_;
    std::unordered_map<std::uint64_t, MutexState> mutexes_;
    std::unordered_map<std::uint64_t, std::vector<ConditionWaiter>> condition_waiters_;
    std::unordered_map<std::uint64_t, PthreadAttribute> pthread_attributes_;
    std::unordered_map<std::uint64_t, AudioPort> audio_ports_;
    std::unordered_map<std::uint64_t, EventQueueState> event_queues_;
    std::unordered_map<std::uint64_t, VideoPort> video_ports_;
    SubmittedGpuState gpu_state_;
    std::vector<CapturedGpuDraw> gpu_draw_captures_;
    std::vector<std::uint8_t> audio_queue_;
    std::vector<std::uint8_t> latest_video_frame_;
    std::uint64_t heap_cursor_ = kHeapBase;
    std::uint64_t total_instruction_count_ = 0;
    std::uint64_t executing_instruction_count_ = 0;
    bool layouts_loaded_ = false;
    std::uint64_t content_loader_thread_ = 0;
    std::uint64_t content_data_bytes_read_ = 0;
    std::uint64_t content_data_size_ = 0;
    std::uint32_t content_priority_streak_ = 0;
    std::uint64_t intercepted_imports_ = 0;
    std::uint64_t active_thread_handle_ = 1;
    std::uint64_t next_thread_stack_top_ = kStackBase + kStackSize - 2ULL * 1024ULL * 1024ULL - 0x100ULL;
    std::uint64_t next_thread_tls_block_ = kTlsBase + 64ULL * 1024ULL;
    std::uint64_t next_audio_handle_ = 1;
    std::uint64_t next_semaphore_handle_ = 1;
    std::uint32_t next_np_universal_handle_ = 2;
    std::uint32_t next_trophy_context_ = 1;
    std::uint32_t save_data_dialog_status_ = 0;
    std::uint64_t condition_timed_wait_count_ = 0;
    std::uint64_t condition_timeout_count_ = 0;
    std::uint64_t condition_signal_count_ = 0;
    std::uint64_t condition_signal_wake_count_ = 0;
    std::uint64_t isfinite_call_count_ = 0;
    std::uint64_t isfinite_reject_count_ = 0;
    std::uint64_t fused_instruction_credit_ = 0;
    std::uint64_t fused_circular_copy_count_ = 0;
    std::uint64_t fused_circular_frame_count_ = 0;
    std::uint64_t next_event_queue_handle_ = 1;
    std::uint64_t next_transaction_resource_ = 1;
    std::uint64_t next_video_handle_ = 1;
    std::uint32_t audio_sample_rate_ = 48000;
    std::uint32_t video_width_ = 0;
    std::uint32_t video_height_ = 0;
    std::uint64_t video_sequence_ = 0;
    std::uint64_t gpu_submit_count_ = 0;
    std::uint64_t gpu_draw_count_ = 0;
    std::uint64_t gpu_flip_count_ = 0;
    std::uint32_t gpu_last_draw_count_ = 0;
    std::uint64_t input_buttons_ = 0;
    float left_x_ = 0;
    float left_y_ = 0;
    float right_x_ = 0;
    float right_y_ = 0;
    bool terminal_ = false;
    bool context_switched_in_import_ = false;
    std::string stop_reason_;
    std::array<std::uint64_t, 256> recent_instruction_addresses_{};
    std::size_t recent_instruction_cursor_ = 0;
    std::size_t recent_instruction_count_ = 0;
    std::vector<std::string> recent_imports_;
    std::vector<std::string> observed_imports_;
    std::optional<std::string> pending_stop_;
    std::vector<RunnableContext> ready_contexts_;
    std::vector<SleepWaiter> sleep_waiters_;
    std::unordered_map<std::uint64_t, std::uint64_t> thread_return_values_;
    std::unordered_map<std::uint64_t, std::vector<JoinWaiter>> join_waiters_;
};

std::string RuntimeRunResult::json() const {
    std::ostringstream stream;
    stream << "{\"instructionCount\":" << instruction_count
           << ",\"totalInstructionCount\":" << total_instruction_count
           << ",\"instructionPointer\":\"" << hexadecimal(instruction_pointer) << "\""
           << ",\"returnValue\":\"" << hexadecimal(return_value) << "\""
           << ",\"interceptedImports\":" << intercepted_imports
           << ",\"gpuSubmissions\":" << gpu_submissions
           << ",\"gpuDraws\":" << gpu_draws
           << ",\"gpuFlips\":" << gpu_flips
           << ",\"videoSequence\":" << video_sequence
           << ",\"frameHash\":\"" << hexadecimal(frame_hash) << "\""
           << ",\"shaderCacheMisses\":" << shader_cache_misses
           << ",\"textureRefreshes\":" << texture_refreshes
           << ",\"eventQueueDepth\":" << event_queue_depth
           << ",\"lastImport\":\"" << json_escape(last_import) << "\""
           << ",\"terminal\":" << (terminal ? "true" : "false")
           << ",\"reason\":\"" << json_escape(reason) << "\""
           << ",\"recentInstructions\":[";
    for (std::size_t index = 0; index < recent_instructions.size(); ++index) {
        if (index != 0) stream << ',';
        stream << '\"' << json_escape(recent_instructions[index]) << '\"';
    }
    stream << "],\"recentImports\":[";
    for (std::size_t index = 0; index < recent_imports.size(); ++index) {
        if (index != 0) stream << ',';
        stream << '\"' << json_escape(recent_imports[index]) << '\"';
    }
    stream << "],\"observedImports\":[";
    for (std::size_t index = 0; index < observed_imports.size(); ++index) {
        if (index != 0) stream << ',';
        stream << '\"' << json_escape(observed_imports[index]) << '\"';
    }
    stream << "],\"threadDiagnostics\":[";
    for (std::size_t index = 0; index < thread_diagnostics.size(); ++index) {
        if (index != 0) stream << ',';
        stream << '\"' << json_escape(thread_diagnostics[index]) << '\"';
    }
    stream << "]}";
    return stream.str();
}

GuestRuntime::GuestRuntime(std::vector<std::uint8_t> executable, std::string content_root)
    : impl_(std::make_unique<Impl>(std::move(executable), std::move(content_root))) {}
GuestRuntime::~GuestRuntime() = default;
RuntimeRunResult GuestRuntime::run(std::uint64_t instruction_budget) { return impl_->run(instruction_budget); }
void GuestRuntime::set_input(std::uint64_t buttons, float left_x, float left_y, float right_x, float right_y) {
    impl_->set_input(buttons, left_x, left_y, right_x, right_y);
}
std::vector<std::uint8_t> GuestRuntime::drain_audio() { return impl_->drain_audio(); }
std::uint32_t GuestRuntime::audio_sample_rate() const { return impl_->audio_sample_rate(); }
GuestVideoFrame GuestRuntime::latest_video_frame(std::uint64_t after_sequence) const {
    return impl_->latest_video_frame(after_sequence);
}
std::string GuestRuntime::dump_gpu_capture(const std::string& directory) const {
    return impl_->dump_gpu_capture(directory);
}
std::string GuestRuntime::description() const { return impl_->description(); }

}  // namespace vibestation
