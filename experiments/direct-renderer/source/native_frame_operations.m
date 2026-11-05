#import "native_value_validation.h"
#import "native_frame_operations.h"
#import "native_owned_blobs.h"
#import "vertex_resources.h"
#include <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


/* Fixed generated leaf names only. Memory payloads are owned byte snapshots,
 * not filesystem identities: no uid/mode claims or descriptor fallback. */
static NSUInteger operation_indexed_blob(NSString *name,NSString *prefix,unsigned maximum) {
    if(![name hasPrefix:prefix]||![name hasSuffix:@".bin"]||name.length<prefix.length+6)return 0;
    NSUInteger digits=name.length-prefix.length-4;unsigned width=2;
    for(unsigned remaining=maximum;remaining>=100;remaining/=10)++width;
    if(digits<2||digits>width)return 0;
    unsigned index=0;
    for(NSUInteger i=0;i<digits;++i){unichar c=[name characterAtIndex:prefix.length+i];
        if(c<'0'||c>'9')return 0;unsigned digit=(unsigned)(c-'0');
        if(digit>maximum||index>(maximum-digit)/10)return 0;index=index*10+digit;}
    return index&&index<=maximum&&[name isEqualToString:[NSString stringWithFormat:@"%@%02u.bin",prefix,index]];
}
static NSUInteger operation_blob_limit(NSString *name) {
    if(![name isKindOfClass:[NSString class]]||!name.length||name.length>82)return 0;
    if([name isEqualToString:@"replay.json"])return 2u*1024u*1024u;
    if([name isEqualToString:@"bindings.json"]||[name isEqualToString:@"draw-resource-cut.json"])return 8u*1024u*1024u;
    if(operation_indexed_blob(name,@"cut-buffer-",FF_DRAW_RESOURCE_LIMIT)||operation_indexed_blob(name,@"cut-texture-",FF_TEXTURE_RESOURCE_LIMIT)||
       operation_indexed_blob(name,@"operation-buffer-",FFS_MAX_RESOURCES)||
       operation_indexed_blob(name,@"operation-texture-",FFS_MAX_RESOURCES))return 32u*1024u*1024u;
    if(name.length!=82||![name hasPrefix:@"pass-lib-"]||![name hasSuffix:@".metallib"])return 0;
    for(NSUInteger i=9;i<73;++i){unichar c=[name characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return 0;}
    return 8u*1024u*1024u;
}
static NSDictionary<NSString *,NSData *> *operation_blob_snapshot(id source) {
    if(![source isKindOfClass:[NSDictionary class]]||[source count]>8192)return nil;
    NSMutableDictionary<NSString *,NSData *> *result=[NSMutableDictionary dictionary];NSUInteger total=0;
    NSMutableArray<NSArray *> *entries=[NSMutableArray arrayWithCapacity:[source count]];
    /* Validate the complete metadata budget before touching any source bytes.
     * Oversized mmap payloads must not churn allocations on their way to reject. */
    for(id rawKey in source){
        if(![rawKey isKindOfClass:[NSString class]])return nil;
        NSString *name=[rawKey copy];NSUInteger maximum=operation_blob_limit(name);id value=source[rawKey];
        if(!maximum||![value isKindOfClass:[NSData class]])return nil;
        NSUInteger length=[value length];
        if(!length||length>maximum||length>64u*1024u*1024u-total)return nil;
        [entries addObject:@[name,value,@(length)]];total+=length;
    }
    for(NSArray *entry in entries){
        NSString *name=entry[0];NSData *value=entry[1];NSUInteger length=[entry[2] unsignedIntegerValue];
        if(value.length!=length)return nil;
        /* NSData wrappers may borrow an mmap slot: force an actual owned copy,
         * even when the wrapper's Objective-C interface is immutable. */
        NSData *data=[[NSData alloc]initWithBytes:value.bytes length:length];if(!data||value.length!=length)return nil;
        if([name hasPrefix:@"pass-lib-"]){unsigned char digest[CC_SHA256_DIGEST_LENGTH];char text[65];
            CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
            for(unsigned i=0;i<32;++i)snprintf(text+2*i,3,"%02x",digest[i]);
            if(![name isEqualToString:[NSString stringWithFormat:@"pass-lib-%s.metallib",text]])return nil;}
        result[name]=data;
    }
    return [result copy];
}

#if !__has_feature(objc_arc)
#error native_frame_operations.m requires ARC
#endif
@interface FFSTNativeFrameOperations ()
@property(nonatomic,readwrite,strong) NSArray<NSDictionary *> *operations;
@property(nonatomic,readwrite,strong) NSDictionary<NSNumber *,NSData *> *bufferImports;
@property(nonatomic,readwrite,strong) NSDictionary<NSNumber *,NSDictionary *> *textureImports;
@property(nonatomic,readwrite) uint64_t importedBytes;
@end
@implementation FFSTNativeFrameOperations @end

typedef struct {
    uint64_t kind,root,view,generation,input,output,payload,offset,length,base,capacity;
    uint64_t format,width,height,mips,type,slices;
} FFSTOperationReference;
static BOOL operation_fail(NSString **failure,NSString *reason) {
    if(failure)*failure=reason;return NO;
}
/* Do not round pointer-free 64-bit identities through NSNumber.doubleValue. */
static BOOL operation_u64(id object,uint64_t maximum,uint64_t *out) {return ffst_value_u64(object,maximum,out);}
static BOOL operation_array(id object,NSUInteger maximum) {
    return [object isKindOfClass:[NSArray class]]&&[object count]<=maximum;
}
static BOOL operation_record(id object) {return [object isKindOfClass:[NSDictionary class]];}
static BOOL operation_keys(NSDictionary *record,NSArray<NSString *> *keys) {
    if(!operation_record(record)||record.count!=keys.count)return NO;
    for(id key in record)if(![key isKindOfClass:[NSString class]]||![keys containsObject:key])return NO;
    return YES;
}
static BOOL operation_string(id object,NSString *expected) {
    return [object isKindOfClass:[NSString class]]&&[object isEqualToString:expected];
}
static BOOL operation_empty(id object) {return !object||(operation_array(object,0)&&[object count]==0);}
static BOOL operation_stable(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_size==b->st_size&&
        a->st_mode==b->st_mode&&a->st_uid==b->st_uid&&a->st_nlink==b->st_nlink&&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
typedef struct { int directory; NSDictionary<NSString *,NSData *> *__strong blobs; } FFSTOperationSource;
static NSData *operation_read_private(int directory,const char *name,size_t length) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);if(fd<0)return nil;
    struct stat before,after;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_uid!=getuid()||before.st_nlink!=1||
        (before.st_mode&07777)!=0600||before.st_size<=0||(uint64_t)before.st_size!=length){close(fd);return nil;}
    uint8_t *bytes=malloc(length);if(!bytes){close(fd);return nil;}
    BOOL valid=YES;size_t consumed=0;
    while(consumed<length){ssize_t n=read(fd,bytes+consumed,length-consumed);
        if(n<0&&errno==EINTR)continue;if(n<=0){valid=NO;break;}consumed+=(size_t)n;}
    uint8_t extra;ssize_t tail;do{tail=read(fd,&extra,1);}while(tail<0&&errno==EINTR);
    if(tail||fstat(fd,&after)||!operation_stable(&before,&after))valid=NO;
    if(close(fd))valid=NO;
    if(!valid){free(bytes);return nil;}
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}
static NSData *operation_read(FFSTOperationSource source,const char *name,size_t length) {
    if(source.blobs){NSData *data=source.blobs[@(name)];
        return [data isKindOfClass:[NSData class]]&&data.length==length?data:nil;}
    return operation_read_private(source.directory,name,length);
}
static BOOL operation_reference(NSDictionary *r,FFSTOperationReference *out) {
    if(!operation_record(r)||!operation_u64(r[@"kind"],FFS_TEXTURE,&out->kind)||!out->kind||
        !operation_u64(r[@"root"],UINT64_MAX,&out->root)||!out->root||
        !operation_u64(r[@"view"],UINT64_MAX,&out->view)||!out->view||
        !operation_u64(r[@"allocation_generation"],UINT64_MAX,&out->generation)||!out->generation||
        !operation_u64(r[@"input_content_version"],UINT64_MAX-1,&out->input)||!out->input||
        !operation_u64(r[@"output_content_version"],UINT64_MAX,&out->output)||
        (out->output!=out->input&&out->output!=out->input+1)||
        !operation_u64(r[@"payload_id"],UINT64_MAX,&out->payload)||!out->payload||
        !operation_u64(r[@"offset"],UINT64_MAX,&out->offset)||
        !operation_u64(r[@"length"],UINT64_MAX-out->offset,&out->length))return NO;
    if(out->kind==FFS_TEXTURE){uint64_t value;
        if(!operation_u64(r[@"format"],UINT32_MAX,&out->format)||!ff_texture_pixel_size((uint32_t)out->format)||
           !operation_u64(r[@"width"],8192,&out->width)||!out->width||
           !operation_u64(r[@"height"],8192,&out->height)||!out->height||
           !operation_u64(r[@"mip_count"],14,&out->mips)||!out->mips||
           out->mips>32-(uint32_t)__builtin_clz((uint32_t)MAX(out->width,out->height)))return NO;
        if(!operation_u64(r[@"type"],MTLTextureTypeCube,&out->type)||
           (out->type!=MTLTextureType2D&&out->type!=MTLTextureTypeCube)||
           (out->type==MTLTextureTypeCube&&out->width!=out->height))return NO;
        out->slices=out->type==MTLTextureTypeCube?6:1;
        NSArray *keys=@[@"base_mip",@"base_slice",@"slice_count",@"array_length",@"sample_count"];
        const uint64_t values[]={0,0,out->slices,1,1};
        for(NSUInteger i=0;i<keys.count;++i)
            if(!operation_u64(r[keys[i]],UINT32_MAX,&value)||value!=values[i])return NO;
        NSArray *swizzle=r[@"swizzle"];
        const uint64_t channels[]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
        if(!operation_array(swizzle,4)||swizzle.count!=4)return NO;
        for(unsigned i=0;i<4;++i)
            if(!operation_u64(swizzle[i],MTLTextureSwizzleAlpha,&value)||value!=channels[i])return NO;
        return YES;
    }
    if(!out->length||!operation_u64(r[@"buffer_base_offset"],UINT64_MAX,&out->base)||
        !operation_u64(r[@"buffer_length"],FFST_OPERATION_BUFFER_BYTES,&out->capacity)||!out->capacity||
        out->base>UINT64_MAX-out->capacity||out->offset<out->base)return NO;
    uint64_t relative=out->offset-out->base;
    return relative<=out->capacity&&out->length<=out->capacity-relative;
}
static BOOL operation_header(NSDictionary *bindings,uint64_t *category,NSString **failure) {
    uint64_t version;
    if(!operation_record(bindings)||!operation_string(bindings[@"format"],@"bedrock-native-frame-operation")||
        !operation_u64(bindings[@"version"],1,&version)||version!=1||
        !operation_u64(bindings[@"category"],FFS_CATEGORY_COUNT-1,category)||
        (*category!=FFS_BLIT&&*category!=FFS_TIMESTAMP&&*category!=FFS_SIGNAL_EVENT))
        return operation_fail(failure,@"Unsupported native frame operation header");
    /* The engine owns exact ledger equality. Present identities must nevertheless
     * remain exact integers here; missing identities are not manufactured. */
    for(NSString *key in @[@"stream",@"frame",@"chunk",@"payload_id"]){uint64_t value;
        if(bindings[key]&&(!operation_u64(bindings[key],UINT64_MAX,&value)||!value))
            return operation_fail(failure,@"Invalid native frame operation identity");}
    uint64_t encoder;
    if(bindings[@"encoder"]&&!operation_u64(bindings[@"encoder"],UINT32_MAX,&encoder))
        return operation_fail(failure,@"Invalid native frame encoder identity");
    if(!operation_array(bindings[@"operations"],FFS_MAX_COMMANDS))
        return operation_fail(failure,@"Invalid native frame operation array");
    return YES;
}
static BOOL operation_blit(FFSTOperationSource source,NSDictionary *bindings,uint64_t budget,
    FFSTNativeFrameOperations *decoded,NSString **failure) {
    NSArray *resources=bindings[@"resources"],*types=bindings[@"command_types"],*commands=bindings[@"operations"];
    NSArray *imports=bindings[@"buffers"] ?: @[],*textureEntries=bindings[@"textures"] ?: @[];
    if(!operation_array(resources,FFS_MAX_RESOURCES)||!operation_array(types,FFS_MAX_COMMANDS)||types.count!=commands.count||
        !operation_array(imports,FFS_MAX_RESOURCES)||!operation_array(textureEntries,FFS_MAX_RESOURCES))
        return operation_fail(failure,@"Invalid blit resource or command counts");
    NSMutableData *storage=[NSMutableData dataWithLength:resources.count*sizeof(FFSTOperationReference)];
    if(!storage)return operation_fail(failure,@"Cannot allocate bounded blit metadata");
    FFSTOperationReference *refs=storage.mutableBytes;
    NSMutableDictionary<NSString *,NSValue *> *roots=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *,NSValue *> *views=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<resources.count;++i){
        if(!operation_reference(resources[i],&refs[i]))return operation_fail(failure,@"Invalid blit resource reference or shape");
        FFSTOperationReference r=refs[i];
        NSString *root=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)r.kind,(unsigned long long)r.root,(unsigned long long)r.generation];
        FFSTOperationReference prior;
        if(roots[root]){[roots[root]getValue:&prior size:sizeof(prior)];
            if(prior.base!=r.base||prior.capacity!=r.capacity||prior.format!=r.format||prior.width!=r.width||
               prior.height!=r.height||prior.mips!=r.mips||prior.type!=r.type||prior.slices!=r.slices||prior.input!=r.input)
                return operation_fail(failure,@"Aliased blit root has inconsistent shape or version");}
        else roots[root]=[NSValue valueWithBytes:&r objCType:@encode(FFSTOperationReference)];
        NSString *view=[root stringByAppendingFormat:@":%llu",(unsigned long long)r.view];
        if(views[view]){[views[view]getValue:&prior size:sizeof(prior)];
            if(prior.offset!=r.offset||prior.length!=r.length)return operation_fail(failure,@"Aliased blit view has inconsistent bounds");}
        else views[view]=[NSValue valueWithBytes:&r objCType:@encode(FFSTOperationReference)];
    }
    NSMutableArray<NSDictionary *> *operations=[NSMutableArray arrayWithCapacity:commands.count];
    for(NSUInteger i=0;i<commands.count;++i){
        uint64_t type;NSDictionary *command=commands[i];
        if(!operation_u64(types[i],4,&type))return operation_fail(failure,@"Unsupported blit command type");
        if(!type){
            if(!operation_keys(command,@[@"op"])||!operation_string(command[@"op"],@"nop"))
                return operation_fail(failure,@"Blit Nop payload does not match command order");
            [operations addObject:@{@"op":@"nop"}];continue;
        }
        if(type==4){
            uint64_t src,dst,sourceSlice,sourceLevel,destinationSlice,destinationLevel,size[3],from[3],to[3];
            if(!operation_keys(command,@[@"op",@"source_resource",@"destination_resource",@"source_slice",@"source_level",
                @"source_origin",@"source_size",@"destination_slice",@"destination_level",@"destination_origin"])||
               !operation_string(command[@"op"],@"copy_texture_to_texture")||!resources.count||
               !operation_u64(command[@"source_resource"],resources.count-1,&src)||refs[src].kind!=FFS_TEXTURE||
               !operation_u64(command[@"destination_resource"],resources.count-1,&dst)||refs[dst].kind!=FFS_TEXTURE||
               refs[src].format!=refs[dst].format||
               !operation_u64(command[@"source_slice"],refs[src].slices-1,&sourceSlice)||
               !operation_u64(command[@"destination_slice"],refs[dst].slices-1,&destinationSlice)||
               !operation_u64(command[@"source_level"],refs[src].mips-1,&sourceLevel)||
               !operation_u64(command[@"destination_level"],refs[dst].mips-1,&destinationLevel))
                return operation_fail(failure,@"Invalid texture-to-texture resource, format or subresource");
            for(NSString *key in @[@"source_origin",@"destination_origin",@"source_size"])
                if(!operation_array(command[key],3)||[command[key] count]!=3)return operation_fail(failure,@"Invalid texture-to-texture coordinates");
            for(unsigned axis=0;axis<3;++axis)
                if(!operation_u64(command[@"source_origin"][axis],8192,&from[axis])||
                   !operation_u64(command[@"destination_origin"][axis],8192,&to[axis])||
                   !operation_u64(command[@"source_size"][axis],8192,&size[axis]))
                    return operation_fail(failure,@"Invalid texture-to-texture coordinate value");
            uint64_t sourceWidth=MAX(UINT64_C(1),refs[src].width>>sourceLevel),sourceHeight=MAX(UINT64_C(1),refs[src].height>>sourceLevel),
                destinationWidth=MAX(UINT64_C(1),refs[dst].width>>destinationLevel),destinationHeight=MAX(UINT64_C(1),refs[dst].height>>destinationLevel);
            if(!size[0]||!size[1]||size[2]!=1||from[2]||to[2]||from[0]>sourceWidth||size[0]>sourceWidth-from[0]||
               from[1]>sourceHeight||size[1]>sourceHeight-from[1]||to[0]>destinationWidth||size[0]>destinationWidth-to[0]||
               to[1]>destinationHeight||size[1]>destinationHeight-to[1])return operation_fail(failure,@"Texture-to-texture extent exceeds its mip");
            if(refs[src].root==refs[dst].root&&refs[src].generation==refs[dst].generation)
                return operation_fail(failure,@"Same-root texture copy is unsupported");
            [operations addObject:@{@"op":@"copy_texture_to_texture",@"source_resource":@(src),@"destination_resource":@(dst),
                @"source_slice":@(sourceSlice),@"source_level":@(sourceLevel),@"source_origin":@[@(from[0]),@(from[1]),@(from[2])],
                @"source_size":@[@(size[0]),@(size[1]),@(size[2])],@"destination_slice":@(destinationSlice),
                @"destination_level":@(destinationLevel),@"destination_origin":@[@(to[0]),@(to[1]),@(to[2])]}];continue;
        }
        if(type==2){
            uint64_t src,dst,offset,row,image,slice,level,size[3],origin[3];
            if(!operation_keys(command,@[@"op",@"source_resource",@"destination_resource",@"source_offset",@"source_bytes_per_row",
                @"source_bytes_per_image",@"source_size",@"destination_slice",@"destination_level",@"destination_origin"])||
               !operation_string(command[@"op"],@"copy_buffer_to_texture")||!resources.count||
               !operation_u64(command[@"source_resource"],resources.count-1,&src)||refs[src].kind!=FFS_BUFFER||
               !operation_u64(command[@"destination_resource"],resources.count-1,&dst)||refs[dst].kind!=FFS_TEXTURE||refs[dst].type!=MTLTextureType2D||
               !operation_u64(command[@"source_offset"],refs[src].length,&offset)||
               !operation_u64(command[@"source_bytes_per_row"],UINT32_MAX,&row)||!row||
               !operation_u64(command[@"source_bytes_per_image"],UINT32_MAX,&image)||
               !operation_u64(command[@"destination_slice"],0,&slice)||
               !operation_u64(command[@"destination_level"],refs[dst].mips-1,&level)||
               !operation_array(command[@"source_size"],3)||[command[@"source_size"] count]!=3||
               !operation_array(command[@"destination_origin"],3)||[command[@"destination_origin"] count]!=3)
                return operation_fail(failure,@"Invalid buffer-to-texture command fields");
            for(unsigned axis=0;axis<3;++axis)
                if(!operation_u64(command[@"source_size"][axis],8192,&size[axis])||
                   !operation_u64(command[@"destination_origin"][axis],8192,&origin[axis]))
                    return operation_fail(failure,@"Invalid buffer-to-texture coordinates");
            uint64_t width=MAX(UINT64_C(1),refs[dst].width>>level),height=MAX(UINT64_C(1),refs[dst].height>>level);
            uint64_t pixel=ff_texture_pixel_size((uint32_t)refs[dst].format),tight=size[0]*pixel;
            if(!size[0]||!size[1]||size[2]!=1||origin[2]||origin[0]>width||size[0]>width-origin[0]||
               origin[1]>height||size[1]>height-origin[1]||row<tight||row%pixel||
               (refs[src].offset-refs[src].base+offset)%pixel||
               (image&&(image<row*size[1]||image%pixel)))
                return operation_fail(failure,@"Unsupported buffer-to-texture extent or pitch");
            uint64_t footprint=(size[1]-1)*row+tight;
            if(footprint>refs[src].length-offset)
                return operation_fail(failure,@"Buffer-to-texture source footprint exceeds its view");
            [operations addObject:@{@"op":@"copy_buffer_to_texture",@"source_resource":@(src),@"destination_resource":@(dst),
                @"source_offset":@(offset),@"source_bytes_per_row":@(row),@"source_bytes_per_image":@(image),
                @"source_size":@[@(size[0]),@(size[1]),@(size[2])],@"destination_slice":@(slice),@"destination_level":@(level),
                @"destination_origin":@[@(origin[0]),@(origin[1]),@(origin[2])]}];continue;
        }
        if(type==3){
            uint64_t src,dst,offset,row,image,slice,level,size[3],origin[3];
            if(!operation_keys(command,@[@"op",@"source_resource",@"destination_resource",@"source_slice",@"source_level",
                @"source_origin",@"source_size",@"destination_offset",@"destination_bytes_per_row",@"destination_bytes_per_image"])||
               !operation_string(command[@"op"],@"copy_texture_to_buffer")||!resources.count||
               !operation_u64(command[@"source_resource"],resources.count-1,&src)||refs[src].kind!=FFS_TEXTURE||refs[src].type!=MTLTextureType2D||
               !operation_u64(command[@"destination_resource"],resources.count-1,&dst)||refs[dst].kind!=FFS_BUFFER||
               !operation_u64(command[@"source_slice"],0,&slice)||
               !operation_u64(command[@"source_level"],refs[src].mips-1,&level)||
               !operation_u64(command[@"destination_offset"],refs[dst].length,&offset)||
               !operation_u64(command[@"destination_bytes_per_row"],UINT32_MAX,&row)||!row||
               !operation_u64(command[@"destination_bytes_per_image"],UINT32_MAX,&image)||
               !operation_array(command[@"source_size"],3)||[command[@"source_size"] count]!=3||
               !operation_array(command[@"source_origin"],3)||[command[@"source_origin"] count]!=3)
                return operation_fail(failure,@"Invalid texture-to-buffer command fields");
            for(unsigned axis=0;axis<3;++axis)
                if(!operation_u64(command[@"source_size"][axis],8192,&size[axis])||
                   !operation_u64(command[@"source_origin"][axis],8192,&origin[axis]))
                    return operation_fail(failure,@"Invalid texture-to-buffer coordinates");
            uint64_t width=MAX(UINT64_C(1),refs[src].width>>level),height=MAX(UINT64_C(1),refs[src].height>>level);
            uint64_t pixel=ff_texture_pixel_size((uint32_t)refs[src].format),tight=size[0]*pixel;
            if(!size[0]||!size[1]||size[2]!=1||origin[2]||origin[0]>width||size[0]>width-origin[0]||
               origin[1]>height||size[1]>height-origin[1]||row<tight||row%pixel||
               (refs[dst].offset-refs[dst].base+offset)%pixel||
               ((refs[dst].offset-refs[dst].base+offset)&3)||(row&3)||(tight&3)||
               (image&&(image<row*size[1]||image%pixel)))
                return operation_fail(failure,@"Unsupported texture-to-buffer extent or pitch");
            uint64_t footprint=(size[1]-1)*row+tight;
            if(footprint>refs[dst].length-offset)
                return operation_fail(failure,@"Texture-to-buffer destination footprint exceeds its view");
            [operations addObject:@{@"op":@"copy_texture_to_buffer",@"source_resource":@(src),@"destination_resource":@(dst),
                @"source_slice":@(slice),@"source_level":@(level),@"source_origin":@[@(origin[0]),@(origin[1]),@(origin[2])],
                @"source_size":@[@(size[0]),@(size[1]),@(size[2])],@"destination_offset":@(offset),
                @"destination_bytes_per_row":@(row),@"destination_bytes_per_image":@(image)}];continue;
        }
        uint64_t source,destination,sourceOffset,destinationOffset,length;
        if(!operation_keys(command,@[@"op",@"source_resource",@"destination_resource",@"source_offset",@"destination_offset",@"length"])||
            !operation_string(command[@"op"],@"copy_buffer")||!resources.count||
            !operation_u64(command[@"source_resource"],resources.count-1,&source)||
            !operation_u64(command[@"destination_resource"],resources.count-1,&destination)||
            refs[source].kind!=FFS_BUFFER||refs[destination].kind!=FFS_BUFFER||
            !operation_u64(command[@"source_offset"],refs[source].length,&sourceOffset)||
            !operation_u64(command[@"destination_offset"],refs[destination].length,&destinationOffset)||
            !operation_u64(command[@"length"],FFST_OPERATION_BUFFER_BYTES,&length)||!length||
            length>refs[source].length-sourceOffset||length>refs[destination].length-destinationOffset)
            return operation_fail(failure,@"Invalid buffer-copy payload or view-relative range");
        uint64_t sourceStart=refs[source].offset+sourceOffset,destinationStart=refs[destination].offset+destinationOffset;
        if(refs[source].root==refs[destination].root&&refs[source].generation==refs[destination].generation&&
            sourceStart<destinationStart+length&&destinationStart<sourceStart+length)
            return operation_fail(failure,@"Overlapping same-root buffer copy is unsupported");
        [operations addObject:@{@"op":@"copy_buffer",@"source_resource":@(source),@"destination_resource":@(destination),
            @"source_offset":@(sourceOffset),@"destination_offset":@(destinationOffset),@"length":@(length)}];
    }
    NSMutableDictionary<NSNumber *,NSData *> *buffers=[NSMutableDictionary dictionary];uint64_t total=0;
    for(NSUInteger i=0;i<imports.count;++i){
        NSDictionary *entry=imports[i];uint64_t resource,bytes;
        if(!operation_keys(entry,@[@"resource",@"file",@"bytes"])||!resources.count||
            !operation_u64(entry[@"resource"],resources.count-1,&resource)||buffers[@(resource)]||
            refs[resource].kind!=FFS_BUFFER||
            !operation_u64(entry[@"bytes"],FFST_OPERATION_BUFFER_BYTES,&bytes)||bytes!=refs[resource].length||
            bytes>budget-total)return operation_fail(failure,@"Invalid buffer import identity, size or byte budget");
        char name[64];snprintf(name,sizeof(name),"operation-buffer-%02u.bin",(unsigned)(i+1));
        if(!operation_string(entry[@"file"],@(name)))return operation_fail(failure,@"Invalid sequential operation buffer filename");
        NSData *data=operation_read(source,name,(size_t)bytes);
        if(!data)return operation_fail(failure,@"Operation buffer is missing, unsafe or changed while reading");
        buffers[@(resource)]=data;total+=bytes;
    }
    NSMutableDictionary<NSNumber *,NSDictionary *> *textures=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *,NSData *> *textureRootBytes=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<textureEntries.count;++i){
        NSDictionary *entry=textureEntries[i];uint64_t resource,length,value;
        if(!operation_keys(entry,@[@"resource",@"file",@"length",@"format",@"texture_type",@"width",@"height",@"mip_count",@"array_length",@"swizzle",@"planes"])||
           !resources.count||!operation_u64(entry[@"resource"],resources.count-1,&resource)||textures[@(resource)]||
           refs[resource].kind!=FFS_TEXTURE||!operation_u64(entry[@"length"],FF_TEXTURE_BYTES_LIMIT,&length)||!length||length>budget-total)
            return operation_fail(failure,@"Invalid texture import identity or byte budget");
        FFSTOperationReference ref=refs[resource];
        NSArray *keys=@[@"format",@"texture_type",@"width",@"height",@"mip_count",@"array_length"];
        const uint64_t expected[]={ref.format,ref.type,ref.width,ref.height,ref.mips,1};
        NSMutableDictionary *metadata=[NSMutableDictionary dictionaryWithDictionary:@{@"resource":@(resource),@"length":@(length)}];
        for(NSUInteger k=0;k<keys.count;++k){
            if(!operation_u64(entry[keys[k]],UINT32_MAX,&value)||value!=expected[k])
                return operation_fail(failure,@"Texture import shape differs from resource");
            metadata[keys[k]]=@(value);
        }
        NSArray *swizzle=entry[@"swizzle"],*planes=entry[@"planes"];
        if(!operation_array(swizzle,4)||swizzle.count!=4||!operation_array(planes,FF_TEXTURE_PLANE_LIMIT)||planes.count!=ref.mips*ref.slices)
            return operation_fail(failure,@"Invalid texture import subresource counts");
        const uint64_t channels[]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
        NSMutableArray *normalizedSwizzle=[NSMutableArray array],*normalizedPlanes=[NSMutableArray array];
        for(unsigned k=0;k<4;++k){
            if(!operation_u64(swizzle[k],MTLTextureSwizzleAlpha,&value)||value!=channels[k])
                return operation_fail(failure,@"Texture import swizzle differs from resource");
            [normalizedSwizzle addObject:@(value)];
        }
        uint64_t next=0,pixel=ff_texture_pixel_size((uint32_t)ref.format);
        for(NSUInteger k=0;k<planes.count;++k){
            NSDictionary *plane=planes[k];uint64_t mip,slice,offset,row,bytes;
            if(!operation_keys(plane,@[@"mip",@"slice",@"offset",@"row_bytes",@"length"])||
               !operation_u64(plane[@"mip"],ref.mips-1,&mip)||mip!=k%ref.mips||
               !operation_u64(plane[@"slice"],ref.slices-1,&slice)||slice!=k/ref.mips||
               !operation_u64(plane[@"offset"],length,&offset)||offset!=next||
               !operation_u64(plane[@"row_bytes"],FF_TEXTURE_BYTES_LIMIT,&row)||
               !operation_u64(plane[@"length"],length,&bytes))
                return operation_fail(failure,@"Invalid texture import plane");
            uint64_t width=MAX(UINT64_C(1),ref.width>>mip),height=MAX(UINT64_C(1),ref.height>>mip);
            if(row!=((width*pixel+255)&~UINT64_C(255))||bytes!=row*height||bytes>length-next)
                return operation_fail(failure,@"Texture import plane layout differs from canonical bytes");
            [normalizedPlanes addObject:@{@"mip":@(mip),@"slice":@(slice),@"offset":@(offset),@"row_bytes":@(row),@"length":@(bytes)}];next+=bytes;
        }
        if(next!=length)return operation_fail(failure,@"Texture import length differs from its planes");
        char name[64];snprintf(name,sizeof(name),"operation-texture-%02u.bin",(unsigned)(i+1));
        if(!operation_string(entry[@"file"],@(name)))return operation_fail(failure,@"Invalid sequential texture import filename");
        NSData *data=operation_read(source,name,(size_t)length);if(!data)return operation_fail(failure,@"Texture import is missing, unsafe or changed");
        /* Full canonical preimages describe the same root contents even when
         * different resource indices or view IDs supplied them. */
        NSString *rootKey=[NSString stringWithFormat:@"%llu:%llu:%llu:%llu",(unsigned long long)ref.kind,
            (unsigned long long)ref.root,(unsigned long long)ref.generation,(unsigned long long)ref.input];
        NSData *prior=textureRootBytes[rootKey];
        if(prior&&![prior isEqualToData:data])return operation_fail(failure,@"Aliased texture preimages contradict the same input version");
        if(!prior)textureRootBytes[rootKey]=data;
        metadata[@"file"]=@(name);metadata[@"swizzle"]=[normalizedSwizzle copy];metadata[@"planes"]=[normalizedPlanes copy];
        textures[@(resource)]=@{@"metadata":[metadata copy],@"bytes":data};total+=length;
    }
    decoded.operations=[operations copy];decoded.bufferImports=[buffers copy];decoded.textureImports=[textures copy];decoded.importedBytes=total;return YES;
}
static BOOL operation_scalar(NSDictionary *bindings,uint64_t category,FFSTNativeFrameOperations *decoded,NSString **failure) {
    NSArray *commands=bindings[@"operations"];
    if(commands.count!=1||!operation_empty(bindings[@"resources"])||!operation_empty(bindings[@"command_types"])||
        !operation_empty(bindings[@"buffers"])||!operation_empty(bindings[@"textures"]))return operation_fail(failure,@"Scalar operation has unexpected resources, commands or imports");
    NSDictionary *command=commands[0],*normalized=nil;
    if(category==FFS_TIMESTAMP){uint64_t index,count;
        if(!operation_keys(command,@[@"op",@"mode",@"readback_index",@"query_count"])||
            !operation_string(command[@"op"],@"timestamp")||!operation_string(command[@"mode"],@"command-buffer-end-ns")||
            !operation_u64(command[@"query_count"],1000000,&count)||!count||
            !operation_u64(command[@"readback_index"],1000000,&index))return operation_fail(failure,@"Unsupported timestamp mode or query range");
        normalized=@{@"op":@"timestamp",@"mode":@"command-buffer-end-ns",@"readback_index":@(index),@"query_count":@(count)};
    }else{uint64_t domain,identifier,value;
        if(!operation_keys(command,@[@"op",@"domain",@"id",@"value"])||!operation_string(command[@"op"],@"signal_event")||
            !operation_u64(command[@"domain"],FFS_EVENT,&domain)||domain!=FFS_EVENT||
            !operation_u64(command[@"id"],UINT64_MAX,&identifier)||!identifier||
            !operation_u64(command[@"value"],UINT64_MAX,&value)||!value)return operation_fail(failure,@"Unsupported signal-event identity or value");
        normalized=@{@"op":@"signal_event",@"domain":@(domain),@"id":@(identifier),@"value":@(value)};
    }
    decoded.operations=@[normalized];decoded.bufferImports=@{};decoded.textureImports=@{};decoded.importedBytes=0;return YES;
}
static FFSTNativeFrameOperations *operation_load_source(FFSTOperationSource source,NSDictionary *bindings,uint64_t maxBytes,NSString **failure) {
    if(failure)*failure=nil;
    @try{
        struct stat status;uint64_t category;
        BOOL validSource=source.blobs!=nil||(source.directory>=0&&!fstat(source.directory,&status)&&
            S_ISDIR(status.st_mode)&&status.st_uid==getuid()&&!(status.st_mode&077));
        if(!validSource){
            operation_fail(failure,@"Operation payload directory is not private and owned");return nil;}
        if(!operation_header(bindings,&category,failure))return nil;
        FFSTNativeFrameOperations *decoded=[FFSTNativeFrameOperations new];
        BOOL valid=category==FFS_BLIT?operation_blit(source,bindings,MIN(maxBytes,FFST_OPERATION_IMPORT_BYTES),decoded,failure):
            operation_scalar(bindings,category,decoded,failure);
        return valid?decoded:nil;
    }@catch(NSException *exception){(void)exception;operation_fail(failure,@"Malformed native operation payload");return nil;}
}

