/* Live RTA regression check. Only numeric status and connection presence are logged. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <xasyncprovider.h>
#include <xuser.h>
#include <winhttp.h>
#include <stdio.h>
#include <string.h>
#include <shellapi.h>

typedef HRESULT (WINAPI *InitializeFn)(ULONG, ULONG);
typedef HRESULT (WINAPI *QueryFn)(const GUID *, REFIID, void **);
static XAsyncBlock block;

static void out(const char *text)
{
    DWORD length = 0, written;
    while (text[length]) ++length;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, length, &written, NULL);
}

static void result(const char *label, HRESULT hr)
{
    char hex[] = "0x00000000\r\n";
    unsigned int value = (unsigned int)hr;
    for (int i = 0; i < 8; ++i) hex[9-i] = "0123456789ABCDEF"[(value >> (4*i)) & 15];
    out(label); out("="); out(hex);
}

static void flag(const char *label, BOOL value)
{
    out(label); out(value ? "=true\r\n" : "=false\r\n");
}

static DWORD WINAPI watchdog(void *unused)
{
    Sleep(120000);
    result("watchdog", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
    TerminateProcess(GetCurrentProcess(), 124);
    return 0;
}

static HRESULT await_status(IXThreadingImpl *threading)
{
    HRESULT hr;
    ULONGLONG deadline = GetTickCount64() + 45000;
    while ((hr = IXThreadingImpl_XAsyncGetStatus(threading, &block, FALSE)) == E_PENDING && GetTickCount64() < deadline) Sleep(25);
    if (hr == E_PENDING)
    {
        result("async_timeout", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
        IXThreadingImpl_XAsyncCancel(threading, &block);
        ExitProcess(124); /* Preserve pending callback storage until teardown. */
    }
    return hr;
}

