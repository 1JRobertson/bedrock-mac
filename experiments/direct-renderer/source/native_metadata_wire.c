#include "native_metadata_wire.h"
#include <string.h>

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error FFMD1 wire decoding requires a little-endian host
#endif

int ffmd_view_decode(const void *bytes, size_t length, enum ffmd_kind kind, ffmd_view *out) {
    if (!bytes || !out || length < sizeof(ffmd_header) || length > FFMD_MAX_BYTES ||
        (kind != FFMD_PLAN && kind != FFMD_GRAPH && kind != FFMD_SIDECAR)) return 0;
    memset(out, 0, sizeof(*out));
    const uint8_t *raw = bytes;
    ffmd_header header;
    memcpy(&header, raw, sizeof(header));
    const unsigned count = kind == FFMD_PLAN ? 2 : kind == FFMD_GRAPH ? 7 : 5;
    const unsigned first = kind == FFMD_PLAN ? FFMD_PLAN_DRAW :
        kind == FFMD_GRAPH ? FFMD_GRAPH_SNAPSHOT : FFMD_SIDECAR_RESOURCE;
    const uint32_t strides[3][7] = {
        {sizeof(ffmd_plan_draw), sizeof(ffmd_plan_argument_slot)},
        {sizeof(ffmd_graph_snapshot), sizeof(ffmd_graph_draw), sizeof(ffmd_graph_binding),
         sizeof(ffmd_graph_argument_value), sizeof(ffmd_graph_texture),
         sizeof(ffmd_graph_texture_plane), sizeof(ffmd_graph_sampler)},
        {sizeof(ffmd_sidecar_resource), sizeof(ffmd_sidecar_index), sizeof(ffmd_sidecar_index),
         sizeof(ffmd_sidecar_attachment), sizeof(ffmd_sidecar_command)}
    };
    if (header.magic != FFMD_MAGIC || header.version != FFMD_VERSION || header.kind != kind ||
        header.total_bytes != length || header.section_count != count || header.reserved ||
        header.flags != (kind == FFMD_PLAN ? 0u : FFMD_COMPLETE_PASS)) return 0;
    if (kind == FFMD_PLAN) {
        if (header.stream || header.frame || header.chunk || header.payload_id || header.cut_id) return 0;
        for (unsigned i = 0; i < sizeof(header.plan_sha256); ++i)
            if (header.plan_sha256[i]) return 0;
    } else if (!header.stream || !header.frame || !header.chunk || !header.payload_id || !header.cut_id) return 0;
    size_t next = sizeof(header) + count * sizeof(ffmd_section);
    if (next > length) return 0;
    for (unsigned i = 0; i < count; ++i) {
        ffmd_section section;
        memcpy(&section, raw + sizeof(header) + i * sizeof(section), sizeof(section));
        if (section.type != first + i || section.version != 1 ||
            section.stride != strides[kind - 1][i] ||
            (uint64_t)section.stride * section.count != section.bytes ||
            section.offset != next || section.bytes > length - next) return 0;
        out->sections[i] = section;
        next += section.bytes;
    }
    if (next != length) return 0;
    out->bytes = raw;
    out->length = length;
    out->header = header;
    return 1;
}

int ffmd_view_row(const ffmd_view *view, unsigned section_index, size_t row_index,
                  void *out, size_t row_size) {
    if (!view || !view->bytes || !out || section_index >= view->header.section_count) return 0;
    const ffmd_section *section = &view->sections[section_index];
    if (row_index >= section->count || row_size != section->stride) return 0;
    memcpy(out, view->bytes + section->offset + row_index * section->stride, row_size);
    return 1;
}
