// GPU correctness probe for skipping redundant IASetInputLayout invalidation.
// Offscreen only: compare exact RGBA pixels, including deferred state restoration.
#include <d3d11.h>
#include <d3dcompiler.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void check(HRESULT hr, const char *operation) {
  if (FAILED(hr)) {
    std::fprintf(stderr, "{\"result\":\"fail\",\"operation\":\"%s\",\"hresult\":\"%08lx\"}\n",
                 operation, static_cast<unsigned long>(hr));
    std::exit(1);
  }
}

template <typename T> static void release(T *&object) {
  if (object) object->Release();
  object = nullptr;
}

struct Probe {
  static constexpr unsigned width = 8, height = 8;
  static constexpr std::uint32_t red = 0xff0000ffu, green = 0xff00ff00u, blue = 0xffff0000u;
  ID3D11Device *device = nullptr;
  ID3D11DeviceContext *immediate = nullptr, *deferred = nullptr;
  ID3D11Texture2D *target = nullptr, *readback = nullptr;
  ID3D11Texture2D *alternate = nullptr, *alternate_readback = nullptr;
  ID3D11Texture2D *depth = nullptr, *depth_readback = nullptr;
  ID3D11RenderTargetView *rtv = nullptr, *alternate_rtv = nullptr;
  ID3D11DepthStencilView *dsv = nullptr;
  ID3D11VertexShader *color_vs = nullptr, *vertex_id_vs = nullptr;
  ID3D11VertexShader *swapped_vs = nullptr, *point_vs = nullptr;
  ID3D11PixelShader *ps = nullptr, *swapped_ps = nullptr;
  ID3D11RasterizerState *rasterizer = nullptr;
  ID3D11BlendState *preserve_destination = nullptr;
  ID3D11DepthStencilState *write_depth = nullptr;
  ID3D11InputLayout *red_layout = nullptr, *green_layout = nullptr;
  ID3D11Buffer *vertices = nullptr;
  unsigned pixel_checks = 0, layout_checks = 0;