void mainCRTStartup(void)
{
    IXThreadingImpl *threading = NULL;
    IXUserImpl *users = NULL;
    XUserHandle user = NULL;
    HMODULE runtime;
    InitializeFn initialize;
    QueryFn query;
    HRESULT hr;
    BOOL valid = FALSE;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    if (!CreateThread(NULL, 0, watchdog, NULL, 0, NULL)) ExitProcess(1);
    runtime = LoadLibraryW(L"xgameruntime.dll");
    if (!runtime) { result("LoadRuntime", HRESULT_FROM_WIN32(GetLastError())); ExitProcess(1); }
    initialize = (InitializeFn)GetProcAddress(runtime, "InitializeApiImpl");
    query = (QueryFn)GetProcAddress(runtime, "QueryApiImpl");
    if (!initialize || !query) ExitProcess(1);
    hr = initialize(10001, 3181); result("InitializeApiImpl", hr);
    if (FAILED(hr)) ExitProcess(1);
    hr = query(&CLSID_XThreadingImpl, &IID_IXThreadingImpl, (void **)&threading);
    if (FAILED(hr)) { result("QueryThreading", hr); ExitProcess(1); }
    hr = query(&CLSID_XUserImpl, &IID_IXUserImpl, (void **)&users);
    if (FAILED(hr)) { result("QueryUser", hr); ExitProcess(1); }
    hr = IXThreadingImpl_XTaskQueueCreate(threading, XTaskQueueDispatchMode_ThreadPool, XTaskQueueDispatchMode_ThreadPool, &block.queue);
    if (FAILED(hr)) { result("CreateQueue", hr); ExitProcess(1); }
    hr = IXUserImpl_XUserAddAsync(users, XUserAddOptions_AddDefaultUserSilently, &block);
    if (SUCCEEDED(hr)) hr = await_status(threading);
    result("XUserAddStatus", hr);
    if (FAILED(hr)) ExitProcess(1);
    hr = IXUserImpl_XUserAddResult(users, &block, &user); result("XUserAddResult", hr);
    if (FAILED(hr) || !user) ExitProcess(1);

    const char *url = "https://rta.xboxlive.com/connect";
    XUserGetTokenAndSignatureData *data=NULL;
    SIZE_T size=0,used=0;
    char headers[32768],bytes[16384]; WCHAR wheaders[32768];
    HINTERNET session,connect,request,ws;
    DWORD count,status=0,err; WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
    hr=IXUserImpl_XUserGetTokenAndSignatureAsync(users,user,XUserGetTokenAndSignatureOptions_None,"GET",url,0,NULL,0,NULL,&block);
    if(SUCCEEDED(hr)) hr=await_status(threading);
    if(SUCCEEDED(hr)) hr=IXUserImpl_XUserGetTokenAndSignatureResultSize(users,&block,&size);
    if(FAILED(hr)||size>1024*1024) {result("auth",hr);ExitProcess(5);}
    void *buffer=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,size);
    hr=IXUserImpl_XUserGetTokenAndSignatureResult(users,&block,size,buffer,&data,&used);
    if(FAILED(hr)||data->tokenSize>16000||data->signatureSize>2000) ExitProcess(6);
    sprintf(headers,"Authorization: %s\r\nSignature: %s\r\nSec-WebSocket-Protocol: rta.xboxlive.com.V2\r\n",data->token,data->signature);
    MultiByteToWideChar(CP_UTF8,0,headers,-1,wheaders,32768);
    session=WinHttpOpen(L"Minecraft connection diagnostic",WINHTTP_ACCESS_TYPE_NO_PROXY,NULL,NULL,0);
    WinHttpSetTimeouts(session,10000,10000,10000,15000);
    connect=WinHttpConnect(session,L"rta.xboxlive.com",443,0);
    request=WinHttpOpenRequest(connect,L"GET",L"/connect",NULL,NULL,NULL,WINHTTP_FLAG_SECURE);
    DWORD redirect=WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(request,WINHTTP_OPTION_REDIRECT_POLICY,&redirect,sizeof(redirect));
    WinHttpSetOption(request,WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,NULL,0);
    if(!WinHttpSendRequest(request,wheaders,-1,NULL,0,0,0)||!WinHttpReceiveResponse(request,NULL)) {result("HTTP_error",GetLastError());ExitProcess(7);}
    SecureZeroMemory(headers,sizeof(headers));SecureZeroMemory(wheaders,sizeof(wheaders));SecureZeroMemory(buffer,size);HeapFree(GetProcessHeap(),0,buffer);
    count=sizeof(status);WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,NULL,&status,&count,NULL);result("HTTP_status",status);
    if(status!=101) ExitProcess(8);
    ws=WinHttpWebSocketCompleteUpgrade(request,0);WinHttpCloseHandle(request);
    char *msg="[1,1,\"https://sessiondirectory.xboxlive.com/connections/\"]";
    err=WinHttpWebSocketSend(ws,WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,msg,strlen(msg));result("send",err);
    err=WinHttpWebSocketReceive(ws,bytes,sizeof(bytes)-1,&count,&type);result("receive",err);
    if(!err) {result("type",type);result("bytes",count);bytes[count]=0;
      valid = type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE && strstr(bytes,"ConnectionId") != NULL;
      flag("hasConnectionId",valid);
      if(type==WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
        USHORT close=0;DWORD reasonlen=0;
        err=WinHttpWebSocketQueryCloseStatus(ws,&close,bytes,sizeof(bytes)-1,&reasonlen);
        result("close_query",err);result("close_code",close);result("reason_bytes",reasonlen);
      } else {
        unsigned nums[4]={0};int n=sscanf(bytes,"[%u,%u,%u,%u",nums,nums+1,nums+2,nums+3);
        for(int i=0;i<n;i++) result("array_number",nums[i]);
      }
    }
    WinHttpWebSocketClose(ws,1000,NULL,0);WinHttpCloseHandle(ws);WinHttpCloseHandle(connect);WinHttpCloseHandle(session);
    IXUserImpl_XUserCloseHandle(users, user);
    IXThreadingImpl_XTaskQueueCloseHandle(threading, block.queue);
    IXUserImpl_Release(users);
    IXThreadingImpl_Release(threading);
    ExitProcess(valid ? 0 : 1);
}
