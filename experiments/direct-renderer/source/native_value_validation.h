/* Exact integer NSNumber validation for pointer-free native payloads.
 * ObjC type admission precedes conversion; floats/booleans never round into
 * identities. Outputs are written only after every check succeeds. */
#ifndef BEDROCK_NATIVE_VALUE_VALIDATION_H
#define BEDROCK_NATIVE_VALUE_VALIDATION_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

/* Foundation may normalize constructor types. Use the represented ObjC type,
 * and its signedness, rather than assuming the original C constructor. */
static inline unsigned ffst_value_integer_kind(id object) {
    if (![object isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)object) == CFBooleanGetTypeID()) return 0;
    const char *type = [object objCType];
    if (!type || !type[0] || type[1]) return 0;
    switch (type[0]) {
        case 'c': case 's': case 'i': case 'l': case 'q': return 1;
        case 'C': case 'S': case 'I': case 'L': case 'Q': return 2;
        default: return 0;
    }
}

static inline BOOL ffst_value_u64(id object, uint64_t maximum, uint64_t *out) {
    if (!out) return NO;
    unsigned kind = ffst_value_integer_kind(object);
    uint64_t value;
    if (kind == 1) {
        int64_t signedValue = [object longLongValue];
        if (signedValue < 0) return NO;
        value = (uint64_t)signedValue;
    } else if (kind == 2) {
        value = [object unsignedLongLongValue];
    } else return NO;
    if (value > maximum) return NO;
    *out = value;
    return YES;
}

static inline BOOL ffst_value_i32(id object, int32_t *out) {
    if (!out) return NO;
    unsigned kind = ffst_value_integer_kind(object);
    int32_t value;
    if (kind == 1) {
        int64_t signedValue = [object longLongValue];
        if (signedValue < INT32_MIN || signedValue > INT32_MAX) return NO;
        value = (int32_t)signedValue;
    } else if (kind == 2) {
        uint64_t unsignedValue = [object unsignedLongLongValue];
        if (unsignedValue > INT32_MAX) return NO;
        value = (int32_t)unsignedValue;
    } else return NO;
    *out = value;
    return YES;
}
#endif
