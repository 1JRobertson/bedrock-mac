/* Private, bounded SM50 input-layout provenance; unknown is never guessed. */
#ifndef FULLFRAME_SHADER_IA_H
#define FULLFRAME_SHADER_IA_H
#import <Metal/Metal.h>
#include <stdint.h>
struct SM50_SHADER_COMPILATION_ARGUMENT_DATA;
struct ff_ia_slot_extent { uint32_t byte_end, step_function, step_rate; };
struct ff_ia_fetch_layout { uint32_t known_mask; struct ff_ia_slot_extent slots[32]; };
/* Input-assembler draw metadata, local to the paired source bridge. Index type
 * 0 is UINT16 and 1 is UINT32, matching WMT. Count fields are widened so the
 * helper can reject out-of-domain values before narrowing. */
struct ff_ia_pre_copy_draw {
  uint64_t vertex_start, vertex_count, instance_count;
  uint32_t base_instance, indexed, index_type;
  int32_t base_vertex;
};
/* Compute a proven byte extent relative to one IA binding's base address.
 * original_length must be its already-resolved accessible byte length. On
 * success writes an extent in 1..original_length and returns 1; on any
 * uncertainty returns 0 without changing *bound. No GPU memory is read. */
static inline int ff_ia_pre_copy_bound(const struct ff_ia_fetch_layout *fetch,uint32_t slot,
                         const struct ff_ia_pre_copy_draw *draw,uint32_t stride,
                         uint32_t original_length,uint32_t *bound) {
    if(!fetch||!draw||!bound||slot>=32||!(fetch->known_mask&(UINT32_C(1)<<slot))||
       !draw->vertex_count||draw->vertex_count>UINT32_MAX||!draw->instance_count||
       draw->instance_count>UINT32_MAX||!original_length||draw->indexed>1)return 0;
    const struct ff_ia_slot_extent *extent=&fetch->slots[slot];
    if(!extent->byte_end||extent->step_function>1)return 0;
    if(draw->indexed&&draw->index_type>1)return 0;
    if(!draw->indexed&&(draw->vertex_start>UINT32_MAX||draw->vertex_count-1>UINT32_MAX-draw->vertex_start))return 0;
    /* The original shader receives uint instance IDs including the base. Do
     * not rely on wraparound even when a divisor would make the result fit. */
    if(draw->instance_count-1>UINT32_MAX-draw->base_instance)return 0;
    uint64_t index;
    if(extent->step_function==1){
        uint64_t step=extent->step_rate?(draw->instance_count-1)/extent->step_rate:0;
        if(step>UINT32_MAX-draw->base_instance)return 0;
        index=(uint64_t)draw->base_instance+step;
    }else if(draw->indexed){
        /* Full UINT16 domain, including strip-restart values. No assumption
         * about GPU-written index contents or primitive topology is needed. */
        if(draw->index_type!=0||draw->base_vertex<0)return 0;
        index=UINT64_C(65535)+(uint32_t)draw->base_vertex;
        if(index>UINT32_MAX)return 0;
    }else{
        index=draw->vertex_start+draw->vertex_count-1;
    }
    /* DXMT's vertex-pulling lowering uses 32-bit multiplication and addition.
     * A bound is safe only when neither can wrap for any reached index. */
    if(stride&&index>(UINT32_MAX-extent->byte_end)/stride)return 0;
    uint64_t bytes=index*stride+extent->byte_end;
    if(!bytes||bytes>original_length)return 0;
    *bound=(uint32_t)bytes;return 1;
}
int ff_ia_enabled(void);
void ff_ia_compile(void *handle,const void *bytes,size_t size,const char *name,struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *args);
void ff_ia_forget(void *handle);
void ff_ia_bind(const void *bytes,size_t size,dispatch_data_t data);
void ff_ia_library(dispatch_data_t data,id<MTLLibrary> library);
void ff_ia_function(id<MTLLibrary> library,id<MTLFunction> function,NSString *name);
void ff_ia_pipeline(id<MTLRenderPipelineState> pipeline,id<MTLFunction> vertex);
int ff_ia_pipeline_mask(id<MTLRenderPipelineState> pipeline,uint32_t *mask);
/* Known slots have a complete copied element extent and consistent stepping.
 * Unknown slots remain zero; a successful lookup may have known_mask zero. */
int ff_ia_pipeline_fetch(id<MTLRenderPipelineState> pipeline,struct ff_ia_fetch_layout *fetch);
void ff_ia_cleanup(void);
#endif
