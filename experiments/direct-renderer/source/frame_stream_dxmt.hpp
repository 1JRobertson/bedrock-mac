#pragma once
/* Copied beside dxmt_context.hpp by the optional frame-stream preparation.
 * Include only after dxmt_context.hpp. Metadata never replaces original work. */
#include "frame_stream.h"
#include "frame_stream_private.h"
#include "frame_stream_lifetime.hpp"
#include "frame_stream_version_index.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>

namespace dxmt {

class FrameStreamWriter {
#ifdef FFS_WRITER_TEST
  friend struct FrameStreamWriterTest;
#endif
  struct Resource {
    uint64_t kind, root, view, generation, offset, length;
    uint32_t flags;
    obj_handle_t handle = 0;
    uint32_t role = 0;
    uint64_t buffer_base_offset = 0, buffer_length = 0;
  };
  struct RawBuffer {obj_handle_t handle;uint64_t base,length,root;};
  struct Event { WMT::Reference<WMT::Event> retained; uint64_t value; };
  struct Dependency { uint64_t domain, id, value, stage, action; uint32_t flags; };
  inline static std::atomic_uint64_t next_stream = {0};
  inline static std::atomic_uint64_t next_upload_slice = {0};
  uint64_t stream = ++next_stream, sequence = 1, target = 0, frame = 0, chunk = 0;
  uint64_t observed_frame = 0;
  uint64_t digest = UINT64_C(14695981039346656037), records = 0, chunks = 0;
  uint64_t encoders = 0, commands = 0, chunk_encoders = 0, chunk_commands = 0;
  uint64_t chunk_dependencies = 0;
  uint64_t command_count = 0, resource_count = 0, dependency_count = 0;
  uint64_t present_root = 0, present_view = 0, present_generation = 0, present_version = 0;
  uint32_t ordinal = 0;
  bool enabled = false, active = false, started = false, closed = false, presented = false, encoder_present = false;
  bool target_set = false, observed = false;
  bool continuous = false;
  std::array<uint64_t, kParityLane> fence_versions{};
  std::array<bool, kParityLane> fence_signalled{};
  static_assert(FrameStreamVersionIndex::capacity==FFS_MAX_RESOURCES,"writer lifetime cap remains unchanged");
  FrameStreamVersionIndex versions;
  std::vector<RawBuffer> raw_writes;
  std::vector<Event> events;
  std::vector<Resource> planned_resources;
  std::vector<Dependency> planned_dependencies;
  std::vector<const wmtcmd_base *> planned_commands;
  EncoderType planned_type = EncoderType::Null;
  ffs_present_info present_state{};
  uint64_t readback_index=0,query_count=0;

  void emit(uint32_t kind, uint32_t flags, const std::vector<uint64_t> &data = {}, uint32_t item = 0) {
    if (!active) return;
    if (records >= FFS_MAX_RECORDS || data.size() > 12 || sequence == UINT64_MAX) {
      const char *stage=records>=FFS_MAX_RECORDS?"record-count":data.size()>12?"record-words":"sequence";
      std::fprintf(stderr,"[native-writer-limit] stage=%s stream=%llu frame=%llu chunk=%llu encoder=%u sequence=%llu records=%llu attempted_kind=%u versions=%zu raw_writes=%zu events=%zu\n",
        stage,(unsigned long long)stream,(unsigned long long)frame,(unsigned long long)chunk,ordinal,(unsigned long long)sequence,
        (unsigned long long)records,kind,(size_t)versions.count(),raw_writes.size(),events.size());active = false; return;
    }
    ffs_record r{};
    r.magic = FFS_MAGIC; r.version = FFS_VERSION; r.bytes = sizeof(r); r.kind = kind; r.flags = flags;
    r.stream = stream; r.sequence = sequence; r.frame = frame; r.chunk = chunk; r.encoder = ordinal; r.item = item;
    std::copy(data.begin(), data.end(), r.data);
    uint32_t result = WMTFrameStreamEmit(&r, sizeof(r));
    if (result != FFS_EMIT_ACCEPT) {
      active = false;
      if (kind == FFS_FRAME_BEGIN && result == FFS_EMIT_IDLE) started = false;
      else closed = true;
      return;
    }
    if (kind != FFS_FRAME_END) {
      auto bytes = reinterpret_cast<const unsigned char *>(&r);
      for (size_t i = 0; i < sizeof(r); i++) { digest ^= bytes[i]; digest *= UINT64_C(1099511628211); }
    }
    sequence++; records++;
    if (kind == FFS_DEPENDENCY) chunk_dependencies++;
  }

