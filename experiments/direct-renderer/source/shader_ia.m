/* Correlate compile variants with the actual pipeline objects; no exported pointers. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "shader_ia.h"
#include "airconv_public.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#define LIMIT 128
#define BYTECODE_LIMIT (16u*1024u*1024u)
#define TRANSIT_LIMIT (32u*1024u*1024u)
struct compiled { void *handle; const void *bytes; size_t size; uint32_t mask; char name[256]; struct ff_ia_fetch_layout fetch; };
struct transit { dispatch_data_t data; size_t size; uint32_t mask; char name[256]; struct ff_ia_fetch_layout fetch; };
struct lib { id<MTLLibrary> object; uint32_t mask; char name[256]; struct ff_ia_fetch_layout fetch; };
struct function { id<MTLFunction> object; uint32_t mask; struct ff_ia_fetch_layout fetch; };
struct pipeline { id<MTLRenderPipelineState> object; uint32_t mask; struct ff_ia_fetch_layout fetch; };
static struct compiled compiled[LIMIT]; static struct transit transit[LIMIT];
static struct lib libs[LIMIT]; static struct function functions[LIMIT]; static struct pipeline pipelines[LIMIT];
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic int enabled;
static int ambiguous,fetch_ambiguous;
static size_t transit_bytes;
static unsigned library_cursor, function_cursor, pipeline_cursor;
__attribute__((constructor)) static void setup(void) { const char *s=getenv("BEDROCK_FULLFRAME_IA_TRACK"); enabled=s&&!strcmp(s,"1"); }
int ff_ia_enabled(void) { return enabled; }
/* Pinned air_operations.cpp loads, not sizeof Metal vector host structs.
 * Three-component 32-bit LLVM loads span12 bytes. Packed formats span4;
 * signed1010102 and the commented-out three-component byte/short formats are
 * unsupported by that lowering and deliberately stay unknown here. */
