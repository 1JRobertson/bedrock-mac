/* Session-targeted, menu-only Win32 message admission. No host HID APIs. */
#ifndef BEDROCK_BACKGROUND_MENU_CORE_H
#define BEDROCK_BACKGROUND_MENU_CORE_H

#include <stdint.h>
#include <string.h>

enum { BMI_KEYDOWN=0x0100, BMI_KEYUP=0x0101 };

typedef struct {
    void *context;
    int (*window_owner)(void *, uintptr_t, uint32_t *);
    int (*process_image)(void *, uint32_t, char *, unsigned);
    unsigned (*scan_code)(void *, unsigned);
    int (*post)(void *, uintptr_t, unsigned, uintptr_t, intptr_t);
} bmi_ops;

typedef struct { unsigned vk; int extended; } bmi_key;

static inline int bmi_parse_key(const char *name, bmi_key *key)
{
    static const struct { const char *name; unsigned vk; int extended; } allowed[]={
        {"return",0x0d,0},{"escape",0x1b,0},{"left",0x25,1},
        {"up",0x26,1},{"right",0x27,1},{"down",0x28,1}
    };
    if (!name || !key) return 0;
    for (unsigned i=0;i<sizeof(allowed)/sizeof(allowed[0]);i++)
        if (!strcmp(name,allowed[i].name)) {
            key->vk=allowed[i].vk;key->extended=allowed[i].extended;return 1;
        }
    return 0;
}

static inline int bmi_equal_path(const char *a,const char *b)
{
    if (!a || !b) return 0;
    while (*a && *b) {
        unsigned char x=(unsigned char)*a++,y=(unsigned char)*b++;
        if (x=='/') x='\\'; if (y=='/') y='\\';
        if (x>='A' && x<='Z') x=(unsigned char)(x+32);
        if (y>='A' && y<='Z') y=(unsigned char)(y+32);
        if (x!=y) return 0;
    }
    return !*a && !*b;
}

/* Returns 1 only when both messages were queued. This is never an app receipt. */
static inline int bmi_send_tap(const bmi_ops *ops,uint32_t pid,uintptr_t hwnd,
                                const char *expected_image,const char *key_name)
{
    uint32_t owner=0;char image[1024]={0};bmi_key key={0};
    if (!ops || !pid || !hwnd || !expected_image || !*expected_image ||
        !ops->window_owner || !ops->process_image || !ops->scan_code || !ops->post ||
        !bmi_parse_key(key_name,&key)) return 0;
    if (!ops->window_owner(ops->context,hwnd,&owner) || owner!=pid ||
        !ops->process_image(ops->context,pid,image,sizeof(image)) ||
        !bmi_equal_path(image,expected_image)) return 0;
    unsigned scan=ops->scan_code(ops->context,key.vk);
    if (!scan || scan>255) return 0;
    intptr_t down=(intptr_t)(1u | (scan<<16) | ((unsigned)key.extended<<24));
    intptr_t up=down | (intptr_t)(3u<<30);
    if (!ops->post(ops->context,hwnd,BMI_KEYDOWN,key.vk,down)) return 0;
    return ops->post(ops->context,hwnd,BMI_KEYUP,key.vk,up);
}

#endif
