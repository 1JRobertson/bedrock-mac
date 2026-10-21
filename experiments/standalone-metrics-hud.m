/* A click-through, in-window HUD. Draws at 2 Hz; frame callbacks only store scalars. */
#import "standalone-metrics-hud.h"
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#include <libproc.h>
#include <sys/resource.h>
#include <pthread.h>
#include <math.h>

enum { HUD_HISTORY = 512, HUD_GRAPH = 72 };
static const CGFloat HUD_WIDTH = 276, HUD_HEIGHT = 154;
static BOOL hudVisible = YES; // Only read/written on AppKit's main thread.
static id hudKeyMonitor;
typedef struct {
  double fps, frame, cpu, memory;
  double graph[HUD_GRAPH];
  size_t count;
  bool framesValid, processValid;
} HUDSnapshot;

static CGRect box(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  return CGRectMake(x, HUD_HEIGHT-y-h, w, h);
}
static NSColor *ink(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
  return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}
static CGFloat label(CGContextRef context, NSString *text, CGFloat x, CGFloat top,
                     CGFloat size, NSFontWeight weight, NSColor *color, BOOL right) {
  NSFont *font = [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
  NSDictionary *attributes = @{(__bridge id)kCTFontAttributeName:font,
      (__bridge id)kCTForegroundColorAttributeName:(__bridge id)color.CGColor};
  NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
  CGFloat width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGContextSetTextPosition(context, right ? x-width : x, HUD_HEIGHT-top-font.ascender);
  CTLineDraw(line, context);
  CFRelease(line);
  return width;
}

static void drawHUD(CGContextRef c, HUDSnapshot s) {
  const CGFloat left=16, right=260;
  CGPathRef outline = CGPathCreateWithRoundedRect(CGRectMake(.5,.5,275,153),12,12,NULL);
  CGContextSaveGState(c);
  CGContextAddPath(c,outline); CGContextClip(c);
  CGFloat colors[] = {.065,.085,.10,.92, .028,.042,.054,.91};
  CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
  CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,NULL,2);
  CGContextDrawLinearGradient(c,gradient,CGPointMake(0,HUD_HEIGHT),CGPointZero,0);
  CGGradientRelease(gradient);CGColorSpaceRelease(space);
  CGContextRestoreGState(c);
  CGContextSetStrokeColorWithColor(c,ink(1,1,1,.12).CGColor);
  CGContextSetLineWidth(c,1);CGContextAddPath(c,outline);CGContextStrokePath(c);CGPathRelease(outline);
  NSColor *muted=ink(.66,.73,.77,1), *white=ink(.94,.97,.97,1);
  NSColor *accent=s.framesValid && s.fps<30 ? ink(1,.52,.45,1) :
                   s.framesValid && s.fps<55 ? ink(1,.77,.42,1) : ink(.48,.92,.75,1);
  NSString *fps=s.framesValid ? [NSString stringWithFormat:@"%.0f",s.fps] : @"—";
  CGFloat width=label(c,fps,left,12,38,NSFontWeightSemibold,accent,NO);
  label(c,@"FPS",left+width+7,34,10,NSFontWeightMedium,muted,NO);
  label(c,s.framesValid ? [NSString stringWithFormat:@"%.1f ms",s.frame] : @"— ms",
        right,21,17,NSFontWeightMedium,white,YES);
  label(c,@"FRAME TIME",right,45,8.5,NSFontWeightMedium,muted,YES);
  const CGFloat top=72, height=34, graphWidth=244;
  CGFloat guide=HUD_HEIGHT-top-height*.5;
  CGContextSetStrokeColorWithColor(c,ink(1,1,1,.075).CGColor);
  CGContextSetLineWidth(c,.5);CGContextMoveToPoint(c,left,guide);CGContextAddLineToPoint(c,right,guide);CGContextStrokePath(c);
  if(s.count>1) {
    CGMutablePathRef graph=CGPathCreateMutable();
    for(size_t i=0;i<s.count;i++) {
      CGFloat x=left+graphWidth*i/(s.count-1);
      CGFloat y=HUD_HEIGHT-top-height+height*fmin(fmax(s.graph[i],0)/33.333,1);
      if(!i)CGPathMoveToPoint(graph,NULL,x,y);else CGPathAddLineToPoint(graph,NULL,x,y);
    }
    CGContextSetStrokeColorWithColor(c,accent.CGColor);CGContextSetLineWidth(c,1.4);
    CGContextSetLineJoin(c,kCGLineJoinRound);CGContextAddPath(c,graph);CGContextStrokePath(c);
    CGPathAddLineToPoint(graph,NULL,right,HUD_HEIGHT-top-height);
    CGPathAddLineToPoint(graph,NULL,left,HUD_HEIGHT-top-height);CGPathCloseSubpath(graph);
    CGContextSetFillColorWithColor(c,[accent colorWithAlphaComponent:.07].CGColor);
    CGContextAddPath(c,graph);CGContextFillPath(c);CGPathRelease(graph);
  }
  CGContextSetFillColorWithColor(c,ink(1,1,1,.085).CGColor);
  CGContextFillRect(c,box(left,119,244,.5));
  label(c,@"CPU",left,134,9,NSFontWeightMedium,muted,NO);
  label(c,s.processValid ? [NSString stringWithFormat:@"%.0f%%",s.cpu] : @"—",
        48,130,14,NSFontWeightMedium,white,NO);
  label(c,@"RAM",156,134,9,NSFontWeightMedium,muted,NO);
  label(c,s.processValid ? [NSString stringWithFormat:@"%.1f GiB",s.memory] : @"—",
        right,130,14,NSFontWeightMedium,white,YES);
}