static uint32_t ia_load_width(uint32_t format){
    switch(format){
    case 45:case 46:case 47:case 48:return 1;
    case 1:case 4:case 7:case 10:case 49:case 50:case 51:case 52:case 53:return 2;
    case 3:case 6:case 9:case 12:case 13:case 16:case 19:case 22:case 25:
    case 28:case 32:case 36:case 41:case 42:case 54:case 55:return 4;
    case 15:case 18:case 21:case 24:case 27:case 29:case 33:case 37:return 8;
    case 30:case 34:case 38:return 12;
    case 31:case 35:case 39:return 16;
    default:return 0;
    }
}
static struct ff_ia_fetch_layout copy_fetch(const struct SM50_SHADER_IA_INPUT_LAYOUT_DATA *layout){
    struct ff_ia_fetch_layout fetch={0};uint32_t seen=0,invalid=0;
    if(!layout->elements||!layout->num_elements||layout->num_elements>32)return fetch;
    for(uint32_t i=0;i<layout->num_elements;i++){
        const struct SM50_IA_INPUT_ELEMENT *element=&layout->elements[i];
        if(element->slot>=32)return (struct ff_ia_fetch_layout){0};
        uint32_t bit=UINT32_C(1)<<element->slot;if(!(layout->slot_mask&bit))continue;
        uint32_t width=ia_load_width(element->format);struct ff_ia_slot_extent *slot=&fetch.slots[element->slot];
        if(!width||element->reg>=32||element->aligned_byte_offset>UINT32_MAX-width){invalid|=bit;continue;}
        if(seen&bit){if(slot->step_function!=element->step_function||slot->step_rate!=element->step_rate)invalid|=bit;}
        else{slot->step_function=element->step_function;slot->step_rate=element->step_rate;seen|=bit;}
        uint32_t end=element->aligned_byte_offset+width;if(end>slot->byte_end)slot->byte_end=end;
    }
    fetch.known_mask=seen&~invalid;
    for(unsigned slot=0;slot<32;slot++)if(!(fetch.known_mask&(UINT32_C(1)<<slot)))fetch.slots[slot]=(struct ff_ia_slot_extent){0};
    return fetch;
}
void ff_ia_compile(void *handle,const void *bytes,size_t size,const char *name,struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *args) {
    if(!enabled||!handle||!bytes||size<32||size>BYTECODE_LIMIT||!name)return;
    size_t name_size=strnlen(name,256); if(!name_size||name_size>=256)return;
    uint32_t seen=0,mask=0; int found=0;struct ff_ia_fetch_layout fetch={0};
    for(unsigned i=0;args&&i<8;i++,args=args->next) {
        unsigned type=(unsigned)args->type;
        if(type<1||type>7||(seen&(1u<<type)))return;
        seen|=1u<<type;
        if(type==SM50_SHADER_IA_INPUT_LAYOUT) { struct SM50_SHADER_IA_INPUT_LAYOUT_DATA *layout=(void *)args;
            mask=layout->slot_mask;fetch=copy_fetch(layout);found=1; }
    }
    if(args||!found)return;
    pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(compiled[i].handle==handle || (compiled[i].handle&&compiled[i].bytes==bytes)) {
        ambiguous=1; pthread_mutex_unlock(&lock); return;
    }
    for(unsigned i=0;i<LIMIT;i++) if(!compiled[i].handle) {
        compiled[i].handle=handle; compiled[i].bytes=bytes; compiled[i].size=size; compiled[i].mask=mask;
        compiled[i].fetch=fetch;
        memcpy(compiled[i].name,name,name_size+1); break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_ia_forget(void *handle) {
    if(!enabled)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(compiled[i].handle==handle) { memset(&compiled[i],0,sizeof(compiled[i])); break; }
    pthread_mutex_unlock(&lock);
}
void ff_ia_bind(const void *bytes,size_t size,dispatch_data_t data) {
    if(!enabled||!bytes||!data)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(compiled[i].handle&&compiled[i].bytes==bytes&&compiled[i].size==size) {
        if(size<=TRANSIT_LIMIT-transit_bytes) for(unsigned j=0;j<LIMIT;j++) if(!transit[j].data) {
            transit[j].data=data; dispatch_retain(data); transit[j].size=size; transit_bytes+=size; transit[j].mask=compiled[i].mask;
            transit[j].fetch=compiled[i].fetch;
            memcpy(transit[j].name,compiled[i].name,sizeof(transit[j].name)); break;
        } break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_ia_library(dispatch_data_t data,id<MTLLibrary> library) {
    if(!enabled||!data)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(transit[i].data==data) {
        if(library) for(unsigned j=0;j<LIMIT;j++) if(libs[j].object==library) {
            if(libs[j].mask!=transit[i].mask||strcmp(libs[j].name,transit[i].name))ambiguous=1;
            if(memcmp(&libs[j].fetch,&transit[i].fetch,sizeof(libs[j].fetch)))fetch_ambiguous=1;
            library=nil; break;
        }
        if(library) {
            unsigned j=library_cursor++%LIMIT;
            [libs[j].object release];memset(&libs[j],0,sizeof(libs[j]));
            libs[j].object=[library retain]; libs[j].mask=transit[i].mask;
            libs[j].fetch=transit[i].fetch;
            memcpy(libs[j].name,transit[i].name,sizeof(libs[j].name));
        }
        transit_bytes-=transit[i].size; dispatch_release(transit[i].data); memset(&transit[i],0,sizeof(transit[i])); break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_ia_function(id<MTLLibrary> library,id<MTLFunction> function,NSString *name) {
    if(!enabled||!library||!function||function.functionType!=MTLFunctionTypeVertex||!name)return;
    const char *value=[name UTF8String]; if(!value)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(libs[i].object==library&&!strcmp(libs[i].name,value)) {
        for(unsigned j=0;j<LIMIT;j++) if(functions[j].object==function) {
            if(functions[j].mask!=libs[i].mask)ambiguous=1;
            if(memcmp(&functions[j].fetch,&libs[i].fetch,sizeof(functions[j].fetch)))fetch_ambiguous=1;
            function=nil; break;
        }
        if(function) {
            unsigned j=function_cursor++%LIMIT;[functions[j].object release];
            functions[j].object=[function retain]; functions[j].mask=libs[i].mask;
            functions[j].fetch=libs[i].fetch;
        } break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_ia_pipeline(id<MTLRenderPipelineState> pipeline,id<MTLFunction> vertex) {
    if(!enabled||!pipeline||!vertex)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; }
    for(unsigned i=0;i<LIMIT;i++) if(functions[i].object==vertex) {
        for(unsigned j=0;j<LIMIT;j++) if(pipelines[j].object==pipeline) {
            if(pipelines[j].mask!=functions[i].mask)ambiguous=1;
            if(memcmp(&pipelines[j].fetch,&functions[i].fetch,sizeof(pipelines[j].fetch)))fetch_ambiguous=1;
            pipeline=nil; break;
        }
        if(pipeline) {
            unsigned j=pipeline_cursor++%LIMIT;[pipelines[j].object release];
            pipelines[j].object=[pipeline retain]; pipelines[j].mask=functions[i].mask;
            pipelines[j].fetch=functions[i].fetch;
        } break;
    }
    pthread_mutex_unlock(&lock);
}
int ff_ia_pipeline_mask(id<MTLRenderPipelineState> pipeline,uint32_t *mask) {
    if(!enabled||!pipeline||!mask)return 0; int found=0; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return 0; }
    if(!ambiguous) for(unsigned i=0;i<LIMIT;i++) if(pipelines[i].object==pipeline) { *mask=pipelines[i].mask; found=1; break; }
    pthread_mutex_unlock(&lock); return found;
}
int ff_ia_pipeline_fetch(id<MTLRenderPipelineState> pipeline,struct ff_ia_fetch_layout *fetch){
    if(!enabled||!pipeline||!fetch)return 0;int found=0;pthread_mutex_lock(&lock);
    if(enabled&&!ambiguous&&!fetch_ambiguous)for(unsigned i=0;i<LIMIT;i++)if(pipelines[i].object==pipeline){*fetch=pipelines[i].fetch;found=1;break;}
    pthread_mutex_unlock(&lock);return found;
}
void ff_ia_cleanup(void) {
    if(!enabled)return; pthread_mutex_lock(&lock);
    if(!enabled) { pthread_mutex_unlock(&lock); return; } enabled=0;
    for(unsigned i=0;i<LIMIT;i++) {
        if(transit[i].data)dispatch_release(transit[i].data);
        [libs[i].object release]; [functions[i].object release]; [pipelines[i].object release];
    }
    transit_bytes=0; memset(compiled,0,sizeof(compiled)); memset(transit,0,sizeof(transit)); memset(libs,0,sizeof(libs));
    memset(functions,0,sizeof(functions)); memset(pipelines,0,sizeof(pipelines)); pthread_mutex_unlock(&lock);
}
