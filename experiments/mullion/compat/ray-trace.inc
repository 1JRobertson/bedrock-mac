/* Process-local, opt-in DXR command recording evidence. Include before level-profile.inc.
 * install_ray_trace(device) hooks only original COM methods; arguments/results pass
 * through unchanged. Counts mean CPU calls recorded, not completed GPU rendering.
 * All indices are derived from the exact Wine headers used to compile this DLL.
 */
#include <stddef.h>

#define RT_SLOT(type, field) ((UINT)(offsetof(type, field) / sizeof(void *)))
#define RT_RECORD_LIMIT 32

typedef HRESULT (WINAPI *RTQuery)(void *, REFIID, void **);
typedef ULONG (WINAPI *RTRelease)(void *);
typedef HRESULT (WINAPI *RTCreateList)(void *, UINT, D3D12_COMMAND_LIST_TYPE, ID3D12CommandAllocator *, ID3D12PipelineState *, REFIID, void **);
typedef HRESULT (WINAPI *RTCreateList1)(void *, UINT, D3D12_COMMAND_LIST_TYPE, D3D12_COMMAND_LIST_FLAGS, REFIID, void **);
typedef HRESULT (WINAPI *RTComputePSO)(void *, const D3D12_COMPUTE_PIPELINE_STATE_DESC *, REFIID, void **);
typedef HRESULT (WINAPI *RTStateObject)(void *, const D3D12_STATE_OBJECT_DESC *, REFIID, void **);
typedef void (WINAPI *RTBuildAS)(void *, const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC *, UINT, const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC *);
typedef void (WINAPI *RTDispatchRays)(void *, const D3D12_DISPATCH_RAYS_DESC *);

typedef struct RTDeviceRecord {
    void **table;
    RTCreateList create;
    RTCreateList1 create1;
    RTComputePSO compute;
    RTStateObject state;
} RTDeviceRecord;
typedef struct RTListRecord {
    void **table;
    RTBuildAS build;
    RTDispatchRays dispatch;
} RTListRecord;
static SRWLOCK rt_lock = SRWLOCK_INIT;
static RTDeviceRecord rt_devices[RT_RECORD_LIMIT];
static RTListRecord rt_lists[RT_RECORD_LIMIT];
static UINT rt_device_count, rt_list_count;
static LONG rt_created, rt_build_calls, rt_dispatch_calls, rt_compute_calls, rt_inline_candidates, rt_state_calls;
static const GUID rt_device5_iid = {0x8b4f173b,0x2fea,0x4b80,{0x8f,0x58,0x43,0x07,0x19,0x1a,0xb9,0x5d}};
static const GUID rt_list4_iid = {0x8754318e,0xd3a9,0x4541,{0x98,0xcf,0x64,0x5b,0x50,0xdc,0x48,0x74}};

static int rt_log_count(LONG n)
{ return n > 0 && (n <= 8 || (n <= 1048576 && !(n & (n-1)))); }

