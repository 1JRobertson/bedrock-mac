#import <objc/runtime.h>
@interface BedrockPresentPacer : NSObject {
@public
  NSCondition *condition;
  NSUInteger pending;
}
@end
@implementation BedrockPresentPacer
- (id)init {
  if ((self = [super init])) condition = [[NSCondition alloc] init];
  return self;
}
- (void)dealloc {
  [condition release];
  [super dealloc];
}
@end
static char bedrock_pacer_key;
static BedrockPresentPacer *bedrock_layer_pacer(CAMetalLayer *layer) {
  @synchronized(layer) {
    BedrockPresentPacer *pacer = objc_getAssociatedObject(layer, &bedrock_pacer_key);
    if (!pacer) {
      pacer = [[BedrockPresentPacer alloc] init];
      objc_setAssociatedObject(layer, &bedrock_pacer_key, pacer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      [pacer release];
    }
    return pacer;
  }
}
static void bedrock_wait_previous_present(CAMetalLayer *layer) {
  if (!bedrock_present_pacing || !layer) return;
  // Bound hidden-window / lost-display waits; no device lock is held here.
  BedrockPresentPacer *pacer = bedrock_layer_pacer(layer);
  [pacer->condition lock];
  if (pacer->pending >= 2) {
    NSDate *deadline = [[NSDate alloc] initWithTimeIntervalSinceNow:0.05];
    while (pacer->pending >= 2 && [pacer->condition waitUntilDate:deadline]) {}
    [deadline release];
  }
  [pacer->condition unlock];
}
static void bedrock_pace_present(id<MTLDrawable> drawable) {
  if (!bedrock_present_pacing || ![drawable respondsToSelector:@selector(layer)]) return;
  BedrockPresentPacer *pacer = bedrock_layer_pacer(((id<CAMetalDrawable>)drawable).layer);
  [pacer->condition lock];
  ++pacer->pending;
  [pacer->condition unlock];
  // Capture the pacer, never the drawable: avoid a drawable/block retain cycle.
  [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
    [pacer->condition lock];
    --pacer->pending;
    [pacer->condition signal];
    [pacer->condition unlock];
  }];
}
