#import "native_frame_files.h"
#import "shared_texture_executor.h"
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error native_frame_files.m requires ARC
#endif
static BOOL files_fail(NSString **failure, NSString *message) {
    if(failure)*failure=message;return NO;
}
static BOOL number(id object,uint64_t maximum,uint64_t *out) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType],*text=[[object stringValue] UTF8String];
    if(!type||type[1]||!strchr("cCsSiIlLqQ",type[0])||!text||!*text)return NO;
    uint64_t value=0;for(const char *p=text;*p;p++){
        if(*p<'0'||*p>'9')return NO;unsigned digit=*p-'0';
        if(digit>maximum||value>(maximum-digit)/10)return NO;value=value*10+digit;
    }*out=value;return YES;
}
static BOOL basename_ok(id name) {
    if(![name isKindOfClass:[NSString class]]||![name length]||[name length]>128||[name hasPrefix:@"."])return NO;
    return [name rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."] invertedSet]].location==NSNotFound;
}
static NSData *read_file(int directory,NSString *name,uint64_t maximum) {
    if(!basename_ok(name))return nil;
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return nil;struct stat a,b;
    if(fstat(fd,&a)||!S_ISREG(a.st_mode)||a.st_uid!=getuid()||a.st_nlink!=1||(a.st_mode&077)||a.st_size<=0||(uint64_t)a.st_size>maximum){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)a.st_size];size_t left=data.length;uint8_t *bytes=data.mutableBytes;
    while(left){ssize_t n=read(fd,bytes,left);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return nil;}bytes+=n;left-=n;}
    BOOL stable=!fstat(fd,&b)&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_size==b.st_size&&
        a.st_mode==b.st_mode&&a.st_nlink==b.st_nlink&&a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec&&
        a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec&&a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec&&
        a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
    close(fd);return stable?data:nil;
}
static NSDictionary *dictionary(NSData *data) {
    id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [value isKindOfClass:[NSDictionary class]]?value:nil;
}
static BOOL identity(NSDictionary *value,uint64_t stream,uint64_t frame,uint64_t payload) {
    uint64_t v;return number(value[@"stream"],UINT64_MAX,&v)&&v==stream&&
        number(value[@"frame"],UINT64_MAX,&v)&&v==frame&&number(value[@"payload_id"],UINT64_MAX,&v)&&v==payload;
}
static int payload_directory(int root,NSString *name,uint64_t *bytes) {
    if(!basename_ok(name))return -1;
    int fd=openat(root,name.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat s;
    if(fd<0)return -1;
    if(fstat(fd,&s)||s.st_uid!=getuid()||(s.st_mode&077)){close(fd);return -1;}
    int scan=dup(fd);DIR *dir=scan>=0?fdopendir(scan):NULL;if(!dir){if(scan>=0)close(scan);close(fd);return -1;}
    unsigned count=0;BOOL valid=YES;struct dirent *entry;
    while((entry=readdir(dir))){
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(++count>2048||fstatat(fd,entry->d_name,&s,AT_SYMLINK_NOFOLLOW)||!S_ISREG(s.st_mode)||
            s.st_uid!=getuid()||s.st_nlink!=1||(s.st_mode&077)||s.st_size<0||
            (uint64_t)s.st_size>FFST_NATIVE_FRAME_MAX_BYTES-*bytes){valid=NO;break;}
        *bytes+=(uint64_t)s.st_size;
    }
    closedir(dir);if(!valid){close(fd);return -1;}return fd;
}

@interface FFSTFrameFiles : NSObject <FFSTNativeFramePayloadProvider>
@property(nonatomic) uint64_t stream,frame;
@property(nonatomic,strong) NSDictionary<NSNumber *,FFSTNativeFramePassPayload *> *renders;
@property(nonatomic,strong) NSDictionary<NSNumber *,FFSTNativeFrameOperationPayload *> *operations;
@property(nonatomic,strong) NSDictionary<NSNumber *,NSDictionary *> *presents;
@property(nonatomic,strong) NSArray<NSDictionary *> *dependencies;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSValue *> *imports;
@property(nonatomic,strong) FFSTExecutorSession *executorSession;
@end
@implementation FFSTFrameFiles
- (FFSTNativeFrameOperationPayload *)operationPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_operations[@(payload)]){files_fail(failure,@"Missing exact native operation payload");return nil;}
    return _operations[@(payload)];
}
- (FFSTNativeFramePassPayload *)renderPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_renders[@(payload)]){files_fail(failure,@"Missing exact native render payload");return nil;}
    return _renders[@(payload)];
}
- (NSDictionary *)presentPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_presents[@(payload)]){files_fail(failure,@"Missing exact native Present payload");return nil;}
    return _presents[@(payload)];
}
- (BOOL)externalDependencyCompleted:(const ffs_record *)record failure:(NSString **)failure {
    if(!record||record->kind!=FFS_DEPENDENCY||!(record->flags&FFS_EXTERNAL)||record->data[4]!=FFS_WAIT)
        return files_fail(failure,@"Invalid external dependency request");
    for(NSDictionary *d in _dependencies){
        uint64_t domain,identity,value,payload;
        if(number(d[@"domain"],FFS_EVENT,&domain)&&number(d[@"id"],UINT64_MAX,&identity)&&
           number(d[@"value"],UINT64_MAX,&value)&&number(d[@"payload_id"],UINT64_MAX,&payload)&&
           domain==record->data[0]&&identity==record->data[1]&&value==record->data[2]&&payload==record->data[5])return YES;
    }return files_fail(failure,@"Producer has not completed this exact external dependency");
}
- (id<MTLTexture>)initialTexture:(NSDictionary *)reference device:(id<MTLDevice>)device failure:(NSString **)failure {
    uint64_t cut,role,index,root,version,level,slice,generation;
    if(!number(reference[@"shared_cut_id"],UINT64_MAX,&cut)||!cut||
       !number(reference[@"shared_role"],FFST_STENCIL,&role)||role<FFST_COLOR||
       !number(reference[@"shared_index"],7,&index)){files_fail(failure,@"Initial attachment lacks an exact shared lease");return nil;}
    if(!number(reference[@"root"],UINT64_MAX,&root)||!number(reference[@"input_content_version"],UINT64_MAX,&version)||
       !number(reference[@"allocation_generation"],UINT64_MAX,&generation)||!number(reference[@"level"],UINT64_MAX,&level)||
       !number(reference[@"slice"],UINT64_MAX,&slice)){files_fail(failure,@"Initial attachment provenance is invalid");return nil;}
    NSValue *value=_imports[@(cut)];FFSTExecutorAttachments lease=value.pointerValue;
    if(!lease){NSString *reason=nil;lease=[_executorSession acquire:cut device:device timeout:15 failure:&reason];
        if(!lease){files_fail(failure,[NSString stringWithFormat:@"Initial attachment lease unavailable cut=%llu root=%llu generation=%llu version=%llu role=%llu index=%llu mip=%llu slice=%llu: %@",
            (unsigned long long)cut,(unsigned long long)root,(unsigned long long)generation,(unsigned long long)version,
            (unsigned long long)role,(unsigned long long)index,(unsigned long long)level,(unsigned long long)slice,reason?:@"Attachment session unavailable"]);return nil;}
        _imports[@(cut)]=[NSValue valueWithPointer:lease];}
    FFSTTextureInfo info={0};
    if(!ffst_executor_texture_info(lease,(FFSTAttachmentRole)role,(uint32_t)index,&info)||
       info.source_id!=root||info.source_generation!=version||info.source_level!=level||info.source_slice!=slice){
        files_fail(failure,@"Initial attachment producer provenance differs");return nil;
    }
    id<MTLTexture> texture=ffst_executor_texture(lease,(FFSTAttachmentRole)role,(uint32_t)index);
    if(!texture||texture.device.registryID!=device.registryID){files_fail(failure,@"Initial attachment identity mismatch");return nil;}
    return texture;
}
- (BOOL)finishImportsWithCommand:(id<MTLCommandBuffer>)command failure:(NSString **)failure {
    for(NSValue *value in _imports.allValues)
        if(!ffst_executor_finish(value.pointerValue,command))return files_fail(failure,@"Shared attachment completion hook rejected");
    return YES;
}
- (BOOL)waitForImportRetirement:(NSString **)failure {
    BOOL retired=YES;
    for(NSValue *value in _imports.allValues)
        if(ffst_executor_wait(value.pointerValue,15)!=FFST_OK)retired=NO;
    return retired?YES:files_fail(failure,@"Shared attachment retirement not acknowledged");
}
- (void)abandonImports {
    for(NSValue *value in _imports.allValues)ffst_executor_release(value.pointerValue);
    [_imports removeAllObjects];
}
- (void)dealloc { [self abandonImports];[_executorSession close]; }
@end

