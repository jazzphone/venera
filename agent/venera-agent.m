// venera-agent: Venera's guest agent for macOS. It speaks the QEMU guest agent protocol (QGA, JSON over a serial port)
// that Proxmox's `qm agent` and `qm guest exec` use, so a macOS VM gets clean shutdowns from the Proxmox page, its IP
// addresses on the VM's Summary, commands and files from the host, and the clock set; Venera's VM script reads
// Venera's status and installs upgrades through it.
//
//   venera-agent [--device PATH] [--stdio] [--answer-max BYTES] [--version] [--memory]   (VENERA_AGENT_TRACE=1: log every request)
//
// The port: QEMU's virtio-serial channel org.qemu.guest_agent.0 when the VM has one (Proxmox's agent type virtio),
// through Venera's own driver (VeneraConsole.kext) when it is in, else through macOS's tty for it; else the ISA
// serial port (type isa, /dev/cu.serial*). --stdio reads requests from stdin and answers on stdout (for
// tests). It runs as root (local.venera.agent): the host already has the whole VM, so this adds nothing it couldn't
// do; it is a Customize choice in Venera's installer for anyone who doesn't want it.
//
// Commands: guest-sync, guest-sync-delimited, guest-ping, guest-info, guest-get-osinfo, guest-get-host-name,
// guest-get-timezone, guest-get-time, guest-set-time, guest-get-vcpus, guest-network-get-interfaces, guest-shutdown,
// guest-exec, guest-exec-status, guest-file-open/-read/-write/-seek/-flush/-close, guest-fsfreeze-status/-freeze/
// -freeze-list/-thaw (macOS can't freeze APFS: freeze syncs the disks and reports none frozen), guest-get-fsinfo,
// guest-get-users, guest-get-load, guest-fstrim (APFS trims at mount: says so), guest-set-user-password (`qm guest
// passwd`), and the suspend and memory-block commands answered as Unsupported.
//
// And Proxmox's memory figure: with VeneraBalloon.kext (QEMU's virtio-balloon device, statistics only) in, the agent
// hands it macOS's memory figures every 2 s (`venera-agent --memory` prints them), so Proxmox shows the VM's memory as
// Activity Monitor does instead of the QEMU process's, which macOS's caches fill.
#import <Foundation/Foundation.h>
#import <OpenDirectory/OpenDirectory.h>
#import <IOKit/IOKitLib.h>
#include "../kext/VeneraConsole/VeneraConsoleAPI.h"
#include "../kext/VeneraBalloon/VeneraBalloonAPI.h"
#include <mach/mach.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <poll.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <spawn.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <utmpx.h>

extern char **environ;

#ifndef VENERA_VERSION
#define VENERA_VERSION "dev"
#endif
#define MAX_OUTPUT (16u << 20)       // guest-exec keeps at most this much of each stream (as QEMU's agent does)
#define MAX_READ (48u << 20)         // guest-file-read's largest count (QEMU's limit)
#define MAX_REQUEST (64u << 20)      // a request bigger than this is dropped (a file-write's base64 fits well inside)

static int gOut = -1;
static io_connect_t gConn = 0;   // the agent port through VeneraConsole.kext (else gOut, a tty)
static BOOL gStdio = NO;
// The most an answer may hold (its JSON, in bytes). Proxmox gives up on an answer after 5 s (its default timeout)
// and hangs up, which is what stalls macOS's virtio console mid-answer; so every answer fits in about 2 s of the
// port: ~1 MB/s on the virtio port, ~100 KB/s on the ISA serial port. A file read returns less than asked (Proxmox
// reads again), and command output past it is marked truncated, as QEMU's own agent does past its limit.
static size_t gAnswerMax = SIZE_MAX;

static void logf_(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logf_(NSString *fmt, ...) {
    if (gStdio) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fprintf(stderr, "%s venera-agent: %s\n", [df stringFromDate:[NSDate date]].UTF8String, s.UTF8String);
}

// ---- answers --------------------------------------------------------------------------------------------------------

@interface AgentError : NSObject
@property NSString *cls, *desc;
@end
@implementation AgentError
@end
static AgentError *err(NSString *cls, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static AgentError *err(NSString *cls, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    AgentError *e = [AgentError new];
    e.cls = cls;
    e.desc = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    return e;
}
#define GENERIC(...) err(@"GenericError", __VA_ARGS__)
#define BADARG(...) err(@"InvalidParameter", __VA_ARGS__)

// The port never blocks the agent. macOS's virtio console stops taking output once the host side has gone while an
// answer was on its way (Proxmox gave up on a big answer and closed its end), and a blocking write, and even the close
// at exit (the tty waits for its output to drain), then waits for good, and it stays stuck until the guest closes and
// opens the port again. So the port is non-blocking: a write that makes no progress for STUCK_SECS throws away what is
// queued (tcflush), drops the rest of that answer, and the agent closes and reopens the port. A
// watchdog is the last resort: if the agent is stuck anyway, it flushes and exits, and launchd starts it again.
#define STUCK_SECS 5
static _Atomic uint64_t gBusySince;   // when the write in progress last moved (monotonic ns), 0 when none

static uint64_t monoNs(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }
static BOOL gDropping;                // the rest of the current answer is dropped
static BOOL gReopen;                  // the port stalled: close it and open it again (that gets it moving)

static void startWatchdog(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            sleep(2);
            uint64_t t = gBusySince;
            if (t && monoNs() - t > (uint64_t)(STUCK_SECS * 4) * 1000000000ull) {
                logf_(@"stuck writing to the port for %d s: starting over", STUCK_SECS * 4);
                if (gOut > 2) tcflush(gOut, TCOFLUSH);
                _exit(75);
            }
        }
    });
}

