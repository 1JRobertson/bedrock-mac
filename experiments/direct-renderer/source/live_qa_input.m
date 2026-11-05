/* Opt-in, foreground-guarded HID input and exact-window screenshots for disposable QA.
 * No Accessibility tree, account access or process kills.
 * Build under the shared resource guard; see live_qa.py --help. */
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <time.h>

static double monotonicSeconds(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void respond(NSDictionary *result) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
}

static NSDictionary *identity(pid_t pid) {
    struct proc_bsdinfo b={0}; char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)||
       proc_pidpath(pid,path,sizeof(path))<=0||b.pbi_uid!=getuid())return nil;
    return @{@"pid":@(pid),@"parent":@(b.pbi_ppid),@"seconds":@(b.pbi_start_tvsec),
             @"microseconds":@(b.pbi_start_tvusec),@"executable":[NSString stringWithUTF8String:path]};
}
static NSString *canonical(NSString *path) { return path.stringByStandardizingPath.stringByResolvingSymlinksInPath; }
static BOOL bound(NSDictionary *expected,NSString *bundle) {
    if(![identity([expected[@"pid"] intValue]) isEqual:expected])return NO;
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:[expected[@"pid"] intValue]];
    return app&&!app.terminated&&[app.bundleIdentifier isEqual:bundle];
}
static NSDictionary *windowFor(pid_t pid) {
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    NSDictionary *best=nil;double area=0;
    for(NSDictionary *w in windows){
        if([w[(id)kCGWindowOwnerPID] intValue]!=pid)continue;
        CGRect r; if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r)||r.size.width<64||r.size.height<64)continue;
        if(r.size.width*r.size.height>area){area=r.size.width*r.size.height;best=w;}
    }
    return best;
}
static NSDictionary *waitWindow(pid_t pid,double timeout) {
    double end=monotonicSeconds()+timeout;NSDictionary *window=nil;
    do {@autoreleasepool {
        window=windowFor(pid);if(window)return window;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }}while(monotonicSeconds()<end);
    return nil;
}
static BOOL key(pid_t pid,CGKeyCode code,BOOL down) {
    if(down&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)return NO;
    CGEventRef e=CGEventCreateKeyboardEvent(NULL,code,down);if(!e)return NO;
    CGEventPost(kCGHIDEventTap,e);CFRelease(e);return YES;
}
static BOOL mouse(pid_t pid,CGWindowID window,CGEventType type,CGPoint point) {
    if(type!=kCGEventLeftMouseUp&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)return NO;
    CGEventRef e=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);if(!e)return NO;
    CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointer,window);
    CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,window);
    CGEventSetIntegerValueField(e,kCGMouseEventClickState,type==kCGEventMouseMoved?0:1);
    CGEventPost(kCGHIDEventTap,e);CFRelease(e);return YES;
}
static NSDictionary *windowDiagnostic(NSDictionary *w) {
    if(!w)return @{};
    return @{@"window":w[(id)kCGWindowNumber]?:@0,@"owner_pid":w[(id)kCGWindowOwnerPID]?:@0,
        @"owner_name":w[(id)kCGWindowOwnerName]?:@"",@"layer":w[(id)kCGWindowLayer]?:@0,
        @"alpha":w[(id)kCGWindowAlpha]?:@1,@"bounds":w[(id)kCGWindowBounds]?:@{}};
}
static AXUIElementRef sourceAXWindow(pid_t pid,NSDictionary *window,NSString **failure) {
    if(!AXIsProcessTrusted()){*failure=@"Unsupported source resize: Accessibility permission unavailable";return NULL;}
    CGRect expected;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&expected))return NULL;
    AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.25);
    CFTypeRef value=NULL;AXError status=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&value);CFRelease(app);
    if(status||!value||CFGetTypeID(value)!=CFArrayGetTypeID()||CFArrayGetCount((CFArrayRef)value)>8){
        if(value)CFRelease(value);*failure=@"Unsupported source resize: bounded AX window enumeration failed";return NULL;}
    AXUIElementRef match=NULL;double deadline=monotonicSeconds()+3;
    for(CFIndex i=0;i<CFArrayGetCount((CFArrayRef)value);i++){
        if(monotonicSeconds()>deadline){if(match)CFRelease(match);match=NULL;*failure=@"Unsupported source resize: AX enumeration deadline";break;}
        AXUIElementRef candidate=(AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)value,i);pid_t actual=0;
        AXUIElementSetMessagingTimeout(candidate,0.25);CFTypeRef p=NULL,s=NULL;
        AXError pe=AXUIElementCopyAttributeValue(candidate,kAXPositionAttribute,&p),se=AXUIElementCopyAttributeValue(candidate,kAXSizeAttribute,&s);
        CGPoint position=CGPointZero;CGSize size=CGSizeZero;
        BOOL valid=!pe&&!se&&p&&s&&CFGetTypeID(p)==AXValueGetTypeID()&&CFGetTypeID(s)==AXValueGetTypeID()&&
            AXValueGetValue((AXValueRef)p,kAXValueCGPointType,&position)&&AXValueGetValue((AXValueRef)s,kAXValueCGSizeType,&size)&&
            !AXUIElementGetPid(candidate,&actual)&&actual==pid;
        if(p)CFRelease(p);if(s)CFRelease(s);
        if(!valid||fabs(position.x-expected.origin.x)>2||fabs(position.y-expected.origin.y)>2||
           fabs(size.width-expected.size.width)>2||fabs(size.height-expected.size.height)>2)continue;
        if(match){CFRelease(match);match=NULL;*failure=@"Ambiguous source resize: multiple AX windows match exact source bounds";break;}
        match=(AXUIElementRef)CFRetain(candidate);
    }
    CFRelease(value);
    if(!match&&!*failure)*failure=@"Unsupported source resize: no exact AX source window";
    return match;
}
static BOOL waitForeground(pid_t pid,double seconds) {
    double end=monotonicSeconds()+seconds;
    do {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
        if(NSApp){for(unsigned i=0;i<32;i++){
            NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
            if(!event)break;[NSApp sendEvent:event];}[NSApp updateWindows];}
        if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==pid)return YES;
    }while(monotonicSeconds()<end);
    return NO;
}
static NSDictionary *visualHit(CGPoint point,CGWindowID source,CGWindowID overlay) {
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    NSDictionary *visual=@{};
    for(NSDictionary *w in windows){
        CGRect r;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r)||
            r.size.width<=0||r.size.height<=0||!CGRectContainsPoint(r,point)||
            (w[(id)kCGWindowAlpha]&&[w[(id)kCGWindowAlpha] doubleValue]<=0))continue;
        CGWindowID number=[w[(id)kCGWindowNumber] unsignedIntValue];
        visual=windowDiagnostic(w);
        if(number==source||(overlay&&number==overlay))return @{@"owned":@YES,@"method":@"exact-window",@"hit":visual};
        break;
    }
    /* Visual stacking includes noninteractive capture overlays. Diagnostic only;
     * exact process/foreground/source bounds govern actual input authorization. */
    return @{@"owned":@NO,@"method":@"visual-diagnostic-only",@"hit":visual};
}
static NSArray *recognize(NSURL *url) {
    VNRecognizeTextRequest *request=[VNRecognizeTextRequest new];
    request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;request.usesLanguageCorrection=NO;
    request.recognitionLanguages=@[@"en-US"];
    VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithURL:url options:@{}];
    NSError *error=nil;if(![handler performRequests:@[request] error:&error])return nil;
    NSImageRep *representation=[NSBitmapImageRep imageRepWithContentsOfURL:url];
    NSBitmapImageRep *bitmap=[representation isKindOfClass:NSBitmapImageRep.class]?(NSBitmapImageRep *)representation:nil;
    NSMutableArray *text=[NSMutableArray new];
    for(VNRecognizedTextObservation *observation in request.results){
        VNRecognizedText *candidate=[observation topCandidates:1].firstObject;if(!candidate)continue;
        CGRect b=observation.boundingBox;
        unsigned green=0,samples=0;
        if(bitmap){
            for(unsigned iy=0;iy<5;iy++)for(unsigned ix=0;ix<24;ix++){
                double x=CGRectGetMinX(b)-0.025+(b.size.width+0.05)*(ix+0.5)/24;
                double y=1-CGRectGetMaxY(b)-b.size.height*0.3+b.size.height*1.6*(iy+0.5)/5;
                NSInteger px=(NSInteger)(x*bitmap.pixelsWide),py=(NSInteger)(y*bitmap.pixelsHigh);
                if(px<0||py<0||px>=bitmap.pixelsWide||py>=bitmap.pixelsHigh)continue;
                NSColor *color=[[bitmap colorAtX:px y:py] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
                if(!color)continue;++samples;
                if(color.greenComponent>0.25&&color.greenComponent>color.redComponent*1.5&&color.greenComponent>color.blueComponent*1.5)++green;
            }
        }
        [text addObject:@{@"text":candidate.string,@"confidence":@(candidate.confidence),
                         @"x":@(CGRectGetMidX(b)),@"y":@(1-CGRectGetMidY(b)),@"width":@(b.size.width),@"height":@(b.size.height),
                         @"highlighted":@(samples&&green*5>samples),@"green_sample_fraction":@(samples?(double)green/samples:0)}];
    }
    return text;
}
static NSArray *coordinateOCR(NSURL *url,NSArray *rows) {
    NSImageRep *representation=[NSBitmapImageRep imageRepWithContentsOfURL:url];
    if(![representation isKindOfClass:NSBitmapImageRep.class])return @[];
    NSBitmapImageRep *bitmap=(NSBitmapImageRep *)representation;
    CGImageRef image=bitmap.CGImage;if(!image)return @[];
    double width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    NSMutableArray *evidence=[NSMutableArray new];
    for(NSDictionary *row in rows){
        if(evidence.count>=4)break;
        if([row[@"text"] rangeOfString:@"Position" options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
        double textWidth=[row[@"width"] doubleValue]*width,textHeight=[row[@"height"] doubleValue]*height;
        double left=MAX(0,[row[@"x"] doubleValue]*width-textWidth/2-6);
        double top=MAX(0,[row[@"y"] doubleValue]*height-textHeight/2-6);
        CGRect bounds=CGRectIntersection(CGRectMake(left,top,MAX(textWidth*4,width/2),textHeight+12),CGRectMake(0,0,width,height));
        CGImageRef crop=CGImageCreateWithImageInRect(image,bounds);if(!crop)continue;
        size_t w=CGImageGetWidth(crop)*4,h=CGImageGetHeight(crop)*4;
        if(!w||!h||w>8192||h>1024){CGImageRelease(crop);continue;}
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate(NULL,w,h,8,w*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(color);if(!context){CGImageRelease(crop);continue;}
        CGContextSetInterpolationQuality(context,kCGInterpolationNone);
        CGContextDrawImage(context,CGRectMake(0,0,w,h),crop);CGImageRelease(crop);
        for(int variant=0;variant<2;variant++){
            if(variant){
                uint8_t *bytes=CGBitmapContextGetData(context);
                for(size_t i=0;i<w*h;i++){uint8_t *p=bytes+i*4;
                    uint8_t value=MAX(p[0],MAX(p[1],p[2]))>160?0:255;p[0]=p[1]=p[2]=value;p[3]=255;}
            }
            CGImageRef enlarged=CGBitmapContextCreateImage(context);if(!enlarged)continue;
            VNRecognizeTextRequest *request=[VNRecognizeTextRequest new];request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection=NO;request.recognitionLanguages=@[@"en-US"];
            VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:enlarged options:@{}];
            NSError *error=nil;
            if([handler performRequests:@[request] error:&error]){
                NSArray *sorted=[request.results sortedArrayUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a,VNRecognizedTextObservation *b){
                    return a.boundingBox.origin.x<b.boundingBox.origin.x?NSOrderedAscending:NSOrderedDescending;}];
                NSMutableArray *parts=[NSMutableArray new];
                for(VNRecognizedTextObservation *observation in sorted){VNRecognizedText *candidate=[observation topCandidates:1].firstObject;
                    if(candidate)[parts addObject:candidate.string];}
                [evidence addObject:@{@"variant":variant?@"marker-crop-4x-threshold-inverted":@"marker-crop-4x",
                    @"text":[parts componentsJoinedByString:@" "],@"crop":@{@"x":@(bounds.origin.x),@"y":@(bounds.origin.y),@"width":@(bounds.size.width),@"height":@(bounds.size.height)}}];
            }
            CGImageRelease(enlarged);
        }
        CGContextRelease(context);
    }
    return evidence;
}
static NSDictionary *cardOutline(NSURL *url,NSDictionary *anchor) {
    NSImageRep *representation=[NSBitmapImageRep imageRepWithContentsOfURL:url];
    if(![representation isKindOfClass:NSBitmapImageRep.class])return @{@"detected":@NO,@"unsupported":@"not a bitmap"};
    NSBitmapImageRep *bitmap=(NSBitmapImageRep *)representation;
    if(bitmap.bitsPerSample!=8||bitmap.samplesPerPixel<3||bitmap.samplesPerPixel>4||bitmap.isPlanar)
        return @{@"detected":@NO,@"unsupported":@"requires bounded 8-bit RGB bitmap"};
    double x=[anchor[@"x"] doubleValue],y=[anchor[@"y"] doubleValue],w=[anchor[@"width"] doubleValue],h=[anchor[@"height"] doubleValue];
    if(!isfinite(x)||!isfinite(y)||!isfinite(w)||!isfinite(h)||x<0||x>1||y<0||y>1||w<=0||w>0.4||h<=0||h>0.1)
        return @{@"detected":@NO,@"unsupported":@"invalid named-row anchor"};
    double tw=w*bitmap.pixelsWide,th=h*bitmap.pixelsHigh,left=(x-w/2)*bitmap.pixelsWide,top=(y-h/2)*bitmap.pixelsHigh;
    NSInteger x0=MAX(0,(NSInteger)floor(left-th*3)),y0=MAX(0,(NSInteger)floor(top-th*2.5));
    /* A short name such as "world" can sit inside a ~400px card. Search the
       full bounded card width, not only a multiple of the text width. */
    NSInteger x1=MIN(bitmap.pixelsWide,(NSInteger)ceil(left+MAX(tw*6,th*22))),y1=MIN(bitmap.pixelsHigh,(NSInteger)ceil(top+th*5));
    NSInteger rw=x1-x0,rh=y1-y0;
    if(rw<=0||rh<=0||rw>2048||rh>1024)return @{@"detected":@NO,@"unsupported":@"named-card pixel region exceeds budget"};
    NSMutableData *mask=[NSMutableData dataWithLength:(NSUInteger)(rw*rh)];uint8_t *white=mask.mutableBytes;
    NSUInteger components[5]={0};NSUInteger offset=(bitmap.bitmapFormat&NSBitmapFormatAlphaFirst)?1:0;
    for(NSInteger py=0;py<rh;py++)for(NSInteger px=0;px<rw;px++){
        [bitmap getPixel:components atX:x0+px y:y0+py];
        NSUInteger r=components[offset],g=components[offset+1],b=components[offset+2];
        white[py*rw+px]=r>=235&&g>=235&&b>=235&&MAX(r,MAX(g,b))-MIN(r,MIN(g,b))<=12;
    }
    NSMutableArray *upper=[NSMutableArray new],*lower=[NSMutableArray new];
    for(NSInteger py=0;py<rh;py++){
        for(NSInteger px=0;px<rw;){if(!white[py*rw+px]){px++;continue;}
            NSInteger start=px;while(px<rw&&white[py*rw+px])px++;NSInteger end=px-1;
            if(end-start+1<MAX(tw*1.4,th*6)||x0+start>left-2||x0+end<left+tw+2)continue;
            NSDictionary *line=@{@"left":@(start),@"right":@(end),@"y":@(py)};
            if(y0+py<top-th*0.3&&upper.count<32)[upper addObject:line];
            if(y0+py>top+th*1.3&&lower.count<32)[lower addObject:line];
        }
    }
    NSInteger band=MAX(2,(NSInteger)ceil(th*0.15));
    for(NSDictionary *a in upper)for(NSDictionary *b in lower){
        NSInteger l=[a[@"left"] integerValue],r=[a[@"right"] integerValue],t=[a[@"y"] integerValue],bottom=[b[@"y"] integerValue];
        if(labs(l-[b[@"left"] integerValue])>band||labs(r-[b[@"right"] integerValue])>band||bottom-t<th*2||bottom-t>th*6)continue;
        unsigned lc=0,rc=0,count=0;
        for(NSInteger py=t;py<=bottom;py++){
            BOOL le=NO,re=NO;for(NSInteger dx=0;dx<band;dx++){
                if(l+dx<rw)le|=white[py*rw+l+dx];if(r-dx>=0)re|=white[py*rw+r-dx];}
            lc+=le;rc+=re;++count;
        }
        if(lc*10<count*9||rc*10<count*9)continue;
        return @{@"detected":@YES,@"method":@"four white pixel edges enclosing named-card label",
            @"bounds":@{@"x":@(x0+l),@"y":@(y0+t),@"width":@(r-l+1),@"height":@(bottom-t+1)},
            @"left_coverage":@((double)lc/count),@"right_coverage":@((double)rc/count)};
    }
    return @{@"detected":@NO,@"method":@"no enclosing four-edge white card focus outline"};
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==7&&!strcmp(argv[1],"--card-outline")){
        NSDictionary *anchor=@{@"x":@(strtod(argv[3],NULL)),@"y":@(strtod(argv[4],NULL)),@"width":@(strtod(argv[5],NULL)),@"height":@(strtod(argv[6],NULL))};
        respond(@{@"ok":@YES,@"outline":cardOutline([NSURL fileURLWithPath:@(argv[2])],anchor)});return 0;
    }
    if(argc==3&&!strcmp(argv[1],"--ocr-image")){
        NSURL *url=[NSURL fileURLWithPath:@(argv[2])];NSArray *rows=recognize(url);
        if(!rows){respond(@{@"ok":@NO,@"error":@"Offline image OCR failed"});return 1;}
        respond(@{@"ok":@YES,@"text":rows,@"coordinate_ocr":coordinateOCR(url,rows)});return 0;
    }
    if(argc==2&&!strcmp(argv[1],"--capabilities")){
        respond(@{@"input_allowed":@(CGPreflightPostEventAccess()),@"capture_allowed":@(CGPreflightScreenCaptureAccess()),
                  @"accessibility_allowed":[NSNumber numberWithBool:AXIsProcessTrusted()],
                  @"clock":@"CLOCK_MONOTONIC",@"monotonic_seconds":@(monotonicSeconds())});return 0;
    }
    if(argc!=8)return 2;
    pid_t pid=(pid_t)strtol(argv[1],NULL,10);
    NSString *executable=canonical(@(argv[2])),*bundle=@(argv[3]);
    NSString *nativeExecutable=canonical(@(argv[4])),*nativeBundle=@(argv[5]),*output=canonical(@(argv[6]));
    pid_t nativePID=(pid_t)strtol(argv[7],NULL,10);
    NSDictionary *owner=nil,*native=nil,*initial=identity(pid),*observed=nil;
    double startupDeadline=monotonicSeconds()+20;NSString *startupReason=@"process-not-ready";
    do {@autoreleasepool {
        observed=identity(pid);
        if(initial&&observed&&(![initial[@"seconds"] isEqual:observed[@"seconds"]]||
           ![initial[@"microseconds"] isEqual:observed[@"microseconds"]])){startupReason=@"process-start-identity-changed";break;}
        if(observed&&[canonical(observed[@"executable"]) isEqual:executable]){
            startupReason=@"bundle-not-ready-or-mismatched";
            if(bound(observed,bundle)){owner=observed;break;}
        }else startupReason=observed?@"executable-not-ready-or-mismatched":@"process-not-ready";
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }}while(monotonicSeconds()<startupDeadline);
    if(!owner){
        NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        respond(@{@"ok":@NO,@"event":@"startup-rejected",@"error":[@"Owned game startup rejected: " stringByAppendingString:startupReason],
                  @"observed_executable":observed[@"executable"]?:@"",@"observed_bundle":app.bundleIdentifier?:@""});return 3;
    }
    respond(@{@"ok":@YES,@"event":@"ready",@"identity":owner,@"monotonic_seconds":@(monotonicSeconds())});
    NSMutableSet<NSNumber *> *held=[NSMutableSet new];
    BOOL mouseHeld=NO;CGPoint mousePoint=CGPointZero;CGWindowID mouseWindow=0;
    unsigned relativeMoves=0;unsigned relativeDistance=0;
    NSWindow *focusWindow=nil;BOOL focusInitialized=NO;CGRect originalResizeBounds=CGRectZero;CGWindowID resizeWindow=0;
    char *line=NULL;size_t capacity=0;
    while(getline(&line,&capacity,stdin)>0){@autoreleasepool {
        NSMutableDictionary *result=[@{@"ok":@NO} mutableCopy];
        @try {
            /* NSWorkspace caches foreground state until a main-run-loop turn. */
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            if(strlen(line)>16384)@throw @"Oversized command";
            NSDictionary *command=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line length:strlen(line)] options:0 error:NULL];
            NSString *operation=command[@"op"];
            if(![command isKindOfClass:NSDictionary.class]||(!bound(owner,bundle)&&![operation isEqual:@"release"]))@throw @"Owned game identity changed";
            if([operation isEqual:@"probe"]){result[@"identity"]=owner;result[@"input_allowed"]=@(CGPreflightPostEventAccess());result[@"capture_allowed"]=@(CGPreflightScreenCaptureAccess());}
            else if([operation isEqual:@"foreground"]){result[@"foreground_pid"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);}
            else if([operation isEqual:@"card-outline"]){
                NSString *name=command[@"name"];NSDictionary *anchor=command[@"anchor"];
                if(![name isKindOfClass:NSString.class]||![name.lastPathComponent isEqual:name]||![name.pathExtension isEqual:@"png"]||
                   ![anchor isKindOfClass:NSDictionary.class])@throw @"Invalid owned card-outline image/anchor";
                result[@"outline"]=cardOutline([NSURL fileURLWithPath:[output stringByAppendingPathComponent:name]],anchor);
            }
            else if([operation isEqual:@"observe"]){
                if(!native){NSDictionary *candidate=identity(nativePID);
                    if(candidate&&[candidate[@"parent"] isEqual:owner[@"parent"]]&&[canonical(candidate[@"executable"]) isEqual:nativeExecutable]&&bound(candidate,nativeBundle))native=candidate;}
                if(!native||!bound(native,nativeBundle))@throw @"Owned native observation identity changed";
                NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                result[@"foreground_pid"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
                result[@"source_active"]=[NSNumber numberWithBool:app.active];result[@"source_hidden"]=[NSNumber numberWithBool:app.hidden];
                result[@"source_window"]=windowDiagnostic(windowFor(pid));result[@"native_window"]=windowDiagnostic(windowFor(nativePID));
                result[@"helper_pid"]=@(getpid());result[@"primary_height"]=@(CGDisplayBounds(CGMainDisplayID()).size.height);
            }
            else if([operation isEqual:@"background"]){
                if(held.count||mouseHeld||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned background transition requires foreground and released input";
                if(!focusInitialized){[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];focusInitialized=YES;}
                if(!focusWindow){focusWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,240,90)
                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];focusWindow.releasedWhenClosed=NO;
                    focusWindow.title=@"Owned renderer QA focus";[focusWindow center];}
                [focusWindow makeKeyAndOrderFront:nil];[NSRunningApplication.currentApplication activateWithOptions:0];
                if(!waitForeground(getpid(),2))@throw @"Owned QA focus window did not become foreground";
                result[@"helper_pid"]=@(getpid());
            }
            else if([operation isEqual:@"activate"]){
                [focusWindow orderOut:nil];
                NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                [app activateWithOptions:0];
                for(int i=0;i<40&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid;i++){[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];}
                if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned game did not become foreground";
            }
            else if([operation isEqual:@"resize"]){
                if(held.count||mouseHeld||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned source resize requires foreground and released input";
                NSDictionary *source=windowFor(pid);CGRect current;
                if(!source||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source[(id)kCGWindowBounds],&current)||
                   [source[(id)kCGWindowNumber] unsignedIntValue]!=[command[@"window"] unsignedIntValue])@throw @"Owned source resize window changed";
                if(!resizeWindow){resizeWindow=[source[(id)kCGWindowNumber] unsignedIntValue];originalResizeBounds=current;}
                double width=[command[@"width"] doubleValue],height=[command[@"height"] doubleValue];
                if(resizeWindow!=[source[(id)kCGWindowNumber] unsignedIntValue]||!isfinite(width)||!isfinite(height)||
                   width<640||height<480||width>originalResizeBounds.size.width+1||height>originalResizeBounds.size.height+1)@throw @"Source resize exceeds owned original/minimum bounds";
                NSString *failure=nil;AXUIElementRef window=sourceAXWindow(pid,source,&failure);if(!window)@throw failure?:@"Unsupported source AX resize";
                Boolean settable=false;AXError status=AXUIElementIsAttributeSettable(window,kAXSizeAttribute,&settable);
                if(status||!settable){CFRelease(window);@throw @"Unsupported source resize: AX size is not writable";}
                if(!bound(owner,bundle)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid){CFRelease(window);@throw @"Owned resize identity/focus changed before update";}
                CGSize size=CGSizeMake(width,height);AXValueRef value=AXValueCreate(kAXValueCGSizeType,&size);
                status=value?AXUIElementSetAttributeValue(window,kAXSizeAttribute,value):kAXErrorFailure;
                if(value)CFRelease(value);CFRelease(window);
                if(status)@throw [NSString stringWithFormat:@"Unsupported source resize: AX size update failed (%d)",status];
                result[@"requested_width"]=@(width);result[@"requested_height"]=@(height);result[@"source_window"]=windowDiagnostic(windowFor(pid));
            }
            else if([operation isEqual:@"close-window"]){
                if(held.count||mouseHeld||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned normal close requires foreground and released input";
                NSDictionary *source=windowFor(pid);
                if(!source||[source[(id)kCGWindowNumber] unsignedIntValue]!=[command[@"window"] unsignedIntValue])@throw @"Owned normal close source window changed";
                NSString *failure=nil;AXUIElementRef window=sourceAXWindow(pid,source,&failure);
                if(!window)@throw [@"Unsupported source close: " stringByAppendingString:failure?:@"exact AX window unavailable"];
                CFTypeRef button=NULL;AXError status=AXUIElementCopyAttributeValue(window,kAXCloseButtonAttribute,&button);CFRelease(window);
                if(status||!button||CFGetTypeID(button)!=AXUIElementGetTypeID()){
                    if(button)CFRelease(button);@throw @"Unsupported source close: no exact AX close button";}
                AXUIElementSetMessagingTimeout((AXUIElementRef)button,0.25);pid_t actualPID=0;
                CFArrayRef actions=NULL;status=AXUIElementCopyActionNames((AXUIElementRef)button,&actions);
                BOOL press=!status&&actions&&CFArrayContainsValue(actions,CFRangeMake(0,CFArrayGetCount(actions)),kAXPressAction);
                if(actions)CFRelease(actions);
                if(!press||AXUIElementGetPid((AXUIElementRef)button,&actualPID)||actualPID!=pid){
                    CFRelease(button);@throw @"Unsupported source close: close button is not pressable by exact owner";}
                NSDictionary *fresh=windowFor(pid);
                if(!bound(owner,bundle)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid||
                   ![fresh[(id)kCGWindowNumber] isEqual:source[(id)kCGWindowNumber]]||
                   ![fresh[(id)kCGWindowBounds] isEqual:source[(id)kCGWindowBounds]]){
                    CFRelease(button);@throw @"Owned source close identity/window/focus changed before press";}
                status=AXUIElementPerformAction((AXUIElementRef)button,kAXPressAction);CFRelease(button);
                if(status)@throw [NSString stringWithFormat:@"Unsupported source close: normal AXPress failed (%d)",status];
                result[@"normal_close_requested"]=@YES;result[@"source_window"]=windowDiagnostic(source);
            }
            else if([operation isEqual:@"key"]){
                int code=[command[@"code"] intValue];BOOL down=[command[@"down"] boolValue];
                if((code!=13&&code!=53&&code!=36&&code!=125&&code!=126&&code!=123&&code!=124)||!CGPreflightPostEventAccess())@throw @"Key outside replay allowlist or input permission unavailable";
                if(down&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned game lost foreground";
                if(!down&&![held containsObject:@(code)])@throw @"No owned key-down to release";
                if(!key(pid,(CGKeyCode)code,down))@throw @"Cannot construct targeted key";
                if(down)[held addObject:@(code)];else [held removeObject:@(code)];
                if(!down&&NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned game lost foreground during held key";
            }
            else if([operation isEqual:@"quit"]){
                if(!CGPreflightPostEventAccess()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned game lacks quit permission/foreground";
                /* Standard macOS Quit after the harness has verified Save & Quit.
                 * This requests the owned application's normal lifecycle; no kill. */
                for(NSNumber *down in @[@YES,@NO]){
                    CGEventRef e=CGEventCreateKeyboardEvent(NULL,12,down.boolValue);
                    if(!e)@throw @"Cannot construct targeted Quit shortcut";
                    CGEventSetFlags(e,kCGEventFlagMaskCommand);CGEventPost(kCGHIDEventTap,e);CFRelease(e);
                    if(down.boolValue)usleep(150000);
                }
            }
            else if([operation isEqual:@"relative-move"]){
                id value=command[@"delta_x"];double delta=[value isKindOfClass:NSNumber.class]?[value doubleValue]:NAN;
                if(!isfinite(delta)||floor(delta)!=delta||delta==0||fabs(delta)>8||relativeMoves>=80||
                   relativeDistance+(unsigned)fabs(delta)>640)@throw @"Relative mouse request exceeds bounded turn budget";
                if(!CGPreflightPostEventAccess()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid||
                   held.count||mouseHeld||CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)||
                   CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonRight)||
                   CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonCenter))@throw @"Owned relative mouse requires foreground and no held input";
                NSDictionary *source=windowFor(pid);CGRect bounds;
                CGEventRef current=CGEventCreate(NULL);if(!current)@throw @"Cannot observe owned cursor location";
                CGPoint point=CGEventGetLocation(current);CFRelease(current);
                if(!source||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source[(id)kCGWindowBounds],&bounds)||
                   !CGRectContainsPoint(bounds,point))@throw @"Relative mouse cursor is outside exact owned window";
                CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);
                if(!event)@throw @"Cannot construct relative horizontal mouse event";
                CGEventSetIntegerValueField(event,kCGMouseEventDeltaX,(int64_t)delta);
                CGEventSetIntegerValueField(event,kCGMouseEventDeltaY,0);
                CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,[source[(id)kCGWindowNumber] longLongValue]);
                CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,[source[(id)kCGWindowNumber] longLongValue]);
                if(!bound(owner,bundle)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid){CFRelease(event);@throw @"Owned relative mouse identity/focus changed";}
                CGEventPost(kCGHIDEventTap,event);CFRelease(event);++relativeMoves;relativeDistance+=(unsigned)fabs(delta);
                result[@"requested_delta_x"]=@((int64_t)delta);result[@"posted_relative_events"]=@(relativeMoves);
                result[@"camera_rotation_observed"]=[NSNull null];
            }
            else if([operation isEqual:@"click"]){
                if(!CGPreflightPostEventAccess()||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned game lacks input permission/foreground";
                BOOL nativeClick=[command[@"native"] boolValue];
                if(nativeClick&&(!native||!bound(native,nativeBundle)))@throw @"Owned native click surface missing";
                NSDictionary *w=windowFor(nativeClick?nativePID:pid);CGRect r;
                if(!w||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r))@throw @"Owned source window missing";
                NSDictionary *source=windowFor(pid);if(!source)@throw @"Exact input source window missing";
                CGWindowID sourceWindow=[source[(id)kCGWindowNumber] unsignedIntValue];
                double x=[command[@"x"] doubleValue],y=[command[@"y"] doubleValue];
                if(!isfinite(x)||!isfinite(y)||x<0||x>1||y<0||y>1)@throw @"Click outside source window";
                CGPoint point=CGPointMake(r.origin.x+x*r.size.width,r.origin.y+y*r.size.height);
                if(!CGRectContainsPoint(r,point))@throw @"Requested input point is outside exact owned surface";
                CGWindowID overlayWindow=nativeClick?[w[(id)kCGWindowNumber] unsignedIntValue]:0;
                NSDictionary *hit=visualHit(point,sourceWindow,overlayWindow);
                result[@"mouse_guard"]=@{@"expected_source":windowDiagnostic(source),@"expected_surface":windowDiagnostic(w),
                    @"normalized":@{@"x":@(x),@"y":@(y)},@"screen_point":@{@"x":@(point.x),@"y":@(point.y)},@"observed":hit};
                if(!mouse(pid,sourceWindow,kCGEventMouseMoved,point))@throw @"Cannot construct targeted mouse move";
                usleep(50000);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                NSDictionary *currentSource=windowFor(pid);CGRect currentBounds;
                if(!bound(owner,bundle)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid||
                   !currentSource||[currentSource[(id)kCGWindowNumber] unsignedIntValue]!=sourceWindow||
                   !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)currentSource[(id)kCGWindowBounds],&currentBounds)||
                   !CGRectContainsPoint(currentBounds,point))@throw @"Owned mouse target/focus changed before down";
                if(!mouse(pid,sourceWindow,kCGEventLeftMouseDown,point))@throw @"Cannot construct targeted mouse down";
                mouseHeld=YES;mousePoint=point;mouseWindow=sourceWindow;
                usleep(150000);
                if(!mouse(pid,sourceWindow,kCGEventLeftMouseUp,point))@throw @"Cannot release owned mouse-down";
                mouseHeld=NO;
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                if(!bound(owner,bundle)||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=pid)@throw @"Owned target/focus changed during click";
                result[@"source_window"]=@(sourceWindow);result[@"hold_seconds"]=@0.15;
            }
            else if([operation isEqual:@"snapshot"]){
                double snapshotDeadline=monotonicSeconds()+20;
                BOOL wantNative=[command[@"native"] boolValue];pid_t capturePID=pid;
                if(wantNative){
                    if(!native){
                        double deadline=snapshotDeadline;
                        do {@autoreleasepool {
                            NSDictionary *i=identity(nativePID);
                            if(i&&[i[@"parent"] isEqual:owner[@"parent"]]&&[canonical(i[@"executable"]) isEqual:nativeExecutable]&&bound(i,nativeBundle)){native=i;break;}
                            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
                        }}while(monotonicSeconds()<deadline);
                    }
                    if(!native||!bound(native,nativeBundle))@throw @"Owned native presenter window missing";
                    capturePID=[native[@"pid"] intValue];
                }
                NSDictionary *w=waitWindow(capturePID,MAX(0,snapshotDeadline-monotonicSeconds()));if(!w)@throw @"Exact capture window missing after startup deadline";
                NSString *name=command[@"name"];
                if(![name isKindOfClass:NSString.class]||![name.lastPathComponent isEqual:name]||![name.pathExtension isEqual:@"png"])@throw @"Invalid screenshot leaf";
                NSString *path=[output stringByAppendingPathComponent:name];
                if([[NSFileManager defaultManager] fileExistsAtPath:path])@throw @"Screenshot already exists";
                BOOL captured=NO;int lastCode=-1;
                for(int attempt=0;attempt<3&&!captured;attempt++){
                    if(!bound(owner,bundle)||(wantNative&&!bound(native,nativeBundle)))@throw @"Capture process identity changed";
                    w=windowFor(capturePID);if(!w){usleep(100000);continue;}
                    NSTask *capture=[NSTask new];capture.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
                    capture.arguments=@[@"-x",@"-o",@"-l",[w[(id)kCGWindowNumber] stringValue],path];
                    capture.standardOutput=[NSFileHandle fileHandleWithNullDevice];capture.standardError=[NSFileHandle fileHandleWithNullDevice];
                    NSError *error=nil;if(![capture launchAndReturnError:&error])@throw @"Cannot launch exact-window capture";
                    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
                    while(capture.running&&deadline.timeIntervalSinceNow>0)usleep(10000);
                    if(capture.running){[capture terminate];@throw @"Exact-window capture deadline";}
                    lastCode=capture.terminationStatus;captured=lastCode==0;
                    if(!captured){[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];usleep(100000);}
                }
                if(!captured)@throw [NSString stringWithFormat:@"Exact-window capture failed after 3 fresh-window attempts (exit %d)",lastCode];
                NSArray *text=recognize([NSURL fileURLWithPath:path]);if(!text)@throw @"Screenshot OCR failed";
                result[@"coordinate_ocr"]=coordinateOCR([NSURL fileURLWithPath:path],text);
                result[@"text"]=text;result[@"window"]=w[(id)kCGWindowNumber];result[@"capture_pid"]=@(capturePID);result[@"native"]=@(wantNative);
            }
            else if([operation isEqual:@"release"]){for(NSNumber *code in held)key(pid,code.unsignedShortValue,NO);[held removeAllObjects];
                if(mouseHeld){mouse(pid,mouseWindow,kCGEventLeftMouseUp,mousePoint);mouseHeld=NO;}}
            else @throw @"Unknown operation";
            result[@"ok"]=@YES;
        }@catch(id error){if(mouseHeld){mouse(pid,mouseWindow,kCGEventLeftMouseUp,mousePoint);mouseHeld=NO;}
            result[@"error"]=[error isKindOfClass:NSString.class]?error:@"Input helper exception";}
        respond(result);
    }}
    for(NSNumber *code in held)key(pid,code.unsignedShortValue,NO);
    if(mouseHeld)mouse(pid,mouseWindow,kCGEventLeftMouseUp,mousePoint);
    [focusWindow close];
    free(line);return 0;
}}