FFSTNativeFrameOperations *ffst_native_frame_operations_load(int directory,NSDictionary *bindings,uint64_t maxBytes,NSString **failure) {
    return operation_load_source((FFSTOperationSource){directory,nil},bindings,maxBytes,failure);
}
FFSTNativeFrameOperations *ffst_native_frame_operations_load_blobs(NSDictionary<NSString *,NSData *> *blobs,
    NSDictionary *bindings,uint64_t maxBytes,NSString **failure) {
    if(failure)*failure=nil;
    @try {
        NSDictionary *owned=operation_blob_snapshot(blobs);
        if(!owned){operation_fail(failure,@"Operation blobs exceed immutable name, hash or byte bounds");return nil;}
        return operation_load_source((FFSTOperationSource){-1,owned},bindings,maxBytes,failure);
    }@catch(__unused NSException *exception){operation_fail(failure,@"Malformed immutable operation blobs");return nil;}
}
FFSTNativeFrameOperations *ffst_native_frame_operations_load_owned(FFSTOwnedBlobs *owned,NSDictionary *bindings,uint64_t maxBytes,NSString **failure) {
    if(!ffst_owned_blob_bounds(owned,operation_blob_limit)||bindings!=[owned jsonDictionary:@"bindings.json"]){
        operation_fail(failure,@"Owned operation provenance or bounds differ");return nil;}
    return operation_load_source((FFSTOperationSource){-1,owned.blobs},bindings,maxBytes,failure);
}
