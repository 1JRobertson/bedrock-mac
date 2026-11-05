/* Bounded, alignment-safe view of one FFMD1 metadata blob. */
#ifndef BEDROCK_NATIVE_METADATA_WIRE_H
#define BEDROCK_NATIVE_METADATA_WIRE_H
#include "metadata_wire_v1.h"
#include <stddef.h>

typedef struct {
    const uint8_t *bytes;
    size_t length;
    ffmd_header header;
    ffmd_section sections[7];
} ffmd_view;

int ffmd_view_decode(const void *bytes, size_t length, enum ffmd_kind kind, ffmd_view *out);
int ffmd_view_row(const ffmd_view *view, unsigned section_index, size_t row_index,
                  void *out, size_t row_size);
#endif
