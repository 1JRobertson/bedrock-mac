/* GPL-3.0-or-later. Deterministic WinRT picker contracts; no visible dialogs,
 * registry changes, Minecraft files or user worlds. ABI layouts in the calls
 * below follow Microsoft metadata, independently of the implementation tables. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <unknwn.h>
#include <objbase.h>
#include <roerrorapi.h>
#include <commdlg.h>
#include <cderr.h>
#include <roapi.h>
#include <winstring.h>
#include <stdio.h>
#include <wchar.h>
static BOOL WINAPI mock_open(LPOPENFILENAMEW dialog);
static BOOL WINAPI mock_save(LPOPENFILENAMEW dialog);
static DWORD WINAPI mock_error(void);
static HRESULT WINAPI mock_duplicate(HSTRING source,HSTRING *out);
#define GetOpenFileNameW mock_open
#define GetSaveFileNameW mock_save
#define CommDlgExtendedError mock_error
#define WindowsDuplicateString mock_duplicate
#include "../native/file-pickers/pickers.c"
#undef GetOpenFileNameW
#undef GetSaveFileNameW
#undef CommDlgExtendedError
#undef WindowsDuplicateString
/* IStorageItem layout from the Windows SDK. Keep this independent of pickers.c
 * and Wine-only aliases so the same contract runs against MSVC's SDK headers. */
typedef struct StorageItemABI StorageItemABI;
typedef struct StorageItemABIVtbl {
    HRESULT(WINAPI *QueryInterface)(StorageItemABI*,REFIID,void**);
    ULONG(WINAPI *AddRef)(StorageItemABI*);
    ULONG(WINAPI *Release)(StorageItemABI*);
    HRESULT(WINAPI *GetIids)(StorageItemABI*,ULONG*,GUID**);
    HRESULT(WINAPI *GetRuntimeClassName)(StorageItemABI*,HSTRING*);
    HRESULT(WINAPI *GetTrustLevel)(StorageItemABI*,int*);
    const void *RenameAsync,*RenameAsyncWithOption,*DeleteAsync,*DeleteAsyncWithOption,*GetBasicPropertiesAsync;
    HRESULT(WINAPI *get_Name)(StorageItemABI*,HSTRING*);
    HRESULT(WINAPI *get_Path)(StorageItemABI*,HSTRING*);
} StorageItemABIVtbl;
struct StorageItemABI {const StorageItemABIVtbl*lpVtbl;};

