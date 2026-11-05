/* Disposable QA only: keep the Wine process's surfaces transparent and prevent
 * it from activating apps or changing desktop input. Load before Wine/AppKit
 * startup with DYLD_INSERT_LIBRARIES, never into the user's normal client. */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

static IMP originalOrder;
static unsigned installed;

static void ignoreObject(id self, SEL selector, id value) {
    (void)self; (void)selector; (void)value;
}
static void ignoreVoid(id self, SEL selector) { (void)self; (void)selector; }
static void ignoreBool(id self, SEL selector, BOOL value) {
    (void)self; (void)selector; (void)value;
}
static BOOL denyOptions(id self, SEL selector, NSApplicationActivationOptions options) {
    (void)self; (void)selector; (void)options; return NO;
}
static BOOL denyApplication(id self, SEL selector, id app, NSApplicationActivationOptions options) {
    (void)self; (void)selector; (void)app; (void)options; return NO;
}
static IMP originalPolicy;
static BOOL prohibitActivation(id self, SEL selector, NSApplicationActivationPolicy policy) {
    (void)policy;
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))originalPolicy)(self, selector,
        NSApplicationActivationPolicyProhibited);
}
static IMP originalAlpha;
static IMP originalNotice;
static void backgroundNotice(id self, SEL selector, NSString *name, NSString *object,
    NSDictionary *userInfo, BOOL immediately) {
    if ([name isEqualToString:@"WineAppWillActivateNotification"]) return;
    ((void (*)(id, SEL, id, id, id, BOOL))originalNotice)(self, selector, name, object, userInfo, immediately);
}
static void transparent(id self, SEL selector, CGFloat alpha) {
    (void)alpha; ((void (*)(id, SEL, CGFloat))originalAlpha)(self, selector, 0);
}
static void backgroundOrder(NSWindow *self, SEL selector, NSWindowOrderingMode mode, NSInteger relative) {
    (void)relative;
    self.alphaValue = 0;
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))originalOrder)(self, selector,
        mode == NSWindowOut ? NSWindowOut : NSWindowBelow, 0);
}
static IMP replace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    return method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void installBackgroundGuard(void) {
    const char *enabled = getenv("BEDROCK_NATIVE_BACKGROUND");
    if (!enabled || strcmp(enabled, "1")) _exit(78);
    @autoreleasepool {
        originalPolicy = replace(NSApplication.class, @selector(setActivationPolicy:), (IMP)prohibitActivation);
        originalAlpha = replace(NSWindow.class, @selector(setAlphaValue:), (IMP)transparent);
        originalOrder = replace(NSWindow.class, @selector(orderWindow:relativeTo:), (IMP)backgroundOrder);
        originalNotice = replace(NSDistributedNotificationCenter.class,
            @selector(postNotificationName:object:userInfo:deliverImmediately:), (IMP)backgroundNotice);
        if (!originalPolicy || !originalAlpha || !originalOrder || !originalNotice) _exit(78);
        replace(NSApplication.class, @selector(activateIgnoringOtherApps:), (IMP)ignoreBool);
        replace(NSApplication.class, @selector(activate), (IMP)ignoreVoid);
        replace(NSApplication.class, @selector(yieldActivationToApplication:), (IMP)ignoreObject);
        replace(NSRunningApplication.class, @selector(activateWithOptions:), (IMP)denyOptions);
        replace(NSRunningApplication.class, @selector(activateFromApplication:options:), (IMP)denyApplication);
        replace(NSWindow.class, @selector(makeKeyWindow), (IMP)ignoreVoid);
        replace(NSWindow.class, @selector(makeMainWindow), (IMP)ignoreVoid);
        replace(NSWindow.class, @selector(toggleFullScreen:), (IMP)ignoreObject);
        replace(NSCursor.class, @selector(set), (IMP)ignoreVoid);
        replace(NSCursor.class, @selector(push), (IMP)ignoreVoid);
        replace(object_getClass(NSCursor.class), @selector(hide), (IMP)ignoreVoid);
        replace(object_getClass(NSCursor.class), @selector(unhide), (IMP)ignoreVoid);
        replace(object_getClass(NSCursor.class), @selector(pop), (IMP)ignoreVoid);
        installed = 1;
        fprintf(stderr, "[background-guard] installed pid=%d\n", getpid());
    }
}

unsigned bedrock_background_guard_installed(void) { return installed; }

/* These calls affect the entire login session; a background QA process must
 * never issue them, even when Wine believes its own Windows window has focus. */
static CGError backgroundWarp(CGPoint point) { (void)point; return kCGErrorSuccess; }
static CGError backgroundAssociate(boolean_t connected) { (void)connected; return kCGErrorSuccess; }
static void backgroundPost(CGEventTapLocation tap, CGEventRef event) { (void)tap; (void)event; }
static void backgroundPostPid(pid_t pid, CGEventRef event) { (void)pid; (void)event; }
static CGError backgroundHide(CGDirectDisplayID display) { (void)display; return kCGErrorSuccess; }
static CGError backgroundShow(CGDirectDisplayID display) { (void)display; return kCGErrorSuccess; }
static CFMachPortRef backgroundEventTap(CGEventTapLocation location, CGEventTapPlacement placement,
    CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback, void *context) {
    (void)location; (void)placement; (void)options; (void)mask; (void)callback; (void)context;
    /* Wine's cursor clipper installs a modifying session event tap. */
    return NULL;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) static const struct { \
        const void *replacement; const void *original; \
    } interpose_##original = {(const void *)replacement, (const void *)original}
INTERPOSE(backgroundWarp, CGWarpMouseCursorPosition);
INTERPOSE(backgroundAssociate, CGAssociateMouseAndMouseCursorPosition);
INTERPOSE(backgroundPost, CGEventPost);
INTERPOSE(backgroundPostPid, CGEventPostToPid);
INTERPOSE(backgroundHide, CGDisplayHideCursor);
INTERPOSE(backgroundShow, CGDisplayShowCursor);
INTERPOSE(backgroundEventTap, CGEventTapCreate);
