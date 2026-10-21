/* Hardware GPU readback and hidden-window swapchain check; creates no visible window. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>

typedef HRESULT (WINAPI *CreateDeviceFn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT, const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **,
    ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

static void result(const char *label, unsigned int value) {
    char digits[] = "0x00000000\r\n";
    DWORD length = 0, written;
    while (label[length]) length++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), label, length, &written, NULL);
    for (int i = 0; i < 8; i++) digits[9-i] = "0123456789ABCDEF"[(value >> (i*4)) & 15];
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), digits, sizeof(digits)-1, &written, NULL);
}

static DWORD WINAPI watchdog(void *unused) { Sleep(45000); ExitProcess(124); return 0; }

void mainCRTStartup(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    HMODULE module = LoadLibraryW(L"d3d11.dll");
    CreateDeviceFn create = module ? (CreateDeviceFn)GetProcAddress(module, "D3D11CreateDeviceAndSwapChain") : NULL;
    if (!create) { result("LoadD3D11=", GetLastError()); ExitProcess(1); }
    HWND window = CreateWindowExW(0, L"STATIC", L"Standalone graphics probe", WS_OVERLAPPEDWINDOW,
        0, 0, 64, 64, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!window) { result("CreateHiddenWindow=", GetLastError()); ExitProcess(1); }
    DXGI_SWAP_CHAIN_DESC swap = {0};
    swap.BufferDesc.Width = 64;
    swap.BufferDesc.Height = 64;
    swap.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap.SampleDesc.Count = 1;
    swap.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap.BufferCount = 2;
    swap.OutputWindow = window;
    swap.Windowed = TRUE;
    swap.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    IDXGISwapChain *chain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_0}, actual = 0;
    HRESULT hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, requested, 1,
        D3D11_SDK_VERSION, &swap, &chain, &device, &actual, &context);
    result("HardwareDeviceAndSwapChain=", hr);
    result("FeatureLevel=", actual);
    if (FAILED(hr)) { DestroyWindow(window); ExitProcess(1); }

    D3D11_TEXTURE2D_DESC desc = {0};
    desc.Width = 4; desc.Height = 4; desc.MipLevels = 1; desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *gpu = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &gpu);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)gpu, NULL, &view);
    if (SUCCEEDED(hr)) {
        float red[4] = {1.f, 0.f, 0.f, 1.f};
        ID3D11DeviceContext_ClearRenderTargetView(context, view, red);
        desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    }
    unsigned int pixel = 0;
    if (SUCCEEDED(hr)) {
        D3D11_MAPPED_SUBRESOURCE mapped;
        ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)gpu);
        hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(hr)) {
            pixel = *(unsigned int *)mapped.pData;
            ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
        }
    }
    result("GPUReadback=", hr);
    result("RedPixel=", pixel);
    HRESULT present = IDXGISwapChain_Present(chain, 0, 0);
    result("HiddenPresent=", present);
    /* Optional bounded soak for diagnosing per-frame host allocation growth. */
    char stress_text[12];
    UINT stress = 0;
    DWORD stress_length = GetEnvironmentVariableA("BEDROCK_GRAPHICS_STRESS_FRAMES", stress_text, sizeof(stress_text));
    if (stress_length > 0 && stress_length < sizeof(stress_text)) {
        for (DWORD i = 0; i < stress_length; i++) {
            if (stress_text[i] < '0' || stress_text[i] > '9') { stress = 0; break; }
            stress = stress * 10 + stress_text[i] - '0';
            if (stress > 1200) { stress = 1200; break; }
        }
    }
    if (stress) {
        typedef UINT64 (WINAPI *PoolCreateFn)(void);
        typedef void (WINAPI *PoolReleaseFn)(UINT64);
        PoolCreateFn pool_create = NULL; PoolReleaseFn pool_release = NULL;
        if (GetEnvironmentVariableA("BEDROCK_GRAPHICS_STRESS_AUTORELEASEPOOL", stress_text, sizeof(stress_text))) {
            HMODULE metal = GetModuleHandleW(L"winemetal.dll");
            pool_create = (PoolCreateFn)GetProcAddress(metal, "NSAutoreleasePool_alloc_init");
            pool_release = (PoolReleaseFn)GetProcAddress(metal, "NSObject_release");
            if (!pool_create || !pool_release) { result("StressPoolUnavailable=", E_NOTIMPL); ExitProcess(1); }
        }
        result("StressStart=", 0);
        Sleep(1000);
        for (UINT i = 0; i < stress && SUCCEEDED(present); i++) {
            UINT64 pool = pool_create ? pool_create() : 0;
            float red[4] = {1.f, 0.f, 0.f, 1.f};
            ID3D11DeviceContext_ClearRenderTargetView(context, view, red);
            present = IDXGISwapChain_Present(chain, 0, 0);
            if (pool) pool_release(pool);
            if ((i+1) % 300 == 0) { result("StressFrames=", i+1); Sleep(1000); }
        }
        result("StressPresent=", present);
    }
    if (view) ID3D11RenderTargetView_Release(view);
    if (staging) ID3D11Texture2D_Release(staging);
    if (gpu) ID3D11Texture2D_Release(gpu);
    IDXGISwapChain_Release(chain);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    DestroyWindow(window);
    ExitProcess(FAILED(hr) || pixel != 0xff0000ff || FAILED(present));
}