  void reject(uint64_t reason) { emit(FFS_REJECT, FFS_UNSUPPORTED, {reason}); active = false; closed = true; }
  void rejectLimit(const char *stage,uint64_t count,uint64_t limit) {
    if(!active){reject(FFS_LIMIT);return;} /* Preserve reject's closed transition. */
    std::fprintf(stderr,"[native-writer-limit] stage=%s stream=%llu frame=%llu chunk=%llu encoder=%u sequence=%llu records=%llu count=%llu limit=%llu versions=%zu raw_writes=%zu events=%zu\n",
      stage,(unsigned long long)stream,(unsigned long long)frame,(unsigned long long)chunk,ordinal,(unsigned long long)sequence,
      (unsigned long long)records,(unsigned long long)count,(unsigned long long)limit,(size_t)versions.count(),raw_writes.size(),events.size());
    reject(FFS_LIMIT);
  }

  void retireLifetimes(const std::vector<FrameStreamLifetime::Root> &released) {
    for(auto root:released){
      versions.retire(root.kind,root.root,root.generation);
      if(root.generation)WMTFrameStreamRetireResource(root.kind,root.root,root.generation);
    }
  }
  void retireInactiveLifetimes(){
    if(!continuous)return;std::vector<FrameStreamLifetime::Root> released;
    if(FrameStreamLifetime::take(released))retireLifetimes(released);
    else FrameStreamLifetime::discard(); /* No captured command in this chunk. */
  }
  Resource rawBuffer(obj_handle_t handle,uint64_t base,uint64_t length,uint32_t flags,bool write){
    for(auto r:raw_writes)if(r.handle==handle&&base>=r.base&&base-r.base<=r.length&&length<=r.length-(base-r.base))
      return {FFS_BUFFER,r.root,1,1,r.base,r.length,flags,handle,FFS_ROLE_SHADER,r.base,r.length};
    uint64_t root=UINT64_C(0x8000000000000000)|++next_upload_slice;
    if(write){if(raw_writes.size()==FFS_MAX_RESOURCES){rejectLimit("raw-writes",raw_writes.size(),FFS_MAX_RESOURCES);return {};}
      raw_writes.push_back({handle,base,length,root});}
    return {FFS_BUFFER,root,1,1,base,length,flags,handle,FFS_ROLE_SHADER,base,length};
  }

  uint64_t version(Resource r,FrameStreamVersionIndex::Handle *result=nullptr) {
    uint64_t value=0;FrameStreamVersionIndex::Handle handle;
    auto status=versions.getOrCreate(r.kind,r.root,r.generation,value,handle);
    if(status==FrameStreamVersionIndex::EntryCapacity){rejectLimit("versions",versions.count(),FFS_MAX_RESOURCES);return 0;}
    if(status!=FrameStreamVersionIndex::Ok){reject(FFS_IDENTITY);return 0;}
    if(result)*result=handle;return value;
  }

  void resource(Resource r,uint64_t payload) {
    if (!r.root || !r.view || !r.generation) {
      emit(FFS_RESOURCE_UNRESOLVED,r.flags | FFS_UNSUPPORTED,{FFS_IDENTITY,r.kind}); return;
    }
    FrameStreamVersionIndex::Handle handle;uint64_t before = version(r,&handle), after = before;
    if(!active)return;
    if (r.flags & FFS_WRITE) {
      if (before == UINT64_MAX || !versions.markWrite(handle,r.kind,r.root,r.generation)) { reject(FFS_RESOURCE_VERSION); return; }
      after++;
    }
    emit(FFS_RESOURCE, r.flags | (payload ? FFS_PAYLOAD : FFS_UNSUPPORTED),
        {r.kind,r.root,r.view,r.generation,before,r.offset,r.length,payload,after});
    present_root = r.root; present_view = r.view; present_generation = r.generation; present_version = after;
  }