/* Caller holds rt_lock exclusively. Publish the original before the hook. */
static int rt_replace(void **table, UINT index, void *replacement, void **original)
{
    DWORD old, ignored;
    if (!VirtualProtect(&table[index], sizeof(void *), PAGE_READWRITE, &old)) return 0;
    *original = table[index];
    InterlockedExchangePointer(&table[index], replacement);
    VirtualProtect(&table[index], sizeof(void *), old, &ignored);
    return 1;
}
static RTDeviceRecord rt_find_device(void *object)
{
    RTDeviceRecord found = {0}; void **table = *(void ***)object;
    AcquireSRWLockShared(&rt_lock);
    for (UINT i=0;i<rt_device_count;i++) if (rt_devices[i].table == table) { found=rt_devices[i]; break; }
    ReleaseSRWLockShared(&rt_lock); return found;
}
static RTListRecord rt_find_list(void *object)
{
    RTListRecord found = {0}; void **table = *(void ***)object;
    AcquireSRWLockShared(&rt_lock);
    for (UINT i=0;i<rt_list_count;i++) if (rt_lists[i].table == table) { found=rt_lists[i]; break; }
    ReleaseSRWLockShared(&rt_lock); return found;
}
static void WINAPI rt_build(void *list, const D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC *desc,
        UINT count, const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC *info)
{
    RTListRecord record=rt_find_list(list);
    LONG n=InterlockedIncrement(&rt_build_calls);
    if (rt_log_count(n)) fprintf(stderr,"MULLION DXR recorded BuildAS count=%ld kind=%s descriptors=%u flags=0x%x\n",
        n,desc ? (desc->Inputs.Type==D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL?"TLAS":"BLAS"):"null",
        desc?desc->Inputs.NumDescs:0,desc?desc->Inputs.Flags:0);
    record.build(list,desc,count,info);
}
static void WINAPI rt_dispatch(void *list, const D3D12_DISPATCH_RAYS_DESC *desc)
{
    RTListRecord record=rt_find_list(list);
    LONG n=InterlockedIncrement(&rt_dispatch_calls);
    if (rt_log_count(n)) fprintf(stderr,"MULLION DXR recorded DispatchRays count=%ld dimensions=%ux%ux%u\n",n,
        desc?desc->Width:0,desc?desc->Height:0,desc?desc->Depth:0);
    record.dispatch(list,desc);
}
static void rt_install_list(void *object)
{
    if (!object) return;
    void **base=*(void ***)object; void *list=NULL;
    if (FAILED(((RTQuery)base[0])(object,&rt_list4_iid,&list)) || !list) return;
    void **table=*(void ***)list;
    AcquireSRWLockExclusive(&rt_lock);
    UINT i=0; for (;i<rt_list_count;i++) if(rt_lists[i].table==table) break;
    if (i==rt_list_count && rt_list_count<RT_RECORD_LIMIT) {
        RTListRecord *record=&rt_lists[rt_list_count++]; record->table=table;
        int a=rt_replace(table,RT_SLOT(ID3D12GraphicsCommandList4Vtbl,BuildRaytracingAccelerationStructure),(void *)rt_build,(void **)&record->build);
        int b=rt_replace(table,RT_SLOT(ID3D12GraphicsCommandList4Vtbl,DispatchRays),(void *)rt_dispatch,(void **)&record->dispatch);
        fprintf(stderr,"MULLION DXR commandlist hooks build=%d dispatch=%d (slots %u,%u)\n",a,b,
            RT_SLOT(ID3D12GraphicsCommandList4Vtbl,BuildRaytracingAccelerationStructure),RT_SLOT(ID3D12GraphicsCommandList4Vtbl,DispatchRays));
    }
    ReleaseSRWLockExclusive(&rt_lock);
    ((RTRelease)table[2])(list);
}
static HRESULT WINAPI rt_create_list(void *device,UINT mask,D3D12_COMMAND_LIST_TYPE type,
        ID3D12CommandAllocator *allocator,ID3D12PipelineState *initial,REFIID iid,void **out)
{
    RTDeviceRecord record=rt_find_device(device);
    HRESULT hr=record.create(device,mask,type,allocator,initial,iid,out);
    LONG n=InterlockedIncrement(&rt_created);
    if(rt_log_count(n)) fprintf(stderr,"MULLION DXR CreateCommandList count=%ld type=%u hr=0x%08lx\n",n,type,(unsigned long)hr);
    if(SUCCEEDED(hr)&&out&&*out) rt_install_list(*out);
    return hr;
}
static HRESULT WINAPI rt_create_list1(void *device,UINT mask,D3D12_COMMAND_LIST_TYPE type,
        D3D12_COMMAND_LIST_FLAGS flags,REFIID iid,void **out)
{
    RTDeviceRecord record=rt_find_device(device);
    HRESULT hr=record.create1(device,mask,type,flags,iid,out);
    LONG n=InterlockedIncrement(&rt_created);
    if(rt_log_count(n)) fprintf(stderr,"MULLION DXR CreateCommandList1 count=%ld type=%u hr=0x%08lx\n",n,type,(unsigned long)hr);
    if(SUCCEEDED(hr)&&out&&*out) rt_install_list(*out);
    return hr;
}
/* Optional declaration-only hint. A DXIL library may contain unused ray-query
 * intrinsics, and stripped/alternative encodings may hide names. No execution
 * claim is made from this marker. Scan at most 16 MiB, never dump bytecode. */
