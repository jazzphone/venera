// Venera.app: the guest's helper, for the person at the screen. It runs at login (LaunchAgent local.venera.helper,
// in the background) and
//   - asks the watcher's questions (venera-watch.sh: "the macOS update took the driver off the system volume:
//     reinstall?") as notifications with buttons, or in its window when notifications are off;
//   - says, once a boot, when something needs a person: the desktop fell back to software, or video decoding is
//     installed but the host's video service isn't there;
//   - shows what runs (opened from /Applications, or from the menu bar item, which is off unless chosen).
// The watcher writes a question into /Library/Application Support/Venera/ask (id, text, buttons: one per line) and an
// empty `answer` file this user may write; the app writes "ID\nBUTTON" into it. Everything here reads; nothing needs
// root.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <UserNotifications/UserNotifications.h>
#include <sys/sysctl.h>

static NSString *const kV = @"/Library/Application Support/Venera";
static NSString *const kMenuBarKey = @"ShowInMenuBar";

// ---- what runs ---------------------------------------------------------------------------------------------------

static io_service_t vn_service(CFMutableDictionaryRef match) {
    return match ? IOServiceGetMatchingService(kIOMainPortDefault, match) : 0;   // consumes match
}
static NSString *vn_prop(io_service_t s, NSString *key) {
    if (!s) {
        return nil;
    }
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        return CFBridgingRelease(v);
    }
    if (v) {
        CFRelease(v);
    }
    return nil;
}

typedef NS_ENUM(int, VNVideo) {
    VNVideoOff,          // not installed
    VNVideoNoDevice,     // installed, the VM has no video device: the host half isn't set up
    VNVideoNoService,    // the device is there, the driver didn't start: venera-videod wasn't running at boot
    VNVideoOn,
};