static int failures, checks, dialog_calls, choose_file, save_dialog;
static DWORD dialog_error;
static int duplicates_until_failure=-1;
static WCHAR selected_path[32768];
static const WCHAR *expected_pattern=L"*.png", *expected_extension;
#define CHECK(x) do{checks++;if(!(x)){printf("FAIL line %u: %s\n",__LINE__,#x);failures++;}}while(0)
typedef HRESULT(WINAPI *Out)(void*,void**);
typedef HRESULT(WINAPI *StringOut)(void*,HSTRING*);
typedef HRESULT(WINAPI *StringIn)(void*,HSTRING);
typedef HRESULT(WINAPI *FactoryCreate)(void*,UINT64,void**);
typedef HRESULT(WINAPI *Append)(void*,HSTRING);
typedef HRESULT(WINAPI *MapInsert)(void*,HSTRING,IUnknown*,BOOLEAN*);
typedef HRESULT(WINAPI *FromPath)(void*,HSTRING,void**);
typedef HRESULT(WINAPI *Activate)(HSTRING,void**);
#define METHOD(o,n,t) ((t)(*(void***)(o))[n])
static HSTRING string(const WCHAR *s){HSTRING out=NULL;CHECK(SUCCEEDED(WindowsCreateString(s,lstrlenW(s),&out)));return out;}
static void check_string(HSTRING s,const WCHAR *expected){CHECK(!wcscmp(WindowsGetStringRawBuffer(s,NULL),expected));WindowsDeleteString(s);}
static BOOL WINAPI mock_open(LPOPENFILENAMEW dialog){
    const WCHAR *pattern=dialog->lpstrFilter+lstrlenW(dialog->lpstrFilter)+1;
    dialog_calls++;
    CHECK(!wcscmp(pattern,expected_pattern));
    CHECK(!wcscmp(dialog->lpstrTitle,save_dialog?L"Save file":L"Open file"));
    CHECK(dialog->Flags&OFN_NOCHANGEDIR);
    CHECK(dialog->Flags&(save_dialog?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST));
    if(expected_extension)CHECK(dialog->lpstrDefExt&&!wcscmp(dialog->lpstrDefExt,expected_extension));
    else CHECK(dialog->lpstrDefExt==NULL);
    if(choose_file)lstrcpynW(dialog->lpstrFile,selected_path,dialog->nMaxFile);
    return choose_file;
}
static BOOL WINAPI mock_save(LPOPENFILENAMEW dialog){return mock_open(dialog);}
static DWORD WINAPI mock_error(void){return dialog_error;}
static HRESULT WINAPI mock_duplicate(HSTRING source,HSTRING*out){
    if(duplicates_until_failure==0){if(out)*out=NULL;return E_OUTOFMEMORY;}
    if(duplicates_until_failure>0)duplicates_until_failure--;
    return WindowsDuplicateString(source,out);
}
static void collection_failure_contract(void){
    Object*vector=create(VECTOR);HSTRING first=string(L".png"),second=string(L".mcworld"),out[2]={NULL,NULL};UINT32 actual=99;
    CHECK(SUCCEEDED(vec_append(&vector->main,first)));CHECK(SUCCEEDED(vec_append(&vector->main,second)));
    duplicates_until_failure=1;
    CHECK(vec_many(&vector->main,0,2,out,&actual)==E_OUTOFMEMORY);
    CHECK(actual==0&&out[0]==NULL&&out[1]==NULL);
    duplicates_until_failure=-1;
    CHECK(vec_replace(&vector->main,1,NULL)==E_POINTER);
    WindowsDeleteString(first);WindowsDeleteString(second);release(&vector->main);
}
static void *make_picker(const WCHAR *name,const GUID *iid,BOOL modern){
    HSTRING s=string(name);IUnknown*factory=NULL;void *picker=NULL,*ctor=NULL;
    CHECK(SUCCEEDED(DllGetActivationFactory(s,(void**)&factory)));WindowsDeleteString(s);
    if(modern){CHECK(SUCCEEDED(IUnknown_QueryInterface(factory,&ID_OpenFactory,&ctor)));CHECK(SUCCEEDED(METHOD(ctor,6,FactoryCreate)(ctor,0,&picker)));IUnknown_Release((IUnknown*)ctor);}
    else CHECK(SUCCEEDED(METHOD(factory,6,Out)(factory,&picker)));
    IUnknown_Release(factory);CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)picker,iid,&ctor)));IUnknown_Release((IUnknown*)ctor);
    return picker;
}
static void append_filter(void*picker,int child_slot,const WCHAR*extension){
    HSTRING s=string(extension);void*vector=NULL;
    CHECK(SUCCEEDED(METHOD(picker,child_slot,Out)(picker,&vector)));
    CHECK(SUCCEEDED(METHOD(vector,13,Append)(vector,s)));
    IUnknown_Release((IUnknown*)vector);WindowsDeleteString(s);
}
static void check_result(void*operation_ptr,BOOL modern,const WCHAR*expected){
    void *result=NULL,*item=NULL;HSTRING s=NULL;
    CHECK(SUCCEEDED(METHOD(operation_ptr,8,Out)(operation_ptr,&result)));
    if(!expected){CHECK(result==NULL);return;}
    CHECK(result!=NULL);
    if(modern)CHECK(SUCCEEDED(METHOD(result,6,StringOut)(result,&s)));
    else{
        CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)result,&ID_StorageItem,&item)));
        CHECK(SUCCEEDED(((StorageItemABI*)item)->lpVtbl->get_Path((StorageItemABI*)item,&s)));
        IUnknown_Release((IUnknown*)item);
    }
    check_string(s,expected);IUnknown_Release((IUnknown*)result);
}
static void open_contract(BOOL modern){
    void *picker=make_picker(modern?L"Microsoft.Windows.Storage.Pickers.FileOpenPicker":L"Windows.Storage.Pickers.FileOpenPicker",modern?&ID_Open:&ID_UwpOpen,modern),*op=NULL,*item=NULL;
    int child_slot=modern?12:14,pick_slot=modern?13:15;HSTRING s=NULL;int calls;
    CHECK(METHOD(picker,pick_slot,Out)(picker,&op)==E_INVALIDARG&&op==NULL);
    append_filter(picker,child_slot,L".png");expected_pattern=L"*.png";expected_extension=NULL;save_dialog=0;
    choose_file=1;dialog_error=0;lstrcpyW(selected_path,L"Z:\\tmp\\Skin \x03b1.png");
    CHECK(SUCCEEDED(METHOD(picker,pick_slot,Out)(picker,&op)));
    check_result(op,modern,selected_path);IUnknown_Release((IUnknown*)op);
    choose_file=0;CHECK(SUCCEEDED(METHOD(picker,pick_slot,Out)(picker,&op)));check_result(op,modern,NULL);IUnknown_Release((IUnknown*)op);
    dialog_error=CDERR_DIALOGFAILURE;
    CHECK(SUCCEEDED(METHOD(picker,pick_slot,Out)(picker,&op)));
    CHECK(METHOD(op,8,Out)(op,&item)==E_FAIL&&item==NULL);IUnknown_Release((IUnknown*)op);dialog_error=0;
    append_filter(picker,child_slot,L".mcworld");expected_pattern=L"*.png;*.mcworld";
    CHECK(SUCCEEDED(METHOD(picker,pick_slot,Out)(picker,&op)));check_result(op,modern,NULL);IUnknown_Release((IUnknown*)op);
    append_filter(picker,child_slot,L".png;*.exe");calls=dialog_calls;
    CHECK(METHOD(picker,pick_slot,Out)(picker,&op)==E_INVALIDARG&&op==NULL);CHECK(dialog_calls==calls);
    CHECK(METHOD(picker,pick_slot+1,Out)(picker,&op)==E_NOTIMPL&&op==NULL);
    s=string(L"unused");WindowsDeleteString(s);IUnknown_Release((IUnknown*)picker);
}