static void writeAll(const void *p, size_t n) {
    const uint8_t *b = p;
    if (gDropping) return;
    if (gConn) {   // VeneraConsole: a write waits at most STUCK_SECS for the host to take it, and never wedges the port
        gBusySince = monoNs();
        while (n) {
            uint64_t timeout = STUCK_SECS * 1000, took = 0;
            uint32_t outs = 1;
            kern_return_t kr = IOConnectCallMethod(gConn, kVCMethodWrite, &timeout, 1, b, MIN(n, (size_t)1 << 20),
                                                   &took, &outs, NULL, NULL);
            if (kr != KERN_SUCCESS) {
                logf_(@"write: 0x%x: reopening the port", kr);
                gDropping = YES;
                gReopen = YES;
                break;
            }
            if (took == 0) {
                logf_(@"the host stopped reading (no progress in %d s): dropped the rest of an answer (%zu bytes)", STUCK_SECS, n);
                gDropping = YES;
                break;
            }
            b += took;
            n -= (size_t)took;
            gBusySince = monoNs();
        }
        gBusySince = 0;
        return;
    }
    uint64_t moved = monoNs();
    gBusySince = moved;
    while (n) {
        ssize_t w = write(gOut, b, MIN(n, (size_t)65536));
        if (w > 0) {
            b += w;
            n -= (size_t)w;
            moved = monoNs();
            gBusySince = moved;
            continue;
        }
        if (w < 0 && errno != EINTR && errno != EAGAIN) {
            logf_(@"write: %s", strerror(errno));
            break;
        }
        if (monoNs() - moved > (uint64_t)STUCK_SECS * 1000000000ull) {
            logf_(@"the host stopped reading (no progress in %d s): dropped the rest of an answer (%zu bytes)", STUCK_SECS, n);
            if (!gStdio) tcflush(gOut, TCOFLUSH);
            gDropping = YES;
            gReopen = !gStdio;
            break;
        }
        struct pollfd pf = {.fd = gOut, .events = POLLOUT};
        poll(&pf, 1, 200);
    }
    gBusySince = 0;
}

static void reply(id answer, id reqId, BOOL delimited) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    if ([answer isKindOfClass:[AgentError class]]) {
        AgentError *e = answer;
        m[@"error"] = @{@"class": e.cls, @"desc": e.desc};
    } else {
        m[@"return"] = answer ?: @{};
    }
    if (reqId) m[@"id"] = reqId;
    NSData *d = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
    gDropping = NO;
    if (delimited) writeAll("\xff", 1);
    writeAll(d.bytes, d.length);
    writeAll("\n", 1);
}

// arguments
static NSString *str(NSDictionary *a, NSString *k) { id v = a[k]; return [v isKindOfClass:[NSString class]] ? v : nil; }
static NSNumber *num(NSDictionary *a, NSString *k) { id v = a[k]; return [v isKindOfClass:[NSNumber class]] ? v : nil; }
static NSArray *strs(NSDictionary *a, NSString *k) {
    id v = a[k];
    if (![v isKindOfClass:[NSArray class]]) return nil;
    for (id x in v) if (![x isKindOfClass:[NSString class]]) return nil;
    return v;
}

// ---- system facts ---------------------------------------------------------------------------------------------------

static NSString *sysctlStr(const char *name) {
    char buf[256];
    size_t n = sizeof buf;
    if (sysctlbyname(name, buf, &n, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

static id osinfo(NSDictionary *a) {
    struct utsname u;
    uname(&u);
    NSString *ver = sysctlStr("kern.osproductversion") ?: @"";
    NSString *build = sysctlStr("kern.osversion") ?: @"";
    return @{
        @"id": @"macos", @"name": @"macOS",
        @"pretty-name": [NSString stringWithFormat:@"macOS %@ (%@)", ver, build],
        @"version": ver, @"version-id": ver,
        @"kernel-release": @(u.release), @"kernel-version": @(u.version), @"machine": @(u.machine),
    };
}

static id hostName(NSDictionary *a) {
    char h[256] = {0};
    gethostname(h, sizeof h - 1);
    return @{@"host-name": @(h)};
}

static id timezone_(NSDictionary *a) {
    NSTimeZone *z = [NSTimeZone localTimeZone];
    return @{@"zone": z.abbreviation ?: z.name, @"offset": @(z.secondsFromGMT)};
}

static int64_t nowNs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000LL;
}

static id getTime(NSDictionary *a) { return @(nowNs()); }

static id setTime(NSDictionary *a) {
    NSNumber *t = num(a, @"time");
    if (!t) return GENERIC(@"macOS keeps no hardware clock to read: give the time (guest-set-time with \"time\")");
    int64_t ns = t.longLongValue;
    struct timeval tv = {.tv_sec = (time_t)(ns / 1000000000LL), .tv_usec = (suseconds_t)((ns % 1000000000LL) / 1000)};
    if (settimeofday(&tv, NULL) != 0) return GENERIC(@"settimeofday: %s", strerror(errno));
    return @{};
}

static id vcpus(NSDictionary *a) {
    int n = 1;
    size_t sz = sizeof n;
    sysctlbyname("hw.logicalcpu", &n, &sz, NULL, 0);
    NSMutableArray *r = [NSMutableArray array];
    for (int i = 0; i < n; i++) [r addObject:@{@"logical-id": @(i), @"online": @YES, @"can-offline": @NO}];
    return r;
}

static int prefixLen(const struct sockaddr *mask) {
    if (!mask) return 0;
    const uint8_t *b;
    size_t n;
    if (mask->sa_family == AF_INET) { b = (const uint8_t *)&((const struct sockaddr_in *)mask)->sin_addr; n = 4; }
    else if (mask->sa_family == AF_INET6) { b = (const uint8_t *)&((const struct sockaddr_in6 *)mask)->sin6_addr; n = 16; }
    else return 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) bits += __builtin_popcount(b[i]);
    return bits;
}

static id interfaces(NSDictionary *a) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return GENERIC(@"getifaddrs: %s", strerror(errno));
    NSMutableDictionary<NSString *, NSMutableDictionary *> *by = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr) continue;
        NSString *name = @(i->ifa_name);
        NSMutableDictionary *e = by[name];
        if (!e) {
            e = [@{@"name": name, @"ip-addresses": [NSMutableArray array]} mutableCopy];
            by[name] = e;
            [order addObject:name];
        }
        int fam = i->ifa_addr->sa_family;
        if (fam == AF_LINK) {
            const struct sockaddr_dl *dl = (const struct sockaddr_dl *)i->ifa_addr;
            if (dl->sdl_alen == 6) {
                const uint8_t *m = (const uint8_t *)LLADDR(dl);
                e[@"hardware-address"] = [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
                                                                    m[0], m[1], m[2], m[3], m[4], m[5]];
            }
            if (i->ifa_data) {
                const struct if_data *d = i->ifa_data;
                e[@"statistics"] = @{
                    @"rx-bytes": @(d->ifi_ibytes), @"rx-packets": @(d->ifi_ipackets), @"rx-errs": @(d->ifi_ierrors),
                    @"rx-dropped": @(d->ifi_iqdrops), @"tx-bytes": @(d->ifi_obytes), @"tx-packets": @(d->ifi_opackets),
                    @"tx-errs": @(d->ifi_oerrors), @"tx-dropped": @0,
                };
            }
        } else if (fam == AF_INET || fam == AF_INET6) {
            char buf[INET6_ADDRSTRLEN] = {0};
            const void *src = fam == AF_INET ? (const void *)&((struct sockaddr_in *)i->ifa_addr)->sin_addr
                                             : (const void *)&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr;
            inet_ntop(fam, src, buf, sizeof buf);
            [e[@"ip-addresses"] addObject:@{
                @"ip-address-type": fam == AF_INET ? @"ipv4" : @"ipv6",
                @"ip-address": @(buf),
                @"prefix": @(prefixLen(i->ifa_netmask)),
            }];
        }
    }
    freeifaddrs(list);
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *n in order) {   // macOS lists USB controllers and idle tunnels too: only those with an address
        NSDictionary *e = by[n];
        if ([e[@"ip-addresses"] count] || e[@"hardware-address"]) [r addObject:e];
    }
    return r;
}