@interface VNStatus : NSObject
@property BOOL installed, driverLoaded, metalDesktop;
@property NSString *graphics, *graphicsWhy, *driver, *version, *videoText;
@property VNVideo video;
@end
@implementation VNStatus
+ (instancetype)now {
    VNStatus *st = [VNStatus new];
    NSFileManager *fm = NSFileManager.defaultManager;
    st.installed = [fm fileExistsAtPath:[kV stringByAppendingPathComponent:@"VERSION"]];
    st.version = [[NSString stringWithContentsOfFile:[kV stringByAppendingPathComponent:@"VERSION"]
                                            encoding:NSUTF8StringEncoding
                                               error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    io_service_t accel = vn_service(IOServiceMatching("VirtioGPUAccel"));
    st.driverLoaded = accel != 0;
    NSString *arm = vn_prop(accel, @"VirtioGPUArmState"), *guard = vn_prop(accel, @"VirtioGPUGuard");
    if (accel) {
        IOObjectRelease(accel);
    }
    if (!st.driverLoaded) {
        st.graphics = st.installed ? @"Not running: restart to start it" : @"Not installed";
    } else if ([arm hasPrefix:@"display + Metal"]) {
        st.metalDesktop = YES;
        st.graphics = @"Metal, on the host's GPU";
    } else {
        st.graphics = @"Software desktop (no Metal for the desktop)";
        st.graphicsWhy = guard ?: arm;
    }
    NSString *link = [fm destinationOfSymbolicLinkAtPath:@"/Library/GPUBundles/VirtioGPUMetal.bundle" error:nil];
    if ([link hasPrefix:@"/System/"]) {
        st.driver = @"On the system volume (Safari's WebGL can use it)";
    } else if ([link containsString:@"/Venera/dev/"]) {
        st.driver = @"A developer build";
    } else if (link) {
        st.driver = @"Kept copy (every app but Safari's WebGL)";
    } else {
        st.driver = @"Not installed";
    }

    BOOL videoInstalled = [fm fileExistsAtPath:[kV stringByAppendingPathComponent:@"VIDEO"]];
    CFMutableDictionaryRef m = IOServiceMatching("IOPCIDevice");
    CFDictionarySetValue(m, CFSTR("IOPCIPrimaryMatch"), CFSTR("0x11101af4"));   // QEMU's ivshmem
    io_service_t dev = vn_service(m);
    io_service_t drv = vn_service(IOServiceMatching("AppleVideoToolboxParavirtualizationDriver"));
    if (drv) {
        st.video = VNVideoOn, st.videoText = @"On the host's GPU (H.264, HEVC, VP9)";
    } else if (!videoInstalled) {
        st.video = VNVideoOff, st.videoText = @"Not installed (macOS decodes in software)";
    } else if (!dev) {
        st.video = VNVideoNoDevice, st.videoText = @"Not set up on the host (install-host.sh)";
    } else {
        st.video = VNVideoNoService, st.videoText = @"The host's video service wasn't running at startup";
    }
    if (dev) {
        IOObjectRelease(dev);
    }
    if (drv) {
        IOObjectRelease(drv);
    }
    return st;
}
@end

static NSString *vn_boot_id(void) {
    struct timeval tv;
    size_t n = sizeof(tv);
    sysctlbyname("kern.boottime", &tv, &n, NULL, 0);
    return [NSString stringWithFormat:@"%ld", (long)tv.tv_sec];
}

// ---- the app -----------------------------------------------------------------------------------------------------

@interface VNApp : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate>
@end

@implementation VNApp {
    NSWindow *_window;
    NSGridView *_grid;
    NSTextField *_questionText;
    NSStackView *_questionButtons, *_questionBox;
    NSButton *_menuBarCheck;
    NSStatusItem *_item;
    NSTimer *_timer;
    VNStatus *_status;
    NSString *_askId, *_askText;
    NSArray<NSString *> *_askButtons;
    BOOL _notifyOK, _background;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _background = [NSProcessInfo.processInfo.arguments containsObject:@"--background"];
    [self buildMenu];
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    c.delegate = self;
    [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                     completionHandler:^(BOOL granted, NSError *e) {
                         dispatch_async(dispatch_get_main_queue(), ^{
                             self->_notifyOK = granted;
                             [self tick];
                         });
                     }];
    [self applyMenuBar];
    _timer = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 1;
    [self tick];
    if (!_background) {
        [self showWindow:nil];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showWindow:nil];
    return NO;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

- (void)buildMenu {
    NSMenu *bar = [NSMenu new], *appMenu = [NSMenu new];
    NSMenuItem *top = [NSMenuItem new];
    top.submenu = appMenu;
    [bar addItem:top];
    [appMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [appMenu addItemWithTitle:@"Quit Venera" action:@selector(terminate:) keyEquivalent:@"q"];
    NSApp.mainMenu = bar;
}

// Every 3 s: the question folder (a stat or two); every 30 s also what runs.
- (void)tick {
    static NSUInteger n;
    [self checkQuestion];
    if (n++ % 10 == 0 || !_status) {
        [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *ns) {
            BOOL ok = ns.authorizationStatus == UNAuthorizationStatusAuthorized ||
                      ns.authorizationStatus == UNAuthorizationStatusProvisional;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_notifyOK = ok;   // the person may change it in System Settings at any time
            });
        }];
        _status = [VNStatus now];
        [self notices];
        [self refreshUI];
    }
}

// ---- notices: once a boot each ------------------------------------------------------------------------------------

- (void)notice:(NSString *)key title:(NSString *)title body:(NSString *)body {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *k = [@"notice." stringByAppendingString:key], *boot = vn_boot_id();
    if ([[d stringForKey:k] isEqualToString:boot]) {
        return;
    }
    [d setObject:boot forKey:k];
    if (!_notifyOK) {
        return;   // the window shows it
    }
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = title;
    c.body = body;
    [UNUserNotificationCenter.currentNotificationCenter
        addNotificationRequest:[UNNotificationRequest requestWithIdentifier:key content:c trigger:nil]
         withCompletionHandler:nil];
}

- (void)notices {
    if (_status.driverLoaded && !_status.metalDesktop) {
        [self notice:@"graphics"
               title:@"Venera: software desktop"
                body:[NSString stringWithFormat:@"The desktop isn't using Metal this time (%@). Apps still can. Restart to try again; "
                                                @"Venera's window has the details.",
                                                _status.graphicsWhy ?: @"no reason given"]];
    }
    if (_status.video == VNVideoNoService) {
        [self notice:@"video"
               title:@"Venera: video decoding is off"
                body:@"The host's video service (venera-videod) wasn't running when this Mac started, so video decodes in "
                     @"software. Start it on the host, then restart this Mac."];
    }
}

// ---- the watcher's questions -------------------------------------------------------------------------------------

- (NSString *)askFile:(NSString *)name {
    return [[kV stringByAppendingPathComponent:@"ask"] stringByAppendingPathComponent:name];
}

- (void)checkQuestion {
    NSString *qid = [[NSString stringWithContentsOfFile:[self askFile:@"id"] encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (qid.length == 0) {
        qid = nil;
    }
    if ((qid == nil && _askId == nil) || [qid isEqualToString:_askId]) {
        return;
    }
    if (_askId) {   // the old one is over (answered here, elsewhere, or the watcher gave up)
        [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[ _askId ]];
    }
    _askId = qid;
    _askText = qid ? [NSString stringWithContentsOfFile:[self askFile:@"text"] encoding:NSUTF8StringEncoding error:nil] : nil;
    NSString *b = qid ? [NSString stringWithContentsOfFile:[self askFile:@"buttons"] encoding:NSUTF8StringEncoding error:nil] : nil;
    NSMutableArray *buttons = [NSMutableArray new];
    for (NSString *line in [b componentsSeparatedByString:@"\n"]) {
        if (line.length) {
            [buttons addObject:line];
        }
    }
    _askButtons = buttons.count ? buttons : @[ @"OK" ];
    [self refreshQuestion];
    if (!qid) {
        return;
    }
    if (_notifyOK) {
        NSString *cat = [@"ask." stringByAppendingString:[_askButtons componentsJoinedByString:@"|"]];
        NSMutableArray *actions = [NSMutableArray new];
        for (NSString *t in _askButtons) {
            [actions addObject:[UNNotificationAction actionWithIdentifier:t title:t options:UNNotificationActionOptionNone]];
        }
        UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
        [c setNotificationCategories:[NSSet setWithObject:[UNNotificationCategory categoryWithIdentifier:cat
                                                                                                  actions:actions
                                                                                        intentIdentifiers:@[]
                                                                                                  options:0]]];
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"Venera";
        content.body = _askText ?: @"";
        content.categoryIdentifier = cat;
        content.sound = UNNotificationSound.defaultSound;
        [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:qid content:content trigger:nil]
            withCompletionHandler:nil];
    } else {
        [self showWindow:nil];   // no notifications: the question waits in the window
    }
}

- (void)answer:(NSString *)button {
    if (!_askId) {
        return;
    }
    NSString *s = [NSString stringWithFormat:@"%@\n%@\n", _askId, button];
    NSError *e;
    if (![s writeToFile:[self askFile:@"answer"] atomically:NO encoding:NSUTF8StringEncoding error:&e]) {
        NSLog(@"Venera: can't answer the watcher: %@", e);
    }
    [UNUserNotificationCenter.currentNotificationCenter removeDeliveredNotificationsWithIdentifiers:@[ _askId ]];
    _askText = nil;
    _askButtons = nil;
    [self refreshQuestion];   // _askId stays until the watcher takes the question down
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)r
             withCompletionHandler:(void (^)(void))done {
    NSString *a = r.actionIdentifier, *nid = r.notification.request.identifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([nid isEqualToString:self->_askId] && [self->_askButtons containsObject:a]) {
            [self answer:a];
        } else if (![a isEqualToString:UNNotificationDismissActionIdentifier]) {
            [self showWindow:nil];
        }
        done();
    });
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)n
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
    done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList |
         UNNotificationPresentationOptionSound);
}

