#pragma once
/* Include after the DXMT context definitions. Synchronous scalar observations;
 * source rendering continues. Native entry pointers never leave the callback. */
#include "native_boundary_capture.hpp"
#include "native_entry_dxmt.hpp"
namespace dxmt::boundary_capture {
inline bool begin(void *,const native_entry::Chunk &c){
  writer().emit(BeginChunk,c.stream,c.frame,c.chunk,0,{c.initializer,c.completion,c.encoders});return true;
}
inline bool visit(void *,const native_entry::Chunk &c,uint32_t ordinal,native_entry::Stage stage,const void *object){
  if(stage!=native_entry::Stage::Encoder)return true;
  auto data=static_cast<const EncoderData *>(object);
  if(data->type!=EncoderType::Render){
    writer().emit(OtherEncoder,c.stream,c.frame,c.chunk,ordinal,{uint64_t(data->type)});return true;
  }
  auto r=static_cast<const RenderEncoderData *>(data);
  uint64_t draws=0,indexed=0,visibility=0,commands=0;
  const auto *head=reinterpret_cast<const wmtcmd_base *>(&r->cmd_head);
  for(auto cmd=head;cmd;cmd=static_cast<const wmtcmd_base *>(cmd->next.ptr)){
    if(++commands>65536){writer().emit(Rejected,c.stream,c.frame,c.chunk,ordinal,{4});return false;}
    if(cmd->type==WMTRenderCommandDraw||cmd->type==WMTRenderCommandDrawIndexed){++draws;indexed+=cmd->type==WMTRenderCommandDrawIndexed;}
    if(cmd->type==WMTRenderCommandSetVisibilityMode)
      visibility|=reinterpret_cast<const wmtcmd_render_setvisibilitymode *>(cmd)->mode;
  }
  writer().emit(Render,c.stream,c.frame,c.chunk,ordinal,{draws,indexed,visibility,
    uint64_t(r->use_geometry),uint64_t(r->use_tessellation),uint64_t(bool(r->depth.attachment)),
    uint64_t(bool(r->stencil.attachment)),r->render_target_count,commands,uint64_t(r->use_visibility_result)});
  for(auto cmd=head;cmd;cmd=static_cast<const wmtcmd_base *>(cmd->next.ptr)){
    if(cmd->type!=WMTRenderCommandUseResource)continue;
    auto u=reinterpret_cast<const wmtcmd_render_useresource *>(cmd);
    writer().emit(Resource,c.stream,c.frame,c.chunk,ordinal,{u->bedrock_frame_kind,u->bedrock_frame_root,
      u->bedrock_frame_view,u->bedrock_frame_generation,u->bedrock_frame_offset,u->bedrock_frame_length,
      uint64_t(u->usage),uint64_t(u->stages),u->bedrock_flags,u->bedrock_source_tag});
  }
  return true;
}
inline void finish(void *,const native_entry::Chunk &c,const void *,bool accepted){
  writer().emit(EndChunk,c.stream,c.frame,c.chunk,0,{uint64_t(accepted)});
}
inline void install(){
  if(!configured())return;
  static native_entry::Sink sink{native_entry::kVersion,sizeof(native_entry::Sink),nullptr,begin,visit,finish};
  static const bool installed=native_entry::install(&sink);(void)installed;
}
} // namespace dxmt::boundary_capture