// ---- shutdown -------------------------------------------------------------------------------------------------------

static id shutdown_(NSDictionary *a) {
    NSString *mode = str(a, @"mode") ?: @"powerdown";
    const char *flag;
    if ([mode isEqualToString:@"powerdown"] || [mode isEqualToString:@"halt"]) flag = "-h";
    else if ([mode isEqualToString:@"reboot"]) flag = "-r";
    else return BADARG(@"mode must be powerdown, halt or reboot");
    logf_(@"shutdown (%@)", mode);
    pid_t pid;
    char *argv[] = {"/sbin/shutdown", (char *)flag, "now", NULL};
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    if (rc != 0) return GENERIC(@"shutdown: %s", strerror(rc));
    return nil;   // guest-shutdown answers nothing when it works (as QEMU's agent)
}

// ---- guest-exec -----------------------------------------------------------------------------------------------------

@interface Exec : NSObject
@property pid_t pid;
@property BOOL exited;
@property int status;
@property NSMutableData *outData, *errData;
@property BOOL outTrunc, errTrunc, capture;
@property dispatch_group_t streams;
@end
@implementation Exec
@end

static NSMutableDictionary<NSNumber *, Exec *> *gExecs;

static void drain(int fd, Exec *x, BOOL isErr) {
    dispatch_group_async(x.streams, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        uint8_t buf[65536];
        for (;;) {
            ssize_t n = read(fd, buf, sizeof buf);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            @synchronized(x) {
                NSMutableData *d = isErr ? x.errData : x.outData;
                size_t room = d.length < MAX_OUTPUT ? MAX_OUTPUT - d.length : 0;
                if ((size_t)n > room) { if (isErr) x.errTrunc = YES; else x.outTrunc = YES; }
                [d appendBytes:buf length:MIN((size_t)n, room)];
            }
        }
        close(fd);
    });
}