  static void texture(std::vector<Resource> &out, TextureViewRef const &view, uint32_t flags,uint32_t role=FFS_ROLE_SHADER) {
    if (!view) return;
    out.push_back({FFS_TEXTURE,view->allocation->bedrock_frame_incarnation,
        uint64_t(view->key) + 1,1,0,0,flags,view.texture().handle,role});
  }

  void fences(std::vector<Dependency> &out, FenceSet set, uint64_t stage, uint64_t action) {
    set.forEach([&](auto lane) {
      if (lane >= fence_versions.size()) { reject(FFS_IDENTITY); return; }
      if (!fence_versions[lane]) fence_versions[lane] = 1;
      uint32_t flags = 0;
      if (action == FFS_SIGNAL) { ++fence_versions[lane]; fence_signalled[lane] = true; }
      else if (!fence_signalled[lane]) flags = FFS_EXTERNAL | FFS_PAYLOAD;
      out.push_back({FFS_FENCE,uint64_t(lane) + 1,fence_versions[lane],stage,action,flags});
    });
  }

  void renderFences(std::vector<Dependency> &out, RenderEncoderData *r, bool signal) {
    auto prior = signal ? r->fence_update : r->fence_wait_vertex;
    auto other = signal ? r->fence_update_vertex : r->fence_wait;
    const uint64_t action = signal ? FFS_SIGNAL : FFS_WAIT;
    auto first = signal ? WMTRenderStageFragment : WMTRenderStagePreRaster;
    auto second = signal ? WMTRenderStagePreRaster : WMTRenderStageFragment;
    other.forEach(prior,
        [&](auto lane) { fences(out,FenceSet(EncoderId(lane)),first,action); },
        [&](auto lane) { fences(out,FenceSet(EncoderId(lane)),second,action); });
  }

  void event(std::vector<Dependency> &out, WMT::Event handle, uint64_t value, uint64_t action) {
    size_t i = 0;
    for (; i < events.size(); i++) if (events[i].retained.handle == handle.handle) break;
    if (i == events.size()) {
      if (i == 64) { rejectLimit("events",i,64); return; }
      /* A retained object cannot be recycled into another event identity. */
      events.push_back({handle,0});
    }
    uint32_t flags = action == FFS_WAIT && events[i].value < value ? FFS_EXTERNAL | FFS_PAYLOAD : 0;
    out.push_back({FFS_EVENT,i + 1,value,0,action,flags});
    if (action == FFS_SIGNAL) events[i].value = value;
  }

  ffs_producer_context context(uint32_t category,uint64_t completion=0) {
    ffs_producer_context c{};c.magic=FFS_PREPARE_MAGIC;c.version=FFS_PREPARE_VERSION;c.bytes=sizeof(c);
    c.stream=stream;c.frame=frame;c.chunk=chunk;c.encoder=ordinal;c.category=category;c.completion=completion;
    return c;
  }

  uint64_t prepare(WMT::CommandBuffer command,WMTRenderPassInfo *info) {
    std::vector<ffs_producer_resource> refs;
    for(auto r:planned_resources){
      uint64_t before=r.root?version(r):0;
      refs.push_back({r.handle,r.kind,r.root,r.view,r.generation,before,before+((r.flags&FFS_WRITE)?1:0),r.offset,r.length,r.flags,r.role,r.buffer_base_offset,r.buffer_length});
    }
    if(!active)return 0;
    auto c=context(uint32_t(planned_type));c.command_count=planned_commands.size();c.resource_count=refs.size();c.resources.set(refs.data());
    c.present.set(planned_type==EncoderType::Present?&present_state:nullptr);
    c.commands.set(planned_commands.empty()?nullptr:planned_commands.front());
    std::vector<ffs_producer_dependency> dependencies;
    for(auto d:planned_dependencies)dependencies.push_back({d.domain,d.id,d.value,d.stage,d.action,(d.flags&FFS_EXTERNAL)?1u:0u,d.flags,0});
    c.dependencies.set(dependencies.data());c.dependency_count=dependencies.size();c.readback_index=readback_index;c.query_count=query_count;
    return WMTFrameStreamPrepareEncoder(command.handle,info,&c);
  }

