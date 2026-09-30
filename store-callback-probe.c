#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include "sources/winegdk/dlls/xgameruntime/GDKComponent/System/XStore.h"

typedef HRESULT (WINAPI *InitializeFn)(ULONG, ULONG);
typedef HRESULT (WINAPI *QueryFn)(const GUID *, REFIID, void **);
static LONG callbacks;
static DWORD callback_thread;
static void WINAPI completed(XAsyncBlock *block)
{
    callback_thread = GetCurrentThreadId();
    InterlockedIncrement(&callbacks);
}
static void report(const char *name, BOOL passed)
{
    DWORD n=0, written;
    while(name[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),name,n,&written,NULL);
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),passed?"=PASS\r\n":"=FAIL\r\n",7,&written,NULL);
}
static DWORD WINAPI watchdog(void *unused) { Sleep(30000); ExitProcess(124); return 0; }
void mainCRTStartup(void)
{
    HMODULE module;
    InitializeFn init;
    QueryFn query;
    IXThreadingImpl *threading=NULL;
    IXStoreImpl *store=NULL;
    XStoreContextHandle context=NULL;
    BOOL passed=FALSE;
    HRESULT hr;
    CreateThread(NULL,0,watchdog,NULL,0,NULL);
    LoadLibraryW(L"xgameruntime.dll.threading");
    module=LoadLibraryW(L"xgameruntime.dll");
    if(!module) goto done;
    init=(InitializeFn)GetProcAddress(module,"InitializeApiImpl");
    query=(QueryFn)GetProcAddress(module,"QueryApiImpl");
    if(!init||!query||FAILED(init(10001,3181))) goto done;
    if(FAILED(query(&CLSID_XThreadingImpl,&IID_IXThreadingImpl,(void **)&threading))) goto done;
    if(FAILED(query(&CLSID_XStoreImpl,&IID_IXStoreImpl,(void **)&store))) goto done;
    if(FAILED(store->lpVtbl->XStoreCreateContext(store,NULL,&context))) goto done;
    passed=TRUE;
    for(int manual=0;manual<2;manual++) {
        XAsyncBlock block={0};
        BYTE license[144];
        ULONGLONG deadline;
        BOOL ok;
        for(int i=0;i<144;i++) license[i]=0xa5;
        callbacks=0; callback_thread=0; block.callback=completed;
        hr=IXThreadingImpl_XTaskQueueCreate(threading,XTaskQueueDispatchMode_ThreadPool,
            manual?XTaskQueueDispatchMode_Manual:XTaskQueueDispatchMode_ThreadPool,&block.queue);
        if(FAILED(hr)) { passed=FALSE; break; }
        hr=store->lpVtbl->XStoreQueryGameLicenseAsync(store,context,&block);
        deadline=GetTickCount64()+5000;
        while(SUCCEEDED(hr)&&!callbacks&&GetTickCount64()<deadline) {
            if(manual) IXThreadingImpl_XTaskQueueDispatch(threading,block.queue,XTaskQueuePort_Completion,25);
            else Sleep(25);
        }
        ok=SUCCEEDED(hr)&&callbacks==1;
        if(manual) ok=ok&&callback_thread==GetCurrentThreadId();
        if(ok) {
            hr=store->lpVtbl->XStoreQueryGameLicenseResult(store,&block,license);
            ok=hr==E_NOTIMPL;
            for(int i=0;i<144;i++) ok=ok&&license[i]==0xa5;
        }
        report(manual?"ManualQueueErrorCompletion":"ThreadPoolErrorCompletion",ok);
        passed=passed&&ok;
        IXThreadingImpl_XTaskQueueCloseHandle(threading,block.queue);
    }
    store->lpVtbl->XStoreCloseContextHandle(store,context);
done:
    report("StoreCallbackProbe",passed);
    ExitProcess(passed?0:1);
}
