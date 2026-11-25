#import "ObjCTry.h"
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

NSException * _Nullable SBTryObjC(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e;
    }
}

static NSString *sbCrashPath = nil;
static char sbCrashPathC[1024];

static void SBAppend(NSString *text) {
    if (!sbCrashPath) return;
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:sbCrashPath];
    if (!h) {
        [[NSFileManager defaultManager] createFileAtPath:sbCrashPath contents:nil attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:sbCrashPath];
    }
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void SBExceptionHandler(NSException *e) {
    NSArray *stack = [e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))];
    SBAppend([NSString stringWithFormat:@"CRASH  %@: %@\n%@\n", e.name, e.reason, [stack componentsJoinedByString:@"\n"]]);
}

// Async-signal-safe: only write() to a pre-opened path.
static void SBSignalHandler(int sig) {
    int fd = open(sbCrashPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        const char *name = sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : sig == SIGABRT ? "SIGABRT"
                         : sig == SIGILL ? "SIGILL" : sig == SIGTRAP ? "SIGTRAP (Swift runtime error)" : "signal";
        const char *pre = "CRASH  ";
        write(fd, pre, strlen(pre));
        write(fd, name, strlen(name));
        write(fd, "\n", 1);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void SBInstallCrashLogger(NSString *path) {
    sbCrashPath = [path copy];
    strlcpy(sbCrashPathC, path.fileSystemRepresentation, sizeof(sbCrashPathC));
    NSSetUncaughtExceptionHandler(&SBExceptionHandler);
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP };
    for (int i = 0; i < 5; i++) signal(sigs[i], SBSignalHandler);
}
