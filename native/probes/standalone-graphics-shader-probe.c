/* Offscreen shader translation, texture sampling, and discard/readback checks. */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
int _fltused;

typedef HRESULT (WINAPI *CreateDeviceFn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *CompileFn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *,
    ID3DInclude *, const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static void report(const char *text, HRESULT code) {
    DWORD n = 0, written;
    char hex[] = "=0x00000000\r\n";
    while (text[n]) n++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, n, &written, NULL);
    for (int i = 0; i < 8; i++) hex[10-i] = "0123456789ABCDEF"[((UINT)code >> (i*4)) & 15];
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), hex, sizeof(hex)-1, &written, NULL);
}
static DWORD WINAPI watchdog(void *unused) { Sleep(45000); ExitProcess(124); return 0; }

static const char source[] =
    "Texture2D image : register(t0); SamplerState nearest : register(s0);"
    "float4 vs(uint id : SV_VertexID) : SV_Position {"
    " if (id == 0) return float4(-1,-1,0,1);"
    " if (id == 1) return float4(-1,3,0,1);"
    " return float4(3,-1,0,1); }"
    "float4 texture_ps(float4 p : SV_Position) : SV_Target {"
    " return image.Sample(nearest, p.xy / 4.0); }"
    "float4 discard_ps(float4 p : SV_Position) : SV_Target {"
    " if (((uint)p.x + (uint)p.y) & 1) discard;"
    " return float4(1,0,0,1); }";

static HRESULT compile(CompileFn compiler, const char *entry, const char *model, ID3DBlob **blob) {
    ID3DBlob *errors = NULL;
    HRESULT hr = compiler(source, sizeof(source)-1, "standalone-probe", NULL, NULL,
        entry, model, 0, 0, blob, &errors);
    if (errors) {
        if (FAILED(hr)) {
            DWORD written;
            WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), ID3D10Blob_GetBufferPointer(errors),
                (DWORD)ID3D10Blob_GetBufferSize(errors), &written, NULL);
        }
        ID3D10Blob_Release(errors);
    }
    return hr;
}

static HRESULT readback(ID3D11DeviceContext *ctx, ID3D11Texture2D *target,
    ID3D11Texture2D *staging, const UINT *expected) {
    D3D11_MAPPED_SUBRESOURCE mapped;
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)target);
    HRESULT hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return hr;
    for (UINT y = 0; y < 4; y++) for (UINT x = 0; x < 4; x++) {
        UINT value = *(UINT *)((BYTE *)mapped.pData + y * mapped.RowPitch + x * 4);
        if (value != expected[y*4+x]) { report("UnexpectedPixel", value); hr = E_FAIL; }
    }
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    return hr;
}

void mainCRTStartup(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    HMODULE d3d = LoadLibraryW(L"d3d11.dll"), compiler = LoadLibraryW(L"d3dcompiler_47.dll");
    CreateDeviceFn create = d3d ? (CreateDeviceFn)GetProcAddress(d3d, "D3D11CreateDevice") : NULL;
    CompileFn compile_fn = compiler ? (CompileFn)GetProcAddress(compiler, "D3DCompile") : NULL;
    if (!create || !compile_fn) { report("LoadGraphicsLibraries", HRESULT_FROM_WIN32(GetLastError())); ExitProcess(1); }
    ID3D11Device *device = NULL; ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, requested, 1,
        D3D11_SDK_VERSION, &device, NULL, &ctx);
    report("HardwareDevice", hr); if (FAILED(hr)) ExitProcess(1);
    ID3DBlob *vs_blob = NULL, *ps_blob = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL, *discard = NULL;
    hr = compile(compile_fn, "vs", "vs_5_0", &vs_blob);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_blob), ID3D10Blob_GetBufferSize(vs_blob), NULL, &vs);
    report("VertexShader", hr); if (FAILED(hr)) ExitProcess(1);
    hr = compile(compile_fn, "texture_ps", "ps_5_0", &ps_blob);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_blob), ID3D10Blob_GetBufferSize(ps_blob), NULL, &ps);
    report("TextureShader", hr); if (FAILED(hr)) ExitProcess(1);
    ID3D10Blob_Release(ps_blob); ps_blob = NULL;
    hr = compile(compile_fn, "discard_ps", "ps_5_0", &ps_blob);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_blob), ID3D10Blob_GetBufferSize(ps_blob), NULL, &discard);
    report("DiscardShader", hr); if (FAILED(hr)) ExitProcess(1);

    UINT colors[16], checker[16];
    for (UINT y = 0; y < 4; y++) for (UINT x = 0; x < 4; x++) {
        colors[y*4+x] = 0xff000000 | ((x*63+33) << 16) | ((y*61+22) << 8) | (x*16+y*9);
        checker[y*4+x] = ((x+y)&1) ? 0xff000000 : 0xff0000ff;
    }
    D3D11_TEXTURE2D_DESC desc = {4,4,1,1,DXGI_FORMAT_R8G8B8A8_UNORM,{1,0},D3D11_USAGE_DEFAULT,D3D11_BIND_RENDER_TARGET,0,0};
    ID3D11Texture2D *target = NULL, *staging = NULL, *texture = NULL;
    ID3D11RenderTargetView *rtv = NULL; ID3D11ShaderResourceView *srv = NULL;
    hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &target);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &rtv);
    desc.BindFlags = 0; desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE; desc.Usage = D3D11_USAGE_IMMUTABLE; desc.CPUAccessFlags = 0;
    D3D11_SUBRESOURCE_DATA initial = {colors,16,0};
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateTexture2D(device, &desc, &initial, &texture);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, NULL, &srv);
    D3D11_SAMPLER_DESC sampling = {0};
    sampling.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sampling.AddressU = sampling.AddressV = sampling.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampling.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11SamplerState *sampler = NULL;
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateSamplerState(device, &sampling, &sampler);
    D3D11_RASTERIZER_DESC raster_desc = {0};
    raster_desc.FillMode = D3D11_FILL_SOLID; raster_desc.CullMode = D3D11_CULL_NONE; raster_desc.DepthClipEnable = TRUE;
    ID3D11RasterizerState *raster = NULL;
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRasterizerState(device, &raster_desc, &raster);
    report("RenderResources", hr); if (FAILED(hr)) ExitProcess(1);

    D3D11_VIEWPORT viewport = {0,0,4,4,0,1}; float black[4] = {0,0,0,1};
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetState(ctx, raster);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &sampler);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, black);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    hr = readback(ctx, target, staging, colors);
    report("ShaderTextureReadback", hr); if (FAILED(hr)) ExitProcess(1);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, black);
    ID3D11DeviceContext_PSSetShader(ctx, discard, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    hr = readback(ctx, target, staging, checker);
    report("ShaderDiscardReadback", hr);
    ID3D11DeviceContext_ClearState(ctx);
    ID3D11RasterizerState_Release(raster); ID3D11SamplerState_Release(sampler);
    ID3D11ShaderResourceView_Release(srv); ID3D11RenderTargetView_Release(rtv);
    ID3D11Texture2D_Release(texture); ID3D11Texture2D_Release(staging); ID3D11Texture2D_Release(target);
    ID3D11PixelShader_Release(discard); ID3D11PixelShader_Release(ps); ID3D11VertexShader_Release(vs);
    ID3D10Blob_Release(ps_blob); ID3D10Blob_Release(vs_blob);
    ID3D11DeviceContext_Release(ctx); ID3D11Device_Release(device);
    ExitProcess(FAILED(hr));
}
