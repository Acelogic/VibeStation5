#include "capstone/vibestation_capstone.h"

#include <stdlib.h>
#include <string.h>

#include "capstone/capstone.h"
#include "capstone/x86.h"

struct vs_decoder {
    csh handle;
    cs_insn *instruction;
};

vs_decoder *vs_decoder_create(void)
{
    vs_decoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        return NULL;
    }
    if (cs_open(CS_ARCH_X86, CS_MODE_64, &decoder->handle) != CS_ERR_OK) {
        free(decoder);
        return NULL;
    }
    if (cs_option(decoder->handle, CS_OPT_DETAIL, CS_OPT_ON) != CS_ERR_OK) {
        cs_close(&decoder->handle);
        free(decoder);
        return NULL;
    }
    decoder->instruction = cs_malloc(decoder->handle);
    if (decoder->instruction == NULL) {
        cs_close(&decoder->handle);
        free(decoder);
        return NULL;
    }
    return decoder;
}

void vs_decoder_destroy(vs_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    if (decoder->instruction != NULL) {
        cs_free(decoder->instruction, 1);
    }
    cs_close(&decoder->handle);
    free(decoder);
}

bool vs_decode_one(
    vs_decoder *decoder,
    const uint8_t *code,
    size_t code_size,
    uint64_t address,
    vs_instruction *output)
{
    if (decoder == NULL || code == NULL || output == NULL || code_size == 0) {
        return false;
    }

    const uint8_t *cursor = code;
    size_t remaining = code_size;
    uint64_t current_address = address;
    if (!cs_disasm_iter(
        decoder->handle,
        &cursor,
        &remaining,
        &current_address,
        decoder->instruction
    )) {
        return false;
    }

    memset(output, 0, sizeof(*output));
    output->id = decoder->instruction->id;
    output->address = decoder->instruction->address;
    output->size = decoder->instruction->size;
    memcpy(output->bytes, decoder->instruction->bytes, decoder->instruction->size);

    const cs_x86 *x86 = &decoder->instruction->detail->x86;
    output->eflags = x86->eflags;
    output->operand_count = x86->op_count > 8 ? 8 : x86->op_count;
    for (uint8_t index = 0; index < output->operand_count; ++index) {
        const cs_x86_op *source = &x86->operands[index];
        vs_operand *destination = &output->operands[index];
        destination->kind = (uint8_t)source->type;
        destination->size = source->size;
        destination->access = source->access;
        switch (source->type) {
        case X86_OP_REG:
            destination->register_id = source->reg;
            break;
        case X86_OP_IMM:
            destination->immediate = (uint64_t)source->imm;
            break;
        case X86_OP_MEM:
            destination->memory.segment = source->mem.segment;
            destination->memory.base = source->mem.base;
            destination->memory.index = source->mem.index;
            destination->memory.scale = source->mem.scale;
            destination->memory.displacement = source->mem.disp;
            break;
        default:
            break;
        }
    }
    return true;
}

const char *vs_decoder_mnemonic(const vs_decoder *decoder)
{
    return decoder == NULL || decoder->instruction == NULL
        ? ""
        : decoder->instruction->mnemonic;
}

const char *vs_decoder_operand_text(const vs_decoder *decoder)
{
    return decoder == NULL || decoder->instruction == NULL
        ? ""
        : decoder->instruction->op_str;
}

const char *vs_decoder_register_name(const vs_decoder *decoder, uint32_t register_id)
{
    if (decoder == NULL) {
        return "";
    }
    const char *name = cs_reg_name(decoder->handle, register_id);
    return name == NULL ? "" : name;
}

const char *vs_decoder_error(const vs_decoder *decoder)
{
    if (decoder == NULL) {
        return "Unable to create the Capstone decoder.";
    }
    return cs_strerror(cs_errno(decoder->handle));
}
