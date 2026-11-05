#include "native_direct_wmt.h"
#include "winemetal.h"
#include <math.h>
#include <string.h>

_Static_assert(sizeof(FFDWBufferIdentity)==48, "paired source buffer identity ABI");
#ifdef WMT_BEDROCK_BUFFER_IDENTITY_VERSION
_Static_assert(WMT_BEDROCK_BUFFER_IDENTITY_MAGIC==FFDW_BUFFER_IDENTITY_MAGIC &&
               WMT_BEDROCK_BUFFER_IDENTITY_VERSION==FFDW_BUFFER_IDENTITY_VERSION &&
               sizeof(struct WMTBedrockBufferIdentity)==sizeof(FFDWBufferIdentity) &&
               offsetof(struct WMTBedrockBufferIdentity,magic)==offsetof(FFDWBufferIdentity,magic) &&
               offsetof(struct WMTBedrockBufferIdentity,version)==offsetof(FFDWBufferIdentity,version) &&
               offsetof(struct WMTBedrockBufferIdentity,reserved)==offsetof(FFDWBufferIdentity,reserved) &&
               offsetof(struct WMTBedrockBufferIdentity,root)==offsetof(FFDWBufferIdentity,root) &&
               offsetof(struct WMTBedrockBufferIdentity,generation)==offsetof(FFDWBufferIdentity,generation) &&
               offsetof(struct WMTBedrockBufferIdentity,base)==offsetof(FFDWBufferIdentity,base) &&
               offsetof(struct WMTBedrockBufferIdentity,length)==offsetof(FFDWBufferIdentity,length),
               "paired WMT operand identity must match translator ABI");
#endif

int ffdw_paired_index_identity(void *context, const struct wmtcmd_base *command, FFDWBufferIdentity *out) {
    (void)context;
#ifdef WMT_BEDROCK_BUFFER_IDENTITY_VERSION
    if (!command || !out || command->type!=WMTRenderCommandDrawIndexed) return 0;
    const struct wmtcmd_render_draw_indexed *draw=(const void *)command;
    memcpy(out,&draw->bedrock_index_identity,sizeof(*out));return 1;
#else
    (void)command;(void)out;return 0;
#endif
}

int ffdw_validate_buffer_identity(const FFDWBufferIdentity *identity, uint64_t offset,
                                  uint64_t length, uint64_t *object, uint64_t *generation,
                                  uint64_t *logical_offset) {
    if (!identity || !object || !generation || !logical_offset ||
        identity->magic!=FFDW_BUFFER_IDENTITY_MAGIC || identity->version!=FFDW_BUFFER_IDENTITY_VERSION ||
        identity->reserved || !identity->root || !identity->generation || !identity->length ||
        identity->base>UINT64_MAX-identity->length || offset<identity->base) return 0;
    uint64_t relative=offset-identity->base;
    if (relative>=identity->length || length>identity->length-relative) return 0;
    *object=identity->root;*generation=identity->generation;*logical_offset=relative;return 1;
}

typedef struct {
    FFDWSourceTable tables[FFDW_TABLES];
    size_t previous[FFDW_TABLES];
    FFDWDrawTables prior;
    uint64_t pipeline;
} FFDWState;

static int special_slot(unsigned stage, unsigned index) {
    if (!stage && index == 16) return FFDW_VERTEX_IA;
    if (!stage && index == 29) return FFDW_VERTEX_CONSTANTS;
    if (!stage && index == 30) return FFDW_VERTEX_ARGUMENTS;
    if (stage == 1 && index == 29) return FFDW_FRAGMENT_CONSTANTS;
    if (stage == 1 && index == 30) return FFDW_FRAGMENT_ARGUMENTS;
    return -1;
}

static int resolve_object(const FFDWResolvers *r, unsigned kind, const struct wmtcmd_base *command,
                          uint64_t handle, uint64_t *object, uint64_t *generation) {
    *object = *generation = 0;
    return handle && r->object && r->object(r->context, kind, command, handle, object, generation) &&
           *object && *generation;
}

static int set_buffer(FFDWState *state, unsigned stage, unsigned index, uint64_t source, uint64_t offset) {
    if (stage > 1 || index >= 31 || (!source && offset)) return 0;
    int slot = special_slot(stage, index);
    if (slot >= 0) { state->tables[slot] = (FFDWSourceTable){source, offset}; return 1; }
    /* The native receiver cannot yet qualify ordinary resource slots. */
    return 0;
}

static int set_offset(FFDWState *state, unsigned stage, unsigned index, uint64_t offset) {
    if (stage > 1 || index >= 31) return 0;
    int slot = special_slot(stage, index);
    if (slot >= 0) {
        if (!state->tables[slot].buffer) return 0;
        state->tables[slot].offset = offset; return 1;
    }
    return 0;
}

