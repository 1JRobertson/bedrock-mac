// Offscreen regression for constant-buffer ownership during delayed command encoding.
#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static void check(HRESULT hr,const char* op){if(FAILED(hr)){std::fprintf(stderr,"FAIL %s: %08lx\n",op,(unsigned long)hr);std::exit(1);}}
template<class T> static void release(T*&v){if(v)v->Release();v=nullptr;}
struct Probe {
 ID3D11Device*dev=nullptr;ID3D11DeviceContext*ctx=nullptr;ID3D11ComputeShader*cs=nullptr;
 unsigned checks=0,state_checks=0;
 Probe(){
  D3D_FEATURE_LEVEL level;check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&dev,&level,&ctx),"device");
  const char shader[]="cbuffer Index:register(b0){uint idx;uint salt;}; cbuffer Value:register(b1){uint value;}; RWStructuredBuffer<uint> output:register(u0); [numthreads(1,1,1)] void main(){output[idx]=salt^value;}";
  ID3DBlob*code=nullptr,*errors=nullptr;auto hr=D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"main","cs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors);
  if(errors)std::fwrite(errors->GetBufferPointer(),1,errors->GetBufferSize(),stderr);release(errors);check(hr,"compile");check(dev->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&cs),"shader");release(code);
 }
 ~Probe(){ctx->ClearState();ctx->Flush();release(cs);release(ctx);release(dev);}
 void run(bool deferred,bool restore,bool dynamic,unsigned width){
  constexpr unsigned count=4096;ID3D11DeviceContext*record=ctx;if(deferred)check(dev->CreateDeferredContext(0,&record),"deferred");
  ID3D11Buffer*out=nullptr,*readback=nullptr,*control=nullptr,*value=nullptr;
  D3D11_BUFFER_DESC d{};d.ByteWidth=count*4;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_UNORDERED_ACCESS;d.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;d.StructureByteStride=4;
  check(dev->CreateBuffer(&d,nullptr,&out),"output");ID3D11UnorderedAccessView*uav=nullptr;D3D11_UNORDERED_ACCESS_VIEW_DESC u{};u.ViewDimension=D3D11_UAV_DIMENSION_BUFFER;u.Buffer.NumElements=count;check(dev->CreateUnorderedAccessView(out,&u,&uav),"uav");
  d.Usage=D3D11_USAGE_STAGING;d.BindFlags=0;d.MiscFlags=0;d.StructureByteStride=0;d.CPUAccessFlags=D3D11_CPU_ACCESS_READ;check(dev->CreateBuffer(&d,nullptr,&readback),"readback");
  d={};d.ByteWidth=256;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_CONSTANT_BUFFER;check(dev->CreateBuffer(&d,nullptr,&control),"control");
  record->CSSetShader(cs,nullptr,0);record->CSSetUnorderedAccessViews(0,1,&uav,nullptr);record->CSSetConstantBuffers(0,1,&control);
  std::vector<uint32_t>expected(count),data(width/4);uint32_t index_data[64]{};
  for(unsigned i=0;i<count;i++){
   // Rebinding and dropping the application owner before execution must be safe.
   if(i%16==0){release(value);d.ByteWidth=width;d.Usage=dynamic?D3D11_USAGE_DYNAMIC:D3D11_USAGE_DEFAULT;d.CPUAccessFlags=dynamic?D3D11_CPU_ACCESS_WRITE:0;check(dev->CreateBuffer(&d,nullptr,&value),"value");}
   data[0]=0x6aa50000u+i;index_data[0]=i;index_data[1]=0xa5330000u+i;
   record->UpdateSubresource(control,0,nullptr,index_data,0,0);
   if(dynamic){D3D11_MAPPED_SUBRESOURCE m{};check(record->Map(value,0,D3D11_MAP_WRITE_DISCARD,0,&m),"discard");std::memcpy(m.pData,data.data(),width);record->Unmap(value,0);}else record->UpdateSubresource(value,0,nullptr,data.data(),0,0);
   ID3D11Buffer*bound=i%3?value:nullptr;record->CSSetConstantBuffers(1,1,&bound);record->Dispatch(1,1,1);expected[i]=index_data[1]^(bound?data[0]:0);
  }
  // Clear bindings and drop all application constant-buffer refs before readback/replay.
  record->ClearState();release(value);release(control);
  ID3D11CommandList*list=nullptr;
  if(deferred){
   check(record->FinishCommandList(restore,&list),"finish");
   ID3D11Buffer*sentinel=nullptr;d={};d.ByteWidth=256;d.Usage=D3D11_USAGE_DEFAULT;d.BindFlags=D3D11_BIND_CONSTANT_BUFFER;check(dev->CreateBuffer(&d,nullptr,&sentinel),"sentinel");
   for(unsigned replay=0;replay<2;replay++){
    ctx->CSSetConstantBuffers(1,1,&sentinel);ctx->ExecuteCommandList(list,restore);
    ID3D11Buffer*observed=nullptr;ctx->CSGetConstantBuffers(1,1,&observed);
    if(observed!=(restore?sentinel:nullptr)){std::fprintf(stderr,"FAIL constant binding restoration restore=%d replay=%u\n",restore,replay);std::exit(3);}release(observed);state_checks++;
   }
   ctx->ClearState();release(sentinel);release(list);release(record);
  }
  ctx->CopyResource(readback,out);D3D11_MAPPED_SUBRESOURCE m{};check(ctx->Map(readback,0,D3D11_MAP_READ,0,&m),"map readback");auto actual=static_cast<const uint32_t*>(m.pData);
  for(unsigned i=0;i<count;i++){if(actual[i]!=expected[i]){std::fprintf(stderr,"FAIL deferred=%d restore=%d dynamic=%d width=%u index=%u expected=%08x actual=%08x\n",deferred,restore,dynamic,width,i,expected[i],actual[i]);std::exit(2);}checks++;}ctx->Unmap(readback,0);release(readback);release(uav);release(out);
  std::printf("PASS deferred=%d restore=%d dynamic=%d width=%u: %u readbacks\n",deferred,restore,dynamic,width,count);
 }
};
int main(){Probe p;for(bool deferred:{false,true})for(bool restore:{false,true})for(bool dynamic:{false,true})for(unsigned width:{256u,4112u})p.run(deferred,restore,dynamic,width);std::printf("PASS total readbacks=%u state_checks=%u\n",p.checks,p.state_checks);}