static id exec_(NSDictionary *a) {
    NSString *path = str(a, @"path");
    if (!path.length) return BADARG(@"path is required");
    NSArray *args = a[@"arg"] ? strs(a, @"arg") : @[];
    NSArray *env = a[@"env"] ? strs(a, @"env") : nil;
    if (!args || (a[@"env"] && !env)) return BADARG(@"arg and env are lists of strings");
    NSData *input = nil;
    if (str(a, @"input-data")) {
        input = [[NSData alloc] initWithBase64EncodedString:str(a, @"input-data") options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!input) return BADARG(@"input-data isn't base64");
    }
    // capture-output: true/false, or none, stdout, stderr, separated, merged
    BOOL capOut = NO, capErr = NO, merged = NO;
    id cap = a[@"capture-output"];
    if ([cap isKindOfClass:[NSNumber class]]) capOut = capErr = [cap boolValue];
    else if ([cap isKindOfClass:[NSString class]]) {
        if ([cap isEqualToString:@"stdout"]) capOut = YES;
        else if ([cap isEqualToString:@"stderr"]) capErr = YES;
        else if ([cap isEqualToString:@"separated"]) capOut = capErr = YES;
        else if ([cap isEqualToString:@"merged"]) capOut = merged = YES;
        else if (![cap isEqualToString:@"none"]) return BADARG(@"capture-output: %@", cap);
    }

    int inP[2] = {-1, -1}, outP[2] = {-1, -1}, errP[2] = {-1, -1};
    if ((input && pipe(inP)) || (capOut && pipe(outP)) || (capErr && pipe(errP))) return GENERIC(@"pipe: %s", strerror(errno));
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (input) posix_spawn_file_actions_adddup2(&fa, inP[0], 0);
    else posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    if (capOut) posix_spawn_file_actions_adddup2(&fa, outP[1], 1);
    else posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    if (merged) posix_spawn_file_actions_adddup2(&fa, outP[1], 2);
    else if (capErr) posix_spawn_file_actions_adddup2(&fa, errP[1], 2);
    else posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    // its own process group: a command outlives the agent being restarted (an upgrade through the agent replaces it)
    posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&at, 0);
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setsigmask(&at, &none);

    NSUInteger argc = args.count + 1;
    char **argv = calloc(argc + 1, sizeof(char *));
    argv[0] = (char *)path.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = (char *)[args[i] UTF8String];
    char **envp = environ;
    if (env) {
        envp = calloc(env.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < env.count; i++) envp[i] = (char *)[env[i] UTF8String];
    }
    pid_t pid = 0;
    int rc = posix_spawnp(&pid, path.UTF8String, &fa, &at, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    free(argv);
    if (env) free(envp);
    if (inP[0] >= 0) close(inP[0]);   // the child's ends
    if (outP[1] >= 0) close(outP[1]);
    if (errP[1] >= 0) close(errP[1]);
    if (rc != 0) {
        if (inP[1] >= 0) close(inP[1]);
        if (outP[0] >= 0) close(outP[0]);
        if (errP[0] >= 0) close(errP[0]);
        return GENERIC(@"%@: %s", path, strerror(rc));
    }

    Exec *x = [Exec new];
    x.pid = pid;
    x.outData = [NSMutableData data];
    x.errData = [NSMutableData data];
    x.capture = capOut || capErr;
    x.streams = dispatch_group_create();
    if (outP[0] >= 0) drain(outP[0], x, NO);
    if (errP[0] >= 0) drain(errP[0], x, YES);
    if (input) {
        int fd = inP[1];
        dispatch_group_async(x.streams, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            const uint8_t *b = input.bytes;
            size_t n = input.length;
            while (n) {
                ssize_t w = write(fd, b, n);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) break;   // the child closed its stdin
                b += w;
                n -= (size_t)w;
            }
            close(fd);
        });
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        dispatch_group_wait(x.streams, DISPATCH_TIME_FOREVER);
        @synchronized(x) {
            x.status = st;
            x.exited = YES;
        }
    });
    @synchronized(gExecs) { gExecs[@(pid)] = x; }
    return @{@"pid": @(pid)};
}

static id execStatus(NSDictionary *a) {
    NSNumber *pid = num(a, @"pid");
    if (!pid) return BADARG(@"pid is required");
    Exec *x;
    @synchronized(gExecs) { x = gExecs[@(pid.intValue)]; }
    if (!x) return BADARG(@"no process %@ started by guest-exec (or its status was already read)", pid);
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    @synchronized(x) {
        r[@"exited"] = @(x.exited);
        if (!x.exited) return r;
        int st = x.status;
        if (WIFEXITED(st)) r[@"exitcode"] = @(WEXITSTATUS(st));
        else if (WIFSIGNALED(st)) r[@"signal"] = @(WTERMSIG(st));
        if (x.capture) {
            NSData *o = x.outData, *e = x.errData;
            size_t room = gAnswerMax == SIZE_MAX ? SIZE_MAX : gAnswerMax / 4 * 3 - 512;   // raw bytes that fit, both streams
            BOOL ot = x.outTrunc, et = x.errTrunc;
            if (room != SIZE_MAX && o.length + e.length > room) {   // keep the start of each; stderr gets up to a quarter
                size_t eKeep = MIN(e.length, room / 4), oKeep = MIN(o.length, room - eKeep);
                eKeep = MIN(e.length, room - oKeep);
                if (oKeep < o.length) { o = [o subdataWithRange:NSMakeRange(0, oKeep)]; ot = YES; }
                if (eKeep < e.length) { e = [e subdataWithRange:NSMakeRange(0, eKeep)]; et = YES; }
            }
            if (o.length) r[@"out-data"] = [o base64EncodedStringWithOptions:0];
            if (e.length) r[@"err-data"] = [e base64EncodedStringWithOptions:0];
            if (ot) r[@"out-truncated"] = @YES;
            if (et) r[@"err-truncated"] = @YES;
        }
    }
    @synchronized(gExecs) { [gExecs removeObjectForKey:@(pid.intValue)]; }
    return r;
}

// ---- files ----------------------------------------------------------------------------------------------------------

static NSMutableDictionary<NSNumber *, NSValue *> *gFiles;
static int64_t gNextHandle = 1000;

static FILE *fileFor(NSDictionary *a, AgentError **e) {
    NSNumber *h = num(a, @"handle");
    NSValue *v = h ? gFiles[h] : nil;
    if (!v) { *e = BADARG(@"no open file with handle %@", h); return NULL; }
    return v.pointerValue;
}

static id fileOpen(NSDictionary *a) {
    NSString *path = str(a, @"path");
    if (!path.length) return BADARG(@"path is required");
    NSString *mode = str(a, @"mode") ?: @"r";
    static NSSet *ok;
    if (!ok) ok = [NSSet setWithArray:@[@"r", @"rb", @"w", @"wb", @"a", @"ab", @"r+", @"rb+", @"r+b", @"w+", @"wb+", @"w+b", @"a+", @"ab+", @"a+b"]];
    if (![ok containsObject:mode]) return BADARG(@"mode %@", mode);
    FILE *f = fopen(path.fileSystemRepresentation, mode.UTF8String);
    if (!f) return GENERIC(@"%@: %s", path, strerror(errno));
    NSNumber *h = @(gNextHandle++);
    gFiles[h] = [NSValue valueWithPointer:f];
    return h;
}

static id fileClose(NSDictionary *a) {
    AgentError *e = nil;
    FILE *f = fileFor(a, &e);
    if (!f) return e;
    [gFiles removeObjectForKey:num(a, @"handle")];
    if (fclose(f) != 0) return GENERIC(@"close: %s", strerror(errno));
    return @{};
}

