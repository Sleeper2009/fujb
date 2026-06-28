// LEDBreathe v3 — viết lại HOÀN TOÀN dựa theo code nguồn mở thật của
// TrollLEDs (TLDeviceManager.m + TLConstants.h), không đoán API nữa.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define PHYSICAL_LED_IS_QUAD true
#define BRIGHTNESS_SCALE 0.55
#define BRIGHTNESS_FLOOR 0.06
#define BREATH_PERIOD_SEC 4.0
#define COLOR_PERIOD_SEC 6.5
#define UPDATE_FPS 30.0
#define AUTO_OFF_SECONDS (15 * 60)

#define LOG_FILE_PATH "/var/containers/Bundle/Application/.jbroot-42267504D25BF468/var/mobile/Documents/ledbreathe_log.txt"

static void FileLog(NSString *message) {
    NSLog(@"%@", message);
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], message];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@LOG_FILE_PATH];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@LOG_FILE_PATH contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@LOG_FILE_PATH];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static NSTimer *gBreatheTimer = nil;
static NSTimer *gAutoOffTimer = nil;
static CFAbsoluteTime gStartTime = 0;

static Class gVendorClass = nil;
static id gVendor = nil;
static int gPid = 0;
static unsigned int gClient = 0;
static void *gDeviceRef = NULL;
static id gDevice = nil;
static void *gStreamRef = NULL;
static id gStream = nil;
static BOOL gReady = NO;

