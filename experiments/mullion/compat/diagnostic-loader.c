/* Diagnostic d3d12.dll for the isolated Mullion experiment only.
 * Retry-only mode preserves feature queries. The separate opt-in limited
 * profile changes the aggregate maximum to 12_0 while preserving sparse tier0.
 * Neither mode establishes full FL12_0 conformance or actual game rendering.
 */
#include <windows.h>
#include <d3d12.h>
#include <stdio.h>
#include <string.h>
#include "ray-trace.inc"
#include "level-profile.inc"

static void trace_address(const char *label, DWORD64 address)
{
    HMODULE module = NULL;
    char path[1024] = "unknown";
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                      (const char *)(ULONG_PTR)address, &module);
    if (module) GetModuleFileNameA(module, path, sizeof(path));
    const char *name = strrchr(path, '\\');
    fprintf(stderr, "MULLION TRACE %s: %s+0x%llx (0x%llx)\n", label, name ? name+1 : path,
            (unsigned long long)(address-(ULONG_PTR)module), (unsigned long long)address);
}
static LONG WINAPI trace_exception(EXCEPTION_POINTERS *exception)
{
    static LONG count;
    if (exception->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || InterlockedIncrement(&count)>4)
        return EXCEPTION_CONTINUE_SEARCH;
    typedef PRUNTIME_FUNCTION (WINAPI *Lookup)(DWORD64, DWORD64 *, void *);
    typedef PEXCEPTION_ROUTINE (WINAPI *Unwind)(ULONG, DWORD64, DWORD64, PRUNTIME_FUNCTION,
                                               CONTEXT *, void **, DWORD64 *, void *);
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    Lookup lookup = (Lookup)GetProcAddress(ntdll,"RtlLookupFunctionEntry");
    Unwind unwind = (Unwind)GetProcAddress(ntdll,"RtlVirtualUnwind");
    CONTEXT context = *exception->ContextRecord;
    fprintf(stderr,"MULLION TRACE access violation; thread=%lu\n",GetCurrentThreadId());
    for (unsigned i=0;i<40 && context.Rip;i++) {
        trace_address(i ? "caller" : "fault",context.Rip);
        DWORD64 image=0,frame=0; void *data=NULL;
        PRUNTIME_FUNCTION entry=lookup ? lookup(context.Rip,&image,NULL) : NULL;
        if (entry && unwind) unwind(0,image,context.Rip,entry,&context,&data,&frame,NULL);
        else {
            DWORD64 next=0; SIZE_T read=0;
            if (!ReadProcessMemory(GetCurrentProcess(),(void *)(ULONG_PTR)context.Rsp,&next,8,&read) || read!=8) break;
            context.Rip=next; context.Rsp+=8;
        }
    }
    fflush(stderr);
    return EXCEPTION_CONTINUE_SEARCH;
}

static FARPROC core_function(const char *name)
{
    HMODULE core = GetModuleHandleW(L"d3d12core.dll");
    if (!core) core = LoadLibraryExW(L"d3d12core.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return core ? GetProcAddress(core, name) : NULL;
}
static void diagnostic_notice(void)
{
    static const char message[] = "MULLION DIAGNOSTIC: rejected FL12_0 minimum; retrying FL11_0. Aggregate override requires the separate relaxed profile.\r\n";
    DWORD written;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), message, sizeof(message)-1, &written, NULL);
    OutputDebugStringA(message);
}
HRESULT WINAPI diag_D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID iid, void **device)
{
    typedef HRESULT (WINAPI *Fn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    Fn fn = (Fn)core_function("D3D12CreateDevice");
    if (!fn) return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    HRESULT hr = fn(adapter, level, iid, device);
    if (SUCCEEDED(hr) && device && *device) install_profile(*device);
    fprintf(stderr,"MULLION TRACE CreateDevice minimum=0x%x result=0x%08lx output=%s\n",level,(unsigned long)hr,device?"requested":"query");
    char enabled[2];
    /* Restrict the retry to the observed unsupported-minimum E_INVALIDARG.
     * Memory failures, removed devices, invalid IIDs and other errors propagate.
     * No 12_1 retry: Minecraft's own next attempt asks for 12_0.
     */
    if (level == D3D_FEATURE_LEVEL_12_0 && hr == E_INVALIDARG &&
        GetEnvironmentVariableA("MULLION_DIAGNOSTIC_RETRY_FL12_0", enabled, sizeof(enabled)) == 1 && enabled[0] == '1') {
        diagnostic_notice();
        if (device) *device = NULL;
        hr=fn(adapter, D3D_FEATURE_LEVEL_11_0, iid, device);
        if (SUCCEEDED(hr) && device && *device) install_profile(*device);
        fprintf(stderr,"MULLION TRACE retry result=0x%08lx\n",(unsigned long)hr);
        return hr;
    }
    return hr;
}
HRESULT WINAPI diag_D3D12GetDebugInterface(REFIID iid, void **object)
{
    typedef HRESULT (WINAPI *Fn)(REFIID, void **);
    Fn fn = (Fn)core_function("D3D12GetDebugInterface");
    return fn ? fn(iid, object) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12CreateRootSignatureDeserializer(const void *data, SIZE_T size, REFIID iid, void **object)
{
    typedef HRESULT (WINAPI *Fn)(const void *, SIZE_T, REFIID, void **);
    Fn fn = (Fn)core_function("D3D12CreateRootSignatureDeserializer");
    return fn ? fn(data, size, iid, object) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12CreateVersionedRootSignatureDeserializer(const void *data, SIZE_T size, REFIID iid, void **object)
{
    typedef HRESULT (WINAPI *Fn)(const void *, SIZE_T, REFIID, void **);
    Fn fn = (Fn)core_function("D3D12CreateVersionedRootSignatureDeserializer");
    return fn ? fn(data, size, iid, object) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12SerializeRootSignature(const D3D12_ROOT_SIGNATURE_DESC *desc,
        D3D_ROOT_SIGNATURE_VERSION version, ID3DBlob **blob, ID3DBlob **errors)
{
    typedef HRESULT (WINAPI *Fn)(const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
    Fn fn = (Fn)core_function("D3D12SerializeRootSignature");
    return fn ? fn(desc, version, blob, errors) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12SerializeVersionedRootSignature(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *desc,
        ID3DBlob **blob, ID3DBlob **errors)
{
    typedef HRESULT (WINAPI *Fn)(const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *, ID3DBlob **, ID3DBlob **);
    Fn fn = (Fn)core_function("D3D12SerializeVersionedRootSignature");
    return fn ? fn(desc, blob, errors) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12GetInterface(REFCLSID clsid, REFIID iid, void **object)
{
    typedef HRESULT (WINAPI *Fn)(REFCLSID, REFIID, void **);
    Fn fn = (Fn)core_function("D3D12GetInterface");
    return fn ? fn(clsid, iid, object) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
HRESULT WINAPI diag_D3D12EnableExperimentalFeatures(UINT count, const IID *iids, void *configuration, UINT *sizes)
{
    typedef HRESULT (WINAPI *Fn)(UINT, const IID *, void *, UINT *);
    Fn fn = (Fn)core_function("D3D12EnableExperimentalFeatures");
    return fn ? fn(count, iids, configuration, sizes) : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance; (void)reserved;
    char enabled[2];
    if (reason==DLL_PROCESS_ATTACH && GetEnvironmentVariableA("MULLION_DIAGNOSTIC_TRACE_EXCEPTION",enabled,2)==1 && enabled[0]=='1')
        AddVectoredExceptionHandler(1,trace_exception);
    return TRUE;
}
BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{ return DllMain(instance, reason, reserved); }
