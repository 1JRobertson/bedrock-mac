#import <Metal/Metal.h>

/* Diagnostic only. Called before scheduling either kind of drawable present. */
void bedrock_trace_present(id<MTLDrawable> drawable, double minimum_duration);
