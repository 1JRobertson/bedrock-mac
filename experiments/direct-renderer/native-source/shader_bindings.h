/* Pinned ordinary DXMT resource ABI, qualified from the actual Metal pipeline. */
#ifndef FULLFRAME_SHADER_BINDINGS_H
#define FULLFRAME_SHADER_BINDINGS_H
#import "vertex_resources.h"
#include <string.h>
static inline int ff_shader_layout(MTLRenderPipelineReflection *reflection, uint32_t ia_mask, ff_draw_layout *layout) {
    if (!reflection || !reflection.vertexBindings || !reflection.fragmentBindings || !layout) return 0;
    memset(layout, 0, sizeof(*layout)); layout->ia_slot_mask = ia_mask;
    NSArray *stages[] = {reflection.vertexBindings, reflection.fragmentBindings};
    unsigned seen[2] = {0};
    for (unsigned stage = 0; stage < 2; ++stage) for (id<MTLBinding> binding in stages[stage]) {
        if (!binding.isUsed) continue;
        if (binding.type != MTLBindingTypeBuffer || binding.access != MTLBindingAccessReadOnly) return 0;
        id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)binding;
        unsigned bit;
        if (binding.index == 16 && stage == 0) {
            bit = 1;
            if (!ia_mask || buffer.bufferDataSize > (NSUInteger)__builtin_popcount(ia_mask) * 16) return 0;
        } else if (binding.index == 29) {
            bit = 2;
            if (!buffer.bufferDataSize || buffer.bufferDataSize % 8 || buffer.bufferDataSize / 8 > FF_CONSTANT_RESOURCE_LIMIT) return 0;
            layout->constant_count[stage] = (uint32_t)(buffer.bufferDataSize / 8);
        } else if (binding.index == 30) {
            bit = 4; ff_shader_table_layout *table = &layout->arguments[stage];
            NSArray<MTLStructMember *> *members = buffer.bufferStructType.members;
            if (!buffer.bufferDataSize || buffer.bufferDataSize > FF_SHADER_TABLE_BYTES_LIMIT || !members.count ||
                members.count > FF_SHADER_FIELD_LIMIT || members.count * 8 != buffer.bufferDataSize) return 0;
            table->byte_length = (uint32_t)buffer.bufferDataSize; table->field_count = (uint32_t)members.count;
            for (NSUInteger i = 0; i < members.count; ++i) {
                MTLStructMember *member = members[i]; unsigned kind;
                if (member.offset % 8 || member.offset > buffer.bufferDataSize - 8) return 0;
                for (NSUInteger j = 0; j < i; ++j) if (table->fields[j].offset == member.offset) return 0;
                switch (member.dataType) {
                case MTLDataTypeULong: kind = FF_FIELD_VALUE; break;
                case MTLDataTypeSampler: kind = FF_FIELD_SAMPLER; break;
                case MTLDataTypeTexture: {
                    MTLTextureReferenceType *texture = member.textureReferenceType;
                    if (!texture || (texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DArray &&
                        texture.textureType != MTLTextureTypeCube) || texture.isDepthTexture ||
                        texture.access != MTLBindingAccessReadOnly ||
                        (texture.textureDataType != MTLDataTypeFloat && texture.textureDataType != MTLDataTypeHalf)) return 0;
                    kind = FF_FIELD_TEXTURE; break;
                }
                case MTLDataTypePointer: {
                    MTLPointerType *pointer = member.pointerType;
                    if (!pointer || pointer.access != MTLBindingAccessReadOnly || pointer.elementIsArgumentBuffer) return 0;
                    /* Source cut resolves the complete typed logical allocation;
                     * adjacent raw byte-length metadata is preserved separately. */
                    kind = FF_FIELD_BUFFER; break;
                }
                default: return 0;
                }
                table->fields[i] = (ff_shader_field){(uint32_t)member.offset, kind};
            }
        } else return 0;
        if (seen[stage] & bit) return 0;
        seen[stage] |= bit;
    }
    if (!(seen[0] & 1)) layout->ia_slot_mask = 0;
    return 1;
}
#endif