typedef struct Handler{const void**vt;LONG refs;int calls;int status;BOOL close_on_callback;}Handler;
static HRESULT WINAPI handler_qi(Handler*h,REFIID iid,void**out){if(!out)return E_POINTER;*out=h;InterlockedIncrement(&h->refs);return S_OK;}
static ULONG WINAPI handler_add(Handler*h){return InterlockedIncrement(&h->refs);}
static ULONG WINAPI handler_release(Handler*h){return InterlockedDecrement(&h->refs);}
static HRESULT WINAPI handler_invoke(Handler*h,Face*a,int status){IUnknown*result=NULL;h->calls++;CHECK(status==h->status);CHECK(SUCCEEDED(results(a,&result)));if(result)IUnknown_Release(result);if(h->close_on_callback)CHECK(SUCCEEDED(async_close(a)));return E_FAIL;}
static const void*handler_vt[]={handler_qi,handler_add,handler_release,handler_invoke};
static void lifetime_contract(void){
    Handler h={handler_vt,1,0,1,FALSE};void*op=NULL,*result=NULL;Face*info=NULL;int status=0;HRESULT hr;
    CHECK(SUCCEEDED(operation(NULL,FALSE,S_OK,&op)));
    CHECK(SUCCEEDED(METHOD(op,6,HRESULT(WINAPI*)(void*,IUnknown*))(op,(IUnknown*)&h)));
    CHECK(h.calls==1&&h.refs==2);
    CHECK(METHOD(op,6,HRESULT(WINAPI*)(void*,IUnknown*))(op,(IUnknown*)&h)==E_ILLEGAL_DELEGATE_ASSIGNMENT);
    CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)op,&ID_AsyncInfo,(void**)&info)));
    CHECK(SUCCEEDED(async_status(info,&status))&&status==1);
    CHECK(SUCCEEDED(async_close(info))&&h.refs==1);
    CHECK(results(op,(IUnknown**)&result)==RO_E_CLOSED&&result==NULL);
    CHECK(completed_get(op,(IUnknown**)&result)==RO_E_CLOSED&&result==NULL);
    CHECK(async_error(info,&hr)==RO_E_CLOSED);
    CHECK(completed_put(op,(IUnknown*)&h)==RO_E_CLOSED);
    release(info);IUnknown_Release((IUnknown*)op);
    h.close_on_callback=TRUE;CHECK(SUCCEEDED(operation(NULL,FALSE,S_OK,&op)));
    CHECK(SUCCEEDED(completed_put(op,(IUnknown*)&h)));CHECK(h.calls==2&&h.refs==1);IUnknown_Release((IUnknown*)op);
    CHECK(SUCCEEDED(operation(NULL,FALSE,E_ACCESSDENIED,&op)));
    CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)op,&ID_AsyncInfo,(void**)&info)));
    CHECK(SUCCEEDED(async_status(info,&status))&&status==3);CHECK(SUCCEEDED(async_error(info,&hr))&&hr==E_ACCESSDENIED);
    CHECK(results(op,(IUnknown**)&result)==E_ACCESSDENIED&&result==NULL);release(info);IUnknown_Release((IUnknown*)op);
}
static void save_and_storage_contract(void){
    void*save=make_picker(L"Windows.Storage.Pickers.FileSavePicker",&ID_Save,FALSE),*map=NULL,*vec=NULL,*op=NULL,*factory=NULL,*statics=NULL;
    HSTRING s=string(L"Minecraft world"),ext=string(L".mcworld"),path;BOOLEAN replaced=FALSE;WCHAR temporary[32768];HANDLE file;DWORD written;char bytes[4]={0};DWORD read;
    vec=&create(VECTOR)->main;CHECK(SUCCEEDED(METHOD(vec,13,Append)(vec,ext)));
    CHECK(SUCCEEDED(METHOD(save,12,Out)(save,&map)));
    CHECK(SUCCEEDED(METHOD(map,10,MapInsert)(map,s,(IUnknown*)vec,&replaced))&&!replaced);
    WindowsDeleteString(s);WindowsDeleteString(ext);IUnknown_Release((IUnknown*)vec);IUnknown_Release((IUnknown*)map);
    GetTempPathW(32768,temporary);CHECK(GetTempFileNameW(temporary,L"bpk",0,selected_path)!=0);
    file=CreateFileW(selected_path,GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);CHECK(file!=INVALID_HANDLE_VALUE);
    CHECK(WriteFile(file,"skin",4,&written,NULL)&&written==4);CloseHandle(file);
    expected_pattern=L"*.mcworld";expected_extension=L"mcworld";save_dialog=1;choose_file=1;
    CHECK(SUCCEEDED(METHOD(save,19,Out)(save,&op)));check_result(op,FALSE,selected_path);IUnknown_Release((IUnknown*)op);
    file=CreateFileW(selected_path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);CHECK(file!=INVALID_HANDLE_VALUE);CHECK(ReadFile(file,bytes,4,&read,NULL)&&read==4&&!memcmp(bytes,"skin",4));CloseHandle(file);
    s=string(L"Windows.Storage.StorageFile");CHECK(SUCCEEDED(DllGetActivationFactory(s,&factory)));WindowsDeleteString(s);
    CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)factory,&ID_StorageFileStatics,&statics)));IUnknown_Release((IUnknown*)factory);
    path=string(selected_path);CHECK(SUCCEEDED(METHOD(statics,6,FromPath)(statics,path,&op)));check_result(op,FALSE,selected_path);IUnknown_Release((IUnknown*)op);
    CHECK(DeleteFileW(selected_path));CHECK(SUCCEEDED(METHOD(statics,6,FromPath)(statics,path,&op)));
    CHECK(FAILED(METHOD(op,8,Out)(op,&factory))&&factory==NULL);IUnknown_Release((IUnknown*)op);WindowsDeleteString(path);
    path=string(L"relative.png");CHECK(METHOD(statics,6,FromPath)(statics,path,&op)==E_INVALIDARG&&op==NULL);WindowsDeleteString(path);
    /* Saving a new file creates it; saving an existing one never truncates it. */
    CHECK(SUCCEEDED(METHOD(save,19,Out)(save,&op)));check_result(op,FALSE,selected_path);IUnknown_Release((IUnknown*)op);CHECK(GetFileAttributesW(selected_path)!=INVALID_FILE_ATTRIBUTES);CHECK(DeleteFileW(selected_path));
    choose_file=0;CHECK(SUCCEEDED(METHOD(save,19,Out)(save,&op)));check_result(op,FALSE,NULL);IUnknown_Release((IUnknown*)op);
    IUnknown_Release((IUnknown*)statics);IUnknown_Release((IUnknown*)save);save_dialog=0;
}
static void dll_contract(void){
    WCHAR path[32768];HMODULE dll;Activate activate_dll;HSTRING s;void*factory=NULL,*statics=NULL;
    DWORD length=GetEnvironmentVariableW(L"BEDROCK_PICKER_DLL",path,32768);
    if(!length)lstrcpyW(path,L"R:\\build\\file-pickers\\bedrock-pickers.dll");
    CHECK(length<32768);dll=LoadLibraryW(path);CHECK(dll!=NULL);if(!dll)return;
    activate_dll=(Activate)GetProcAddress(dll,"DllGetActivationFactory");CHECK(activate_dll!=NULL);if(!activate_dll)return;
    s=string(L"Microsoft.Windows.Storage.Pickers.FileOpenPicker");CHECK(SUCCEEDED(activate_dll(s,&factory)));CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)factory,&ID_OpenFactory,&statics)));IUnknown_Release((IUnknown*)statics);IUnknown_Release((IUnknown*)factory);WindowsDeleteString(s);
    s=string(L"Windows.Storage.StorageFile");CHECK(SUCCEEDED(activate_dll(s,&factory)));CHECK(SUCCEEDED(IUnknown_QueryInterface((IUnknown*)factory,&ID_StorageFileStatics,&statics)));IUnknown_Release((IUnknown*)statics);IUnknown_Release((IUnknown*)factory);WindowsDeleteString(s);
    FreeLibrary(dll);
}
static int run_contracts(void){
    setvbuf(stdout,NULL,_IONBF,0);CHECK(SUCCEEDED(RoInitialize(RO_INIT_MULTITHREADED)));
    open_contract(TRUE);open_contract(FALSE);lifetime_contract();collection_failure_contract();save_and_storage_contract();dll_contract();
    printf("Picker contracts: %d checks, %d failures\n",checks,failures);RoUninitialize();return failures?1:0;
}
#ifdef __WINESRC__
void mainCRTStartup(void){ExitProcess(run_contracts());}
#else
int main(void){return run_contracts();}
#endif