// ---- the window --------------------------------------------------------------------------------------------------

static NSTextField *vn_label(NSString *s, BOOL bold) {
    NSTextField *t = [NSTextField wrappingLabelWithString:s ?: @""];
    t.font = bold ? [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold]
                  : [NSFont systemFontOfSize:NSFont.systemFontSize];
    t.selectable = YES;
    return t;
}

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 300)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Venera";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;

    _questionText = vn_label(@"", NO);
    _questionButtons = [NSStackView stackViewWithViews:@[]];
    _questionButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _questionBox = [NSStackView stackViewWithViews:@[ _questionText, _questionButtons ]];
    _questionBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    _questionBox.alignment = NSLayoutAttributeTrailing;
    _questionBox.spacing = 12;
    _questionBox.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    _questionBox.wantsLayer = YES;
    _questionBox.layer.cornerRadius = 10;
    _questionBox.layer.backgroundColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.12].CGColor;
    [_questionText.widthAnchor constraintEqualToConstant:472].active = YES;

    _grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    _grid.rowSpacing = 8;
    _grid.columnSpacing = 14;
    [_grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    _menuBarCheck = [NSButton checkboxWithTitle:@"Show Venera in the menu bar" target:self action:@selector(toggleMenuBar:)];
    NSButton *log = [NSButton buttonWithTitle:@"Open Log" target:self action:@selector(openLog:)];
    NSStackView *bottom = [NSStackView stackViewWithViews:@[ _menuBarCheck, [NSView new], log ]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;

    NSStackView *all = [NSStackView stackViewWithViews:@[ _questionBox, _grid, bottom ]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeLeading;
    all.spacing = 18;
    all.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [bottom.widthAnchor constraintEqualToAnchor:all.widthAnchor constant:-40].active = YES;
    _window.contentView = all;
    [all.widthAnchor constraintEqualToConstant:520].active = YES;
}

- (void)refreshUI {
    _item.menu = [self statusMenu];
    if (!_window) {
        return;
    }
    while (_grid.numberOfRows) {   // removing a row leaves its views in the grid: take them out first
        NSGridRow *row = [_grid rowAtIndex:0];
        for (NSInteger c = 0; c < row.numberOfCells; c++) {
            [[row cellAtIndex:c].contentView removeFromSuperview];
        }
        [_grid removeRowAtIndex:0];
    }
    VNStatus *s = _status;
    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
        @[ @"Desktop", s.graphics ?: @"" ],
        @[ @"Metal driver", s.driver ?: @"" ],
        @[ @"Video decoding", s.videoText ?: @"" ],
        @[ @"Version", s.version ?: @"(not installed by the installer)" ],
        @[ @"Notifications", _notifyOK ? @"On" : @"Off (questions wait in this window; System Settings > Notifications > Venera)" ],
    ]];
    if (s.graphicsWhy) {
        [rows insertObject:@[ @"Why", s.graphicsWhy ] atIndex:1];
    }
    for (NSArray *r in rows) {
        NSTextField *v = vn_label(r[1], NO);
        v.preferredMaxLayoutWidth = 360;   // so the row is as tall as its text, no taller
        [v.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
        [_grid addRowWithViews:@[ vn_label(r[0], YES), v ]];
    }
    _menuBarCheck.state = [NSUserDefaults.standardUserDefaults boolForKey:kMenuBarKey] ? NSControlStateValueOn
                                                                                        : NSControlStateValueOff;
    [self refreshQuestion];
}

- (void)refreshQuestion {
    if (!_questionBox) {
        return;
    }
    BOOL show = _askId && _askText;
    _questionBox.hidden = !show;
    for (NSView *v in _questionButtons.arrangedSubviews.copy) {
        [v removeFromSuperview];
    }
    if (!show) {
        [self fit];
        return;
    }
    _questionText.stringValue = _askText;
    _questionText.preferredMaxLayoutWidth = 472;
    for (NSString *t in _askButtons) {
        NSButton *b = [NSButton buttonWithTitle:t target:self action:@selector(answerButton:)];
        if (t == _askButtons.lastObject) {
            b.keyEquivalent = @"\r";
        }
        [_questionButtons addArrangedSubview:b];
    }
    [self fit];
}

- (void)answerButton:(NSButton *)b { [self answer:b.title]; }

// The window as tall as what it shows, its top edge where it was.
- (void)fit {
    if (!_window) {
        return;
    }
    [_window.contentView layoutSubtreeIfNeeded];
    NSSize want = _window.contentView.fittingSize;
    NSRect f = _window.frame, r = [_window frameRectForContentRect:NSMakeRect(0, 0, want.width, want.height)];
    [_window setFrame:NSMakeRect(f.origin.x, NSMaxY(f) - r.size.height, r.size.width, r.size.height) display:YES];
}

- (void)showWindow:(id)sender {
    if (!_window) {
        [self buildWindow];
        [self refreshUI];
        [_window center];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];   // a Dock icon while the window is open
    [_window makeKeyAndOrderFront:nil];
    [_window orderFrontRegardless];   // in front even when macOS doesn't let the app activate (launched in the background)
    [NSApp activate];
}
- (void)windowWillClose:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)openLog:(id)sender {
    NSURL *log = [NSURL fileURLWithPath:[kV stringByAppendingPathComponent:@"watch.log"]];
    NSURL *console = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Console"];
    if (console && [NSFileManager.defaultManager fileExistsAtPath:log.path]) {
        [NSWorkspace.sharedWorkspace openURLs:@[ log ]
                         withApplicationAtURL:console
                                configuration:[NSWorkspaceOpenConfiguration configuration]
                            completionHandler:nil];
    } else {
        NSBeep();
    }
}

