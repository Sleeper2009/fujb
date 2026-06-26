// LEDBreathe — tweak cho TrollLEDs / Quad-LED iPhone (rootless, Dopamine)
//
// PHIÊN BẢN AN TOÀN: mọi lệnh gọi tới API private đều được kiểm tra kỹ
// bằng respondsToSelector: trước khi gọi. Nếu bất kỳ bước nào không khớp
// (class không tồn tại, method không có...), tweak sẽ CHỈ ghi log và
// TỰ TẮT, không gọi liều để tránh làm crash mediaserverd.

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

static NSTimer *gBreatheTimer = nil;
static NSTimer *gAutoOffTimer = nil;
static id gTorchDevice = nil;
static BOOL gApiVerifiedSafe = NO;
static CFAbsoluteTime gStartTime = 0;

static id SafeGetTorchDevice(void) {
    if (gTorchDevice) return gTorchDevice;

    Class vendorClass = NSClassFromString(@"BWFigCaptureDeviceVendor");
    if (!vendorClass) {
        NSLog(@"[LEDBreathe][SAFE] Class BWFigCaptureDeviceVendor không tồn tại -> dừng an toàn.");
        return nil;
    }

    if (![vendorClass respondsToSelector:@selector(sharedVendor)]) {
        NSLog(@"[LEDBreathe][SAFE] vendorClass không có method sharedVendor -> dừng an toàn.");
        return nil;
    }

    id vendor = ((id (*)(id, SEL))objc_msgSend)(vendorClass, @selector(sharedVendor));
    if (!vendor) {
        NSLog(@"[LEDBreathe][SAFE] sharedVendor trả về nil -> dừng an toàn.");
        return nil;
    }

    SEL deviceForTypeSel = @selector(deviceForType:);
    if (![vendor respondsToSelector:deviceForTypeSel]) {
        NSLog(@"[LEDBreathe][SAFE] vendor không có method deviceForType: -> dừng an toàn.");
        return nil;
    }

    id device = ((id (*)(id, SEL, NSString *))objc_msgSend)(vendor, deviceForTypeSel, @"Torch");
    if (!device) {
        NSLog(@"[LEDBreathe][SAFE] deviceForType:Torch trả về nil -> dừng an toàn.");
        return nil;
    }

    SEL setParamsSel = NSSelectorFromString(@"setTorchManualParameters:white2:amber1:amber2:");
    if (![device respondsToSelector:setParamsSel]) {
        NSLog(@"[LEDBreathe][SAFE] device không có method setTorchManualParameters:white2:amber1:amber2: -> dừng an toàn.");
        return nil;
    }

    gTorchDevice = device;
    gApiVerifiedSafe = YES;
    NSLog(@"[LEDBreathe][SAFE] Mọi kiểm tra an toàn ĐỀU QUA.");
    return gTorchDevice;
}

static BOOL SafeSetTorchParams(id device, float w1, float w2, float a1, float a2) {
    if (!gApiVerifiedSafe || !device) return NO;

    SEL sel = NSSelectorFromString(@"setTorchManualParameters:white2:amber1:amber2:");

    @try {
        BOOL (*func)(id, SEL, float, float, float, float) =
            (BOOL (*)(id, SEL, float, float, float, float))objc_msgSend;
        return func(device, sel, w1, w2, a1, a2);
    } @catch (NSException *e) {
        NSLog(@"[LEDBreathe][SAFE] Exception khi gọi setTorchManualParameters: %@ -> tự tắt.", e);
        gApiVerifiedSafe = NO;
        return NO;
    }
}

static void ApplyBreatheFrame(void) {
    if (!gApiVerifiedSafe) return;
    id device = gTorchDevice;
    if (!device) return;

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

    BOOL ok = SafeSetTorchParams(device, white1, white2, amber1, amber2);
    if (!ok && !gApiVerifiedSafe) {
        if (gBreatheTimer) {
            [gBreatheTimer invalidate];
            gBreatheTimer = nil;
        }
    }
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
    if (gApiVerifiedSafe && gTorchDevice) {
        SafeSetTorchParams(gTorchDevice, 0, 0, 0, 0);
    }
    NSLog(@"[LEDBreathe] Đã dừng animation và tắt LED.");
}

static void StartBreathing(void) {
    if (gBreatheTimer) {
        NSLog(@"[LEDBreathe] Animation đã đang chạy, bỏ qua.");
        return;
    }

    id device = SafeGetTorchDevice();
    if (!device || !gApiVerifiedSafe) {
        NSLog(@"[LEDBreathe] Kiểm tra an toàn KHÔNG qua -> không khởi động animation.");
        return;
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
                                                          NSLog(@"[LEDBreathe] Hết thời gian an toàn -> tự tắt.");
                                                          StopBreathing();
                                                      }]
                                                    selector:@selector(main)
                                                    userInfo:nil
                                                     repeats:NO];
#endif

    NSLog(@"[LEDBreathe] Bắt đầu animation breathing (đã qua kiểm tra an toàn).");
}

static void DarwinNotifyCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
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
    Boolean enabled = CFPreferencesGetAppBooleanValue(
        CFSTR("enabled"),
        CFSTR("com.yourname.ledbreathe"),
        &keyExists
    );

    if (keyExists && enabled) {
        NSLog(@"[LEDBreathe] Toggle Settings = ON -> thử bắt đầu animation.");
        StartBreathing();
    } else {
        NSLog(@"[LEDBreathe] Toggle Settings = OFF -> dừng animation.");
        StopBreathing();
    }
}

static void SettingsChangedCallback(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    ApplySettingsState();
}

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    if (![processName isEqualToString:@"mediaserverd"]) {
        return;
    }

    NSLog(@"[LEDBreathe] Tweak loaded trong mediaserverd (bản an toàn).");

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        DarwinNotifyCallback,
        CFSTR("com.yourname.ledbreathe.start"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        DarwinNotifyCallback,
        CFSTR("com.yourname.ledbreathe.stop"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        SettingsChangedCallback,
        CFSTR("com.yourname.ledbreathe/preferenceschanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApplySettingsState();
    });
}
