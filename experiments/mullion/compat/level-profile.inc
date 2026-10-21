/* Opt-in aggregate level profile for applications that do not require tiled resources.
 * Sparse-resource tiers remain truthful. Any actual sparse use is recorded.
 * This is not a conformant FL12_0 implementation or evidence of ray rendering. */
typedef HRESULT (WINAPI *FeatureFn)(void *,D3D12_FEATURE,void *,UINT);
static FeatureFn original_feature;
typedef HRESULT (WINAPI *ReserveFn)(void *,const D3D12_RESOURCE_DESC *,D3D12_RESOURCE_STATES,const D3D12_CLEAR_VALUE *,REFIID,void **);
typedef HRESULT (WINAPI *Reserve1Fn)(void *,const D3D12_RESOURCE_DESC *,D3D12_RESOURCE_STATES,const D3D12_CLEAR_VALUE *,void *,REFIID,void **);
typedef HRESULT (WINAPI *Reserve2Fn)(void *,const D3D12_RESOURCE_DESC *,D3D12_BARRIER_LAYOUT,const D3D12_CLEAR_VALUE *,void *,UINT,DXGI_FORMAT *,REFIID,void **);
static ReserveFn original_reserved;
static Reserve1Fn original_reserved1;
static Reserve2Fn original_reserved2;
static SRWLOCK profile_lock=SRWLOCK_INIT;

static HRESULT WINAPI profile_feature(void *device,D3D12_FEATURE feature,void *data,UINT size)
{
    HRESULT hr=original_feature(device,feature,data,size);
    if (SUCCEEDED(hr) && feature==D3D12_FEATURE_FEATURE_LEVELS && size==sizeof(D3D12_FEATURE_DATA_FEATURE_LEVELS)) {
        D3D12_FEATURE_DATA_FEATURE_LEVELS *levels=data;
        D3D_FEATURE_LEVEL before=levels->MaxSupportedFeatureLevel;
        for (UINT i=0;i<levels->NumFeatureLevels;i++)
            if (levels->pFeatureLevelsRequested[i]<=D3D_FEATURE_LEVEL_12_0 && levels->pFeatureLevelsRequested[i]>levels->MaxSupportedFeatureLevel)
                levels->MaxSupportedFeatureLevel=levels->pFeatureLevelsRequested[i];
        static LONG count;
        if (InterlockedIncrement(&count)<=12)
            fprintf(stderr,"MULLION PROFILE aggregate level 0x%x -> 0x%x; sparse tier unchanged\n",before,levels->MaxSupportedFeatureLevel);
    }
    if (SUCCEEDED(hr) && feature==D3D12_FEATURE_D3D12_OPTIONS) {
        static LONG count;
        if (InterlockedIncrement(&count)<=6) {
            D3D12_FEATURE_DATA_D3D12_OPTIONS *o=data;
            fprintf(stderr,"MULLION PROFILE actual tiled tier=%u binding tier=%u typed UAV=%u\n",o->TiledResourcesTier,o->ResourceBindingTier,o->TypedUAVLoadAdditionalFormats);
        }
    }
    return hr;
}
static HRESULT WINAPI profile_reserved(void *d,const D3D12_RESOURCE_DESC *desc,D3D12_RESOURCE_STATES state,const D3D12_CLEAR_VALUE *clear,REFIID iid,void **resource)
{
    fprintf(stderr,"MULLION SPARSE CreateReservedResource invoked\n");
    return original_reserved(d,desc,state,clear,iid,resource);
}
static HRESULT WINAPI profile_reserved1(void *d,const D3D12_RESOURCE_DESC *desc,D3D12_RESOURCE_STATES state,const D3D12_CLEAR_VALUE *clear,void *session,REFIID iid,void **resource)
{
    fprintf(stderr,"MULLION SPARSE CreateReservedResource1 invoked\n");
    return original_reserved1(d,desc,state,clear,session,iid,resource);
}
static HRESULT WINAPI profile_reserved2(void *d,const D3D12_RESOURCE_DESC *desc,D3D12_BARRIER_LAYOUT state,const D3D12_CLEAR_VALUE *clear,void *session,UINT count,DXGI_FORMAT *formats,REFIID iid,void **resource)
{
    fprintf(stderr,"MULLION SPARSE CreateReservedResource2 invoked\n");
    return original_reserved2(d,desc,state,clear,session,count,formats,iid,resource);
}
static int replace_slot(void **table,UINT index,void *replacement,void **previous)
{
    DWORD before,ignored;
    if (!VirtualProtect(&table[index],sizeof(void *),PAGE_READWRITE,&before)) return 0;
    *previous=table[index];
    InterlockedExchangePointer(&table[index],replacement);
    VirtualProtect(&table[index],sizeof(void *),before,&ignored);
    return 1;
}
static void install_profile(void *object)
{
    char enabled[2];
    if (!object || GetEnvironmentVariableA("MULLION_DIAGNOSTIC_RELAX_LEVELS",enabled,2)!=1 || enabled[0]!='1') return;
    /* Extended slots below require the full Device10 interface. */
    static const GUID profile_iid={0x517f8718,0xaa66,0x49f9,{0xb0,0x2b,0xa7,0xab,0x89,0xc0,0x60,0x31}};
    typedef HRESULT (WINAPI *Query)(void *,REFIID,void **);
    typedef ULONG (WINAPI *Release)(void *);
    void **table=*(void ***)object; void *base=NULL;
    if (FAILED(((Query)table[0])(object,&profile_iid,&base))) return;
    table=*(void ***)base;
    install_ray_trace(base);
    AcquireSRWLockExclusive(&profile_lock);
    if (table[13]!=(void *)profile_feature) {
        replace_slot(table,13,(void *)profile_feature,(void **)&original_feature);
        replace_slot(table,30,(void *)profile_reserved,(void **)&original_reserved);
        replace_slot(table,55,(void *)profile_reserved1,(void **)&original_reserved1);
        replace_slot(table,78,(void *)profile_reserved2,(void **)&original_reserved2);
        fprintf(stderr,"MULLION PROFILE installed aggregate-level compatibility profile; tiled resources remain unsupported\n");
    }
    ReleaseSRWLockExclusive(&profile_lock);
    ((Release)table[2])(base);
}
