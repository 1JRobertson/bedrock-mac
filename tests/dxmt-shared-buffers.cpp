#include <d3d11.h>
#include <d3dcompiler.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
static void check(HRESULT hr, const char *what) {
  if (FAILED(hr)) { std::fprintf(stderr,"%s: HRESULT=%08lx\n",what,(unsigned long)hr); std::exit(1); }
}
int main(int argc, char **) {
  ID3D11Device *dev; ID3D11DeviceContext *ctx; D3D_FEATURE_LEVEL level;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&dev,&level,&ctx),"device");
  const char shader[]= "cbuffer Data:register(b0){uint idx;uint salt;}; RWStructuredBuffer<uint> output:register(u0); [numthreads(1,1,1)] void main(){output[idx]=idx^salt;}";
  ID3DBlob *code=nullptr,*errors=nullptr;
  auto hr=D3DCompile(shader,sizeof(shader)-1,nullptr,nullptr,nullptr,"main","cs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors);
  if(errors) { std::fwrite(errors->GetBufferPointer(),1,errors->GetBufferSize(),stderr); errors->Release(); }
  check(hr,"shader compile"); ID3D11ComputeShader *cs;
  check(dev->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&cs),"compute shader"); code->Release();
  constexpr unsigned count=4096;
  D3D11_BUFFER_DESC desc{}; desc.ByteWidth=count*4; desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_UNORDERED_ACCESS; desc.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; desc.StructureByteStride=4;
  ID3D11Buffer *output,*readback,*constant;
  uint32_t zero[count]={}; D3D11_SUBRESOURCE_DATA output_init{}; output_init.pSysMem=zero;
  check(dev->CreateBuffer(&desc,argc>1 ? &output_init : nullptr,&output),"output buffer");
  D3D11_UNORDERED_ACCESS_VIEW_DESC uv{}; uv.ViewDimension=D3D11_UAV_DIMENSION_BUFFER; uv.Buffer.NumElements=count;
  ID3D11UnorderedAccessView *uav; check(dev->CreateUnorderedAccessView(output,&uv,&uav),"uav");
  desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ; desc.MiscFlags=0; desc.StructureByteStride=0;
  check(dev->CreateBuffer(&desc,nullptr,&readback),"readback buffer");
  desc={}; desc.ByteWidth=256; desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
  uint32_t data[64]={}; D3D11_SUBRESOURCE_DATA init{}; init.pSysMem=data;
  check(dev->CreateBuffer(&desc,&init,&constant),"constant buffer");
  ctx->CSSetShader(cs,nullptr,0); ctx->CSSetUnorderedAccessViews(0,1,&uav,nullptr); ctx->CSSetConstantBuffers(0,1,&constant);
  for(unsigned round=0;round<8;round++) {
    auto salt=0xa5a5a5a5u+round;
    for(unsigned i=0;i<count;i++) {
      data[0]=i; data[1]=salt;
      ctx->UpdateSubresource(constant,0,nullptr,data,0,0);
      ctx->Dispatch(1,1,1);
    }
    ctx->CopyResource(readback,output);
    D3D11_MAPPED_SUBRESOURCE mapped{}; check(ctx->Map(readback,0,D3D11_MAP_READ,0,&mapped),"readback map");
    auto values=static_cast<const uint32_t*>(mapped.pData);
    for(unsigned i=0;i<count;i++) if(values[i]!=(i^salt)) { std::fprintf(stderr,"FAIL round=%u index=%u actual=%08x expected=%08x\n",round,i,values[i],i^salt); return 2; }
    ctx->Unmap(readback,0);
  }
  ctx->ClearState();ctx->Flush(); constant->Release();readback->Release();uav->Release();output->Release();cs->Release();ctx->Release();dev->Release();
  std::puts("PASS: 32768 queued constant-buffer updates and GPU readbacks, including allocation reuse");
}
