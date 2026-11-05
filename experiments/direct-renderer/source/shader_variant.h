/* Private, pointer-free SM50Compile argument transport, pinned DXMT ABI only. */
#ifndef FULLFRAME_SHADER_VARIANT_H
#define FULLFRAME_SHADER_VARIANT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "airconv_public.h"

#define FF_VARIANT_WORDS 2048
#define FF_VARIANT_NODES 7
#define FF_VARIANT_ELEMENTS 128

union ff_node {
        struct SM50_SHADER_COMPILATION_ARGUMENT_DATA base;
        struct SM50_SHADER_COMMON_DATA common;
        struct SM50_SHADER_PSO_PIXEL_SHADER_DATA pixel;
        struct SM50_SHADER_IA_INPUT_LAYOUT_DATA layout;
        struct SM50_SHADER_GS_PASS_THROUGH_DATA pass;
        struct SM50_SHADER_PSO_GEOMETRY_SHADER_DATA geometry;
        struct SM50_SHADER_PSO_TESSELLATOR_DATA tess;
        struct SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT_DATA stream;
};
struct ff_variant {
    union ff_node nodes[FF_VARIANT_NODES];
    struct SM50_IA_INPUT_ELEMENT elements[FF_VARIANT_ELEMENTS];
    struct SM50_STREAM_OUTPUT_ELEMENT outputs[FF_VARIANT_ELEMENTS];
};

/* Word encoding is little endian on both supported macOS architectures. */
static inline int ff_variant_encode(const struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *arg,
                                    uint32_t *words, size_t *size) {
    size_t n=11; uint32_t count=0, seen=0;
#define FF_PUT(v) do { if(n>=FF_VARIANT_WORDS)return 0; words[n++]=(uint32_t)(v); } while(0)
    words[0]=0x31564642; words[1]=1; words[2]=0; memset(words+3,0,32);
    while(arg) {
        uint32_t t=(uint32_t)arg->type;
        if(t<1||t>7||(seen&(1u<<t))||count>=FF_VARIANT_NODES)return 0;
        seen|=1u<<t; ++count; FF_PUT(t);
        switch(t) {
        case SM50_SHADER_COMMON: { const struct SM50_SHADER_COMMON_DATA *p=(const struct SM50_SHADER_COMMON_DATA *)arg;
            FF_PUT(p->metal_version); FF_PUT(p->flags); break; }
        case SM50_SHADER_PSO_PIXEL_SHADER: { const struct SM50_SHADER_PSO_PIXEL_SHADER_DATA *p=(const struct SM50_SHADER_PSO_PIXEL_SHADER_DATA *)arg;
            FF_PUT(p->sample_mask); FF_PUT(p->dual_source_blending); FF_PUT(p->disable_depth_output); FF_PUT(p->unorm_output_reg_mask); break; }
        case SM50_SHADER_IA_INPUT_LAYOUT: { const struct SM50_SHADER_IA_INPUT_LAYOUT_DATA *p=(const struct SM50_SHADER_IA_INPUT_LAYOUT_DATA *)arg;
            if(p->num_elements>FF_VARIANT_ELEMENTS||(p->num_elements&&!p->elements))return 0;
            /* Ordinary SM50Compile does not consume this field; DXMT leaves it unset. */
            FF_PUT(0); FF_PUT(p->slot_mask); FF_PUT(p->num_elements);
            for(uint32_t i=0;i<p->num_elements;i++) { const struct SM50_IA_INPUT_ELEMENT *e=&p->elements[i];
                FF_PUT(e->reg); FF_PUT(e->slot); FF_PUT(e->aligned_byte_offset); FF_PUT(e->format); FF_PUT(e->step_function); FF_PUT(e->step_rate); } break; }
        case SM50_SHADER_GS_PASS_THROUGH: { const struct SM50_SHADER_GS_PASS_THROUGH_DATA *p=(const struct SM50_SHADER_GS_PASS_THROUGH_DATA *)arg;
            FF_PUT(p->DataEncoded); FF_PUT(p->RasterizationDisabled); break; }
        case SM50_SHADER_PSO_GEOMETRY_SHADER: { const struct SM50_SHADER_PSO_GEOMETRY_SHADER_DATA *p=(const struct SM50_SHADER_PSO_GEOMETRY_SHADER_DATA *)arg;
            FF_PUT(p->strip_topology); break; }
        case SM50_SHADER_PSO_TESSELLATOR: { const struct SM50_SHADER_PSO_TESSELLATOR_DATA *p=(const struct SM50_SHADER_PSO_TESSELLATOR_DATA *)arg;
            FF_PUT(p->max_potential_tess_factor); break; }
        /* Upstream leaves unused stream-output fields unset; reject this variant. */
        case SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT: return 0;
        default: return 0;
        }
        arg=(const struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *)arg->next;
    }
    words[2]=count; *size=n*sizeof(*words); return 1;
#undef FF_PUT
}

