/* CPU-only decoder fixture: no device enumeration, GPU work, IPC or game data. */
#import "shared_texture_pass_resources.h"
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(condition) do { ++checks; if (!(condition)) { fprintf(stderr, "decoder fixture failed line %u\n", __LINE__); return 1; } } while (0)
static NSDictionary *binding(uint64_t offset, uint32_t stride, uint32_t length) {
    return @{@"id":@1, @"generation":@1, @"offset":@(offset), @"stride":@(stride), @"length":@(length)};
}
static NSMutableDictionary *fixture_graph(void) {
    NSDictionary *draw = @{
        @"draw":@[@3,@0,@3,@2,@1], @"ia_slot_mask":@1, @"bindings":@[binding(0,4,64)],
        @"vertex_constants":@[binding(16,0,16)], @"fragment_constants":@[],
        @"arguments":@[@[
            @{@"offset":@0,@"kind":@1,@"value":@0,@"buffer":binding(8,0,8)},
            @{@"offset":@8,@"kind":@2,@"value":@1},
            @{@"offset":@16,@"kind":@3,@"value":@1},
            @{@"offset":@24,@"kind":@4,@"value":@(UINT64_MAX)}], @[]], @"argument_bytes":@[@32,@0]
    };
    NSMutableDictionary *indexed = [draw mutableCopy];
    indexed[@"indexed"] = @{@"index_type":@0,@"base_vertex":@(-2),@"index_count":@3,@"index_offset":@16};
    indexed[@"index_binding"] = binding(16,0,6);
    NSDictionary *graph = @{
        @"format":@"bedrock-draw-resource-cut",@"version":@1,@"cut_id":@"host-validates-this",
        @"snapshots":@[@{@"id":@1,@"generation":@1,@"file":@"cut-buffer-01.bin",@"length":@64,
            @"source_incarnation":@7,@"source_generation":@8,@"source_offset":@0}],
        @"textures":@[@{@"id":@1,@"file":@"cut-texture-01.bin",@"length":@512,
            @"format":@(MTLPixelFormatRGBA8Unorm),@"texture_type":@(MTLTextureType2D),
            @"width":@2,@"height":@2,@"mip_count":@1,@"array_length":@1,
            @"planes":@[@{@"mip":@0,@"slice":@0,@"offset":@0,@"row_bytes":@256,@"length":@512}]}],
        @"samplers":@[@{@"id":@1,@"address":@[@0,@0,@0],@"min_filter":@1,@"mag_filter":@1,
            @"mip_filter":@0,@"compare":@7,@"border":@0,@"max_anisotropy":@1,
            @"lod_min":@0,@"lod_max":@16,@"normalized":@1,@"lod_average":@0}],
        @"draws":@[draw,indexed]
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:graph options:0 error:nil];
    return json ? [NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingMutableContainers error:nil] : nil;
}
static ff_draw_layout layout(void) {
    ff_draw_layout l = {0}; l.ia_slot_mask = 1; l.constant_count[0] = 1;
    l.arguments[0].byte_length = 32; l.arguments[0].field_count = 4;
    /* Reflection need not list fields in serialized offset order. */
    l.arguments[0].fields[0] = (ff_shader_field){24,FF_FIELD_VALUE};
    l.arguments[0].fields[1] = (ff_shader_field){0,FF_FIELD_BUFFER};
    l.arguments[0].fields[2] = (ff_shader_field){16,FF_FIELD_SAMPLER};
    l.arguments[0].fields[3] = (ff_shader_field){8,FF_FIELD_TEXTURE}; return l;
}
static BOOL rejected(int dir, void (^mutate)(NSMutableDictionary *)) {
    NSMutableDictionary *g = fixture_graph(); mutate(g);
    FFSTPassResources r = ffst_pass_resources_load(dir,g); BOOL bad = r == NULL;
    ffst_pass_resources_destroy(r); return bad;
}
static NSMutableDictionary *cube_graph(void) {
    NSMutableDictionary *g = fixture_graph(), *t = g[@"textures"][0];
    t[@"texture_type"] = @(MTLTextureTypeCube); t[@"mip_count"] = @2; t[@"length"] = @4608;
    NSMutableArray *planes = [NSMutableArray array];
    for (unsigned face=0;face<6;++face) for (unsigned mip=0;mip<2;++mip)
        [planes addObject:[@{@"mip":@(mip),@"slice":@(face),@"offset":@(face*768+mip*512),
            @"row_bytes":@256,@"length":@(mip?256:512)} mutableCopy]];
    t[@"planes"] = planes; return g;
}
static BOOL rejected_cube(int dir, void (^mutate)(NSMutableDictionary *)) {
    NSMutableDictionary *g = cube_graph(); mutate(g);
    FFSTPassResources r = ffst_pass_resources_load(dir,g); BOOL bad = r == NULL;
    ffst_pass_resources_destroy(r); return bad;
}
static BOOL write_bytes(int dir, const char *name, const void *bytes, size_t length) {
    int fd = openat(dir,name,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600); if (fd < 0) return NO;
    BOOL ok = write(fd,bytes,length) == (ssize_t)length; if (close(fd)) ok = NO; return ok;
}
static int run(int dir) {
    uint8_t buffer[64], texture[512];
    for (unsigned i = 0; i < sizeof(buffer); ++i) buffer[i] = (uint8_t)(i ^ 0x5a);
    memset(texture,0x7b,sizeof(texture));
    CHECK(write_bytes(dir,"cut-buffer-01.bin",buffer,sizeof(buffer)));
    CHECK(write_bytes(dir,"cut-texture-01.bin",texture,sizeof(texture)));
    FFSTPassResources resources = NULL;
    @autoreleasepool { resources = ffst_pass_resources_load(dir,fixture_graph()); }
    CHECK(resources != NULL); CHECK(ffst_pass_resources_draw_count(resources) == 2);
    size_t ns = 0, nt = 0, nsa = 0;
    const ff_vertex_snapshot *snapshots = ffst_pass_resources_snapshots(resources,&ns);
    const ff_texture_snapshot *textures = ffst_pass_resources_textures(resources,&nt);
    const ff_sampler_snapshot *samplers = ffst_pass_resources_samplers(resources,&nsa);
    CHECK(ns == 1 && nt == 1 && nsa == 1 && snapshots && textures && samplers);
    CHECK(!memcmp(snapshots[0].bytes,buffer,sizeof(buffer)) && !memcmp(textures[0].bytes,texture,sizeof(texture)));
    CHECK(snapshots[0].generation == 1 && textures[0].planes[0].row_bytes == 256 && samplers[0].lod_max == 16 && !textures[0].has_swizzle);
    ff_draw_layout expected = layout(); ff_draw_bindings first, second;
    CHECK(ffst_pass_resources_draw_bindings(resources,0,&expected,&first));
    CHECK(ffst_pass_resources_draw_bindings(resources,1,&expected,&second));
    CHECK(first.textures == second.textures && first.samplers == second.samplers && first.textures == textures);
    CHECK(first.argument_count[0] == 4 && first.arguments[0][3].value == UINT64_MAX);
    CHECK(first.vertices[0].length == 64 && first.constants[0][0].offset == 16 && !first.index);
    CHECK(second.index && second.index->offset == 16 && second.index->length == 6);
    FFSTPassDrawInfo info;
    CHECK(ffst_pass_resources_draw_info(resources,1,&info) && info.indexed && info.base_vertex == -2 && info.index_count == 3 && info.instances == 2);
    ff_draw_bindings zero = {0}, out; memset(&out,0xa5,sizeof(out));
    CHECK(!ffst_pass_resources_draw_bindings(resources,2,&expected,&out) && !memcmp(&out,&zero,sizeof(out)));
    expected.ia_slot_mask = 3; CHECK(!ffst_pass_resources_draw_bindings(resources,0,&expected,&out)); expected = layout();
    expected.constant_count[0] = 0; CHECK(!ffst_pass_resources_draw_bindings(resources,0,&expected,&out)); expected = layout();
    expected.arguments[0].fields[0].kind = FF_FIELD_BUFFER; CHECK(!ffst_pass_resources_draw_bindings(resources,0,&expected,&out)); expected = layout();
    expected.arguments[0].fields[0].offset = 8; CHECK(!ffst_pass_resources_draw_bindings(resources,0,&expected,&out));
    ffst_pass_resources_destroy(resources);
    NSMutableDictionary *v2 = fixture_graph(); v2[@"version"] = @2;
    resources = ffst_pass_resources_load(dir,v2); CHECK(resources != NULL); ffst_pass_resources_destroy(resources);
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"version"]=@3;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"version"]=@YES;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"]=@[];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){NSMutableArray *a=[NSMutableArray array]; for(unsigned i=0;i<257;++i)[a addObject:g[@"draws"][0]]; g[@"draws"]=a;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"snapshots"][0][@"id"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"snapshots"][0][@"generation"]=@0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"snapshots"][0][@"length"]=@(FF_VERTEX_BYTES_LIMIT+1ull);}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"snapshots"][0][@"file"]=@"../cut-buffer-01.bin";}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"snapshots"][0][@"length"]=@63;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"bindings"][0][@"generation"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"bindings"][0][@"offset"]=@63;g[@"draws"][0][@"bindings"][0][@"length"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"bindings"][0][@"id"]=@0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"ia_slot_mask"]=@3;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"draw"][2]=@0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"draw"][1]=@0.0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"draw"][3]=@1000001;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"draw"][0]=@5;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][1][@"indexed"][@"index_count"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][1][@"indexed"][@"base_vertex"]=@(INT64_C(2147483648));}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][1][@"indexed"][@"index_offset"]=@15;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][1][@"indexed"][@"index_offset"]=@18;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][1][@"index_binding"][@"length"]=@4;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"index_binding"]=binding(0,0,6);}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"arguments"][0][1][@"offset"]=@0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"arguments"][0][0][@"value"]=@1;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"arguments"][0][1][@"value"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"arguments"][0][2][@"value"]=@2;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"draws"][0][@"argument_bytes"][0]=@40;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"planes"][0][@"offset"]=@1;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"planes"][0][@"row_bytes"]=@512;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"format"]=@(MTLPixelFormatDepth32Float_Stencil8);}));
    NSMutableDictionary *swizzled=fixture_graph();
    swizzled[@"textures"][0][@"swizzle"]=@[@(MTLTextureSwizzleBlue),@(MTLTextureSwizzleGreen),@(MTLTextureSwizzleRed),@(MTLTextureSwizzleOne)];
    resources=ffst_pass_resources_load(dir,swizzled);CHECK(resources!=NULL);
    textures=ffst_pass_resources_textures(resources,&nt);
    CHECK(nt==1 && textures[0].has_swizzle==1 && textures[0].swizzle[0]==MTLTextureSwizzleBlue && textures[0].swizzle[3]==MTLTextureSwizzleOne);
    CHECK(!memcmp(textures[0].bytes,texture,sizeof(texture)));ffst_pass_resources_destroy(resources);
    swizzled[@"textures"][0][@"swizzle"]=@[@0,@0,@0,@0];
    resources=ffst_pass_resources_load(dir,swizzled);CHECK(resources!=NULL);
    textures=ffst_pass_resources_textures(resources,&nt);
    CHECK(textures[0].has_swizzle==1 && !textures[0].swizzle[0] && !textures[0].swizzle[3]);ffst_pass_resources_destroy(resources);
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=[NSNull null];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2,@3,@4];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2,@6];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2,@(-1)];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2,@YES];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"swizzle"]=@[@0,@1,@2,@3.0];}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"samplers"][0][@"max_anisotropy"]=@0;}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"samplers"][0][@"lod_max"]=@(NAN);}));
    CHECK(rejected(dir,^(NSMutableDictionary *g){g[@"samplers"][0][@"normalized"]=@2;}));
    /* Six distinct physical faces, each with two canonical mip planes. The
     * descriptor arrayLength remains 1 and must never become a six-layer array. */
    CHECK(renameat(dir,"cut-texture-01.bin",dir,"original-texture")==0);
    uint8_t cube[4608];
    for (unsigned face=0;face<6;++face) memset(cube+face*768,(int)(face+1),768);
    CHECK(write_bytes(dir,"cut-texture-01.bin",cube,sizeof(cube)));
    resources = ffst_pass_resources_load(dir,cube_graph()); CHECK(resources != NULL);
    textures = ffst_pass_resources_textures(resources,&nt);
    CHECK(nt==1 && textures[0].texture_type==MTLTextureTypeCube && textures[0].array_length==1 && textures[0].plane_count==12);
    CHECK(textures[0].planes[11].slice==5 && textures[0].planes[11].mip==1 && textures[0].planes[11].offset==4352);
    CHECK(!memcmp(textures[0].bytes,cube,sizeof(cube))); ffst_pass_resources_destroy(resources);
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"width"]=@4;}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"array_length"]=@2;}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"texture_type"]=@(MTLTextureTypeCubeArray);}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){[g[@"textures"][0][@"planes"] removeLastObject];}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"planes"][10][@"slice"]=@4;}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"planes"][10][@"slice"]=@6;}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){g[@"textures"][0][@"planes"][11][@"mip"]=@0;}));
    CHECK(rejected_cube(dir,^(NSMutableDictionary *g){[g[@"textures"][0][@"planes"] exchangeObjectAtIndex:0 withObjectAtIndex:2];}));
    CHECK(unlinkat(dir,"cut-texture-01.bin",0)==0);
    CHECK(renameat(dir,"original-texture",dir,"cut-texture-01.bin")==0);
    CHECK(fchmodat(dir,"cut-buffer-01.bin",0644,0)==0);
    CHECK(ffst_pass_resources_load(dir,fixture_graph())==NULL);
    CHECK(fchmodat(dir,"cut-buffer-01.bin",0600,0)==0);
    CHECK(linkat(dir,"cut-buffer-01.bin",dir,"extra-link",0)==0);
    CHECK(ffst_pass_resources_load(dir,fixture_graph())==NULL);
    CHECK(unlinkat(dir,"extra-link",0)==0);
    CHECK(renameat(dir,"cut-buffer-01.bin",dir,"original-buffer")==0);
    CHECK(symlinkat("original-buffer",dir,"cut-buffer-01.bin")==0);
    CHECK(ffst_pass_resources_load(dir,fixture_graph())==NULL);
    CHECK(unlinkat(dir,"cut-buffer-01.bin",0)==0);
    CHECK(mkfifoat(dir,"cut-buffer-01.bin",0600)==0);
    CHECK(ffst_pass_resources_load(dir,fixture_graph())==NULL);
    CHECK(unlinkat(dir,"cut-buffer-01.bin",0)==0);
    CHECK(renameat(dir,"original-buffer",dir,"cut-buffer-01.bin")==0);
    CHECK(fchmod(dir,0755)==0);
    CHECK(ffst_pass_resources_load(dir,fixture_graph())==NULL);
    CHECK(fchmod(dir,0700)==0);
    printf("{\"cpu_decoder_checks\":%u,\"gpu_calls\":0,\"status\":\"passed\"}\n",checks); return 0;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 2;
    int dir=open(argv[1],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); if(dir<0)return 2;
    int result=run(dir); close(dir); return result;
} }
