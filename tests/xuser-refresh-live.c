/* Isolated token-refresh regression probe. Never print credentials or account IDs. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <xasyncprovider.h>
#include <xuser.h>
#include <winstring.h>
#include <time.h>
#include "XUserTestState.h"

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

static BOOL privilege(IXUserImpl *users, XUserHandle user, XUserPrivilege requested, const char *name)
{
    BOOLEAN allowed = FALSE;
    XUserPrivilegeDenyReason reason = XUserPrivilegeDenyReason_Unknown;
    HRESULT hr = IXUserImpl_XUserCheckPrivilege(users, user, XUserPrivilegeOptions_None, requested, &allowed, &reason);
    out(name); result(".status", hr);
    out(name); flag(".available", SUCCEEDED(hr));
    out(name); flag(".allowed", SUCCEEDED(hr) && allowed);
    out(name); result(".deny_reason", (HRESULT)reason);
    /* An authentic denial is a valid implemented result. */
    return SUCCEEDED(hr) && (!allowed || reason == XUserPrivilegeDenyReason_None);
}

static BOOL token_shape(IXUserImpl *users, IXThreadingImpl *threading, XUserHandle user, const char *name, const char *url, XUserGetTokenAndSignatureOptions options)
{
    XUserGetTokenAndSignatureData *data = NULL;
    SIZE_T size = 0, used = 0;
    void *buffer = NULL;
    BOOL valid = FALSE;
    HRESULT hr = IXUserImpl_XUserGetTokenAndSignatureAsync(users, user, options,
        "GET", url, 0, NULL, 0, NULL, &block);
    if (SUCCEEDED(hr)) hr = await_status(threading);
    out(name); result(".async_status", hr);
    if (FAILED(hr)) return FALSE;
    hr = IXUserImpl_XUserGetTokenAndSignatureResultSize(users, &block, &size);
    if (SUCCEEDED(hr) && (size < sizeof(*data) || size > 1024 * 1024)) hr = E_UNEXPECTED;
    out(name); result(".size_status", hr);
    if (FAILED(hr)) return FALSE;
    buffer = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (!buffer) return FALSE;
    hr = IXUserImpl_XUserGetTokenAndSignatureResult(users, &block, size, buffer, &data, &used);
    out(name); result(".result_status", hr);
    if (SUCCEEDED(hr) && data == buffer && used <= size)
    {
        ULONG_PTR first = (ULONG_PTR)buffer, end = first + size;
        ULONG_PTR token = (ULONG_PTR)data->token, signature = (ULONG_PTR)data->signature;
        valid = data->tokenSize > 0 && data->signatureSize == 104 && token >= first && token < end &&
            signature >= first && signature < end && data->tokenSize < end-token && data->signatureSize < end-signature;
    }
    out(name); flag(".valid_shape", valid);
    SecureZeroMemory(buffer, size);
    HeapFree(GetProcessHeap(), 0, buffer);
    return valid;
}

static BOOL token_utf16_force(IXUserImpl *users, IXThreadingImpl *threading, XUserHandle user)
{
    XUserGetTokenAndSignatureUtf16Data *data = NULL;
    XUserGetTokenAndSignatureUtf16HttpHeader header = {L"Accept", L"application/json"};
    SIZE_T size = 0, used = 0;
    void *buffer;
    BOOL valid = FALSE;
    HRESULT hr = IXUserImpl_XUserGetTokenAndSignatureUtf16Async(users, user,
        XUserGetTokenAndSignatureOptions_ForceRefresh, L"GET",
        L"https://profile.xboxlive.com/users/me/profile/settings", 1, &header, 0, NULL, &block);
    if (SUCCEEDED(hr)) hr = await_status(threading);
    result("utf16_forced.async_status", hr);
    if (FAILED(hr)) return FALSE;
    hr = IXUserImpl_XUserGetTokenAndSignatureUtf16ResultSize(users, &block, &size);
    if (FAILED(hr) || size < sizeof(*data) || size > 1024 * 1024) return FALSE;
    buffer = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (!buffer) return FALSE;
    hr = IXUserImpl_XUserGetTokenAndSignatureUtf16Result(users, &block, size, buffer, &data, &used);
    result("utf16_forced.result_status", hr);
    if (SUCCEEDED(hr) && data == buffer && used <= size)
    {
        ULONG_PTR first = (ULONG_PTR)buffer, end = first + size;
        ULONG_PTR token = (ULONG_PTR)data->token, signature = (ULONG_PTR)data->signature;
        valid = data->tokenCount > 0 && data->signatureCount == 104 && token >= first && token < end &&
            signature >= first && signature < end && data->tokenCount < (end-token)/sizeof(WCHAR) &&
            data->signatureCount < (end-signature)/sizeof(WCHAR);
    }
    flag("utf16_forced.valid_shape", valid);
    SecureZeroMemory(buffer, size);
    HeapFree(GetProcessHeap(), 0, buffer);
    return valid;
}