static BOOL InitVendor(void) {
    void *cmCaptureHandle = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    if (!cmCaptureHandle) {
        void *celestialHandle = dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
        if (!celestialHandle) {
            FileLog(@"[LEDBreathe] Không load được CMCapture/Celestial framework -> dừng.");
            return NO;
        }
    }

    gVendorClass = NSClassFromString(@"BWFigCaptureDeviceVendor");
    if (!gVendorClass) {
        FileLog(@"[LEDBreathe] Không tìm thấy class BWFigCaptureDeviceVendor -> dừng.");
        return NO;
    }

    if ([gVendorClass respondsToSelector:@selector(sharedCaptureDeviceVendor)]) {
        gVendor = ((id (*)(id, SEL))objc_msgSend)(gVendorClass, @selector(sharedCaptureDeviceVendor));
    } else if ([gVendorClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
        gVendor = ((id (*)(id, SEL))objc_msgSend)(gVendorClass, NSSelectorFromString(@"sharedInstance"));
    }

    if (!gVendor) {
        FileLog(@"[LEDBreathe] Không lấy được vendor instance -> dừng.");
        return NO;
    }

    gPid = getpid();
    FileLog(@"[LEDBreathe] InitVendor thành công.");
    return YES;
}

static BOOL SetupStream(void) {
    if (gReady) return YES;

    SEL copyDefaultSel = NSSelectorFromString(
        @"copyDefaultVideoDeviceWithStealingBehavior:forPID:clientIDOut:withDeviceAvailabilityChangedHandler:");

    if ([gVendorClass respondsToSelector:copyDefaultSel]) {
        unsigned int clientOut = 0;
        void *(*func)(id, SEL, int, int, unsigned int *, void *) =
            (void *(*)(id, SEL, int, int, unsigned int *, void *))objc_msgSend;
        gDeviceRef = func(gVendorClass, copyDefaultSel, 1, gPid, &clientOut, NULL);
        gClient = clientOut;

        if (!gDeviceRef) {
            FileLog(@"[LEDBreathe] copyDefaultVideoDeviceWithStealingBehavior trả về NULL -> dừng.");
            return NO;
        }
        FileLog(@"[LEDBreathe] Lấy deviceRef qua nhánh mới thành công.");

        SEL streamSel = NSSelectorFromString(@"copyStreamForFlashlightWithPosition:deviceType:forDevice:");
        if ([gVendorClass respondsToSelector:streamSel]) {
            void *(*sfunc)(id, SEL, int, int, void *) = (void *(*)(id, SEL, int, int, void *))objc_msgSend;
            gStreamRef = sfunc(gVendorClass, streamSel, 1, 2, gDeviceRef);
        } else {
            SEL streamSel2 = NSSelectorFromString(@"copyStreamWithPosition:deviceType:forDevice:");
            void *(*sfunc2)(id, SEL, int, int, void *) = (void *(*)(id, SEL, int, int, void *))objc_msgSend;
            gStreamRef = sfunc2(gVendorClass, streamSel2, 1, 2, gDeviceRef);
        }

        if (!gStreamRef) {
            FileLog(@"[LEDBreathe] copyStreamForFlashlightWithPosition trả về NULL (nhánh mới) -> dừng.");
            return NO;
        }
        FileLog(@"[LEDBreathe] Lấy streamRef qua nhánh mới thành công.");
        gReady = YES;
        return YES;
    }

    SEL regSel1 = NSSelectorFromString(
        @"registerClientWithPID:clientDescription:clientPriority:canStealFromClientsWithSamePriority:deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:");

    if ([gVendor respondsToSelector:regSel1]) {
        NSMethodSignature *sig = [gVendor methodSignatureForSelector:regSel1];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = regSel1;
        inv.target = gVendor;
        NSString *desc = @"LEDBreathe tweak";
        int priority = 1;
        BOOL canSteal = NO;
        BOOL sharing = YES;
        void *nullHandler = NULL;
        [inv setArgument:&gPid atIndex:2];
        [inv setArgument:&desc atIndex:3];
        [inv setArgument:&priority atIndex:4];
        [inv setArgument:&canSteal atIndex:5];
        [inv setArgument:&sharing atIndex:6];
        [inv setArgument:&nullHandler atIndex:7];
        [inv invoke];
        unsigned int result = 0;
        [inv getReturnValue:&result];
        gClient = result;
    }

    if (gClient == 0) {
        FileLog(@"[LEDBreathe] registerClientWithPID thất bại hoặc không tồn tại -> dừng (nhánh cũ).");
        return NO;
    }

    SEL copyDevSel = NSSelectorFromString(@"copyDeviceForClient:informClientWhenDeviceAvailableAgain:error:");
    if ([gVendor respondsToSelector:copyDevSel]) {
        int errOut = 0;
        id (*dfunc)(id, SEL, unsigned int, BOOL, int *) = (id (*)(id, SEL, unsigned int, BOOL, int *))objc_msgSend;
        gDevice = dfunc(gVendor, copyDevSel, gClient, NO, &errOut);
    }

    if (!gDevice) {
        FileLog(@"[LEDBreathe] copyDeviceForClient trả về nil (nhánh cũ) -> dừng.");
        return NO;
    }

    SEL streamSel = NSSelectorFromString(@"copyStreamForFlashlightWithPosition:deviceType:forDevice:");
    if ([gVendor respondsToSelector:streamSel]) {
        id (*sfunc)(id, SEL, int, int, id) = (id (*)(id, SEL, int, int, id))objc_msgSend;
        gStream = sfunc(gVendor, streamSel, 1, 2, gDevice);
    }

    if (!gStream) {
        FileLog(@"[LEDBreathe] copyStreamForFlashlightWithPosition trả về nil (nhánh cũ id-style) -> dừng.");
        return NO;
    }

    FileLog(@"[LEDBreathe] Setup stream qua nhánh cũ (id-style) thành công.");
    gReady = YES;
    return YES;
}

static void SetTorchParams(float w1, float w2, float a1, float a2) {
    if (!gReady) return;

    float values[4] = { w1, w2, a1, a2 };
    NSData *data = [NSData dataWithBytes:values length:sizeof(values)];

    @try {
        if (gStream) {
            SEL setPropSel = NSSelectorFromString(@"setProperty:value:");
            if ([gStream respondsToSelector:setPropSel]) {
                ((void (*)(id, SEL, CFStringRef, id))objc_msgSend)
                    (gStream, setPropSel, CFSTR("TorchManualParameters"), data);
            }
        } else if (gStreamRef) {
            FileLog(@"[LEDBreathe] Có streamRef (CF-style) nhưng chưa hỗ trợ set property qua vtable trong bản này -> bỏ qua an toàn.");
        }
    } @catch (NSException *e) {
        FileLog([NSString stringWithFormat:@"[LEDBreathe] Exception khi setProperty: %@", e]);
    }
}

static void ApplyBreatheFrame(void) {
    if (!gReady) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double t = now - gStartTime;

    double breathPhase = (2.0 * M_PI * t) / BREATH_PERIOD_SEC;
    double breath01 = (sin(breathPhase) + 1.0) / 2.0;
    double intensity = BRIGHTNESS_FLOOR + breath01 * (BRIGHTNESS_SCALE - BRIGHTNESS_FLOOR);

    double colorPhase = (2.0 * M_PI * t) / COLOR_PERIOD_SEC;
    double colorMix01 = (sin(colorPhase) + 1.0) / 2.0;

    double coolWeight = 1.0 - colorMix01;
    double warmWeight = colorMix01;

    float white1 = (float)(intensity * coolWeight);
    float amber1 = (float)(intensity * warmWeight);
    float white2 = 0.0f;
    float amber2 = 0.0f;

#if PHYSICAL_LED_IS_QUAD
    white2 = white1;
    amber2 = amber1;
#endif

    SetTorchParams(white1, white2, amber1, amber2);
}

static void StopBreathing(void) {
    if (gBreatheTimer) {
        [gBreatheTimer invalidate];
        gBreatheTimer = nil;
    }
    if (gAutoOffTimer) {
        [gAutoOffTimer invalidate];
        gAutoOffTimer = nil;
    }
    if (gReady) {
        SetTorchParams(0, 0, 0, 0);
    }
    FileLog(@"[LEDBreathe] Đã dừng animation.");
}

static void StartBreathing(void) {
    if (gBreatheTimer) {
        FileLog(@"[LEDBreathe] Animation đã đang chạy, bỏ qua.");
        return;
    }

    if (!gVendor) {
        if (!InitVendor()) return;
    }
    if (!gReady) {
        if (!SetupStream()) return;
    }

    gStartTime = CFAbsoluteTimeGetCurrent();

    gBreatheTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / UPDATE_FPS)
                                                      target:[NSBlockOperation blockOperationWithBlock:^{
                                                          ApplyBreatheFrame();
                                                      }]
                                                    selector:@selector(main)
                                                    userInfo:nil
                                                     repeats:YES];