  void emitPlanned(uint64_t payload) {
    if(!active)return;
    emit(FFS_ENCODER_BEGIN,planned_type==EncoderType::Null?0:(payload?FFS_PAYLOAD:FFS_UNSUPPORTED),
        {uint64_t(planned_type),command_count,resource_count,dependency_count,payload});
    for(auto d:planned_dependencies)if(d.action==FFS_WAIT)emit(FFS_DEPENDENCY,d.flags,{d.domain,d.id,d.value,d.stage,d.action,(d.flags&FFS_EXTERNAL)?1u:0u});
    for(auto r:planned_resources)resource(r,payload);
    for(size_t i=0;i<planned_commands.size();i++)emit(FFS_COMMAND,payload?FFS_PAYLOAD:FFS_UNSUPPORTED,{planned_commands[i]->type,payload},uint32_t(i));
    for(auto d:planned_dependencies)if(d.action==FFS_SIGNAL)emit(FFS_DEPENDENCY,d.flags,{d.domain,d.id,d.value,d.stage,d.action});
    if(planned_type==EncoderType::Present&&(!present_root||!present_view))reject(FFS_IDENTITY);
    encoder_present=planned_type==EncoderType::Present;
  }

public:
  FrameStreamWriter() {
    const char *mode = std::getenv("DXMT_FRAME_STREAM"); enabled = mode && !std::strcmp(mode,"1");
    const char *chunks_mode=std::getenv("DXMT_CHUNK_STREAM");continuous=chunks_mode&&!std::strcmp(chunks_mode,"1");
    if (const char *text = std::getenv("DXMT_FRAME_STREAM_FRAME")) {
      target_set = true;
      char *end = nullptr; target = std::strtoull(text,&end,10);
      if (!*text || *end || *text == '-') enabled = false;
    }
  }

  void beginChunk(uint64_t frame_id, uint64_t chunk_id, unsigned count, uint64_t initializer, uint64_t completion) {
    raw_writes.clear();
    if (!enabled || closed) {retireInactiveLifetimes();return;}
    bool first_chunk = !observed || observed_frame != frame_id;
    observed = true; observed_frame = frame_id;
    if (!started) {
      if (!first_chunk || (target_set && frame_id != target)) {retireInactiveLifetimes();return;}
      active = true;
      if(continuous){records=chunks=encoders=commands=0;digest=UINT64_C(14695981039346656037);presented=false;}
      frame = frame_id; chunk = chunk_id; ordinal = 0; started = true;
      emit(FFS_FRAME_BEGIN,0,{chunk_id,1});
      if (!active) {retireInactiveLifetimes();return;}
      if(continuous)target_set=false;
    } else if (frame != frame_id || chunk_id != chunk + 1) { reject(FFS_ORDER); return; }
    chunk = chunk_id; ordinal = 0; chunk_encoders = chunk_commands = chunk_dependencies = 0;
    emit(FFS_CHUNK_BEGIN,0,{chunks,count,initializer,completion});
    if (initializer) emit(FFS_DEPENDENCY,FFS_EXTERNAL | FFS_PAYLOAD,{FFS_INITIALIZER,1,initializer,0,FFS_WAIT,1});
  }