FFSTNativeFrameRequest *ffst_frame_request_from_files(int directory,NSString *marker,NSString **failure) {
    NSData *ready=read_file(directory,marker,2u*1024u*1024u);NSDictionary *m=dictionary(ready);
    uint64_t stream,frame,declared,ledgerBytes;
    if(![m[@"format"] isEqual:@"bedrock-native-frame-files"]||![m[@"version"] isEqual:@1]||
       CFGetTypeID((__bridge CFTypeRef)(m[@"producer_completed"]?:@0))!=CFBooleanGetTypeID()||![m[@"producer_completed"] boolValue]||
       !number(m[@"stream"],UINT64_MAX,&stream)||!stream||!number(m[@"frame"],UINT64_MAX,&frame)||!frame||
       !number(m[@"retained_bytes"],FFST_NATIVE_FRAME_MAX_BYTES,&declared)||!declared||
       ![marker isEqual:[NSString stringWithFormat:@"frame-%llu-%llu.ready.json",(unsigned long long)stream,(unsigned long long)frame]]){
        files_fail(failure,@"Invalid completed frame publication");return nil;
    }
    NSDictionary *ledger=[m[@"ledger"] isKindOfClass:[NSDictionary class]]?m[@"ledger"]:nil;
    if(!number(ledger[@"bytes"],FFS_MAX_RECORDS*sizeof(ffs_record),&ledgerBytes)||!ledgerBytes){files_fail(failure,@"Invalid frame ledger extent");return nil;}
    NSData *wire=read_file(directory,ledger[@"file"],ledgerBytes);unsigned char digest[CC_SHA256_DIGEST_LENGTH];char hex[65];
    if(!wire||wire.length!=ledgerBytes){files_fail(failure,@"Missing immutable frame ledger");return nil;}
    CC_SHA256(wire.bytes,(CC_LONG)wire.length,digest);for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    if(![ledger[@"sha256"] isEqual:[NSString stringWithUTF8String:hex]]){files_fail(failure,@"Frame ledger digest mismatch");return nil;}
    NSArray *entries=m[@"payloads"],*dependencies=m[@"dependencies"];
    if(![entries isKindOfClass:[NSArray class]]||!entries.count||entries.count>FFST_NATIVE_FRAME_MAX_PASSES+1||
       ![dependencies isKindOfClass:[NSArray class]]||dependencies.count>FFS_MAX_DEPENDENCIES){files_fail(failure,@"Invalid frame payload bounds");return nil;}
    NSMutableSet *dependencyKeys=[NSMutableSet new];
    for(id d in dependencies){uint64_t domain,identifier,value,payload;
        if(![d isKindOfClass:[NSDictionary class]]||!number(d[@"domain"],FFS_EVENT,&domain)||!domain||
           !number(d[@"id"],UINT64_MAX,&identifier)||!identifier||!number(d[@"value"],UINT64_MAX,&value)||
           !number(d[@"payload_id"],UINT64_MAX,&payload)||!payload){files_fail(failure,@"Invalid completed dependency tuple");return nil;}
        NSString *key=[NSString stringWithFormat:@"%@:%@:%@:%@",d[@"domain"],d[@"id"],d[@"value"],d[@"payload_id"]];
        if([dependencyKeys containsObject:key]){files_fail(failure,@"Duplicated completed dependency tuple");return nil;}
        [dependencyKeys addObject:key];
    }
    FFSTFrameFiles *provider=[FFSTFrameFiles new];provider.stream=stream;provider.frame=frame;
    provider.dependencies=dependencies;provider.imports=[NSMutableDictionary new];provider.executorSession=[FFSTExecutorSession new];
    NSMutableDictionary *renders=[NSMutableDictionary new],*presents=[NSMutableDictionary new],*operations=[NSMutableDictionary new];
    NSMutableSet *directories=[NSMutableSet new];uint64_t actual=wire.length;
    for(id entry in entries){uint64_t payload;
        if(![entry isKindOfClass:[NSDictionary class]]||!number(entry[@"payload_id"],UINT64_MAX,&payload)||!payload||
           renders[@(payload)]||presents[@(payload)]||operations[@(payload)]||!basename_ok(entry[@"directory"])||[directories containsObject:entry[@"directory"]]){
            files_fail(failure,@"Invalid or duplicated frame payload identity");return nil;}
        [directories addObject:entry[@"directory"]];int fd=payload_directory(directory,entry[@"directory"],&actual);
        if(fd<0){files_fail(failure,@"Unsafe or excessive frame payload directory");return nil;}
        NSDictionary *bindings=dictionary(read_file(fd,@"bindings.json",8u*1024u*1024u));
        if(!identity(bindings,stream,frame,payload)){close(fd);files_fail(failure,@"Frame payload identity differs");return nil;}
        if([entry[@"kind"] isEqual:@"render"]){
            NSDictionary *manifest=dictionary(read_file(fd,@"replay.json",2u*1024u*1024u));
            FFSTNativeFramePassPayload *pass=[FFSTNativeFramePassPayload payloadWithDirectory:fd manifest:manifest bindings:bindings failure:failure];
            close(fd);if(!pass)return nil;renders[@(payload)]=pass;
        }else if([entry[@"kind"] isEqual:@"operation"]){
            FFSTNativeFrameOperationPayload *operation=[FFSTNativeFrameOperationPayload payloadWithDirectory:fd bindings:bindings failure:failure];
            close(fd);if(!operation)return nil;operations[@(payload)]=operation;
        }else if([entry[@"kind"] isEqual:@"present"]&&[bindings[@"format"] isEqual:@"bedrock-native-frame-present"]&&[bindings[@"version"] isEqual:@1]){
            close(fd);presents[@(payload)]=bindings;
        }else {close(fd);files_fail(failure,@"Unsupported frame payload kind");return nil;}
    }
    if(actual>declared||presents.count!=1){files_fail(failure,@"Frame retained bytes or Present coverage differ");return nil;}
    provider.renders=renders;provider.presents=presents;provider.operations=operations;
    FFSTNativeFrameRequest *request=[FFSTNativeFrameRequest requestWithRecords:wire firstSequence:1 retainedBytes:(size_t)declared payloads:provider failure:failure];
    if(request&&(request.streamID!=stream||request.frameID!=frame)){files_fail(failure,@"Frame publication and ledger identity differ");return nil;}
    return request;
}
