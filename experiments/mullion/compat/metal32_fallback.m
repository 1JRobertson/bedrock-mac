/* Experimental process-local workaround for v0.3's internal library built as MSL 4.1.
 * Does not replace Wine/Metal files. Only recognizes Mullion's own command library.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <string.h>
#include <stdlib.h>

static id (*originalLibrary)(id, SEL, dispatch_data_t, NSError **);
static BOOL containsBytes(const void *bytes, size_t length, const char *needle) {
    return memmem(bytes, length, needle, strlen(needle)) != NULL;
}

static id fallbackLibrary(id device, SEL selector, dispatch_data_t data, NSError **error) {
    NSError *originalError = nil;
    id library = originalLibrary(device, selector, data, &originalError);
    if (library) {
        if (error) *error = nil;
        return library;
    }
    const char *sourcePath = getenv("MULLION_COMPAT_INTERNAL_SOURCE");
    NSString *message = [originalError localizedDescription];
    BOOL versionFailure = [message rangeOfString:@"4.1"].location != NSNotFound &&
                          [message rangeOfString:@"language" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!sourcePath || !versionFailure) {
        if (error) *error = originalError;
        return nil;
    }
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &length);
    BOOL isInternal = containsBytes(bytes, length, "mullion_ray_trace") &&
                      containsBytes(bytes, length, "cs_clear_sparse_tbuffer");
    dispatch_release(mapped);
    if (!isInternal) {
        if (error) *error = originalError;
        return nil;
    }
    NSError *readError = nil;
    NSString *source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:sourcePath]
                                               encoding:NSUTF8StringEncoding error:&readError];
    if (!source) {
        fprintf(stderr, "Mullion Metal3.2 fallback: cannot read internal source\n");
        if (error) *error = readError;
        return nil;
    }
    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    options.languageVersion = (MTLLanguageVersion)((3 << 16) | 2);
    NSError *compileError = nil;
    library = [(id<MTLDevice>)device newLibraryWithSource:source options:options error:&compileError];
    [options release];
    fprintf(stderr, "Mullion Metal3.2 fallback: internal library %s\n", library ? "compiled" : "failed");
    if (!library) fprintf(stderr, "%s\n", [[compileError localizedDescription] UTF8String]);
    if (error) *error = compileError;
    return library;
}

__attribute__((constructor)) static void installFallback(void) {
    if (!getenv("MULLION_COMPAT_INTERNAL_SOURCE")) return;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return;
        Method method = class_getInstanceMethod(object_getClass(device), @selector(newLibraryWithData:error:));
        if (method) {
            originalLibrary = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)fallbackLibrary);
            fprintf(stderr, "Mullion Metal3.2 fallback: installed for internal command library only\n");
        }
        [device release];
    }
}
