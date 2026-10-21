#define COBJMACROS
#include <windows.h>
#include <d3d11.h>

typedef HRESULT (WINAPI *CreateDeviceFn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
static void result(const char *label, unsigned int n) {
    char s[] = "0x00000000\r\n";
    DWORD len = 0, written;
    while (label[len]) len++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), label, len, &written, NULL);
    for (int i = 0; i < 8; i++) s[9-i] = "0123456789ABCDEF"[(n >> (i*4)) & 15];
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, sizeof(s)-1, &written, NULL);
}
void mainCRTStartup(void) {
    HMODULE module = LoadLibraryW(L"d3d11.dll");
    if (!module) { result("LoadD3D11=", GetLastError()); ExitProcess(1); }
    CreateDeviceFn create = (CreateDeviceFn)GetProcAddress(module, "D3D11CreateDevice");
    if (!create) { result("ResolveD3D11=", GetLastError()); ExitProcess(1); }
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL requested[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL actual = 0;
    HRESULT hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, requested, 1,
        D3D11_SDK_VERSION, &device, &actual, &context);
    result("D3D11CreateDevice=", hr);
    result("FeatureLevel=", actual);
    if (context) ID3D11DeviceContext_Release(context);
    if (device) ID3D11Device_Release(device);
    ExitProcess(FAILED(hr));
}