@class BedrockHUDState;
@interface BedrockHUDLayer : CALayer
@property HUDSnapshot snapshot;
@end
@implementation BedrockHUDLayer
- (void)drawInContext:(CGContextRef)context { drawHUD(context,self.snapshot); }
@end

@interface BedrockHUDState : NSObject {
  pthread_mutex_t mutex;
  double times[HUD_HISTORY];
  size_t head, count;
  double lastCPU, lastWall;
}
@property(nonatomic,weak) CAMetalLayer *metal;
@property(nonatomic,strong) BedrockHUDLayer *panel;
@property(nonatomic,strong) dispatch_source_t timer;
- (void)record:(double)time;
- (void)start;
- (void)update;
@end
@implementation BedrockHUDState
- (id)init { if((self=[super init]))pthread_mutex_init(&mutex,NULL); return self; }
- (void)dealloc { if(_timer)dispatch_source_cancel(_timer); pthread_mutex_destroy(&mutex); }
- (void)record:(double)t {
  if(!isfinite(t)||t<=0)return;
  pthread_mutex_lock(&mutex);times[head]=t;head=(head+1)%HUD_HISTORY;
  if(count<HUD_HISTORY)++count;pthread_mutex_unlock(&mutex);
}
- (void)start {
  if(self.panel || !self.metal)return;
  self.panel=[BedrockHUDLayer layer];
  self.panel.contentsScale=self.metal.contentsScale ?: 1;
  self.panel.zPosition=10000;
  self.panel.shadowColor=NSColor.blackColor.CGColor;
  self.panel.shadowOpacity=.25;self.panel.shadowRadius=10;self.panel.shadowOffset=CGSizeMake(0,-3);
  [self.metal addSublayer:self.panel];
  self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
  __weak BedrockHUDState *weakSelf=self;
  dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/2,NSEC_PER_SEC/20);
  dispatch_source_set_event_handler(self.timer,^{[weakSelf update];});
  dispatch_resume(self.timer);
}
- (void)update {
  CAMetalLayer *metal=self.metal;
  if(!metal)return;
  @autoreleasepool {
    double now=CACurrentMediaTime(), data[HUD_HISTORY];size_t n;
    pthread_mutex_lock(&mutex);n=count;
    for(size_t i=0;i<n;i++)data[i]=times[(head+HUD_HISTORY-count+i)%HUD_HISTORY];
    pthread_mutex_unlock(&mutex);
    // Metal may deliver callbacks out of order. Count distinct presentation times.
    for(size_t i=1;i<n;i++){double v=data[i];size_t j=i;while(j&&data[j-1]>v){data[j]=data[j-1];--j;}data[j]=v;}
    size_t valid=0;
    for(size_t i=0;i<n;i++)if(data[i]>=now-2 && (!valid||data[i]-data[valid-1]>.000001))data[valid++]=data[i];
    HUDSnapshot s={0};
    if(valid>1 && now-data[valid-1]<.5){
      s.framesValid=true;s.fps=(valid-1)/(data[valid-1]-data[0]);s.frame=1000/s.fps;
      size_t first=valid>HUD_GRAPH ? valid-HUD_GRAPH : 1;
      for(size_t i=first;i<valid;i++)s.graph[s.count++]=(data[i]-data[i-1])*1000;
    }
    struct rusage cpu;struct rusage_info_v2 memory;
    if(!getrusage(RUSAGE_SELF,&cpu) && !proc_pid_rusage(getpid(),RUSAGE_INFO_V2,(rusage_info_t *)&memory)){
      double seconds=cpu.ru_utime.tv_sec+cpu.ru_utime.tv_usec/1e6+cpu.ru_stime.tv_sec+cpu.ru_stime.tv_usec/1e6;
      if(lastWall>0 && now>lastWall){s.cpu=fmax(0,fmin(100,(seconds-lastCPU)/(now-lastWall)*100/NSProcessInfo.processInfo.activeProcessorCount));s.processValid=true;}
      s.memory=memory.ri_phys_footprint/1073741824.0;lastCPU=seconds;lastWall=now;
    }
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGRect bounds=metal.bounds;
    self.panel.hidden=!hudVisible || bounds.size.width<HUD_WIDTH+36 || bounds.size.height<HUD_HEIGHT+36;
    self.panel.contentsScale=metal.contentsScale ?: 1;
    // Core Animation sublayers use bottom-left coordinates in Wine's Metal host.
    self.panel.frame=CGRectMake(bounds.size.width-HUD_WIDTH-18,bounds.size.height-HUD_HEIGHT-18,HUD_WIDTH,HUD_HEIGHT);
    self.panel.snapshot=s;[self.panel setNeedsDisplay];
    [CATransaction commit];
  }
}
@end

