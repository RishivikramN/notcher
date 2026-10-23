// MediaRemote adapter.
//
// Since macOS 15.4 MediaRemote only returns now-playing data to Apple-signed processes, so this
// library is loaded into /usr/bin/perl (com.apple.perl) instead of into Notcher itself. It
// streams one JSON object per line on stdout whenever the now-playing state changes, and reads
// playback commands from stdin.
//
// MediaRemote's "now playing" app is the one that most recently started playback, and it stays
// so after pausing even while another app (say, a browser video) keeps playing. When it is
// paused, the adapter shows the first other client that is playing instead, marked "fallback".
//
// Commands can't follow it: MediaRemote delivers commands from this process to the now-playing
// app whatever player path they're addressed to (verified with SendCommandToClient/ToPlayer and
// explicit client + default-player paths), so a "pause" would resume the paused app instead.
// Commands are dropped while a fallback client is shown. Overriding the now-playing app
// (MRMediaRemoteSetOverriddenNowPlayingApplication) would route them, but the override outlives
// the process and couldn't be cleared again without restarting mediaremoted, so it isn't used.
//
// Per-client signatures were read from the MediaRemote disassembly:
//   GetNowPlayingClients(queue, ^(CFArrayRef clients))
//   NowPlayingPlayerPathCreate(origin, client, player)
//   GetPlaybackStateForPlayer(path, queue, ^(uint32 state))          1 playing, 2 paused
//   GetNowPlayingInfoForClient(client, origin, NULL, queue, ^(CFDictionaryRef))
//
// Entry points are installed as Perl XSUBs, so they receive (and ignore) Perl's arguments.
// They leave with _exit(): exit() runs Perl's teardown, which can hang inside an XSUB.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef const void *MRRef;
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef MRRef (*LocalOriginFn)(void);
typedef MRRef (*PathCreateFn)(MRRef, MRRef, MRRef);
typedef void (*StateForPlayerFn)(MRRef, dispatch_queue_t, void (^)(unsigned int));
typedef void (*InfoForClientFn)(MRRef, MRRef, MRRef, dispatch_queue_t, void (^)(CFDictionaryRef));
typedef CFStringRef (*ClientBundleFn)(MRRef);
typedef int (*ClientPIDFn)(MRRef);

static GetInfoFn MRGetInfo;
static GetIsPlayingFn MRGetIsPlaying;
static GetPIDFn MRGetPID;
static RegisterFn MRRegister;
static SendCommandFn MRSendCommand;
static SetElapsedFn MRSetElapsed;
static GetClientsFn MRGetClients;
static LocalOriginFn MRLocalOrigin;
static PathCreateFn MRPathCreate;
static StateForPlayerFn MRStateForPlayer;
static InfoForClientFn MRInfoForClient;
static ClientBundleFn MRClientBundle;
static ClientPIDFn MRClientPID;

static NSString *kTitle, *kArtist, *kAlbum, *kDuration, *kElapsed, *kTimestamp, *kRate,
    *kArtworkData, *kArtworkMIME, *kShuffleMode;

static NSUInteger lastArtworkHash = 0;
static BOOL emitScheduled = NO;
/// The client shown instead of the paused now-playing app, or nil.
static id shownClient = nil;

static NSString *LoadKey(void *handle, const char *name) {
    CFStringRef *ref = dlsym(handle, name);
    return ref ? (__bridge NSString *)*ref : nil;
}