  void beforeEncoder(WMT::CommandBuffer command,EncoderData *data) {
    if (!active) return;
    versions.clearWrites();
    readback_index=query_count=0;
    std::vector<Resource> resources;
    std::vector<Dependency> dependencies;
    const wmtcmd_base *head = nullptr;
    auto type = data->type;
    if (type == EncoderType::Render) {
      auto r = static_cast<RenderEncoderData *>(data);
      head = reinterpret_cast<const wmtcmd_base *>(&r->cmd_head);
      for (size_t i=0;i<r->colors.size();i++) {
        auto &c=r->colors[i];
        texture(resources,c.attachment,FFS_ATTACHMENT | FFS_WRITE | (c.load_action == WMTLoadActionLoad ? FFS_READ : 0),FFS_ROLE_COLOR+i);
        texture(resources,c.resolve_attachment,FFS_ATTACHMENT | FFS_WRITE,FFS_ROLE_COLOR_RESOLVE+i);
      }
      texture(resources,r->depth.attachment,FFS_ATTACHMENT | FFS_WRITE | (r->depth.load_action==WMTLoadActionLoad?FFS_READ:0),FFS_ROLE_DEPTH);
      texture(resources,r->stencil.attachment,FFS_ATTACHMENT | FFS_WRITE | (r->stencil.load_action==WMTLoadActionLoad?FFS_READ:0),FFS_ROLE_STENCIL);
      renderFences(dependencies,r,false);
    } else if (type == EncoderType::Compute) head = reinterpret_cast<const wmtcmd_base *>(&static_cast<ComputeEncoderData *>(data)->cmd_head);
    else if (type == EncoderType::Blit) head = reinterpret_cast<const wmtcmd_base *>(&static_cast<BlitEncoderData *>(data)->cmd_head);
    else if(type==EncoderType::SampleTimestamp){auto sample=static_cast<SampleTimestampData *>(data);readback_index=sample->readback_index;query_count=sample->queries.size();}
    else if (type == EncoderType::Clear) {
      auto clear=static_cast<ClearEncoderData *>(data);
      if(!clear->clear_dsv)texture(resources,clear->attachment,FFS_ATTACHMENT|FFS_WRITE,FFS_ROLE_COLOR);
      if(clear->clear_dsv&1)texture(resources,clear->attachment,FFS_ATTACHMENT|FFS_WRITE,FFS_ROLE_DEPTH);
      if(clear->clear_dsv&2)texture(resources,clear->attachment,FFS_ATTACHMENT|FFS_WRITE,FFS_ROLE_STENCIL);
    }
    else if (type == EncoderType::Resolve) {
      auto r = static_cast<ResolveEncoderData *>(data);
      texture(resources,r->src,FFS_ATTACHMENT | FFS_READ,FFS_ROLE_COLOR); texture(resources,r->dst,FFS_ATTACHMENT | FFS_WRITE,FFS_ROLE_COLOR_RESOLVE);
    } else if (type == EncoderType::Present) {
      auto p=static_cast<PresentData *>(data);
      texture(resources,p->bedrock_frame_backbuffer,FFS_READ,FFS_ROLE_PRESENT);
      present_state=p->presenter->frameStreamInfo(p->metadata);
    }
    else if (type == EncoderType::SignalEvent) {
      auto r = static_cast<SignalEventData *>(data); event(dependencies,r->event,r->value,FFS_SIGNAL);
    } else if (type == EncoderType::WaitForEvent) {
      auto r = static_cast<WaitForEventData *>(data); event(dependencies,r->event,r->value,FFS_WAIT);
    }
    if (type != EncoderType::Null && type != EncoderType::Render) {
      uint64_t stage = type == EncoderType::Present||type==EncoderType::Clear||type==EncoderType::Resolve ? WMTRenderStageFragment : 0;
      fences(dependencies,data->fence_wait,stage,FFS_WAIT);
    }
    std::vector<const wmtcmd_base *> list;
    for (auto cmd = head; cmd; cmd = static_cast<const wmtcmd_base *>(cmd->next.ptr)) {
      if (list.size() == FFS_MAX_COMMANDS) { rejectLimit("commands",list.size(),FFS_MAX_COMMANDS); return; }
      list.push_back(cmd);
      if (type == EncoderType::Render && cmd->type == WMTRenderCommandUseResource) {
        auto r = reinterpret_cast<const wmtcmd_render_useresource *>(cmd);
        resources.push_back({r->bedrock_frame_kind,r->bedrock_frame_root,
            r->bedrock_frame_view,r->bedrock_frame_generation,r->bedrock_frame_offset,r->bedrock_frame_length,
            uint32_t((r->usage & WMTResourceUsageRead ? FFS_READ : 0) | (r->usage & WMTResourceUsageWrite ? FFS_WRITE : 0)),r->resource});
      } else if(type==EncoderType::Blit&&cmd->type==WMTBlitCommandCopyFromBufferToBuffer){
        auto copy=reinterpret_cast<const wmtcmd_blit_copy_from_buffer_to_buffer *>(cmd);
        bool valid=copy->bedrock_copy_magic==0x46424331;
        uint64_t src_root=valid?copy->bedrock_src_root:0,src_generation=valid?copy->bedrock_src_generation:0;
        uint64_t src_base=valid?copy->bedrock_src_base:0,src_length=valid?copy->bedrock_src_length:0;
        bool upload=valid&&!src_root&&!src_generation&&src_length==copy->copy_length;
        if(upload)resources.push_back(rawBuffer(copy->src,src_base,src_length,FFS_READ,false));
        else resources.push_back({FFS_BUFFER,src_root,((src_base<<1)|1),src_generation,src_base,src_length,FFS_READ,copy->src});
        resources.push_back({FFS_BUFFER,valid?copy->bedrock_dst_root:0,valid?((copy->bedrock_dst_base<<1)|1):0,
            valid?copy->bedrock_dst_generation:0,valid?copy->bedrock_dst_base:0,valid?copy->bedrock_dst_length:0,
            uint32_t(FFS_WRITE|((valid&&copy->dst_offset==copy->bedrock_dst_base&&copy->copy_length==copy->bedrock_dst_length)?0:FFS_READ)),copy->dst});
      } else if(type==EncoderType::Blit&&cmd->type==WMTBlitCommandCopyFromBufferToTexture){
        auto copy=reinterpret_cast<const wmtcmd_blit_copy_from_buffer_to_texture *>(cmd);
        bool valid=copy->bedrock_copy_magic==0x46544331;
        uint64_t src_root=valid?copy->bedrock_src_root:0,src_generation=valid?copy->bedrock_src_generation:0;
        uint64_t src_base=valid?copy->bedrock_src_base:0,src_length=valid?copy->bedrock_src_length:0;
        bool upload=valid&&!src_root&&!src_generation&&src_length;
        if(upload)resources.push_back(rawBuffer(copy->src,src_base,src_length,FFS_READ,false));
        else resources.push_back({FFS_BUFFER,src_root,((src_base<<1)|1),src_generation,src_base,src_length,FFS_READ,copy->src});
        resources.push_back({FFS_TEXTURE,valid?copy->bedrock_dst_root:0,valid?copy->bedrock_dst_view:0,
            valid?copy->bedrock_dst_generation:0,0,0,FFS_READ|FFS_WRITE,copy->dst});
      } else if(type==EncoderType::Blit&&cmd->type==WMTBlitCommandCopyFromTextureToBuffer){
        auto copy=reinterpret_cast<const wmtcmd_blit_copy_from_texture_to_buffer *>(cmd);
        bool valid=copy->bedrock_copy_magic==0x46524231;
        resources.push_back({FFS_TEXTURE,valid?copy->bedrock_src_root:0,valid?copy->bedrock_src_view:0,
            valid?copy->bedrock_src_generation:0,0,0,FFS_READ,copy->src});
        uint64_t root=valid?copy->bedrock_dst_root:0,generation=valid?copy->bedrock_dst_generation:0;
        uint64_t base=valid?copy->bedrock_dst_base:0,length=valid?copy->bedrock_dst_length:0;
        if(valid&&!root&&!generation&&length)resources.push_back(rawBuffer(copy->dst,base,length,FFS_READ|FFS_WRITE,true));
        else resources.push_back({FFS_BUFFER,root,((base<<1)|1),generation,base,length,FFS_READ|FFS_WRITE,copy->dst});
      } else if(type==EncoderType::Blit&&cmd->type==WMTBlitCommandCopyFromTextureToTexture){
        auto copy=reinterpret_cast<const wmtcmd_blit_copy_from_texture_to_texture *>(cmd);
        bool valid=copy->bedrock_copy_magic==0x46545431&&!copy->bedrock_copy_reserved;
        resources.push_back({FFS_TEXTURE,valid?copy->bedrock_src_root:0,valid?copy->bedrock_src_view:0,
            valid?copy->bedrock_src_generation:0,0,0,FFS_READ,copy->src});
        resources.push_back({FFS_TEXTURE,valid?copy->bedrock_dst_root:0,valid?copy->bedrock_dst_view:0,
            valid?copy->bedrock_dst_generation:0,0,0,FFS_READ|FFS_WRITE,copy->dst});
      } else if (type == EncoderType::Compute && cmd->type == WMTComputeCommandUseResource) {
        auto r = reinterpret_cast<const wmtcmd_compute_useresource *>(cmd);
        resources.push_back({r->bedrock_frame_kind,r->bedrock_frame_root,
            r->bedrock_frame_view,r->bedrock_frame_generation,r->bedrock_frame_offset,r->bedrock_frame_length,
            uint32_t((r->usage & WMTResourceUsageRead ? FFS_READ : 0) | (r->usage & WMTResourceUsageWrite ? FFS_WRITE : 0)),r->resource});
      }
    }
    if (type == EncoderType::Render) renderFences(dependencies,static_cast<RenderEncoderData *>(data),true);
    else if (type != EncoderType::Null) fences(dependencies,data->fence_update,type == EncoderType::Present||type==EncoderType::Clear||type==EncoderType::Resolve ? WMTRenderStageFragment : 0,FFS_SIGNAL);
    command_count = list.size(); resource_count = resources.size(); dependency_count = dependencies.size();
    if (resource_count > FFS_MAX_RESOURCES) { rejectLimit("resources",resource_count,FFS_MAX_RESOURCES); return; }
    if (dependency_count > FFS_MAX_DEPENDENCIES) { rejectLimit("dependencies",dependency_count,FFS_MAX_DEPENDENCIES); return; }
    planned_type=type;planned_resources=std::move(resources);planned_dependencies=std::move(dependencies);planned_commands=std::move(list);
    if(type!=EncoderType::Render&&type!=EncoderType::Clear&&type!=EncoderType::Resolve&&type!=EncoderType::Blit)
      emitPlanned(type==EncoderType::Present||type==EncoderType::SampleTimestamp||type==EncoderType::SignalEvent?prepare(command,nullptr):0);
  }