static int rt_inline_marker(const D3D12_SHADER_BYTECODE *code)
{
    static const char marker[]="rayQuery_TraceRayInline";
    const unsigned char *p=code->pShaderBytecode;
    SIZE_T size=code->BytecodeLength;
    if(!p||size<sizeof(marker)-1||size>16*1024*1024) return 0;
    for(SIZE_T i=0;i<=size-(sizeof(marker)-1);i++)
        if(p[i]=='r'&&!memcmp(p+i,marker,sizeof(marker)-1)) return 1;
    return 0;
}
static HRESULT WINAPI rt_compute(void *device,const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc,REFIID iid,void **out)
{
    RTDeviceRecord record=rt_find_device(device);
    HRESULT hr=record.compute(device,desc,iid,out);
    InterlockedIncrement(&rt_compute_calls);
    if(desc&&rt_inline_marker(&desc->CS)) {
        LONG n=InterlockedIncrement(&rt_inline_candidates);
        if(rt_log_count(n)) fprintf(stderr,"MULLION DXR shader declaration TraceRayInline candidate=%ld hr=0x%08lx (not execution evidence)\n",n,(unsigned long)hr);
    }
    return hr;
}
static HRESULT WINAPI rt_state(void *device,const D3D12_STATE_OBJECT_DESC *desc,REFIID iid,void **out)
{
    RTDeviceRecord record=rt_find_device(device);
    HRESULT hr=record.state(device,desc,iid,out);
    LONG n=InterlockedIncrement(&rt_state_calls);
    if(rt_log_count(n)) fprintf(stderr,"MULLION DXR CreateStateObject count=%ld type=%u hr=0x%08lx\n",n,desc?desc->Type:0,(unsigned long)hr);
    return hr;
}
static void install_ray_trace(void *object)
{
    char enabled[2];
    if(!object||GetEnvironmentVariableA("MULLION_DIAGNOSTIC_TRACE_DXR",enabled,2)!=1||enabled[0]!='1') return;
    void **base=*(void ***)object; void *device=NULL;
    if(FAILED(((RTQuery)base[0])(object,&rt_device5_iid,&device))||!device) return;
    void **table=*(void ***)device;
    AcquireSRWLockExclusive(&rt_lock);
    UINT i=0;for(;i<rt_device_count;i++)if(rt_devices[i].table==table)break;
    if(i==rt_device_count&&rt_device_count<RT_RECORD_LIMIT) {
        RTDeviceRecord *record=&rt_devices[rt_device_count++];record->table=table;
        int a=rt_replace(table,RT_SLOT(ID3D12Device5Vtbl,CreateCommandList),(void *)rt_create_list,(void **)&record->create);
        int b=rt_replace(table,RT_SLOT(ID3D12Device5Vtbl,CreateCommandList1),(void *)rt_create_list1,(void **)&record->create1);
        int c=rt_replace(table,RT_SLOT(ID3D12Device5Vtbl,CreateComputePipelineState),(void *)rt_compute,(void **)&record->compute);
        int d=rt_replace(table,RT_SLOT(ID3D12Device5Vtbl,CreateStateObject),(void *)rt_state,(void **)&record->state);
        fprintf(stderr,"MULLION DXR device hooks create=%d create1=%d compute=%d state=%d (slots %u,%u,%u,%u)\n",a,b,c,d,
            RT_SLOT(ID3D12Device5Vtbl,CreateCommandList),RT_SLOT(ID3D12Device5Vtbl,CreateCommandList1),
            RT_SLOT(ID3D12Device5Vtbl,CreateComputePipelineState),RT_SLOT(ID3D12Device5Vtbl,CreateStateObject));
    }
    ReleaseSRWLockExclusive(&rt_lock);
    ((RTRelease)table[2])(device);
}
static void ray_trace_summary(void)
{
    fprintf(stderr,"MULLION DXR summary lists=%ld buildAS=%ld dispatchRays=%ld computePSO=%ld inlineCandidates=%ld stateObjects=%ld; CPU records only\n",
        InterlockedCompareExchange(&rt_created,0,0),InterlockedCompareExchange(&rt_build_calls,0,0),
        InterlockedCompareExchange(&rt_dispatch_calls,0,0),InterlockedCompareExchange(&rt_compute_calls,0,0),
        InterlockedCompareExchange(&rt_inline_candidates,0,0),InterlockedCompareExchange(&rt_state_calls,0,0));
}