static BOOL LoadMediaRemote(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSendCommand = dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
    kTitle = LoadKey(h, "kMRMediaRemoteNowPlayingInfoTitle");
    kArtist = LoadKey(h, "kMRMediaRemoteNowPlayingInfoArtist");
    kAlbum = LoadKey(h, "kMRMediaRemoteNowPlayingInfoAlbum");
    kDuration = LoadKey(h, "kMRMediaRemoteNowPlayingInfoDuration");
    kElapsed = LoadKey(h, "kMRMediaRemoteNowPlayingInfoElapsedTime");
    kTimestamp = LoadKey(h, "kMRMediaRemoteNowPlayingInfoTimestamp");
    kRate = LoadKey(h, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    kArtworkData = LoadKey(h, "kMRMediaRemoteNowPlayingInfoArtworkData");
    kArtworkMIME = LoadKey(h, "kMRMediaRemoteNowPlayingInfoArtworkMIMEType");
    kShuffleMode = LoadKey(h, "kMRMediaRemoteNowPlayingInfoShuffleMode");
    MRGetClients = dlsym(h, "MRMediaRemoteGetNowPlayingClients");
    MRLocalOrigin = dlsym(h, "MRMediaRemoteGetLocalOrigin");
    MRPathCreate = dlsym(h, "MRNowPlayingPlayerPathCreate");
    MRStateForPlayer = dlsym(h, "MRMediaRemoteGetPlaybackStateForPlayer");
    MRInfoForClient = dlsym(h, "MRMediaRemoteGetNowPlayingInfoForClient");
    MRClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRClientPID = dlsym(h, "MRNowPlayingClientGetProcessIdentifier");
    return MRGetInfo && MRGetIsPlaying && MRGetPID && MRRegister;
}

static void WriteLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static BOOL CanFollowClients(void) {
    return MRGetClients && MRLocalOrigin && MRPathCreate && MRStateForPlayer && MRInfoForClient
        && MRClientBundle && MRClientPID;
}

static void WriteNowPlaying(NSDictionary *info, BOOL playing, int pid, NSString *bundleIdentifier) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"type"] = @"nowPlaying";
    out[@"playing"] = @(playing);
    if (shownClient) out[@"fallback"] = @YES;
    NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
    NSString *bundle = bundleIdentifier ?: app.bundleIdentifier;
    if (bundle) out[@"bundleIdentifier"] = bundle;
    if (app.localizedName) out[@"appName"] = app.localizedName;
    if (info.count > 0) {
        if (kTitle && info[kTitle]) out[@"title"] = info[kTitle];
        if (kArtist && info[kArtist]) out[@"artist"] = info[kArtist];
        if (kAlbum && info[kAlbum]) out[@"album"] = info[kAlbum];
        if (kDuration && info[kDuration]) out[@"duration"] = info[kDuration];
        if (kElapsed && info[kElapsed]) out[@"elapsed"] = info[kElapsed];
        if (kRate && info[kRate]) out[@"rate"] = info[kRate];
        // MRMediaRemoteShuffleMode: 1 off, 2 albums, 3 songs.
        if (kShuffleMode && info[kShuffleMode]) out[@"shuffle"] = info[kShuffleMode];
        NSDate *timestamp = kTimestamp ? info[kTimestamp] : nil;
        if ([timestamp isKindOfClass:NSDate.class]) {
            out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
        }
        NSData *artwork = kArtworkData ? info[kArtworkData] : nil;
        if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
            // Artwork is only re-sent when it changes; "artworkSame" keeps the previous one.
            NSUInteger hash = artwork.length ^ artwork.hash;
            if (hash != lastArtworkHash) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                if (kArtworkMIME && info[kArtworkMIME]) out[@"artworkMIME"] = info[kArtworkMIME];
                lastArtworkHash = hash;
            } else {
                out[@"artworkSame"] = @YES;
            }
        } else {
            lastArtworkHash = 0;
        }
    }
    WriteLine(out);
}

/// The system's now-playing app.
static void EmitDefault(BOOL playing) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    shownClient = nil;
    MRGetInfo(queue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        MRGetPID(queue, ^(int pid) {
            WriteNowPlaying(info, playing, pid, nil);
        });
    });
}

/// A specific client that is playing while the now-playing app is paused.
static void EmitClient(id client) {
    shownClient = client;
    MRRef ref = (__bridge MRRef)client;
    MRInfoForClient(ref, MRLocalOrigin(), NULL, dispatch_get_main_queue(), ^(CFDictionaryRef cfInfo) {
        NSString *bundle = (__bridge NSString *)MRClientBundle(ref);
        WriteNowPlaying((__bridge NSDictionary *)cfInfo, YES, MRClientPID(ref), bundle);
    });
}

