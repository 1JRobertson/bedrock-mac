#ifndef FFST_NATIVE_DRAW_STATE_H
#define FFST_NATIVE_DRAW_STATE_H

/* Encoder-local state shadow. Compare exact representations: a false positive
 * merely emits an extra setter; a false negative could change rendering. */
#include <stdint.h>
#include <string.h>

typedef struct {
    const void *pipeline, *depth;
    double viewport[6];
    uint64_t scissor[4];
    uint32_t raster[4];
    float bias[3], blend[4];
    uint32_t stencil;
} FFSTDrawState;

enum {
    FFST_STATE_PIPELINE=1u<<0, FFST_STATE_DEPTH=1u<<1,
    FFST_STATE_VIEWPORT=1u<<2, FFST_STATE_SCISSOR=1u<<3,
    FFST_STATE_FILL=1u<<4, FFST_STATE_CULL=1u<<5,
    FFST_STATE_CLIP=1u<<6, FFST_STATE_WINDING=1u<<7,
    FFST_STATE_BIAS=1u<<8, FFST_STATE_BLEND=1u<<9,
    FFST_STATE_STENCIL=1u<<10, FFST_STATE_ALL=(1u<<11)-1
};

typedef struct { FFSTDrawState previous; int initialized; } FFSTDrawStateShadow;

static inline uint32_t ffst_draw_state_update(FFSTDrawStateShadow *shadow,const FFSTDrawState *state) {
    uint32_t changed=0;
    if(!shadow->initialized)changed=FFST_STATE_ALL;
    else {
        const FFSTDrawState *p=&shadow->previous;
        if(p->pipeline!=state->pipeline)changed|=FFST_STATE_PIPELINE;
        if(p->depth!=state->depth)changed|=FFST_STATE_DEPTH;
        if(memcmp(p->viewport,state->viewport,sizeof(p->viewport)))changed|=FFST_STATE_VIEWPORT;
        if(memcmp(p->scissor,state->scissor,sizeof(p->scissor)))changed|=FFST_STATE_SCISSOR;
        if(p->raster[0]!=state->raster[0])changed|=FFST_STATE_FILL;
        if(p->raster[1]!=state->raster[1])changed|=FFST_STATE_CULL;
        if(p->raster[2]!=state->raster[2])changed|=FFST_STATE_CLIP;
        if(p->raster[3]!=state->raster[3])changed|=FFST_STATE_WINDING;
        if(memcmp(p->bias,state->bias,sizeof(p->bias)))changed|=FFST_STATE_BIAS;
        if(memcmp(p->blend,state->blend,sizeof(p->blend)))changed|=FFST_STATE_BLEND;
        if(p->stencil!=state->stencil)changed|=FFST_STATE_STENCIL;
    }
    shadow->previous=*state;shadow->initialized=1;return changed;
}
#endif