static char hudKey;
static bool hudEnabled;
__attribute__((constructor)) static void initializeHUD(void) {
  const char *value=getenv("BEDROCK_METRICS_HUD");hudEnabled=value && !strcmp(value,"1");
  if(hudEnabled)dispatch_async(dispatch_get_main_queue(),^{
    hudKeyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){
      if(event.keyCode==100 && !event.isARepeat){hudVisible=!hudVisible;return nil;} // F8
      return event;
    }];
  });
}
static BedrockHUDState *stateForLayer(CAMetalLayer *layer) {
  @synchronized(layer) {
    BedrockHUDState *state=objc_getAssociatedObject(layer,&hudKey);
    if(!state){state=[BedrockHUDState new];state.metal=layer;objc_setAssociatedObject(layer,&hudKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      dispatch_async(dispatch_get_main_queue(),^{[state start];});}
    return state;
  }
}
void bedrock_hud_attach(CAMetalLayer *layer) { if(hudEnabled && layer)stateForLayer(layer); }
void bedrock_hud_present(id<MTLDrawable> drawable) {
  if(!hudEnabled || ![drawable respondsToSelector:@selector(layer)])return;
  BedrockHUDState *state=stateForLayer(((id<CAMetalDrawable>)drawable).layer);
  [drawable addPresentedHandler:^(id<MTLDrawable> presented){[state record:presented.presentedTime];}];
}

#ifdef HUD_PREVIEW
int main(int argc,const char **argv) {
  @autoreleasepool {
    if(argc!=2)return 2;
    HUDSnapshot s={.fps=99.8,.frame=10.0,.cpu=18,.memory=3.2,.framesValid=true,.processValid=true,.count=HUD_GRAPH};
    for(size_t i=0;i<HUD_GRAPH;i++)s.graph[i]=10+sin(i*.65)*.9+(i==46?13:0);
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:552 pixelsHigh:308 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *graphics=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    CGContextRef c=graphics.CGContext;CGContextScaleCTM(c,2,2);drawHUD(c,s);
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
  } return 0;
}
#endif