static id fileRead(NSDictionary *a) {
    AgentError *e = nil;
    FILE *f = fileFor(a, &e);
    if (!f) return e;
    int64_t count = num(a, @"count") ? num(a, @"count").longLongValue : 4096;
    if (count < 0 || count > MAX_READ) return BADARG(@"count must be 0 to %u", MAX_READ);
    if (gAnswerMax != SIZE_MAX) count = MIN(count, (int64_t)(gAnswerMax / 4 * 3) - 256);   // base64 and the rest
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)count];
    size_t n = fread(d.mutableBytes, 1, (size_t)count, f);
    if (ferror(f)) { clearerr(f); return GENERIC(@"read: %s", strerror(errno)); }
    d.length = n;
    return @{@"count": @(n), @"buf-b64": [d base64EncodedStringWithOptions:0], @"eof": @(feof(f) != 0)};
}

static id fileWrite(NSDictionary *a) {
    AgentError *e = nil;
    FILE *f = fileFor(a, &e);
    if (!f) return e;
    NSData *d = str(a, @"buf-b64") ? [[NSData alloc] initWithBase64EncodedString:str(a, @"buf-b64") options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
    if (!d) return BADARG(@"buf-b64 is required, in base64");
    size_t count = num(a, @"count") ? (size_t)num(a, @"count").longLongValue : d.length;
    if (count > d.length) return BADARG(@"count is more than buf-b64 holds");
    size_t n = fwrite(d.bytes, 1, count, f);
    if (n < count) { clearerr(f); return GENERIC(@"write: %s", strerror(errno)); }
    return @{@"count": @(n), @"eof": @(feof(f) != 0)};
}

static id fileSeek(NSDictionary *a) {
    AgentError *e = nil;
    FILE *f = fileFor(a, &e);
    if (!f) return e;
    int whence = SEEK_SET;
    id w = a[@"whence"];
    if ([w isKindOfClass:[NSNumber class]]) whence = [w intValue];
    else if ([w isEqual:@"cur"]) whence = SEEK_CUR;
    else if ([w isEqual:@"end"]) whence = SEEK_END;
    if (fseeko(f, (off_t)num(a, @"offset").longLongValue, whence) != 0) return GENERIC(@"seek: %s", strerror(errno));
    return @{@"position": @(ftello(f)), @"eof": @(feof(f) != 0)};
}

static id fileFlush(NSDictionary *a) {
    AgentError *e = nil;
    FILE *f = fileFor(a, &e);
    if (!f) return e;
    if (fflush(f) != 0) return GENERIC(@"flush: %s", strerror(errno));
    return @{};
}

// ---- filesystem freeze (backups) ------------------------------------------------------------------------------------

static id freezeStatus(NSDictionary *a) { return @"thawed"; }
static id freeze(NSDictionary *a) { sync(); return @0; }   // APFS can't be frozen from user space: the disks are synced
static id thaw(NSDictionary *a) { return @0; }

// ---- filesystems, users, load ---------------------------------------------------------------------------------------

static id fsinfo(NSDictionary *a) {
    int n = getfsstat(NULL, 0, MNT_NOWAIT);
    if (n < 0) return GENERIC(@"getfsstat: %s", strerror(errno));
    struct statfs *fs = calloc((size_t)n + 4, sizeof *fs);
    n = getfsstat(fs, (int)(((size_t)n + 4) * sizeof *fs), MNT_NOWAIT);
    NSMutableArray *r = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        struct statfs *f = &fs[i];
        if (!(f->f_flags & MNT_LOCAL) || !strcmp(f->f_fstypename, "devfs") || !strcmp(f->f_fstypename, "autofs")) continue;
        uint64_t bs = f->f_bsize, total = f->f_blocks * bs, avail = f->f_bavail * bs, free_ = f->f_bfree * bs;
        const char *dev = f->f_mntfromname;
        if (!strncmp(dev, "/dev/", 5)) dev += 5;
        [r addObject:@{
            @"name": @(dev), @"mountpoint": @(f->f_mntonname), @"type": @(f->f_fstypename),
            @"total-bytes": @(total), @"used-bytes": @(total - free_), @"total-bytes-privileged": @(total - free_ + avail),
            @"disk": @[],
        }];
    }
    free(fs);
    return r;
}

static id users(NSDictionary *a) {
    NSMutableDictionary<NSString *, NSNumber *> *first = [NSMutableDictionary dictionary];
    setutxent();
    struct utmpx *u;
    while ((u = getutxent())) {
        if (u->ut_type != USER_PROCESS || !u->ut_user[0]) continue;
        NSString *name = [[NSString alloc] initWithBytes:u->ut_user length:strnlen(u->ut_user, sizeof u->ut_user)
                                                encoding:NSUTF8StringEncoding];
        double t = u->ut_tv.tv_sec + u->ut_tv.tv_usec / 1e6;
        if (name && (!first[name] || t < first[name].doubleValue)) first[name] = @(t);
    }
    endutxent();
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *n in first) [r addObject:@{@"user": n, @"login-time": first[n]}];
    return r;
}

static id load(NSDictionary *a) {
    double l[3] = {0};
    if (getloadavg(l, 3) != 3) return GENERIC(@"getloadavg failed");
    return @{@"load1": @(l[0]), @"load5": @(l[1]), @"load15": @(l[2])};
}

// APFS trims a volume's free space itself when it mounts (on a disk that takes TRIM); there is nothing to run now
static id fstrim(NSDictionary *a) {
    return @{@"paths": @[@{@"path": @"/", @"error": @"macOS trims APFS free space itself when a volume mounts"}]};
}