static int draw_tables(FFDCWriter *w, FFDWState *state, const FFDWResolvers *r,
                       const struct wmtcmd_base *draw) {
    FFDWDrawTables result = {0};
    if (!state->pipeline || !r->tables || !r->tables(r->context, draw, state->pipeline, state->tables, &result)) return 0;
    /* FFDCReceiver rejects IA draws until element widths and ranges are proven. */
    if (result.vertex_count) return 0;
    const void *arrays[FFDW_TABLES] = {result.vertices, result.constants[0], result.arguments[0],
                                     result.constants[1], result.arguments[1]};
    size_t counts[FFDW_TABLES] = {result.vertex_count, result.constant_count[0], result.argument_count[0],
                                  result.constant_count[1], result.argument_count[1]};
    void *prior[FFDW_TABLES] = {state->prior.vertices,state->prior.constants[0],state->prior.arguments[0],
                                state->prior.constants[1],state->prior.arguments[1]};
    const size_t limits[FFDW_TABLES] = {32,14,128,14,128};
    const size_t sizes[FFDW_TABLES] = {sizeof(FFDCLogicalBuffer),sizeof(FFDCLogicalBuffer),sizeof(FFDCLogicalField),
                                       sizeof(FFDCLogicalBuffer),sizeof(FFDCLogicalField)};
    const uint32_t operations[FFDW_TABLES] = {FFDC_VERTEX_TABLE, FFDC_CONSTANT_TABLE, FFDC_ARGUMENT_TABLE,
                                              FFDC_CONSTANT_TABLE, FFDC_ARGUMENT_TABLE};
    const uint32_t stages[FFDW_TABLES] = {FFDC_VERTEX, FFDC_VERTEX, FFDC_VERTEX, FFDC_FRAGMENT, FFDC_FRAGMENT};
    for (unsigned i=0; i<FFDW_TABLES; ++i) {
        if (counts[i]>limits[i]) return 0;
        int changed=counts[i]!=state->previous[i] || memcmp(arrays[i],prior[i],counts[i]*sizes[i]);
        if (changed && !ffdc_logical_table(w,operations[i],stages[i],arrays[i],counts[i])) return 0;
        if (changed && counts[i]) memcpy(prior[i],arrays[i],counts[i]*sizes[i]);
        state->previous[i] = counts[i];
    }
    return 1;
}

static int viewport(FFDCWriter *w, const struct WMTViewport *v) {
    if (v->znear<0 || v->znear>1 || v->zfar<0 || v->zfar>1) return 0;
    FFDCViewport value = {v->originX, v->originY, v->width, v->height, v->znear, v->zfar};
    return ffdc_render_command(w, FFDC_SET_VIEWPORT, &value, sizeof(value));
}
static int scissor(FFDCWriter *w, const struct WMTScissorRect *v) {
    FFDCScissor value = {v->x, v->y, v->width, v->height};
    return ffdc_render_command(w, FFDC_SET_SCISSOR, &value, sizeof(value));
}

