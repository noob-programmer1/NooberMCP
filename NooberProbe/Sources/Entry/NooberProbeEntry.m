// NooberProbeEntry.m — Objective-C bootstrap entry point.
//
// iOS 26.2+ simulator's dyld silently skips C `__attribute__((constructor))`
// entries for dylibs loaded via DYLD_INSERT_LIBRARIES — the dylib gets mapped
// into the process (visible in vmmap) but its constructor is never invoked.
// Diagnosed via DYLD_PRINT_INITIALIZERS which listed every system framework's
// initializer but skipped ours.
//
// Fix: piggy-back on the Objective-C runtime's `+load` mechanism. ObjC runtime
// scans every Mach-O image (including DYLD-inserted ones) on load and invokes
// `+load` on every class that implements it — this happens BEFORE `main()` and
// is independent of dyld's initializer machinery, so it fires even when dyld
// skips the regular constructor path.

#import <Foundation/Foundation.h>

extern void NooberProbeBootstrap(void);

static int nooberprobe_loaded = 0;

static void nooberprobe_run_swift_bootstrap(const char *path) {
    fprintf(stderr, "[NooberProbe] About to call Swift bootstrap (%s)\n", path);
    NSLog(@"[NooberProbe] About to call Swift bootstrap (%s)", path);
    NooberProbeBootstrap();
    fprintf(stderr, "[NooberProbe] Swift bootstrap returned (%s).\n", path);
    NSLog(@"[NooberProbe] Swift bootstrap returned (%s).", path);
}

static void nooberprobe_bootstrap(const char *trigger) {
    if (nooberprobe_loaded) return;
    nooberprobe_loaded = 1;
    fprintf(stderr, "[NooberProbe] Bootstrap fired (%s)\n", trigger);
    NSLog(@"[NooberProbe] Bootstrap fired (%s)", trigger);

    // Try synchronous Swift call first — works for most apps.
    nooberprobe_run_swift_bootstrap("sync from +load");

    // Belt-and-suspenders: also schedule a runloop-deferred invocation.
    // If the synchronous call succeeded, NooberProbeBootstrap will short-circuit
    // (it's idempotent thanks to ProbeServer.shared.start being a singleton).
    [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        nooberprobe_run_swift_bootstrap("UIApplication launch");
    }];
}

// Belt: classic C constructor, in case dyld DOES honor it on this platform.
__attribute__((constructor))
static void nooberprobe_constructor(void) {
    nooberprobe_bootstrap("C constructor");
}

// Suspenders: ObjC +load. Runs even when dyld silently skips C constructors
// for DYLD-inserted dylibs on iOS 26.2+ simulators.
@interface _NooberProbeLoader : NSObject @end
@implementation _NooberProbeLoader
+ (void)load {
    nooberprobe_bootstrap("ObjC +load");
}
@end
