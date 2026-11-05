/* Translation of borrowed DXMT/WineMetal render commands into staged FFDC.
 * This is an observer-side adapter, not permission to replace source work. */
#ifndef BEDROCK_NATIVE_DIRECT_WMT_H
#define BEDROCK_NATIVE_DIRECT_WMT_H
#include "direct_commands.h"
#ifdef __cplusplus
extern "C" {
#endif

struct WMTRenderPassInfo;
struct wmtcmd_base;

enum { FFDW_TARGET = 1, FFDW_PIPELINE = 2 };
enum { FFDW_VERTEX_IA = 0, FFDW_VERTEX_CONSTANTS = 1,
       FFDW_VERTEX_ARGUMENTS = 2, FFDW_FRAGMENT_CONSTANTS = 3,
       FFDW_FRAGMENT_ARGUMENTS = 4, FFDW_TABLES = 5 };

/* Source handles are borrowed and process-local. They are passed ONLY to the
 * synchronous resolvers; no source handle, GPU address or pointer goes on the
 * wire. Initial special tables are bound by DXMT outside its command list. */
typedef struct { uint64_t buffer, offset; } FFDWSourceTable;
#define FFDW_BUFFER_IDENTITY_MAGIC UINT64_C(0x42444944454e5431)
#define FFDW_BUFFER_IDENTITY_VERSION 1u
/* Copy of the paired source's WMTBedrockBufferIdentity. Never manufacture one
 * from a Metal handle. The source stamps it at allocation selection. */
typedef struct {
    uint64_t magic;
    uint32_t version, reserved;
    uint64_t root, generation, base, length;
} FFDWBufferIdentity;
typedef struct {
    FFDCLogicalBuffer vertices[32], constants[2][14];
    FFDCLogicalField arguments[2][128];
    size_t vertex_count, constant_count[2], argument_count[2];
} FFDWDrawTables;
typedef struct {
    void *context;
    /* Resolve the exact target view or pipeline identity.
     * command is NULL only for the pass attachment. */
    int (*object)(void *context, unsigned kind, const struct wmtcmd_base *command,
                  uint64_t source_handle, uint64_t *object, uint64_t *generation);
    /* Copy the source command's indexed-operand provenance stamp. Zero or
     * missing stamps reject; this must not resolve by source Metal handle. */
    int (*index_identity)(void *context, const struct wmtcmd_base *command, FFDWBufferIdentity *out);
    /* Reconstruct logical tables for this exact pipeline and current source
     * table offsets. Called before every draw, including pipeline changes.
     * Populate only exact, live generation-qualified identities and values;
     * reject unresolved, stale, ambiguous or concurrently mutable input.
     * Nonempty IA tables reject until the native executor qualifies ranges. */
    int (*tables)(void *context, const struct wmtcmd_base *draw,
                  uint64_t source_pipeline, const FFDWSourceTable source[FFDW_TABLES],
                  FFDWDrawTables *out);
} FFDWResolvers;

/* Validate the selected logical allocation and convert an absolute WMT byte
 * range to its allocation-relative offset. No output is modified on failure. */
int ffdw_validate_buffer_identity(const FFDWBufferIdentity *identity, uint64_t offset,
                                  uint64_t length, uint64_t *object, uint64_t *generation,
                                  uint64_t *logical_offset);
/* Resolver for the paired DXMT indexed-command stamp. Returns false when the
 * paired header extension is absent or the command is not an indexed draw. */
int ffdw_paired_index_identity(void *context, const struct wmtcmd_base *command, FFDWBufferIdentity *out);

/* Append one complete supported pass atomically to an initialized writer.
 * Unsupported commands/attachments, missing provenance, or insufficient space
 * leave the writer's visible length/count unchanged. The caller must serialize
 * access, keep source objects valid during this call, and use pure resolvers.
 * After assembling the entire chunk, seal and ffdc_validate_complete before
 * publication. This function does not account for the enclosing encoder's
 * implicit state, fences, initializer, queries, readbacks or presentation; a
 * successful translation alone NEVER authorizes source-render suppression. */
int ffdw_append_render(FFDCWriter *writer, const struct WMTRenderPassInfo *pass,
                       const struct wmtcmd_base *commands, uint64_t initial_argbuffer,
                       const FFDWResolvers *resolvers);
#ifdef __cplusplus
}
#endif
#endif