#if AUTO_OFF_SECONDS > 0
    gAutoOffTimer = [NSTimer scheduledTimerWithTimeInterval:AUTO_OFF_SECONDS
                                                      target:[NSBlockOperation blockOperationWithBlock:^{
                                                          FileLog(@"[LEDBreathe] Hết thời gian an toàn -> tự tắt.");
                                                          StopBreathing();
                                                      }]
                                                    selector:@selector(main)
                                                    userInfo:nil
                                                     repeats:NO];
#endif

    FileLog(@"[LEDBreathe] Bắt đầu animation breathing.");
}

static void DarwinNotifyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    NSString *notifName = (__bridge NSString *)name;
    if ([notifName isEqualToString:@"com.yourname.ledbreathe.start"]) {
        StartBreathing();
    } else if ([notifName isEqualToString:@"com.yourname.ledbreathe.stop"]) {
        StopBreathing();
    }
}

static void ApplySettingsState(void) {
    CFPreferencesAppSynchronize(CFSTR("com.yourname.ledbreathe"));
    Boolean keyExists = false;
    Boolean enabled = CFPreferencesGetAppBooleanValue(CFSTR("enabled"), CFSTR("com.yourname.ledbreathe"), &keyExists);
    if (keyExists && enabled) {
        StartBreathing();
    } else {
        StopBreathing();
    }
}

static void SettingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                     const void *object, CFDictionaryRef userInfo) {
    ApplySettingsState();
}

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    if (![processName isEqualToString:@"mediaserverd"]) {
        return;
    }

    FileLog(@"[LEDBreathe] Tweak v3 loaded trong mediaserverd (theo code thật TrollLEDs).");

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DarwinNotifyCallback,
                                     CFSTR("com.yourname.ledbreathe.start"), NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DarwinNotifyCallback,
                                     CFSTR("com.yourname.ledbreathe.stop"), NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SettingsChangedCallback,
                                     CFSTR("com.yourname.ledbreathe/preferenceschanged"), NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApplySettingsState();
    });
}