// `qm guest passwd`: sets a local account's password as an administrator's reset would. The login keychain keeps the
// old password (macOS offers to update or replace it at the next login), and FileVault's unlock isn't changed.
static id setPassword(NSDictionary *a) {
    NSString *user = str(a, @"username"), *b64 = str(a, @"password");
    if (!user.length || !b64) return BADARG(@"username and password are required");
    if ([num(a, @"crypted") boolValue]) return err(@"Unsupported", @"macOS takes the password itself, not a crypt(3) hash");
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *pw = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!pw) return BADARG(@"password isn't base64 UTF-8");
    NSError *e = nil;
    ODNode *node = [ODNode nodeWithSession:[ODSession defaultSession] type:kODNodeTypeLocalNodes error:&e];
    ODRecord *rec = node ? [node recordWithRecordType:kODRecordTypeUsers name:user attributes:nil error:&e] : nil;
    if (!rec) return GENERIC(@"no local account %@%@", user, e ? [@": " stringByAppendingString:e.localizedDescription] : @"");
    if (![rec changePassword:nil toPassword:pw error:&e]) return GENERIC(@"%@", e.localizedDescription ?: @"the change failed");
    logf_(@"set the password of %@", user);
    return @{};
}

static id unsupported(NSDictionary *a) { return err(@"Unsupported", @"not on macOS"); }
static id noSleep(NSDictionary *a) {
    return err(@"Unsupported", @"macOS VMs here don't sleep or hibernate (QEMU can't wake them reliably)");
}

// ---- dispatch -------------------------------------------------------------------------------------------------------

typedef id (*Handler)(NSDictionary *);
static NSDictionary<NSString *, NSValue *> *gHandlers;
static NSSet<NSString *> *gNoAnswer;

static id ping(NSDictionary *a) { return @{}; }
static id info(NSDictionary *a) {
    NSMutableArray *cmds = [NSMutableArray array];
    for (NSString *n in [gHandlers.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [cmds addObject:@{@"name": n, @"enabled": @YES, @"success-response": @(![gNoAnswer containsObject:n])}];
    return @{@"version": @VENERA_VERSION, @"supported_commands": cmds};
}

static void setup(void) {
    gExecs = [NSMutableDictionary dictionary];
    gFiles = [NSMutableDictionary dictionary];
#define H(name, fn) name : [NSValue valueWithPointer:(void *)fn]
    gHandlers = @{
        H(@"guest-ping", ping), H(@"guest-info", info), H(@"guest-get-osinfo", osinfo),
        H(@"guest-get-host-name", hostName), H(@"guest-get-timezone", timezone_), H(@"guest-get-time", getTime),
        H(@"guest-set-time", setTime), H(@"guest-get-vcpus", vcpus), H(@"guest-network-get-interfaces", interfaces),
        H(@"guest-shutdown", shutdown_), H(@"guest-exec", exec_), H(@"guest-exec-status", execStatus),
        H(@"guest-file-open", fileOpen), H(@"guest-file-close", fileClose), H(@"guest-file-read", fileRead),
        H(@"guest-file-write", fileWrite), H(@"guest-file-seek", fileSeek), H(@"guest-file-flush", fileFlush),
        H(@"guest-fsfreeze-status", freezeStatus), H(@"guest-fsfreeze-freeze", freeze),
        H(@"guest-fsfreeze-freeze-list", freeze), H(@"guest-fsfreeze-thaw", thaw),
        H(@"guest-sync", ping), H(@"guest-sync-delimited", ping),
        H(@"guest-get-fsinfo", fsinfo), H(@"guest-get-users", users), H(@"guest-get-load", load),
        H(@"guest-fstrim", fstrim), H(@"guest-set-user-password", setPassword),
        H(@"guest-suspend-ram", noSleep), H(@"guest-suspend-disk", noSleep), H(@"guest-suspend-hybrid", noSleep),
        H(@"guest-get-memory-blocks", unsupported), H(@"guest-get-memory-block-info", unsupported),
        H(@"guest-set-memory-blocks", unsupported),
    };
#undef H
    gNoAnswer = [NSSet setWithObject:@"guest-shutdown"];
}

static void handle(NSData *json) {
    NSError *e = nil;
    id req = [NSJSONSerialization JSONObjectWithData:json options:0 error:&e];
    if (![req isKindOfClass:[NSDictionary class]]) {
        reply(GENERIC(@"not a JSON object: %@", e.localizedDescription ?: @"?"), nil, NO);
        return;
    }
    NSString *cmd = str(req, @"execute");
    id reqId = req[@"id"];
    if (getenv("VENERA_AGENT_TRACE")) logf_(@"request %@ (%lu bytes)", cmd, (unsigned long)json.length);
    NSDictionary *args = [req[@"arguments"] isKindOfClass:[NSDictionary class]] ? req[@"arguments"] : @{};
    if (!cmd) { reply(GENERIC(@"no \"execute\""), reqId, NO); return; }
    if ([cmd isEqualToString:@"guest-sync"] || [cmd isEqualToString:@"guest-sync-delimited"]) {
        id v = args[@"id"];
        if (!v) { reply(BADARG(@"id is required"), reqId, NO); return; }
        reply(v, reqId, [cmd isEqualToString:@"guest-sync-delimited"]);
        return;
    }
    Handler h = (Handler)[gHandlers[cmd] pointerValue];
    if (!h) { reply(err(@"CommandNotFound", @"The command %@ has not been found", cmd), reqId, NO); return; }
    id r;
    @autoreleasepool { r = h(args); }
    if (!r && [gNoAnswer containsObject:cmd]) return;
    reply(r, reqId, NO);
}

// ---- the port -------------------------------------------------------------------------------------------------------

static NSString *findDevice(void) {
    NSString *v = @"/dev/cu.org.qemu.guest_agent.0";
    if (access(v.fileSystemRepresentation, R_OK | W_OK) == 0) return v;
    glob_t g;
    NSString *found = nil;
    if (glob("/dev/cu.serial*", 0, NULL, &g) == 0 && g.gl_pathc) found = @(g.gl_pathv[0]);
    globfree(&g);
    return found;
}

// ---- Proxmox's memory figure ---------------------------------------------------------------------------------------

// macOS's memory as Activity Monitor counts it. Its Memory Used is the anonymous pages (purgeable ones included) +
// Wired + Compressed: checked on VM 108, where it read 3.46 GB while App Memory (anonymous less purgeable) and Wired
// added to 3.42, the purgeable pages' 43 MB apart; Cached Files (file-backed + purgeable) counts the purgeable pages
// too. Those caches and the free pages are what macOS gives back when an app asks, so "free" for the host is the total
// less Memory Used, and Proxmox's figure (total - free) is Memory Used. The kernel's own free count alone would leave
// the caches looking used, as the QEMU process's figure does.
static BOOL memoryFigures(uint64_t v[kVBStatCount]) {
    static mach_port_t host;
    if (!host) host = mach_host_self();
    vm_statistics64_data_t s;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&s, &n) != KERN_SUCCESS) return NO;
    uint64_t total = 0;
    size_t len = sizeof total;
    if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) != 0 || !total) return NO;
    uint64_t page = vm_page_size;
    uint64_t used = ((uint64_t)s.internal_page_count + s.wire_count + s.compressor_page_count) * page;
    v[kVBTotal] = total;
    v[kVBFree] = total > used ? total - used : 0;
    v[kVBAvail] = v[kVBFree];
    v[kVBCaches] = ((uint64_t)s.external_page_count + s.purgeable_count) * page;
    v[kVBSwapIn] = s.swapins * page;
    v[kVBSwapOut] = s.swapouts * page;
    v[kVBMajorFaults] = s.pageins;
    v[kVBMinorFaults] = s.faults > s.pageins ? s.faults - s.pageins : 0;
    return YES;
}