static inline int ff_variant_decode(const uint32_t *w,size_t bytes,struct ff_variant *out,
                                    struct SM50_SHADER_COMPILATION_ARGUMENT_DATA **head) {
    if(bytes%4||bytes<44||bytes>FF_VARIANT_WORDS*4||w[0]!=0x31564642||w[1]!=1||w[2]>FF_VARIANT_NODES)return 0;
    size_t n=11, end=bytes/4; uint32_t seen=0; memset(out,0,sizeof(*out)); *head=NULL;
#define FF_GET(v) do { if(n>=end)return 0; (v)=w[n++]; } while(0)
#define FF_BOOL(v) do { uint32_t b; FF_GET(b); if(b>1)return 0; (v)=b; } while(0)
    for(uint32_t j=0;j<w[2];j++) {
        uint32_t t; FF_GET(t); if(t<1||t>7||(seen&(1u<<t)))return 0; seen|=1u<<t;
        union ff_node *node=&out->nodes[j]; node->base.type=(enum SM50_SHADER_COMPILATION_ARGUMENT_TYPE)t;
        if(j)out->nodes[j-1].base.next=&node->base; else *head=&node->base;
        switch(t) {
        case SM50_SHADER_COMMON: { uint32_t v; FF_GET(v); node->common.metal_version=(enum SM50_SHADER_METAL_VERSION)v;
            FF_GET(v); node->common.flags=(enum SM50_SHADER_FLAG)v; break; }
        case SM50_SHADER_PSO_PIXEL_SHADER:
            FF_GET(node->pixel.sample_mask); FF_BOOL(node->pixel.dual_source_blending); FF_BOOL(node->pixel.disable_depth_output); FF_GET(node->pixel.unorm_output_reg_mask); break;
        case SM50_SHADER_IA_INPUT_LAYOUT: { uint32_t v; FF_GET(v); if(v>2)return 0; node->layout.index_buffer_format=(enum SM50_INDEX_BUFFER_FORMAT)v;
            FF_GET(node->layout.slot_mask); FF_GET(node->layout.num_elements); if(node->layout.num_elements>FF_VARIANT_ELEMENTS)return 0;
            node->layout.elements=out->elements; for(uint32_t i=0;i<node->layout.num_elements;i++) { struct SM50_IA_INPUT_ELEMENT *e=&out->elements[i];
                FF_GET(e->reg); FF_GET(e->slot); FF_GET(e->aligned_byte_offset); FF_GET(e->format); FF_GET(v); if(v>1)return 0; e->step_function=v;
                FF_GET(v); if(v>0x7fffffff)return 0; e->step_rate=v; } break; }
        case SM50_SHADER_GS_PASS_THROUGH: FF_GET(node->pass.DataEncoded); FF_BOOL(node->pass.RasterizationDisabled); break;
        case SM50_SHADER_PSO_GEOMETRY_SHADER: FF_BOOL(node->geometry.strip_topology); break;
        case SM50_SHADER_PSO_TESSELLATOR: FF_GET(node->tess.max_potential_tess_factor); break;
        case SM50_SHADER_EMULATE_VERTEX_STREAM_OUTPUT: return 0;
        default: return 0;
        }
    }
    return n==end;
#undef FF_GET
#undef FF_BOOL
}
#endif
