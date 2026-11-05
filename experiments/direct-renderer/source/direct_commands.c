#include "direct_commands.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <sys/socket.h>

static int valid_header(FFDCHeader h,size_t n) {
    return h.magic==FFDC_MAGIC && h.version==FFDC_VERSION && h.bytes==n &&
        n>=sizeof(h) && n<=FFDC_MAX_BYTES && h.serial && h.stream && h.chunk &&
        h.completion && h.count<=FFDC_MAX_COMMANDS && !h.reserved;
}
static int generic_slot(uint32_t index) { return index<31 && index!=16 && index!=29 && index!=30; }
static int zero_fields(FFDCRecord r) {
    return !r.target&&!r.target_generation&&!r.source&&!r.source_generation&&!r.offset&&!r.source_offset&&!r.length;
}
static int paired_handle(uint64_t object,uint64_t generation) { return (!!object)==(!!generation); }
static int logical_buffer(FFDCLogicalBuffer b) {
    return paired_handle(b.object,b.generation) && b.offset<=UINT64_MAX-b.length &&
        (b.object || (!b.offset&&!b.stride&&!b.length));
}
static int typed_payload(FFDCRecord r,const void *payload) {
    size_t n=r.bytes-sizeof(r);
    if(r.operation==FFDC_SET_FRAGMENT_BYTES)
        return generic_slot((uint32_t)r.target) && r.target<31 && !r.target_generation && !r.source && !r.source_generation && !r.offset && !r.source_offset && r.length==n && n && n<=FFDC_MAX_INLINE_BYTES;
    if(r.operation>=FFDC_VERTEX_TABLE&&r.operation<=FFDC_ARGUMENT_TABLE) {
        size_t max=r.operation==FFDC_VERTEX_TABLE?32:r.operation==FFDC_CONSTANT_TABLE?14:128;
        size_t item=r.operation==FFDC_ARGUMENT_TABLE?sizeof(FFDCLogicalField):sizeof(FFDCLogicalBuffer);
        if(r.target>FFDC_FRAGMENT||(r.operation==FFDC_VERTEX_TABLE&&r.target!=FFDC_VERTEX)||
           r.target_generation||r.source||r.source_generation||r.offset||r.source_offset||
           r.length>max||n!=r.length*item)return 0;
        const unsigned char *p=payload;
        for(size_t i=0;i<r.length;i++) {
            if(r.operation!=FFDC_ARGUMENT_TABLE) { FFDCLogicalBuffer b;memcpy(&b,p+i*item,sizeof(b));if(!logical_buffer(b))return 0;continue; }
            FFDCLogicalField f;memcpy(&f,p+i*item,sizeof(f));
            if((f.offset&7)||f.offset>=4096||!logical_buffer(f.buffer)||!paired_handle(f.object,f.generation))return 0;
            for(size_t j=0;j<i;j++){FFDCLogicalField prev;memcpy(&prev,p+j*item,sizeof(prev));if(prev.offset==f.offset)return 0;}
            int bufferNull=!f.buffer.object;
            if(f.kind==FFDC_FIELD_BUFFER){if(f.object||f.value)return 0;}
            else if(f.kind==FFDC_FIELD_VALUE){if(f.object||!bufferNull)return 0;}
            else if(f.kind==FFDC_FIELD_TEXTURE||f.kind==FFDC_FIELD_SAMPLER){if(!bufferNull||f.value)return 0;}
            else return 0;
        }
        return 1;
    }
    if(!zero_fields(r))return 0;
    switch(r.operation) {
    case FFDC_SET_VIEWPORT: {
        if(n!=sizeof(FFDCViewport))return 0;FFDCViewport v;memcpy(&v,payload,sizeof(v));
        return isfinite(v.x)&&isfinite(v.y)&&isfinite(v.width)&&isfinite(v.height)&&isfinite(v.znear)&&isfinite(v.zfar)&&v.width>=0&&v.height>=0;
    }
    case FFDC_SET_SCISSOR: {
        if(n!=sizeof(FFDCScissor))return 0;FFDCScissor v;memcpy(&v,payload,sizeof(v));
        return v.x<=UINT64_MAX-v.width&&v.y<=UINT64_MAX-v.height;
    }
    case FFDC_SET_RASTER: {
        if(n!=sizeof(FFDCRaster))return 0;FFDCRaster v;memcpy(&v,payload,sizeof(v));
        return v.fill<=1&&v.cull<=2&&v.depth_clip<=1&&v.winding<=1&&!v.reserved&&isfinite(v.depth_bias)&&isfinite(v.slope_scale)&&isfinite(v.depth_bias_clamp);
    }
    case FFDC_SET_BUFFER: {
        if(n!=sizeof(FFDCBufferBinding))return 0;FFDCBufferBinding v;memcpy(&v,payload,sizeof(v));
        return v.stage<=FFDC_FRAGMENT&&generic_slot(v.index)&&paired_handle(v.object,v.generation)&&(v.object||!v.offset);
    }
    case FFDC_SET_BUFFER_OFFSET: {
        if(n!=sizeof(FFDCBufferOffset))return 0;FFDCBufferOffset v;memcpy(&v,payload,sizeof(v));
        return v.stage<=FFDC_FRAGMENT&&generic_slot(v.index);
    }
    case FFDC_SET_FRAGMENT_TEXTURE: {
        if(n!=sizeof(FFDCTextureBinding))return 0;FFDCTextureBinding v;memcpy(&v,payload,sizeof(v));
        return v.index<128&&!v.reserved&&paired_handle(v.object,v.generation);
    }
    case FFDC_DRAW: {
        if(n!=sizeof(FFDCDraw))return 0;FFDCDraw v;memcpy(&v,payload,sizeof(v));
        return v.primitive<=4&&!v.reserved&&v.first<=UINT64_MAX-v.count;
    }
    case FFDC_DRAW_INDEXED: {
        if(n!=sizeof(FFDCIndexedDraw))return 0;FFDCIndexedDraw v;memcpy(&v,payload,sizeof(v));
        if(!v.object||!v.generation||v.primitive>4||v.index_type>1||v.reserved)return 0;
        uint64_t stride=v.index_type?4:2;return !(v.offset%stride)&&v.count<=(UINT64_MAX-v.offset)/stride;
    }
    default:return 0;
    }
}
static int valid_record(FFDCRecord r,size_t remaining) {
    if(r.bytes<sizeof(r) || r.bytes>remaining) return 0;
    uint64_t payload=r.bytes-sizeof(r);
    if(r.operation>=FFPS_CREATE && r.operation<=FFPS_DESTROY && (!r.target||!r.target_generation))return 0;
    switch(r.operation) {
    case FFPS_CREATE: return r.length && !r.source && !r.source_generation && !r.offset && !r.source_offset && !payload;
    case FFPS_WRITE: return r.length && r.length==payload && !r.source && !r.source_generation && !r.source_offset && r.offset<=UINT64_MAX-r.length;
    case FFPS_COPY: return r.length && !payload && r.source && r.source_generation && r.offset<=UINT64_MAX-r.length && r.source_offset<=UINT64_MAX-r.length;
    case FFPS_DESTROY: return !r.source && !r.source_generation && !r.offset && !r.source_offset && !r.length && !payload;
    case FFDC_BEGIN_RENDER: return r.target && r.target_generation && !r.source && !r.source_generation && !r.offset && !r.source_offset && !r.length && payload==4*sizeof(float);
    case FFDC_BIND_PIPELINE: return r.target && r.target_generation && !r.source && !r.source_generation && !r.offset && !r.source_offset && !r.length && !payload;
    case FFDC_DRAW_TRIANGLES: return r.target==0 && r.target_generation==3 && r.source==1 && !r.source_generation && !r.offset && !r.source_offset && !r.length && !payload;
    case FFDC_END_RENDER: return !r.target && !r.target_generation && !r.source && !r.source_generation && !r.offset && !r.source_offset && !r.length && !payload;
    case FFDC_SET_VIEWPORT:case FFDC_SET_SCISSOR:case FFDC_SET_RASTER:case FFDC_SET_BUFFER:case FFDC_SET_BUFFER_OFFSET:case FFDC_SET_FRAGMENT_BYTES:case FFDC_SET_FRAGMENT_TEXTURE:case FFDC_DRAW:case FFDC_DRAW_INDEXED:case FFDC_VERTEX_TABLE:case FFDC_CONSTANT_TABLE:case FFDC_ARGUMENT_TABLE: return 1;
    default: return 0;
    }
}
int ffdc_begin(FFDCWriter *w,void *data,size_t capacity,uint64_t serial,uint64_t stream,uint64_t frame,uint64_t chunk,uint64_t completion) {
    if(!w||!data||capacity<sizeof(FFDCHeader)||capacity>FFDC_MAX_BYTES||!serial||!stream||!chunk||!completion)return 0;
    FFDCHeader h={FFDC_MAGIC,serial,stream,frame,chunk,completion,FFDC_VERSION,sizeof(h),0,0};
    memcpy(data,&h,sizeof(h)); *w=(FFDCWriter){data,capacity,sizeof(h),0,0}; return 1;
}
int ffdc_emit(void *context,const FFPSEvent *e) {
    FFDCWriter *w=context;if(!w||!e||w->sealed||!w->data||w->count==FFDC_MAX_COMMANDS||e->operation<FFPS_CREATE||e->operation>FFPS_DESTROY)return 0;
    if(e->operation==FFPS_WRITE && (!e->bytes||e->length>UINT32_MAX-sizeof(FFDCRecord)))return 0;
    size_t payload=e->operation==FFPS_WRITE?(size_t)e->length:0;
    if(payload>w->capacity-w->length || sizeof(FFDCRecord)>w->capacity-w->length-payload)return 0;
    FFDCRecord r={(uint32_t)e->operation,(uint32_t)(sizeof(r)+payload),e->target.object,e->target.generation,
        e->source.object,e->source.generation,e->offset,e->source_offset,e->length};
    if(!valid_record(r,sizeof(r)+payload))return 0;
    memcpy(w->data+w->length,&r,sizeof(r));if(payload)memcpy(w->data+w->length+sizeof(r),e->bytes,payload);
    w->length+=sizeof(r)+payload;w->count++;return 1;
}
static int append_render(FFDCWriter *w,FFDCRecord r,const void *payload,size_t n) {
    if(!w||w->sealed||!w->data||w->count==FFDC_MAX_COMMANDS||n>w->capacity-w->length||sizeof(r)>w->capacity-w->length-n)return 0;
    r.bytes=(uint32_t)(sizeof(r)+n);if(!valid_record(r,sizeof(r)+n))return 0;
    memcpy(w->data+w->length,&r,sizeof(r));if(n)memcpy(w->data+w->length+sizeof(r),payload,n);
    w->length+=sizeof(r)+n;w->count++;return 1;
}
int ffdc_begin_render(FFDCWriter *w,uint64_t object,uint64_t generation,const float clear[4]) {
    if(!clear||!isfinite(clear[0])||!isfinite(clear[1])||!isfinite(clear[2])||!isfinite(clear[3]))return 0;
    FFDCRecord r={.operation=FFDC_BEGIN_RENDER,.target=object,.target_generation=generation};return append_render(w,r,clear,4*sizeof(float));
}
int ffdc_bind_pipeline(FFDCWriter *w,uint64_t object,uint64_t generation) {
    FFDCRecord r={.operation=FFDC_BIND_PIPELINE,.target=object,.target_generation=generation};return append_render(w,r,NULL,0);
}
int ffdc_draw_triangles(FFDCWriter *w,uint32_t first,uint32_t count,uint32_t instances) {
    FFDCRecord r={.operation=FFDC_DRAW_TRIANGLES,.target=first,.target_generation=count,.source=instances};return append_render(w,r,NULL,0);
}
int ffdc_end_render(FFDCWriter *w) { FFDCRecord r={.operation=FFDC_END_RENDER};return append_render(w,r,NULL,0); }
int ffdc_render_command(FFDCWriter *w,uint32_t op,const void *payload,size_t n) {
    if(op<FFDC_SET_VIEWPORT||op>FFDC_DRAW_INDEXED||op==FFDC_SET_FRAGMENT_BYTES||!payload||n>UINT32_MAX-sizeof(FFDCRecord))return 0;
    FFDCRecord r={.operation=op,.bytes=(uint32_t)(sizeof(r)+n)};
    return typed_payload(r,payload)&&append_render(w,r,payload,n);
}
int ffdc_fragment_bytes(FFDCWriter *w,uint32_t index,const void *data,size_t n) {
    if(!data||n>FFDC_MAX_INLINE_BYTES)return 0;
    FFDCRecord r={.operation=FFDC_SET_FRAGMENT_BYTES,.bytes=(uint32_t)(sizeof(r)+n),.target=index,.length=n};
    return typed_payload(r,data)&&append_render(w,r,data,n);
}
int ffdc_logical_table(FFDCWriter *w,uint32_t operation,uint32_t stage,const void *entries,size_t count) {
    if(operation<FFDC_VERTEX_TABLE||operation>FFDC_ARGUMENT_TABLE||count>128||(!entries&&count))return 0;
    size_t item=operation==FFDC_ARGUMENT_TABLE?sizeof(FFDCLogicalField):sizeof(FFDCLogicalBuffer);
    size_t n=count*item;FFDCRecord r={.operation=operation,.bytes=(uint32_t)(sizeof(r)+n),.target=stage,.length=count};
    return typed_payload(r,entries)&&append_render(w,r,entries,n);
}
int ffdc_seal(FFDCWriter *w) {
    if(!w||!w->data||w->sealed)return 0;
    FFDCHeader h;memcpy(&h,w->data,sizeof(h));h.bytes=(uint32_t)w->length;h.count=w->count;
    memcpy(w->data,&h,sizeof(h));w->sealed=1;return 1;
}
static int validate_batch(const void *data,size_t n,int requireComplete) {
    if(!data||n<sizeof(FFDCHeader))return 0;FFDCHeader h;memcpy(&h,data,sizeof(h));if(!valid_header(h,n))return 0;
    size_t offset=sizeof(h);const unsigned char *p=data;int inPass=0,pipeline=0;uint32_t buffers[2]={0,0};
    for(uint32_t i=0;i<h.count;i++) {
        if(n-offset<sizeof(FFDCRecord))return 0;FFDCRecord r;memcpy(&r,p+offset,sizeof(r));
        if(!valid_record(r,n-offset))return 0;
        const void *payload=p+offset+sizeof(r);
        if(r.operation>=FFDC_SET_VIEWPORT && !typed_payload(r,payload))return 0;
        if(r.operation==FFDC_BEGIN_RENDER){
            float c[4];memcpy(c,payload,sizeof(c));
            if(inPass||!isfinite(c[0])||!isfinite(c[1])||!isfinite(c[2])||!isfinite(c[3]))return 0;
            inPass=1;pipeline=0;buffers[0]=buffers[1]=0;
        } else if(r.operation==FFDC_END_RENDER) {
            if(!inPass)return 0;inPass=0;pipeline=0;
        } else if(r.operation>=FFPS_CREATE && r.operation<=FFPS_DESTROY) {
            if(inPass)return 0;
        } else {
            if(!inPass)return 0;
            if(r.operation==FFDC_BIND_PIPELINE)pipeline=1;
            if((r.operation==FFDC_DRAW_TRIANGLES||r.operation==FFDC_DRAW||r.operation==FFDC_DRAW_INDEXED)&&!pipeline)return 0;
            if(r.operation==FFDC_SET_BUFFER) {
                FFDCBufferBinding binding;memcpy(&binding,payload,sizeof(binding));uint32_t bit=UINT32_C(1)<<binding.index;
                if(binding.object)buffers[binding.stage]|=bit;else buffers[binding.stage]&=~bit;
            } else if(r.operation==FFDC_SET_BUFFER_OFFSET) {
                FFDCBufferOffset binding;memcpy(&binding,payload,sizeof(binding));
                if(!(buffers[binding.stage]&(UINT32_C(1)<<binding.index)))return 0;
            } else if(r.operation==FFDC_SET_FRAGMENT_BYTES)buffers[FFDC_FRAGMENT]&=~(UINT32_C(1)<<r.target);
        }
        offset+=r.bytes;
    }
    /* Legacy receiver rejects an unterminated pass without GPU submission. */
    return offset==n&&(!requireComplete||!inPass);
}
int ffdc_validate(const void *data,size_t n) { return validate_batch(data,n,0); }
int ffdc_validate_complete(const void *data,size_t n) { return validate_batch(data,n,1); }
int ffdc_visit(const void *data,size_t n,FFDCVisit visit,void *context) {
    if(!visit||!ffdc_validate(data,n))return 0;FFDCHeader h;memcpy(&h,data,sizeof(h));const unsigned char *p=data;size_t offset=sizeof(h);
    for(uint32_t i=0;i<h.count;i++){FFDCRecord r;memcpy(&r,p+offset,sizeof(r));if(!visit(context,&r,p+offset+sizeof(r)))return 0;offset+=r.bytes;}return 1;
}
static int transfer(int fd,void *data,size_t n,int writing) {
    unsigned char *p=data;while(n){ssize_t k=writing?write(fd,p,n):read(fd,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)return 0;p+=k;n-=(size_t)k;}return 1;
}
int ffdc_send(int fd,const void *data,size_t n) {
    if(!ffdc_validate_complete(data,n))return 0;int enabled=1;
    if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled)))return 0;uint32_t length=(uint32_t)n;
    return transfer(fd,&length,sizeof(length),1)&&transfer(fd,(void *)data,n,1);
}
int ffdc_receive(int fd,void **out,size_t *length) {
    if(!out||!length)return 0;*out=NULL;*length=0;uint32_t n;
    if(!transfer(fd,&n,sizeof(n),0)||n<sizeof(FFDCHeader)||n>FFDC_MAX_BYTES)return 0;
    void *p=malloc(n);if(!p)return 0;if(!transfer(fd,p,n,0)||!ffdc_validate_complete(p,n)){free(p);return 0;}
    *out=p;*length=n;return 1;
}

#define FFDC_RECEIPT_MAGIC UINT64_C(0x3154504352444646)
int ffdc_send_receipt(int fd,uint64_t serial,uint64_t completion,int gpu_completed) {
    if(!serial||!completion||(gpu_completed!=0&&gpu_completed!=1))return 0;
    int enabled=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled)))return 0;
    FFDCReceipt receipt={FFDC_RECEIPT_MAGIC,serial,completion,gpu_completed?FFDC_GPU_COMPLETED:FFDC_GPU_FAILED,0};
    return transfer(fd,&receipt,sizeof(receipt),1);
}
int ffdc_receive_receipt(int fd,uint64_t serial,uint64_t completion,int *gpu_completed) {
    if(!serial||!completion||!gpu_completed)return 0;FFDCReceipt receipt;
    if(!transfer(fd,&receipt,sizeof(receipt),0)||receipt.magic!=FFDC_RECEIPT_MAGIC||
       receipt.serial!=serial||receipt.completion!=completion||receipt.reserved||
       (receipt.status!=FFDC_GPU_COMPLETED&&receipt.status!=FFDC_GPU_FAILED))return 0;
    *gpu_completed=receipt.status==FFDC_GPU_COMPLETED;return 1;
}