static io_connect_t openBalloon(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("VeneraBalloon"));
    if (!svc) return 0;
    io_connect_t c = 0;
    if (IOServiceOpen(svc, mach_task_self(), 0, &c) != KERN_SUCCESS) c = 0;
    IOObjectRelease(svc);
    return c;
}

// Every 2 s (Proxmox asks QEMU for fresh figures every 2 s and reads them every 10); without the kext, a look for it
// every minute (it comes with an OpenCore restart, and the balloon device with the VM's next start).
static void startBalloon(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        io_connect_t c = 0;
        BOOL said = NO;
        for (;;) {
            if (!c && !(c = openBalloon())) {
                if (!said) logf_(@"no VeneraBalloon.kext (or no balloon device): Proxmox shows the QEMU process's memory");
                said = YES;
                sleep(60);
                continue;
            }
            uint64_t v[kVBStatCount];
            if (memoryFigures(v)) {
                kern_return_t kr = IOConnectCallScalarMethod(c, kVBMethodSetStats, v, kVBStatCount, NULL, NULL);
                if (kr != KERN_SUCCESS) {
                    logf_(@"VeneraBalloon: 0x%x: opening it again", kr);
                    IOServiceClose(c);
                    c = 0;
                    said = NO;
                    sleep(5);
                    continue;
                }
                static BOOL first = YES;
                if (first) {
                    logf_(@"on VeneraBalloon: Proxmox gets macOS's memory figures (%llu of %llu MB used)",
                          (v[kVBTotal] - v[kVBFree]) >> 20, v[kVBTotal] >> 20);
                    first = NO;
                }
            }
            sleep(2);
        }
    });
}

static int printMemory(void) {
    uint64_t v[kVBStatCount];
    if (!memoryFigures(v)) { fprintf(stderr, "host_statistics64 failed\n"); return 1; }
    printf("total %llu MB, used %llu MB (Activity Monitor's Memory Used), free %llu MB, cached files %llu MB\n"
           "swapped in %llu MB, out %llu MB; page-ins %llu, other faults %llu\n",
           v[kVBTotal] >> 20, (v[kVBTotal] - v[kVBFree]) >> 20, v[kVBFree] >> 20, v[kVBCaches] >> 20,
           v[kVBSwapIn] >> 20, v[kVBSwapOut] >> 20, v[kVBMajorFaults], v[kVBMinorFaults]);
    io_connect_t c = openBalloon();
    if (!c) { printf("VeneraBalloon: not there (or not root)\n"); return 0; }
    uint64_t st[4];
    uint32_t outs = 4;
    if (IOConnectCallScalarMethod(c, kVBMethodState, NULL, 0, st, &outs) == KERN_SUCCESS) {
        if (st[1] == ~0ULL) printf("VeneraBalloon: %llu stats buffers to the host, no figures from the agent yet\n", st[0]);
        else printf("VeneraBalloon: %llu stats buffers to the host, the agent's last figures %llu ms ago (stale past %llu); "
                    "the host's balloon target %llu MB (not acted on)\n", st[0], st[1], st[3], st[2] * 4096 >> 20);
    }
    IOServiceClose(c);
    return 0;
}