static void Emit(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    MRGetIsPlaying(queue, ^(Boolean playing) {
        if (playing || !CanFollowClients()) {
            EmitDefault(playing);
            return;
        }
        MRGetClients(queue, ^(CFArrayRef cfClients) {
            NSArray *clients = [(__bridge NSArray *)cfClients copy] ?: @[];
            if (clients.count < 2) {
                EmitDefault(NO);
                return;
            }
            // Ask every client for its state; take the first that is playing. A client that
            // never answers can't hold this up past half a second.
            NSMutableArray *playingClients = [NSMutableArray array];
            __block NSUInteger pending = clients.count;
            __block BOOL finished = NO;
            void (^finish)(void) = ^{
                if (finished) return;
                finished = YES;
                id chosen = playingClients.firstObject;
                if (chosen) EmitClient(chosen); else EmitDefault(NO);
            };
            for (id client in clients) {
                MRRef path = MRPathCreate(MRLocalOrigin(), (__bridge MRRef)client, NULL);
                id pathObject = (__bridge_transfer id)path;
                MRStateForPlayer(path, queue, ^(unsigned int state) {
                    (void)pathObject;
                    if (state == 1) [playingClients addObject:client];
                    if (--pending == 0) finish();
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), queue, finish);
        });
    });
}

/// Several notifications arrive for one change; coalesce them into one line.
static void ScheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emitScheduled = NO;
        Emit();
    });
}

/// Runs every complete line in `pending` on the main queue, then refreshes the state.
static void HandleCommandLines(NSMutableData *pending) {
    while (YES) {
        NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                       options:0
                                         range:NSMakeRange(0, pending.length)];
        if (newline.location == NSNotFound) return;
        NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, newline.location)]
                                               encoding:NSUTF8StringEncoding];
        [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        if (line.length < 3) continue;

        unichar kind = [line characterAtIndex:0];
        NSString *argument = [line substringFromIndex:2];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (shownClient) {
                // They would reach the paused now-playing app instead (see the header).
                return;
            } else if (kind == 'c' && MRSendCommand) {
                MRSendCommand(argument.intValue, NULL);
            } else if (kind == 's' && MRSetElapsed) {
                MRSetElapsed(argument.doubleValue);
            }
            // Some players don't notify after a seek; re-read the state shortly after.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                ScheduleEmit();
            });
        });
    }
}

void notcher_adapter_stream(void) {
    @autoreleasepool {
        if (!LoadMediaRemote()) {
            WriteLine(@{@"type" : @"error", @"message" : @"MediaRemote unavailable"});
            _exit(1);
        }
        MRRegister(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            @"kMRPlaybackQueueContentItemsChangedNotification",
        ];
        // MediaRemote posts on its own queue and waits for observers to finish. Observing on
        // NSOperationQueue.mainQueue deadlocks it, so observe on the posting queue and hop to the
        // main queue without waiting.
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
                                                            dispatch_async(dispatch_get_main_queue(), ^{ ScheduleEmit(); });
                                                        }];
        }
        WriteLine(@{@"type" : @"ready"});
        Emit();

        // Other clients' changes aren't always announced; while the now-playing app is paused
        // (or another client is shown), look again every two seconds.
        static dispatch_source_t pollTimer;
        pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(pollTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC,
                                  200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(pollTimer, ^{
            if (!CanFollowClients()) return;
            MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                if (!playing || shownClient) ScheduleEmit();
            });
        });
        dispatch_resume(pollTimer);

        // stdin carries commands, one per line: "c <MRMediaRemoteCommand>" or "s <seconds>".
        // Notcher going away (stdin closing, or the parent exiting) ends the adapter. Both are
        // watched on a background queue so a wedged main thread can never leave an orphan behind.
        dispatch_queue_t watchQueue = dispatch_queue_create("notcher.adapter.stdin", DISPATCH_QUEUE_SERIAL);
        static dispatch_source_t stdinSource, parentSource;
        static NSMutableData *pending;
        pending = [NSMutableData data];
        stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, watchQueue);
        dispatch_source_set_event_handler(stdinSource, ^{
            char buffer[1024];
            ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
            if (count <= 0) _exit(0);
            [pending appendBytes:buffer length:count];
            HandleCommandLines(pending);
        });
        dispatch_resume(stdinSource);

        pid_t parent = getppid();
        parentSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, watchQueue);
        dispatch_source_set_event_handler(parentSource, ^{ _exit(0); });
        dispatch_resume(parentSource);
        if (getppid() != parent || getppid() == 1) _exit(0);

        CFRunLoopRun();
    }
}
