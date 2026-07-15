#ifndef VIBESTATION_CAPSTONE_H
#define VIBESTATION_CAPSTONE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vs_decoder vs_decoder;

typedef enum vs_operand_kind {
    VS_OPERAND_INVALID = 0,
    VS_OPERAND_REGISTER = 1,
    VS_OPERAND_IMMEDIATE = 2,
    VS_OPERAND_MEMORY = 3
} vs_operand_kind;

typedef struct vs_memory_operand {
    uint32_t segment;
    uint32_t base;
    uint32_t index;
    int32_t scale;
    int64_t displacement;
} vs_memory_operand;

typedef struct vs_operand {
    uint8_t kind;
    uint8_t size;
    uint8_t access;
    uint8_t reserved;
    uint32_t register_id;
    uint64_t immediate;
    vs_memory_operand memory;
} vs_operand;

typedef struct vs_instruction {
    uint32_t id;
    uint64_t address;
    uint8_t size;
    uint8_t bytes[16];
    uint8_t operand_count;
    uint8_t reserved[7];
    uint64_t eflags;
    vs_operand operands[8];
} vs_instruction;

vs_decoder *vs_decoder_create(void);
void vs_decoder_destroy(vs_decoder *decoder);
bool vs_decode_one(
    vs_decoder *decoder,
    const uint8_t *code,
    size_t code_size,
    uint64_t address,
    vs_instruction *instruction
);
const char *vs_decoder_mnemonic(const vs_decoder *decoder);
const char *vs_decoder_operand_text(const vs_decoder *decoder);
const char *vs_decoder_register_name(const vs_decoder *decoder, uint32_t register_id);
const char *vs_decoder_error(const vs_decoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