// The agent port through VeneraConsole.kext, when it has the virtio-serial devices: the first that has a port of
// that name and lets us open it.
static io_connect_t openConsole(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("VeneraConsole"), &it) != KERN_SUCCESS) return 0;
    io_connect_t found = 0;
    io_service_t svc;
    static const char name[] = "org.qemu.guest_agent.0";
    while (!found && (svc = IOIteratorNext(it))) {
        io_connect_t c = 0;
        if (IOServiceOpen(svc, mach_task_self(), 0, &c) == KERN_SUCCESS) {
            uint64_t id = 0;
            uint32_t outs = 1;
            if (IOConnectCallMethod(c, kVCMethodOpen, NULL, 0, name, strlen(name), &id, &outs, NULL, NULL) == KERN_SUCCESS) {
                found = c;
            } else {
                IOServiceClose(c);
            }
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

static int openPort(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return -1;
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {   // a serial port: raw bytes, no echo, no flow control (a virtio port has none)
        cfmakeraw(&t);
        t.c_cflag |= CLOCAL | CREAD;
        t.c_cflag &= ~(CRTSCTS | HUPCL);
        t.c_iflag &= ~(IXON | IXOFF | IXANY);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        cfsetspeed(&t, B115200);
        tcsetattr(fd, TCSANOW, &t);
        tcflush(fd, TCIOFLUSH);
    }
    return fd;
}

// Requests are JSON objects back to back (whitespace between); a 0xFF byte from the host throws away whatever came
// before it (guest-sync-delimited's resynchronization).
static void serve(int in) {
    NSMutableData *buf = [NSMutableData data];
    int depth = 0;
    BOOL inStr = NO, esc = NO;
    uint8_t chunk[65536];
    uint64_t lastByte = 0;
    for (;;) {
        ssize_t n;
        if (gConn) {   // VeneraConsole: a read waits up to 2 s, 0 bytes when nothing came
            uint64_t timeout = 2000, got = 0;
            uint32_t outs = 1;
            size_t size = sizeof chunk;
            kern_return_t kr = IOConnectCallMethod(gConn, kVCMethodRead, &timeout, 1, NULL, 0, &got, &outs, chunk, &size);
            if (kr != KERN_SUCCESS) { logf_(@"read: 0x%x: reopening the port", kr); return; }
            if (size == 0) continue;
            n = (ssize_t)size;
        } else {
            struct pollfd pf = {.fd = in, .events = POLLIN};
            if (!gStdio && poll(&pf, 1, -1) < 0 && errno != EINTR) { logf_(@"poll: %s", strerror(errno)); return; }
            n = read(in, chunk, sizeof chunk);
        }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        // A request left unfinished by a host that went away: Proxmox's `qm guest exec` sends only part of a request
        // with a character past U+07FF in it (a check mark, an emoji) and gives up, and the rest of it never comes.
        // Proxmox never sends the 0xFF that would reset the parser, so every later request would land inside that
        // string. A request arrives in one go; one that has sat with nothing more for longer than Proxmox ever waits
        // for an answer (5 s) is dropped before the new bytes are read.
        uint64_t now = monoNs();
        if (n > 0 && buf.length && lastByte && now - lastByte > 4000000000ull) {
            logf_(@"dropped an unfinished request (%lu bytes) its host left behind", (unsigned long)buf.length);
            buf.length = 0; depth = 0; inStr = esc = NO;
        }
        if (n > 0) lastByte = now;
        if (n <= 0) {
            if (gStdio) exit(0);
            logf_(@"the port closed (%s): reopening", n < 0 ? strerror(errno) : "end of file");
            return;
        }
        for (ssize_t i = 0; i < n; i++) {
            uint8_t c = chunk[i];
            if (c == 0xff) { buf.length = 0; depth = 0; inStr = esc = NO; continue; }
            if (depth == 0) {
                if (c == '{') { depth = 1; [buf appendBytes:&c length:1]; }
                continue;   // whitespace or stray bytes between requests
            }
            [buf appendBytes:&c length:1];
            if (inStr) {
                if (esc) esc = NO;
                else if (c == '\\') esc = YES;
                else if (c == '"') inStr = NO;
            } else if (c == '"') inStr = YES;
            else if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') {
                if (--depth == 0) {
                    handle(buf);
                    buf = [NSMutableData data];
                    if (gReopen) {
                        logf_(@"reopening the port");
                        gReopen = NO;
                        return;
                    }
                }
            }
            if (buf.length > MAX_REQUEST) {
                logf_(@"a request over %u MB: dropped", MAX_REQUEST >> 20);
                buf.length = 0; depth = 0; inStr = esc = NO;
            }
        }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dev = nil;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--stdio")) gStdio = YES;
            else if (!strcmp(argv[i], "--device") && i + 1 < argc) dev = @(argv[++i]);
            else if (!strcmp(argv[i], "--answer-max") && i + 1 < argc) gAnswerMax = strtoull(argv[++i], NULL, 10);
            else if (!strcmp(argv[i], "--version")) { printf("venera-agent %s\n", VENERA_VERSION); return 0; }
            else if (!strcmp(argv[i], "--memory")) return printMemory();
            else { fprintf(stderr, "usage: venera-agent [--device PATH] [--stdio] [--answer-max BYTES] [--version] [--memory]\n"); return 2; }
        }
        signal(SIGPIPE, SIG_IGN);
        setup();
        if (!gStdio) startWatchdog();
        if (!gStdio) startBalloon();
        if (gStdio) {
            gOut = 1;
            serve(0);
            return 0;
        }
        logf_(@"%s starting", VENERA_VERSION);
        NSString *last = nil;
        for (;;) {   // the port can show up late at boot, or go away: look for it again every few seconds
            @autoreleasepool {
                if (!dev && (gConn = openConsole())) {   // VeneraConsole.kext first
                    gAnswerMax = 1500000;
                    if (![last isEqualToString:@"VeneraConsole"]) logf_(@"on VeneraConsole (answers up to %zu KB)", gAnswerMax / 1000);
                    last = @"VeneraConsole";
                    serve(-1);
                    IOServiceClose(gConn);
                    gConn = 0;
                    sleep(1);
                    continue;
                }
                NSString *path = dev ?: findDevice();
                int fd = path ? openPort(path) : -1;
                if (fd < 0) {
                    if (![path ?: @"" isEqualToString:last ?: @"-"]) logf_(@"no agent port yet (%@)", path ?: @"none found");
                    last = path ?: @"";
                    sleep(3);
                    continue;
                }
                gAnswerMax = [path hasPrefix:@"/dev/cu.serial"] ? 200000 : 1500000;
                logf_(@"on %@ (answers up to %zu KB)", path, gAnswerMax / 1000);
                last = path;
                gOut = fd;
                serve(fd);
                tcflush(fd, TCOFLUSH);
                close(fd);
                sleep(1);
            }
        }
    }
}