// ---- the menu bar item (off by default) ----------------------------------------------------------------------------

- (void)toggleMenuBar:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:kMenuBarKey];
    [self applyMenuBar];
}
- (void)hideMenuBar:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kMenuBarKey];
    [self applyMenuBar];
    _menuBarCheck.state = NSControlStateValueOff;
}
- (void)applyMenuBar {
    BOOL want = [NSUserDefaults.standardUserDefaults boolForKey:kMenuBarKey];
    if (want && !_item) {
        _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
        _item.button.image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"Venera"];
        _item.menu = [self statusMenu];
    } else if (!want && _item) {
        [NSStatusBar.systemStatusBar removeStatusItem:_item];
        _item = nil;
    }
}
- (NSMenu *)statusMenu {
    NSMenu *m = [NSMenu new];
    VNStatus *s = _status;
    for (NSString *line in @[
             [@"Desktop: " stringByAppendingString:s.graphics ?: @""],
             [@"Video: " stringByAppendingString:s.videoText ?: @""],
         ]) {
        NSMenuItem *i = [m addItemWithTitle:line action:nil keyEquivalent:@""];
        i.enabled = NO;
    }
    if (_askId && _askText) {
        [m addItem:NSMenuItem.separatorItem];
        [m addItemWithTitle:@"Venera has a question…" action:@selector(showWindow:) keyEquivalent:@""].target = self;
    }
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"Open Venera…" action:@selector(showWindow:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:@"Hide from Menu Bar" action:@selector(hideMenuBar:) keyEquivalent:@""].target = self;
    return m;
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        VNApp *d = [VNApp new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
