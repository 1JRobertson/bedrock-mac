#include "shader_handles.h"
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#define HANDLE_COUNT 128u
#define HANDLE_MAX_SINGLE (16u*1024u*1024u)
#define HANDLE_MAX_TOTAL (32u*1024u*1024u)
struct handle_slot { void *bytes,*original; dispatch_data_t data; size_t size; unsigned pins, data_refs; int issued,retired; };
static struct handle_slot handles[HANDLE_COUNT];
static size_t used_bytes;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static void *finish(struct handle_slot *h) {
    void *original=h->original; h->original=NULL;
    if(h->bytes) { used_bytes-=h->size; free(h->bytes); h->bytes=NULL; h->size=0; }
    h->data=NULL; h->data_refs=0;
    return original;
}
void *ff_shader_handle_create(void *original,const void *native,size_t size) {
    if(!original||!native||size<32||size>HANDLE_MAX_SINGLE)return NULL;
    void *handle=NULL; pthread_mutex_lock(&lock);
    if(size<=HANDLE_MAX_TOTAL-used_bytes) for(unsigned i=0;i<HANDLE_COUNT;i++) if(!handles[i].issued) {
        void *copy=malloc(size);
        if(copy) { memcpy(copy,native,size); handles[i].issued=1; handles[i].bytes=copy;
            handles[i].original=original; handles[i].size=size; used_bytes+=size; handle=&handles[i]; }
        break;
    }
    pthread_mutex_unlock(&lock); return handle;
}
int ff_shader_handle_get(void *handle,const void **bytes,size_t *size) {
    int found=0; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handle==&handles[i]) {
        if(bytes)*bytes=handles[i].retired?NULL:handles[i].bytes;
        if(size)*size=handles[i].retired?0:handles[i].size; found=1; break;
    }
    pthread_mutex_unlock(&lock); return found;
}
int ff_shader_handle_release(void *handle,void **original) {
    int found=0; if(original)*original=NULL; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handle==&handles[i]) {
        if(!handles[i].retired) { handles[i].retired=1; if(!handles[i].pins) {
            void *owned=finish(&handles[i]); if(original)*original=owned;
        }} found=1; break;
    }
    pthread_mutex_unlock(&lock); return found;
}
void ff_shader_handle_bind(const void *bytes,size_t size,void *data) {
    if(!data)return; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&!handles[i].retired&&
        handles[i].bytes==bytes&&handles[i].size==size&&!handles[i].data) {
        handles[i].data=(dispatch_data_t)data; handles[i].data_refs=1; handles[i].pins++; break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_shader_data_retain(void *data) {
    if(!data)return; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handles[i].data==(dispatch_data_t)data) {
        handles[i].data_refs++; break;
    }
    pthread_mutex_unlock(&lock);
}
void *ff_shader_data_release(void *data) {
    void *original=NULL; if(!data)return NULL; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handles[i].data==(dispatch_data_t)data) {
        if(handles[i].data_refs&&!--handles[i].data_refs) {
            handles[i].data=NULL; handles[i].pins--;
            if(!handles[i].pins&&handles[i].retired)original=finish(&handles[i]);
        }
        break;
    }
    pthread_mutex_unlock(&lock); return original;
}
void *ff_shader_library_begin(void *data) {
    void *handle=NULL; if(!data)return NULL; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handles[i].data==(dispatch_data_t)data) {
        /* The binding pin becomes the library-call pin. */
        handles[i].data=NULL; handles[i].data_refs=0; handle=&handles[i]; break;
    }
    pthread_mutex_unlock(&lock); return handle;
}
void *ff_shader_handle_original(void *handle) {
    void *original=NULL; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handle==&handles[i]&&handles[i].pins) { original=handles[i].original; break; }
    pthread_mutex_unlock(&lock); return original;
}
void *ff_shader_library_end(void *handle) {
    void *original=NULL; pthread_mutex_lock(&lock);
    for(unsigned i=0;i<HANDLE_COUNT;i++) if(handles[i].issued&&handle==&handles[i]&&handles[i].pins) {
        handles[i].pins--; if(!handles[i].pins&&handles[i].retired)original=finish(&handles[i]); break;
    }
    pthread_mutex_unlock(&lock); return original;
}