  void prepareRender(WMT::CommandBuffer command,WMTRenderPassInfo *info){
    if(active&&(planned_type==EncoderType::Render||planned_type==EncoderType::Clear||planned_type==EncoderType::Resolve||planned_type==EncoderType::Blit))emitPlanned(prepare(command,info));
  }

  void afterEncoder() {
    if (!active) return;
    if (encoder_present) {
      emit(FFS_PRESENT,0,{present_root,present_view,present_generation,present_version});
      presented = true;
    }
    if(!versions.commitWrites()){reject(FFS_RESOURCE_VERSION);return;}
    emit(FFS_ENCODER_END,0,{command_count,resource_count,dependency_count});
    encoders++; chunk_encoders++; commands += command_count; chunk_commands += command_count; ordinal++;
  }

  void endChunk(WMT::CommandBuffer command,uint64_t completion) {
    if (!active) {retireInactiveLifetimes();return;}
    std::vector<FrameStreamLifetime::Root> released;
    if(continuous&&!FrameStreamLifetime::take(released)){rejectLimit("lifetime-queue",4096,4096);return;}
    auto c=context(FFS_PREPARE_CHUNK,completion);(void)WMTFrameStreamPrepareEncoder(command.handle,nullptr,&c);
    emit(FFS_DEPENDENCY,0,{FFS_QUEUE,1,completion,0,FFS_SIGNAL});
    emit(FFS_CHUNK_END,0,{chunk_encoders,chunk_commands,chunk_dependencies}); chunks++;
    if(continuous)versions.retireRawBuffers(FFS_BUFFER); /* Immutable raw upload slices live for this chunk only. */
    if (presented) {
      emit(FFS_FRAME_END,0,{chunks,encoders,commands,records,digest}); active = false; closed = !continuous;
      if(continuous)started=false;
    }
    /* list_enc.execute can stamp old/new/old generations into this chunk.
     * Never release one before every actual encoder and frame-end record. */
    if(continuous)retireLifetimes(released);
  }
};
static_assert(uint64_t(EncoderType::SampleTimestamp) + 1 == FFS_CATEGORY_COUNT, "record every DXMT encoder category");
}