static int convert(FFDCWriter *w, FFDWState *s, const FFDWResolvers *r, const struct wmtcmd_base *c) {
    switch ((enum WMTRenderCommandType)c->type) {
    case WMTRenderCommandNop: return 1;
    case WMTRenderCommandSetPSO: {
        uint64_t source=((const struct wmtcmd_render_setpso *)c)->pso, object, generation;
        if (!resolve_object(r, FFDW_PIPELINE, c, source, &object, &generation) ||
            !ffdc_bind_pipeline(w, object, generation)) return 0;
        s->pipeline=source; return 1;
    }
    case WMTRenderCommandSetVertexBuffer: case WMTRenderCommandSetFragmentBuffer: {
        const struct wmtcmd_render_setbuffer *b=(const void *)c;
        return set_buffer(s,c->type==WMTRenderCommandSetFragmentBuffer,b->index,b->buffer,b->offset);
    }
    case WMTRenderCommandSetVertexBufferOffset: case WMTRenderCommandSetFragmentBufferOffset: {
        const struct wmtcmd_render_setbufferoffset *b=(const void *)c;
        return set_offset(s,c->type==WMTRenderCommandSetFragmentBufferOffset,b->index,b->offset);
    }
    case WMTRenderCommandSetRasterizerState: {
        const struct wmtcmd_render_setrasterizerstate *v=(const void *)c;
        FFDCRaster value={v->fill_mode,v->cull_mode,v->depth_clip_mode,v->winding,
                          v->depth_bias,v->scole_scale,v->depth_bias_clamp,0};
        return ffdc_render_command(w,FFDC_SET_RASTER,&value,sizeof(value));
    }
    case WMTRenderCommandSetViewport:
        return viewport(w,&((const struct wmtcmd_render_setviewport *)c)->viewport);
    case WMTRenderCommandSetViewports: {
        const struct wmtcmd_render_setviewports *v=(const void *)c;
        return v->viewport_count==1 && v->viewports.ptr && viewport(w,v->viewports.ptr);
    }
    case WMTRenderCommandSetScissorRect:
        return scissor(w,&((const struct wmtcmd_render_setscissorrect *)c)->scissor_rect);
    case WMTRenderCommandSetScissorRects: {
        const struct wmtcmd_render_setscissorrects *v=(const void *)c;
        return v->rect_count==1 && v->scissor_rects.ptr && scissor(w,v->scissor_rects.ptr);
    }
    case WMTRenderCommandDraw: {
        const struct wmtcmd_render_draw *d=(const void *)c;
        if ((d->instance_count && d->base_instance>UINT32_MAX-(d->instance_count-1)) || !draw_tables(w,s,r,c)) return 0;
        int empty=1; for (unsigned i=0;i<FFDW_TABLES;i++) if(s->previous[i]) empty=0;
        if (empty && d->primitive_type==WMTPrimitiveTypeTriangle && !d->vertex_start &&
            d->vertex_count==3 && d->instance_count==1 && !d->base_instance)
            return ffdc_draw_triangles(w,0,3,1);
        FFDCDraw value={d->vertex_start,d->vertex_count,d->primitive_type,d->instance_count,d->base_instance,0};
        return ffdc_render_command(w,FFDC_DRAW,&value,sizeof(value));
    }
    case WMTRenderCommandDrawIndexed: {
        const struct wmtcmd_render_draw_indexed *d=(const void *)c;
        if (d->index_type>WMTIndexTypeUInt32 || !d->index_buffer || !r->index_identity ||
            (d->instance_count && d->base_instance>UINT32_MAX-(d->instance_count-1))) return 0;
        uint64_t stride=d->index_type==WMTIndexTypeUInt32?4:2;
        if (d->index_count>UINT64_MAX/stride || d->index_buffer_offset>UINT64_MAX-d->index_count*stride) return 0;
        FFDCIndexedDraw value={.count=d->index_count,.primitive=d->primitive_type,.index_type=d->index_type,
            .instances=d->instance_count,.base_vertex=d->base_vertex,.base_instance=d->base_instance};
        FFDWBufferIdentity identity={0};
        if (!r->index_identity(r->context,c,&identity) ||
            !ffdw_validate_buffer_identity(&identity,d->index_buffer_offset,d->index_count*stride,
                                           &value.object,&value.generation,&value.offset) ||
            !draw_tables(w,s,r,c)) return 0;
        return ffdc_render_command(w,FFDC_DRAW_INDEXED,&value,sizeof(value));
    }
    default: return 0; /* Includes useResource, barriers, visibility and indirect draws. */
    }
}

int ffdw_append_render(FFDCWriter *writer, const struct WMTRenderPassInfo *pass,
                       const struct wmtcmd_base *commands, uint64_t initial_argbuffer,
                       const FFDWResolvers *r) {
    if (!writer || !writer->data || writer->sealed || writer->length < sizeof(FFDCHeader) ||
        writer->length > writer->capacity || writer->capacity > FFDC_MAX_BYTES ||
        writer->count > FFDC_MAX_COMMANDS || !pass || !r || !r->object) return 0;
    const struct WMTColorAttachmentInfo *color=&pass->colors[0];
    if (!color->texture || color->load_action!=WMTLoadActionClear || color->store_action!=WMTStoreActionStore ||
        color->level || color->slice || color->depth_plane || color->resolve_texture ||
        pass->depth.texture || pass->stencil.texture || pass->visibility_buffer ||
        pass->default_raster_sample_count || pass->render_target_array_length ||
        pass->tile_width || pass->tile_height || pass->render_target_width || pass->render_target_height) return 0;
    for (unsigned i=1;i<8;i++) if (pass->colors[i].texture || pass->colors[i].resolve_texture) return 0;
    double input[4]={color->clear_color.r,color->clear_color.g,color->clear_color.b,color->clear_color.a};
    float clear[4];
    for (unsigned i=0;i<4;i++) {
        clear[i]=(float)input[i];
        if (!isfinite(input[i]) || !isfinite(clear[i]) || (double)clear[i]!=input[i] ||
            (!!signbit(clear[i]) != !!signbit(input[i]))) return 0;
    }
    uint64_t object,generation;
    if (!resolve_object(r,FFDW_TARGET,NULL,color->texture,&object,&generation)) return 0;
    FFDCWriter staged=*writer;
    FFDWState state={0};
    for(unsigned i=0;i<FFDW_TABLES;i++) state.tables[i].buffer=initial_argbuffer;
    if (!ffdc_begin_render(&staged,object,generation,clear)) return 0;
    size_t count=0;
    for (const struct wmtcmd_base *c=commands;c;c=c->next.ptr) {
        if (++count>FFDC_MAX_COMMANDS || !convert(&staged,&state,r,c)) return 0;
    }
    if (!ffdc_end_render(&staged)) return 0;
    *writer=staged; return 1;
}
