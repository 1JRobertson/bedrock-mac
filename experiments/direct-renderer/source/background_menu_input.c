/* Explicitly opted-in Win32 menu key sender for one Wine window.
 * It neither posts macOS events nor changes foreground, focus or cursor.
 * Queue success is not evidence that Bedrock handled a key. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "background_menu_core.h"
#define GAME_IMAGE "G:\\Minecraft.Windows.exe"

static int owner(void *unused,uintptr_t handle,uint32_t *pid)
{
    DWORD value=0;(void)unused;
    if (!IsWindow((HWND)handle) || !GetWindowThreadProcessId((HWND)handle,&value)) return 0;
    *pid=value;return 1;
}

static int image(void *unused,uint32_t pid,char *out,unsigned capacity)
{
    WCHAR wide[512];DWORD length=sizeof(wide)/sizeof(wide[0]);(void)unused;
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if (!process) return 0;
    int ok=QueryFullProcessImageNameW(process,0,wide,&length) &&
        WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide,-1,out,(int)capacity,NULL,NULL)>0;
    CloseHandle(process);return ok;
}

static unsigned scan(void *unused,unsigned vk)
{
    (void)unused;return MapVirtualKeyW(vk,MAPVK_VK_TO_VSC) & 255u;
}

static int post(void *unused,uintptr_t hwnd,unsigned message,uintptr_t vk,intptr_t parameter)
{
    (void)unused;return PostMessageW((HWND)hwnd,message,(WPARAM)vk,(LPARAM)parameter)!=0;
}

static int decimal_pid(const char *text,uint32_t *value)
{
    char *end=NULL;unsigned long parsed;
    if (!text || !*text || *text=='-' || *text=='+') return 0;
    errno=0;
    parsed=strtoul(text,&end,10);
    if (errno==ERANGE || !end || *end || !parsed || parsed>0xffffffffUL) return 0;
    *value=(uint32_t)parsed;return 1;
}

static int exact_hwnd(const char *text,uintptr_t *value)
{
    char *end=NULL;unsigned long long parsed;
    if (!text || strlen(text)<3 || text[0]!='0' || text[1]!='x') return 0;
    errno=0;
    parsed=strtoull(text,&end,16);
    if (errno==ERANGE || !end || *end || !parsed || parsed>(uintptr_t)-1) return 0;
    *value=(uintptr_t)parsed;return 1;
}

typedef struct {
    uint32_t pid,found_pid;
    const char *expected_image;
    HWND found;
    unsigned scanned,count;
} window_search;
static BOOL CALLBACK matching_window(HWND hwnd,LPARAM opaque)
{
    window_search *search=(window_search *)opaque;DWORD pid=0;RECT rect;char path[1024]={0};
    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd,&rect) ||
        rect.right-rect.left<64 || rect.bottom-rect.top<64) return TRUE;
    if (++search->scanned>256) return FALSE;
    if (!GetWindowThreadProcessId(hwnd,&pid) || (search->pid && pid!=search->pid) ||
        !image(NULL,pid,path,sizeof(path)) || !bmi_equal_path(path,search->expected_image)) return TRUE;
    search->found=hwnd;search->found_pid=pid;search->count++;
    return search->count<2;
}

static int selected_target(const char *pid_text,const char *hwnd_text,const char *expected_image,
                           uint32_t *pid,uintptr_t *hwnd)
{
    if (strcmp(pid_text,"auto") && !decimal_pid(pid_text,pid)) return 0;
    if (strcmp(hwnd_text,"auto")) return *pid && exact_hwnd(hwnd_text,hwnd);
    window_search search={.pid=*pid,.expected_image=expected_image};
    EnumWindows(matching_window,(LPARAM)&search);
    if (search.count!=1 || search.scanned>256) return 0;
    *pid=search.found_pid;*hwnd=(uintptr_t)search.found;return 1;
}

typedef struct { const char *expected_image;unsigned scanned,matches,truncated; } inspect_search;
static BOOL CALLBACK inspect_window(HWND hwnd,LPARAM opaque)
{
    inspect_search *search=(inspect_search *)opaque;DWORD pid=0,thread;RECT rect,client;
    GUITHREADINFO info={.cbSize=sizeof(info)};char path[1024]={0};
    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd,&rect) ||
        rect.right-rect.left<64 || rect.bottom-rect.top<64) return TRUE;
    if (++search->scanned>256) return FALSE;
    thread=GetWindowThreadProcessId(hwnd,&pid);
    if (!thread || !image(NULL,pid,path,sizeof(path)) ||
        !bmi_equal_path(path,search->expected_image)) return TRUE;
    if (!GetClientRect(hwnd,&client)) return TRUE;
    GetGUIThreadInfo(thread,&info);
    if (search->matches++) putchar(',');
    printf("{\"pid\":%lu,\"hwnd\":\"0x%llx\",\"client_width\":%ld,\"client_height\":%ld,"
           "\"wine_focus_hwnd\":\"0x%llx\",\"wine_active_hwnd\":\"0x%llx\"}",
           (unsigned long)pid,(unsigned long long)(uintptr_t)hwnd,
           (long)(client.right-client.left),(long)(client.bottom-client.top),
           (unsigned long long)(uintptr_t)info.hwndFocus,(unsigned long long)(uintptr_t)info.hwndActive);
    if (search->matches>=8) { search->truncated=1;return FALSE; }
    return TRUE;
}

static int inspect(const char *expected_image)
{
    inspect_search search={expected_image,0,0};
    printf("{\"format\":\"bedrock-background-menu-window-inspect\",\"version\":1,"
           "\"wine_foreground_hwnd\":\"0x%llx\",\"windows\":[",
           (unsigned long long)(uintptr_t)GetForegroundWindow());
    EnumWindows(inspect_window,(LPARAM)&search);
    printf("],\"matches\":%u,\"unique\":%s,\"bounded\":%s}\n",search.matches,
           search.matches==1?"true":"false",
           search.scanned<=256 && !search.truncated?"true":"false");
    return search.matches==1 && search.scanned<=256 && !search.truncated ? 0 : 1;
}

int main(int argc,char **argv)
{
    uint32_t pid=0;uintptr_t hwnd=0;
    bmi_ops ops={NULL,owner,image,scan,post};
    if (argc==4 && !strcmp(argv[1],"--inspect") && !strcmp(argv[2],"--exe") &&
        bmi_equal_path(argv[3],GAME_IMAGE))
        return inspect(argv[3]);
    if (argc!=10 || strcmp(argv[1],"--background-menu-input") ||
        strcmp(argv[2],"--pid") || strcmp(argv[4],"--hwnd") ||
        strcmp(argv[6],"--exe") || strcmp(argv[8],"--key") ||
        !bmi_equal_path(argv[7],GAME_IMAGE) ||
        !selected_target(argv[3],argv[5],argv[7],&pid,&hwnd) ||
        !bmi_parse_key(argv[9],&(bmi_key){0})) {
        fputs("usage: background_menu_input --background-menu-input --pid auto|WIN_PID --hwnd auto|0xHEX --exe EXACT_WIN_PATH --key return|escape|left|up|right|down\n",stderr);
        return 2;
    }
    if (!bmi_send_tap(&ops,pid,hwnd,argv[7],argv[9])) {
        fputs("No key receipt: window/PID/image identity, scan code, or message queue failed\n",stderr);
        return 1;
    }
    printf("{\"format\":\"bedrock-background-menu-key-queued\",\"version\":1,"
           "\"pid\":%lu,\"hwnd\":\"0x%llx\",\"key\":\"%s\",\"game_handled\":false}\n",
           (unsigned long)pid,(unsigned long long)hwnd,argv[9]);
    return 0;
}
