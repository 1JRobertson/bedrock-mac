#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <cstring>
static void check(HRESULT hr, const char *what) {
  if (FAILED(hr)) { std::fprintf(stderr,"%s: HRESULT=%08lx\n",what,(unsigned long)hr); std::exit(1); }
}
int main(int argc, char **argv) {
  unsigned width=argc>1 ? std::strtoul(argv[1],nullptr,10) : 256;
  bool deferred=argc>2 && std::strcmp(argv[2],"deferred")==0;
  if(width<16 || width>65536 || (width%16)) return 3;
  ID3D11Device *dev; ID3D11DeviceContext *ctx; D3D_FEATURE_LEVEL level;
  check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&dev,&level,&ctx),"device");
  ID3D11Multithread *mt;
  check(ctx->QueryInterface(__uuidof(ID3D11Multithread),reinterpret_cast<void **>(&mt)),"multithread interface");
  mt->SetMultithreadProtected(TRUE); mt->Release();
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
  desc={}; desc.ByteWidth=width; desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
  std::vector<uint32_t> data(width/4); D3D11_SUBRESOURCE_DATA init{}; init.pSysMem=data.data();
  check(dev->CreateBuffer(&desc,&init,&constant),"constant buffer");
  ID3D11Buffer *constant_copy, *constant_readback;
  check(dev->CreateBuffer(&desc,nullptr,&constant_copy),"copy constant buffer");
  desc.Usage=D3D11_USAGE_STAGING; desc.BindFlags=0; desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  check(dev->CreateBuffer(&desc,nullptr,&constant_readback),"constant readback buffer");
  auto verify_constant = [&](ID3D11Buffer *buffer) {
    ctx->CopyResource(constant_readback,buffer);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check(ctx->Map(constant_readback,0,D3D11_MAP_READ,0,&mapped),"constant map");
    if(std::memcmp(mapped.pData,data.data(),width)) { std::fprintf(stderr,"FAIL constant copy width=%u\n",width); std::exit(2); }
    ctx->Unmap(constant_readback,0);
  };
  verify_constant(constant); // Initialization before the first rename.
  ID3D11DeviceContext *record=ctx;
  if(deferred) check(dev->CreateDeferredContext(0,&record),"deferred context");
  for(unsigned round=0;round<8;round++) {
    auto salt=0xa5a5a5a5u+round;
    record->CSSetShader(cs,nullptr,0); record->CSSetUnorderedAccessViews(0,1,&uav,nullptr); record->CSSetConstantBuffers(0,1,&constant);
    for(unsigned i=0;i<count;i++) {
      data[0]=i; data[1]=salt;
      record->UpdateSubresource(constant,0,nullptr,data.data(),0,0);
      record->Dispatch(1,1,1);
    }
    if(deferred) {
      ID3D11CommandList *list; check(record->FinishCommandList(FALSE,&list),"finish command list");
      ctx->ExecuteCommandList(list,FALSE);
      // Immediate updates must not overwrite allocations retained by a command list.
      std::vector<uint32_t> temporary(width/4, 0x12345678u);
      for(unsigned reuse=0;reuse<40;reuse++)
        ctx->UpdateSubresource(constant,0,nullptr,temporary.data(),0,0);
      // Replaying must retain each update's original suballocation.
      ctx->ExecuteCommandList(list,FALSE);
      list->Release();
    }
    ctx->CopyResource(readback,output);
    D3D11_MAPPED_SUBRESOURCE mapped{}; check(ctx->Map(readback,0,D3D11_MAP_READ,0,&mapped),"readback map");
    auto values=static_cast<const uint32_t*>(mapped.pData);
    for(unsigned i=0;i<count;i++) if(values[i]!=(i^salt)) { std::fprintf(stderr,"FAIL round=%u index=%u actual=%08x expected=%08x\n",round,i,values[i],i^salt); return 2; }
    ctx->Unmap(readback,0);
    verify_constant(constant);
    // Copy both from and to nonzero suballocation offsets.
    for(unsigned repeat=0;repeat<3;repeat++)
      ctx->UpdateSubresource(constant_copy,0,nullptr,data.data(),0,0);
    ctx->CopyResource(constant_copy,constant);
    verify_constant(constant_copy);
  }
  if(deferred) record->Release();
  ctx->ClearState();ctx->Flush(); constant_copy->Release();constant_readback->Release();constant->Release();readback->Release();uav->Release();output->Release();cs->Release();ctx->Release();dev->Release();
  std::printf("PASS width=%u deferred=%d: 32768 updates, GPU readback and allocation reuse\n",width,int(deferred));
}