void mainCRTStartup(void)
{
    IXThreadingImpl *threading = NULL;
    IXUserImpl *users = NULL;
    XUserHandle user = NULL;
    XUserAgeGroup age = XUserAgeGroup_Unknown;
    HMODULE runtime;
    InitializeFn initialize;
    QueryFn query;
    HRESULT hr;
    BOOL valid = TRUE;
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
    /* The generated layout comes from the same private source as the candidate
     * DLL. Only this probe's own user is modified, and only by expiring caches
     * sooner. Every replacement token/claim still comes from the real service. */
    {
        struct XUserTestState *state = (struct XUserTestState *)user;
        const char *xbox = "https://profile.xboxlive.com/users/me/profile/settings";
        const char *realms = "https://bedrock.frontendlegacy.realms.minecraft-services.net/worlds";
        HSTRING before;
        FILETIME time;
        ULONGLONG now;
        GetSystemTimeAsFileTime(&time);
        now = ((ULONGLONG)time.dwHighDateTime << 32) | time.dwLowDateTime;
        flag("initial_user_token_unexpired", state->userTokenExpiry > now);
        flag("initial_xsts_unexpired", state->xstsExpiry > now);
        valid &= state->usesXodus && state->userTokenExpiry > now && state->xstsExpiry > now;
        if (!valid) ExitProcess(1); /* Reject a mismatched layout before any write. */

        before = state->xstsToken;
        valid &= token_shape(users, threading, user, "cached", xbox, XUserGetTokenAndSignatureOptions_None);
        flag("cache_hit_reused_token", before == state->xstsToken);
        valid &= before == state->xstsToken;
        valid &= token_shape(users, threading, user, "forced", xbox, XUserGetTokenAndSignatureOptions_ForceRefresh);
        flag("forced_replaced_token", before != state->xstsToken);
        valid &= before != state->xstsToken;
        before = state->xstsToken;
        valid &= token_utf16_force(users, threading, user);
        flag("utf16_forced_replaced_token", before != state->xstsToken);
        valid &= before != state->xstsToken;

        AcquireSRWLockExclusive(&state->xstsLock);
        state->xstsExpiry = 0;
        ReleaseSRWLockExclusive(&state->xstsLock);
        valid &= token_shape(users, threading, user, "expired_xsts", xbox, XUserGetTokenAndSignatureOptions_None);
        flag("expired_xsts_renewed", state->xstsExpiry > now);
        valid &= state->xstsExpiry > now;

        AcquireSRWLockExclusive(&state->xstsLock);
        state->userTokenExpiry = state->xstsExpiry = 0;
        ReleaseSRWLockExclusive(&state->xstsLock);
        valid &= token_shape(users, threading, user, "expired_parent", xbox, XUserGetTokenAndSignatureOptions_None);
        flag("parent_and_xsts_renewed", state->userTokenExpiry > now && state->xstsExpiry > now);
        valid &= state->userTokenExpiry > now && state->xstsExpiry > now;

        valid &= token_shape(users, threading, user, "realms", realms, XUserGetTokenAndSignatureOptions_None);
        AcquireSRWLockExclusive(&state->xstsLock);
        state->xboxClaimsExpiry = 0;
        ReleaseSRWLockExclusive(&state->xstsLock);
        valid &= privilege(users, user, XUserPrivilege_Multiplayer, "expired_privilege");
        flag("expired_policy_renewed", state->xboxClaimsExpiry > now);
        valid &= state->xboxClaimsExpiry > now;

        AcquireSRWLockExclusive(&state->xstsLock);
        state->xboxClaimsExpiry = 0;
        ReleaseSRWLockExclusive(&state->xstsLock);
        hr = IXUserImpl_XUserGetAgeGroup(users, user, &age);
        result("expired_age.status", hr);
        flag("expired_age_available", SUCCEEDED(hr) && age != XUserAgeGroup_Unknown);
        valid &= SUCCEEDED(hr) && age != XUserAgeGroup_Unknown && state->xboxClaimsExpiry > now;
    }
    flag("refresh_checks_passed", valid);
    IXUserImpl_XUserCloseHandle(users, user);
    IXThreadingImpl_XTaskQueueCloseHandle(threading, block.queue);
    IXUserImpl_Release(users);
    IXThreadingImpl_Release(threading);
    ExitProcess(valid ? 0 : 1);
}
