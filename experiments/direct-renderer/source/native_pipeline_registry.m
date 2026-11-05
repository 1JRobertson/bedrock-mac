#import "native_pipeline_registry.h"
#import "shader_bindings.h"

#if !__has_feature(objc_arc)
#error native_pipeline_registry.m requires ARC
#endif

@interface FFSTPipelineBinding ()
@property(nonatomic,readwrite,strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic,readwrite) ff_draw_layout layout;
@property(nonatomic,strong) NSArray<NSDictionary<NSNumber *,MTLTextureReferenceType *> *> *textureReferences;
@end
@implementation FFSTPipelineBinding
- (MTLTextureReferenceType *)textureReferenceForStage:(unsigned)stage offset:(uint32_t)offset {
    return stage<2?_textureReferences[stage][@(offset)]:nil;
}
@end

@interface FFSTPipelineRegistryEntry : NSObject
@property(nonatomic) uint64_t generation;
@property(nonatomic,strong) FFSTPipelineBinding *binding;
@end
@implementation FFSTPipelineRegistryEntry @end

@implementation FFSTPipelineRegistry {
    id<MTLDevice> _device;
    NSUInteger _maxObjects;
    NSMutableDictionary<NSNumber *,FFSTPipelineRegistryEntry *> *_entries;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device maxObjects:(NSUInteger)maxObjects {
    if(!device||!maxObjects)return nil;
    if((self=[super init])){_device=device;_maxObjects=maxObjects;_entries=[NSMutableDictionary dictionary];}
    return self;
}
- (BOOL)defineObject:(uint64_t)object generation:(uint64_t)generation
           pipeline:(id<MTLRenderPipelineState>)pipeline
         reflection:(MTLRenderPipelineReflection *)reflection iaMask:(uint32_t)iaMask {
    if(!object||!generation||!pipeline||pipeline.device.registryID!=_device.registryID)return NO;
    NSNumber *key=@(object);FFSTPipelineRegistryEntry *entry=_entries[key];
    if((entry&&(entry.binding||generation<=entry.generation))||(!entry&&_entries.count>=_maxObjects))return NO;
    ff_draw_layout layout;
    if(!ff_shader_layout(reflection,iaMask,&layout))return NO;
    NSMutableArray *references=[NSMutableArray arrayWithCapacity:2];
    NSArray *stages=@[reflection.vertexBindings,reflection.fragmentBindings];
    for(unsigned stage=0;stage<2;stage++){
        NSMutableDictionary *fields=[NSMutableDictionary dictionary];
        for(id<MTLBinding> binding in stages[stage])if(binding.isUsed&&binding.type==MTLBindingTypeBuffer&&binding.index==30){
            id<MTLBufferBinding> buffer=(id<MTLBufferBinding>)binding;
            for(MTLStructMember *member in buffer.bufferStructType.members)
                if(member.dataType==MTLDataTypeTexture)fields[@(member.offset)]=member.textureReferenceType;
        }
        [references addObject:[fields copy]];
    }
    FFSTPipelineBinding *binding=[FFSTPipelineBinding new];binding.pipeline=pipeline;binding.layout=layout;binding.textureReferences=[references copy];
    if(!entry){entry=[FFSTPipelineRegistryEntry new];_entries[key]=entry;}
    entry.generation=generation;entry.binding=binding;return YES;
}
- (FFSTPipelineBinding *)bindingForObject:(uint64_t)object generation:(uint64_t)generation {
    FFSTPipelineRegistryEntry *entry=_entries[@(object)];
    return object&&generation&&entry.generation==generation?entry.binding:nil;
}
- (BOOL)destroyObject:(uint64_t)object generation:(uint64_t)generation {
    FFSTPipelineRegistryEntry *entry=_entries[@(object)];
    if(!object||!generation||entry.generation!=generation||!entry.binding)return NO;
    entry.binding=nil;return YES;
}
@end
