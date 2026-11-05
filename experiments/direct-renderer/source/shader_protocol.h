/* Private, bounded one-request-per-connection SM50 translation protocol. */
#ifndef FULLFRAME_SHADER_PROTOCOL_H
#define FULLFRAME_SHADER_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#define FF_SHADER_MAX_DXBC (1024u*1024u)
#define FF_SHADER_MAX_VARIANT (8192u)
#define FF_SHADER_MAX_METAL (16u*1024u*1024u)
#define FF_SHADER_MAX_NAME 255u
#define FF_SHADER_TIMEOUT_MS 15000
struct ff_shader_request { uint32_t magic, version, dxbc, variant, name; };
struct ff_shader_response { uint32_t magic, version, status, length; };
#define FF_SHADER_MAGIC 0x31534842u
static inline int64_t ff_shader_now(void) {
    struct timespec ts; if(clock_gettime(CLOCK_MONOTONIC,&ts)) return -1;
    return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000;
}
static inline int ff_shader_io(int fd,void *buf,size_t length,int writing,int64_t deadline) {
    unsigned char *p=(unsigned char *)buf;
    while(length) {
        int64_t left=deadline-ff_shader_now(); if(left<=0)return 0;
        struct pollfd item={fd,(short)(writing?POLLOUT:POLLIN),0};
        int rc=poll(&item,1,(int)left); if(rc<0&&errno==EINTR)continue; if(rc<=0)return 0;
        ssize_t n=writing?send(fd,p,length,0):recv(fd,p,length,0);
        if(n<0&&(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK))continue;
        if(n<=0)return 0; p+=n; length-=(size_t)n;
    }
    return 1;
}
static inline int ff_shader_name_valid(const char *name,size_t size) {
    if(!size||size>FF_SHADER_MAX_NAME)return 0;
    for(size_t i=0;i<size;i++) if(!((name[i]>='a'&&name[i]<='z')||(name[i]>='A'&&name[i]<='Z')||
       (name[i]>='0'&&name[i]<='9')||name[i]=='_'))return 0;
    return 1;
}
#endif