  static ID3DBlob *compile(const char *source, const char *entry, const char *profile) {
    ID3DBlob *code = nullptr, *errors = nullptr;
    HRESULT hr = D3DCompile(source, std::strlen(source), nullptr, nullptr, nullptr, entry, profile,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
    if (FAILED(hr) && errors)
      std::fwrite(errors->GetBufferPointer(), 1, errors->GetBufferSize(), stderr);
    release(errors);
    check(hr, "compile_shader");
    return code;
  }

  Probe() {
    D3D_FEATURE_LEVEL level;
    check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                           D3D11_SDK_VERSION, &device, &level, &immediate), "create_device");
    check(device->CreateDeferredContext(0, &deferred), "create_deferred_context");
    const char shader[] =
        "struct V { float4 position:SV_Position; float4 color:COLOR0; };"
        "float4 position(uint id) {"
        " return float4(id==2?3.0:-1.0, id==1?3.0:-1.0, 0.0, 1.0); }"
        "V color_main(float4 color:COLOR0, uint id:SV_VertexID) {"
        " V v; v.position=position(id); v.color=color; return v; }"
        "V id_main(uint id:SV_VertexID) {"
        " V v; v.position=position(id); v.color=float4(0,0,1,1); return v; }"
        "V swapped_main(float4 color:COLOR0, uint id:SV_VertexID) {"
        " V v; v.position=position(id); v.color=color.grba; return v; }"
        "V point_main(float4 color:COLOR0) {"
        " V v; v.position=float4(0,0,0,1); v.color=color; return v; }"
        "float4 pixel_main(V v):SV_Target { return v.color; }"
        "float4 swapped_pixel(V v):SV_Target { return v.color.grba; }";
    ID3DBlob *code = compile(shader, "color_main", "vs_5_0");
    check(device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &color_vs),
          "create_color_vertex_shader");
    D3D11_INPUT_ELEMENT_DESC element = {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0,
                                        D3D11_INPUT_PER_VERTEX_DATA, 0};
    check(device->CreateInputLayout(&element, 1, code->GetBufferPointer(), code->GetBufferSize(), &red_layout),
          "create_red_layout");
    element.AlignedByteOffset = 16;
    check(device->CreateInputLayout(&element, 1, code->GetBufferPointer(), code->GetBufferSize(), &green_layout),
          "create_green_layout");
    release(code);
    code = compile(shader, "id_main", "vs_5_0");
    check(device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &vertex_id_vs),
          "create_vertex_id_shader");
    release(code);
    code = compile(shader, "pixel_main", "ps_5_0");
    check(device->CreatePixelShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &ps),
          "create_pixel_shader");
    release(code);
    code = compile(shader, "swapped_pixel", "ps_5_0");
    check(device->CreatePixelShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &swapped_ps),
          "create_swapped_pixel_shader");
    release(code);
    code = compile(shader, "swapped_main", "vs_5_0");
    check(device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &swapped_vs),
          "create_swapped_vertex_shader");
    release(code);
    code = compile(shader, "point_main", "vs_5_0");
    check(device->CreateVertexShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &point_vs),
          "create_point_vertex_shader");
    release(code);
    // The SAME buffer/stride/shader produces red or green solely through layout offset.
    const float data[3][8] = {{1, 0, 0, 1, 0, 1, 0, 1},
                              {1, 0, 0, 1, 0, 1, 0, 1},
                              {1, 0, 0, 1, 0, 1, 0, 1}};
    D3D11_BUFFER_DESC buffer{};
    buffer.ByteWidth = sizeof(data);
    buffer.Usage = D3D11_USAGE_IMMUTABLE;
    buffer.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA initial{};
    initial.pSysMem = data;
    check(device->CreateBuffer(&buffer, &initial, &vertices), "create_vertex_buffer");
    D3D11_TEXTURE2D_DESC texture{};
    texture.Width = width;
    texture.Height = height;
    texture.MipLevels = texture.ArraySize = texture.SampleDesc.Count = 1;
    texture.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    texture.Usage = D3D11_USAGE_DEFAULT;
    texture.BindFlags = D3D11_BIND_RENDER_TARGET;
    check(device->CreateTexture2D(&texture, nullptr, &target), "create_target");
    check(device->CreateRenderTargetView(target, nullptr, &rtv), "create_target_view");
    texture.Usage = D3D11_USAGE_STAGING;
    texture.BindFlags = 0;
    texture.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    check(device->CreateTexture2D(&texture, nullptr, &readback), "create_readback");
    texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    check(device->CreateTexture2D(&texture, nullptr, &alternate_readback), "create_alternate_readback");
    texture.Usage = D3D11_USAGE_DEFAULT;
    texture.CPUAccessFlags = 0;
    texture.BindFlags = D3D11_BIND_RENDER_TARGET;
    check(device->CreateTexture2D(&texture, nullptr, &alternate), "create_alternate_target");
    check(device->CreateRenderTargetView(alternate, nullptr, &alternate_rtv), "create_alternate_view");
    texture.Format = DXGI_FORMAT_D32_FLOAT;
    texture.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    check(device->CreateTexture2D(&texture, nullptr, &depth), "create_depth_target");
    check(device->CreateDepthStencilView(depth, nullptr, &dsv), "create_depth_view");
    texture.Usage = D3D11_USAGE_STAGING;
    texture.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    texture.BindFlags = 0;
    check(device->CreateTexture2D(&texture, nullptr, &depth_readback), "create_depth_readback");
    D3D11_RASTERIZER_DESC raster{};
    raster.FillMode = D3D11_FILL_SOLID;
    raster.CullMode = D3D11_CULL_NONE;
    raster.DepthClipEnable = TRUE;
    check(device->CreateRasterizerState(&raster, &rasterizer), "create_rasterizer");
    D3D11_BLEND_DESC blend{};
    auto &b = blend.RenderTarget[0];
    b.BlendEnable = TRUE;
    b.SrcBlend = b.SrcBlendAlpha = D3D11_BLEND_ZERO;
    b.DestBlend = b.DestBlendAlpha = D3D11_BLEND_ONE;
    b.BlendOp = b.BlendOpAlpha = D3D11_BLEND_OP_ADD;
    b.RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    check(device->CreateBlendState(&blend, &preserve_destination), "create_blend_state");
    D3D11_DEPTH_STENCIL_DESC ds{};
    ds.DepthEnable = TRUE;
    ds.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    ds.DepthFunc = D3D11_COMPARISON_LESS;
    ds.FrontFace.StencilFailOp = ds.FrontFace.StencilDepthFailOp = ds.FrontFace.StencilPassOp = D3D11_STENCIL_OP_KEEP;
    ds.FrontFace.StencilFunc = D3D11_COMPARISON_ALWAYS;
    ds.BackFace = ds.FrontFace;
    check(device->CreateDepthStencilState(&ds, &write_depth), "create_depth_state");
  }

  ~Probe() {
    deferred->ClearState();
    immediate->ClearState();
    immediate->Flush();
    release(vertices); release(green_layout); release(red_layout); release(rasterizer);
    release(preserve_destination); release(write_depth); release(swapped_ps); release(swapped_vs); release(point_vs);
    release(dsv); release(depth_readback); release(depth); release(alternate_rtv);
    release(alternate_readback); release(alternate);
    release(ps); release(vertex_id_vs); release(color_vs); release(rtv);
    release(readback); release(target); release(deferred); release(immediate); release(device);
  }

  // Deliberately does not bind a layout, so restoration/rebinding bugs stay visible.
  void bind(ID3D11DeviceContext *context, bool vertex_id = false) {
    D3D11_VIEWPORT viewport = {0, 0, float(width), float(height), 0, 1};
    const UINT stride = 32, offset = 0;
    context->OMSetRenderTargets(1, &rtv, nullptr);
    context->RSSetViewports(1, &viewport);
    context->RSSetState(rasterizer);
    context->VSSetShader(vertex_id ? vertex_id_vs : color_vs, nullptr, 0);
    context->PSSetShader(ps, nullptr, 0);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->IASetVertexBuffers(0, 1, &vertices, &stride, &offset);
  }

  void clear(ID3D11DeviceContext *context) {
    const float black[4] = {0, 0, 0, 0};
    context->ClearRenderTargetView(rtv, black);
  }

  void layout_is(ID3D11DeviceContext *context, ID3D11InputLayout *expected, const char *phase) {
    ID3D11InputLayout *actual = nullptr;
    context->IAGetInputLayout(&actual);
    const bool equal = actual == expected;
    release(actual);
    if (!equal) {
      std::fprintf(stderr, "{\"result\":\"fail\",\"layout_phase\":\"%s\"}\n", phase);
      std::exit(2);
    }
    ++layout_checks;
  }

  void pixels(std::uint32_t expected, const char *phase, ID3D11Texture2D *source = nullptr,
              ID3D11Texture2D *staging = nullptr, unsigned expected_count = width * height) {
    if (!source) source = target;
    if (!staging) staging = readback;
    immediate->CopyResource(staging, source);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check(immediate->Map(staging, 0, D3D11_MAP_READ, 0, &mapped), "map_readback");
    unsigned count = 0;
    for (unsigned y = 0; y < height; ++y) {
      auto row = reinterpret_cast<const std::uint32_t *>(static_cast<const unsigned char *>(mapped.pData)
                                                        + y * mapped.RowPitch);
      for (unsigned x = 0; x < width; ++x) {
        if (row[x] == expected) ++count;
        else if (expected_count == width * height || row[x] != 0) {
          std::fprintf(stderr, "{\"result\":\"fail\",\"pixel_phase\":\"%s\",\"x\":%u,\"y\":%u,"
                               "\"actual\":\"%08x\",\"expected\":\"%08x\"}\n",
                       phase, x, y, row[x], expected);
          std::exit(2);
        }
      }
    }
    immediate->Unmap(staging, 0);
    if (count != expected_count) {
      std::fprintf(stderr, "{\"result\":\"fail\",\"pixel_phase\":\"%s\",\"matched_pixels\":%u,"
                           "\"expected_pixels\":%u}\n", phase, count, expected_count);
      std::exit(2);
    }
    ++pixel_checks;
  }

  void rebind_same_and_draw(unsigned vertices_to_draw = 3) {
    immediate->IASetInputLayout(red_layout);
    immediate->Draw(vertices_to_draw, 0);
  }

  void other_pipeline_state_changes() {
    repeated_draw(immediate, red_layout);
    immediate->PSSetShader(swapped_ps, nullptr, 0);
    rebind_same_and_draw();
    pixels(green, "same_layout_changed_pixel_shader");
    immediate->PSSetShader(ps, nullptr, 0);
    immediate->VSSetShader(swapped_vs, nullptr, 0);
    rebind_same_and_draw();
    pixels(green, "same_layout_changed_vertex_shader");
    immediate->VSSetShader(color_vs, nullptr, 0);
    rebind_same_and_draw();
    pixels(red, "same_layout_restored_shaders");

    immediate->OMSetRenderTargets(1, &alternate_rtv, nullptr);
    const float black[4] = {0, 0, 0, 0};
    immediate->ClearRenderTargetView(alternate_rtv, black);
    rebind_same_and_draw();
    // BGRA's bytes for red equal RGBA's bytes for blue. Formats differ intentionally.
    pixels(blue, "same_layout_changed_target_format", alternate, alternate_readback);
    immediate->OMSetRenderTargets(1, &rtv, nullptr);
    rebind_same_and_draw();
    pixels(red, "same_layout_restored_target");

    const float blue_clear[4] = {0, 0, 1, 1};
    immediate->ClearRenderTargetView(rtv, blue_clear);
    immediate->OMSetBlendState(preserve_destination, nullptr, 0xffffffffu);
    rebind_same_and_draw();
    pixels(blue, "same_layout_changed_blend");
    immediate->OMSetBlendState(nullptr, nullptr, 0xffffffffu);
    rebind_same_and_draw();
    pixels(red, "same_layout_restored_blend");
    clear(immediate);
    immediate->OMSetBlendState(nullptr, nullptr, 0);
    rebind_same_and_draw();
    pixels(0, "same_layout_zero_sample_mask");
    immediate->OMSetBlendState(nullptr, nullptr, 0xffffffffu);
    rebind_same_and_draw();
    pixels(red, "same_layout_restored_sample_mask");

    immediate->VSSetShader(point_vs, nullptr, 0);
    clear(immediate);
    // One vertex is an incomplete triangle and must draw nothing.
    rebind_same_and_draw(1);
    pixels(0, "triangle_topology_one_vertex");
    immediate->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);
    rebind_same_and_draw(1);
    pixels(red, "same_layout_changed_point_topology", nullptr, nullptr, 1);
    immediate->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    immediate->VSSetShader(color_vs, nullptr, 0);

    immediate->OMSetRenderTargets(1, &rtv, dsv);
    immediate->OMSetDepthStencilState(write_depth, 0);
    immediate->ClearDepthStencilView(dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    clear(immediate);
    rebind_same_and_draw();
    pixels(red, "same_layout_added_depth_target_with_pixel_shader");

    // Null PS is the excluded depth-only path. Read the actual depth writes, then
    // switch back to ordinary color rendering with exactly the same layout object.
    immediate->OMSetRenderTargets(0, nullptr, dsv);
    immediate->OMSetDepthStencilState(write_depth, 0);
    immediate->ClearDepthStencilView(dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    immediate->PSSetShader(nullptr, nullptr, 0);
    rebind_same_and_draw();
    rebind_same_and_draw();
    immediate->OMSetRenderTargets(0, nullptr, nullptr);
    pixels(0, "null_pixel_shader_depth_only", depth, depth_readback); // Float +0.0 bits.
    bind(immediate);
    immediate->OMSetDepthStencilState(nullptr, 0);
    clear(immediate);
    rebind_same_and_draw();
    pixels(red, "same_layout_return_from_depth_only");
  }

  void repeated_draw(ID3D11DeviceContext *context, ID3D11InputLayout *layout, bool vertex_id = false) {
    bind(context, vertex_id);
    clear(context);
    for (unsigned i = 0; i < 32; ++i) {
      context->IASetInputLayout(layout);
      context->Draw(3, 0);
    }
  }

  void run() {
    repeated_draw(immediate, red_layout);
    pixels(red, "immediate_repeated_red");
    // Change only the layout: reusing the old pipeline would produce the wrong color.
    for (unsigned i = 0; i < 6; ++i) {
      immediate->IASetInputLayout((i & 1) ? red_layout : green_layout);
      immediate->Draw(3, 0);
      pixels((i & 1) ? red : green, "immediate_alternating_offsets");
    }
    repeated_draw(immediate, nullptr, true);
    pixels(blue, "immediate_repeated_null_vertex_id");
    immediate->ClearState();
    layout_is(immediate, nullptr, "immediate_clear_state");
    repeated_draw(immediate, red_layout);
    pixels(red, "immediate_rebind_after_clear");
    other_pipeline_state_changes();

    // Keep red state on the immediate context while the list draws green.
    repeated_draw(deferred, red_layout);
    deferred->IASetInputLayout(green_layout);
    deferred->Draw(3, 0);
    ID3D11CommandList *list = nullptr;
    check(deferred->FinishCommandList(TRUE, &list), "finish_restore_deferred_true");
    layout_is(deferred, green_layout, "finish_true_preserves_deferred");
    for (unsigned replay = 0; replay < 2; ++replay) {
      immediate->ExecuteCommandList(list, TRUE);
      pixels(green, "execute_true_green_replay");
      layout_is(immediate, red_layout, "execute_true_preserves_immediate");
      // No rebind: this draw must use the immediate context's restored red layout.
      clear(immediate);
      immediate->Draw(3, 0);
      pixels(red, "draw_using_restored_immediate_state");
    }
    release(list);

    // Deferred state survived Finish(TRUE). Rebinding that SAME pointer must still
    // produce a self-contained second command list with correct initial state.
    repeated_draw(deferred, green_layout);
    check(deferred->FinishCommandList(FALSE, &list), "finish_restore_deferred_false");
    layout_is(deferred, nullptr, "finish_false_clears_deferred");
    immediate->ExecuteCommandList(list, FALSE);
    pixels(green, "second_list_repeated_preserved_layout");
    layout_is(immediate, nullptr, "execute_false_clears_immediate");
    release(list);

    deferred->ClearState();
    repeated_draw(deferred, nullptr, true);
    check(deferred->FinishCommandList(TRUE, &list), "finish_deferred_null");
    repeated_draw(immediate, green_layout);
    immediate->ExecuteCommandList(list, TRUE);
    pixels(blue, "deferred_null_to_null_vertex_id");
    layout_is(immediate, green_layout, "null_list_restores_nonnull_layout");
    immediate->Draw(3, 0);
    pixels(green, "draw_after_null_list_restore");
    release(list);

    deferred->ClearState();
    repeated_draw(deferred, red_layout);
    check(deferred->FinishCommandList(FALSE, &list), "finish_deferred_rebind");
    immediate->ExecuteCommandList(list, FALSE);
    pixels(red, "deferred_rebind_after_clear");
    release(list);
    std::printf("{\"result\":\"pass\",\"pixel_checks\":%u,\"pixels_per_check\":%u,"
                 "\"layout_state_checks\":%u,\"immediate\":true,\"deferred\":true,\"replay\":true}\n",
                pixel_checks, width * height, layout_checks);
  }
};

int main() {
  Probe probe;
  probe.run();
}
