/* Real GPU DXR test. No presentation, account access, or game files. */
#define EDGE 64
#define PIXEL_BYTES (EDGE * EDGE * sizeof(UINT))
#define HR(call) do { HRESULT _hr = (call); printf("stage.%s: 0x%08lx\n", #call, (unsigned long)_hr); if (FAILED(_hr)) return 10; } while (0)
static DWORD WINAPI watchdog(void *unused) { (void)unused; Sleep(60000); ExitProcess(124); return 0; }
static D3D12_GPU_VIRTUAL_ADDRESS va(ID3D12Resource *r) { return ID3D12Resource_GetGPUVirtualAddress(r); }
static ID3D12Resource *buffer(ID3D12Device5 *d, UINT64 size, D3D12_HEAP_TYPE heap, D3D12_RESOURCE_STATES state, D3D12_RESOURCE_FLAGS flags)
{
    D3D12_HEAP_PROPERTIES hp = {0}; D3D12_RESOURCE_DESC desc = {0}; ID3D12Resource *r = NULL;
    hp.Type = heap;
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; desc.Width = size;
    desc.Height = 1; desc.DepthOrArraySize = 1; desc.MipLevels = 1;
    desc.SampleDesc.Count = 1; desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; desc.Flags = flags;
    HRESULT hr = ID3D12Device5_CreateCommittedResource(d, &hp, D3D12_HEAP_FLAG_NONE, &desc,
        state, NULL, &IID_ID3D12Resource, (void **)&r);
    if (FAILED(hr)) printf("buffer.failed: 0x%08lx size=%llu\n", (unsigned long)hr, (unsigned long long)size);
    return r;
}
static int upload(ID3D12Resource *r, const void *src, SIZE_T n)
{
    void *p; D3D12_RANGE read = {0,0};
    HRESULT hr = ID3D12Resource_Map(r, 0, &read, &p);
    if (FAILED(hr)) return 0;
    memcpy(p, src, n); ID3D12Resource_Unmap(r, 0, NULL); return 1;
}
static void uav_barrier(ID3D12GraphicsCommandList4 *list, ID3D12Resource *r)
{
    D3D12_RESOURCE_BARRIER b = {0}; b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
    b.UAV.pResource = r; ID3D12GraphicsCommandList4_ResourceBarrier(list, 1, &b);
}
static int render_triangle(ID3D12Device *base, const char *shaderpath, pfn_D3D12SerializeRootSignature serialize, int inline_query)
{
    ID3D12Device5 *d; ID3D12CommandQueue *queue; ID3D12CommandAllocator *allocator;
    ID3D12GraphicsCommandList4 *list; ID3D12Fence *fence;
    ID3D12RootSignature *root; ID3DBlob *blob = NULL, *errors = NULL;
    ID3D12StateObject *pipeline = NULL; ID3D12StateObjectProperties *props;
    ID3D12PipelineState *compute_pipeline = NULL;
    ID3D12Resource *vertices, *instances, *blas, *tlas, *scratch, *pixels, *readback, *table;
    D3D12_COMMAND_QUEUE_DESC qd = {0}; D3D12_ROOT_PARAMETER params[2] = {{0}};
    D3D12_ROOT_SIGNATURE_DESC rd = {0};
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC bd = {0}, td = {0};
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO bp = {0}, tp = {0};
    D3D12_RAYTRACING_GEOMETRY_DESC geometry = {0}; D3D12_RAYTRACING_INSTANCE_DESC instance = {0};
    D3D12_DXIL_LIBRARY_DESC lib = {0}; D3D12_HIT_GROUP_DESC hit = {0};
    D3D12_RAYTRACING_SHADER_CONFIG sc = {sizeof(UINT), 8};
    D3D12_RAYTRACING_PIPELINE_CONFIG pc = {1}; D3D12_STATE_SUBOBJECT subs[5] = {{0}};
    D3D12_STATE_OBJECT_DESC sd = {0}; D3D12_DISPATCH_RAYS_DESC rays = {0};
    D3D12_RESOURCE_BARRIER transition = {0};
    float triangle[] = {-.75f,-.75f,0, 0,.75f,0, .75f,-.75f,0};
    unsigned char identifiers[192] = {0}; unsigned char *code; long length; FILE *f;
    HANDLE event; UINT *data; D3D12_RANGE range = {0, PIXEL_BYTES};
    UINT hits=0, misses=0, wrong=0;
    printf("render.mode: %s\n", inline_query ? "inline_ray_query_cs_6_5" : "pipeline_trace_ray_lib_6_3");
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    HR(ID3D12Device_QueryInterface(base, &IID_ID3D12Device5, (void **)&d));
    f = fopen(shaderpath, "rb"); if (!f) { fprintf(stderr,"Shader file missing\n"); return 11; }
    fseek(f,0,SEEK_END); length = ftell(f); rewind(f);
    if (length <= 0 || length > 16*1024*1024) { fclose(f); return 11; }
    code = malloc(length); if (!code || fread(code,1,length,f) != (SIZE_T)length) { fclose(f); return 11; } fclose(f);
    HR(ID3D12Device5_CreateCommandQueue(d, &qd, &IID_ID3D12CommandQueue, (void **)&queue));
    HR(ID3D12Device5_CreateCommandAllocator(d, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&allocator));
    HR(ID3D12Device5_CreateCommandList(d,0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator,NULL,&IID_ID3D12GraphicsCommandList4,(void **)&list));
    HR(ID3D12Device5_CreateFence(d,0,D3D12_FENCE_FLAG_NONE,&IID_ID3D12Fence,(void **)&fence));
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV; params[0].Descriptor.ShaderRegister = 0;
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV; params[1].Descriptor.ShaderRegister = 0;
    rd.NumParameters=2; rd.pParameters=params;
    HR(serialize(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&errors));
    HR(ID3D12Device5_CreateRootSignature(d,0,ID3D10Blob_GetBufferPointer(blob),ID3D10Blob_GetBufferSize(blob),&IID_ID3D12RootSignature,(void **)&root));
    if (inline_query) {
        D3D12_COMPUTE_PIPELINE_STATE_DESC compute_desc = {0};
        compute_desc.pRootSignature = root;
        compute_desc.CS.pShaderBytecode = code;
        compute_desc.CS.BytecodeLength = length;
        HR(ID3D12Device5_CreateComputePipelineState(d, &compute_desc, &IID_ID3D12PipelineState, (void **)&compute_pipeline));
    } else {
        lib.DXILLibrary.pShaderBytecode=code; lib.DXILLibrary.BytecodeLength=length;
        hit.HitGroupExport=L"HitGroup"; hit.ClosestHitShaderImport=L"ClosestHit"; hit.Type=D3D12_HIT_GROUP_TYPE_TRIANGLES;
        subs[0].Type=D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY; subs[0].pDesc=&lib;
        subs[1].Type=D3D12_STATE_SUBOBJECT_TYPE_HIT_GROUP; subs[1].pDesc=&hit;
        subs[2].Type=D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG; subs[2].pDesc=&sc;
        subs[3].Type=D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE; subs[3].pDesc=&root;
        subs[4].Type=D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG; subs[4].pDesc=&pc;
        sd.Type=D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE; sd.NumSubobjects=5; sd.pSubobjects=subs;
        HR(ID3D12Device5_CreateStateObject(d,&sd,&IID_ID3D12StateObject,(void **)&pipeline));
        HR(ID3D12StateObject_QueryInterface(pipeline,&IID_ID3D12StateObjectProperties,(void **)&props));
        const WCHAR *names[]={L"RayGen",L"Miss",L"HitGroup"};
        for (UINT i=0;i<3;i++) { const void *id=ID3D12StateObjectProperties_GetShaderIdentifier(props,names[i]); if(!id) return 12; memcpy(identifiers+i*64,id,32); }
    }
    vertices=buffer(d,sizeof(triangle),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ,0);
    instances=buffer(d,sizeof(instance),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ,0);
    table=buffer(d,sizeof(identifiers),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ,0);
    pixels=buffer(d,PIXEL_BYTES,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    readback=buffer(d,PIXEL_BYTES,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST,0);
    if(!vertices||!instances||!table||!pixels||!readback) return 13;
    if(!upload(vertices,triangle,sizeof(triangle))||!upload(table,identifiers,sizeof(identifiers))) return 13;
    geometry.Type=D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES; geometry.Flags=D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
    geometry.Triangles.VertexFormat=DXGI_FORMAT_R32G32B32_FLOAT; geometry.Triangles.VertexCount=3;
    geometry.Triangles.VertexBuffer.StartAddress=va(vertices); geometry.Triangles.VertexBuffer.StrideInBytes=12;
    bd.Inputs.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL; bd.Inputs.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;
    bd.Inputs.NumDescs=1; bd.Inputs.pGeometryDescs=&geometry;
    td.Inputs.Type=D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL; td.Inputs.DescsLayout=D3D12_ELEMENTS_LAYOUT_ARRAY;
    td.Inputs.NumDescs=1; td.Inputs.InstanceDescs=va(instances);
    ID3D12Device5_GetRaytracingAccelerationStructurePrebuildInfo(d,&bd.Inputs,&bp);
    ID3D12Device5_GetRaytracingAccelerationStructurePrebuildInfo(d,&td.Inputs,&tp);
    printf("render.blas_bytes: %llu\nrender.tlas_bytes: %llu\n",(unsigned long long)bp.ResultDataMaxSizeInBytes,(unsigned long long)tp.ResultDataMaxSizeInBytes);
    if(!bp.ResultDataMaxSizeInBytes||!tp.ResultDataMaxSizeInBytes||!bp.ScratchDataSizeInBytes||!tp.ScratchDataSizeInBytes) return 14;
    blas=buffer(d,bp.ResultDataMaxSizeInBytes,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    tlas=buffer(d,tp.ResultDataMaxSizeInBytes,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    scratch=buffer(d,bp.ScratchDataSizeInBytes>tp.ScratchDataSizeInBytes?bp.ScratchDataSizeInBytes:tp.ScratchDataSizeInBytes,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
    if(!blas||!tlas||!scratch) return 14;
    instance.Transform[0][0]=instance.Transform[1][1]=instance.Transform[2][2]=1;
    instance.InstanceMask=255; instance.AccelerationStructure=va(blas);
    if(!upload(instances,&instance,sizeof(instance))) return 14;
    bd.DestAccelerationStructureData=va(blas); bd.ScratchAccelerationStructureData=va(scratch);
    td.DestAccelerationStructureData=va(tlas); td.ScratchAccelerationStructureData=va(scratch);
    printf("render.build_blas: begin\n"); ID3D12GraphicsCommandList4_BuildRaytracingAccelerationStructure(list,&bd,0,NULL);
    uav_barrier(list,NULL);
    printf("render.build_tlas: begin\n"); ID3D12GraphicsCommandList4_BuildRaytracingAccelerationStructure(list,&td,0,NULL);
    uav_barrier(list,NULL);
    ID3D12GraphicsCommandList4_SetComputeRootSignature(list,root);
    ID3D12GraphicsCommandList4_SetComputeRootUnorderedAccessView(list,0,va(pixels));
    ID3D12GraphicsCommandList4_SetComputeRootShaderResourceView(list,1,va(tlas));
    if (inline_query) {
        ID3D12GraphicsCommandList4_SetPipelineState(list, compute_pipeline);
        printf("render.dispatch_inline_compute: begin\n");
        ID3D12GraphicsCommandList4_Dispatch(list, EDGE/8, EDGE/8, 1);
    } else {
        ID3D12GraphicsCommandList4_SetPipelineState1(list,pipeline);
        rays.RayGenerationShaderRecord.StartAddress=va(table); rays.RayGenerationShaderRecord.SizeInBytes=32;
        rays.MissShaderTable.StartAddress=va(table)+64; rays.MissShaderTable.SizeInBytes=32; rays.MissShaderTable.StrideInBytes=32;
        rays.HitGroupTable.StartAddress=va(table)+128; rays.HitGroupTable.SizeInBytes=32; rays.HitGroupTable.StrideInBytes=32;
        rays.Width=EDGE; rays.Height=EDGE; rays.Depth=1;
        printf("render.dispatch_rays: begin\n"); ID3D12GraphicsCommandList4_DispatchRays(list,&rays);
    }
    transition.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; transition.Transition.pResource=pixels;
    transition.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    transition.Transition.StateBefore=D3D12_RESOURCE_STATE_UNORDERED_ACCESS; transition.Transition.StateAfter=D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList4_ResourceBarrier(list,1,&transition);
    ID3D12GraphicsCommandList4_CopyResource(list,readback,pixels);
    HR(ID3D12GraphicsCommandList4_Close(list));
    ID3D12CommandList *lists[]={(ID3D12CommandList *)list}; ID3D12CommandQueue_ExecuteCommandLists(queue,1,lists);
    event=CreateEventW(NULL,FALSE,FALSE,NULL); if(!event) return 15;
    HR(ID3D12CommandQueue_Signal(queue,fence,1)); HR(ID3D12Fence_SetEventOnCompletion(fence,1,event));
    if(WaitForSingleObject(event,30000)!=WAIT_OBJECT_0) { printf("render.fence: timeout\n"); return 15; }
    HR(ID3D12Device5_GetDeviceRemovedReason(d));
    HR(ID3D12Resource_Map(readback,0,&range,(void **)&data));
    f=fopen(inline_query ? "inline.ppm" : "triangle.ppm","wb"); if(!f) return 16; fprintf(f,"P6\n%d %d\n255\n",EDGE,EDGE);
    for(UINT y=0;y<EDGE;y++) for(UINT x=0;x<EDGE;x++) {
        UINT value=data[y*EDGE+x];
        /* CPU triangle half planes; pixel centers never lie on these edges. */
        float px=((float)x+.5f)/EDGE*2-1, py=1-((float)y+.5f)/EDGE*2;
        int expected_hit=py>=-.75f && py<=.75f && px>=-(.75f-py)*.5f && px<=(.75f-py)*.5f;
        UINT expected=expected_hit?0x0020e040:0x00302010;
        if(value!=expected) wrong++; if(value==0x0020e040) hits++; if(value==0x00302010) misses++;
        unsigned char rgb[]={(unsigned char)value,(unsigned char)(value>>8),(unsigned char)(value>>16)}; fwrite(rgb,1,3,f);
    }
    fclose(f); ID3D12Resource_Unmap(readback,0,NULL);
    printf("render.hit_pixels: %u\nrender.miss_pixels: %u\nrender.wrong_pixels: %u\n",hits,misses,wrong);
    if(wrong||!hits||!misses) {
        if (inline_query) printf("verdict.inline_ray_query_rendering: FAIL\n");
        printf("verdict.real_dxr_rendering: FAIL\n"); return 17;
    }
    if (inline_query) printf("verdict.inline_ray_query_rendering: PASS\n");
    printf("verdict.real_dxr_rendering: PASS\n");
    return 0;
}
