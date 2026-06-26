// LEDBreathe — tweak cho TrollLEDs / Quad-LED iPhone (rootless, Dopamine)

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>

#define PHYSICAL_LED_IS_QUAD true
#define BRIGHTNESS_SCALE 0.55
#define BRIGHTNESS_FLOOR 0.06
#define BREATH_PERIOD_SEC 4.0
#define COLOR_PERIOD_SEC 6.5
#define UPDATE_FPS 30.0
#define AUTO_OFF_SECONDS (15 * 60)

@interface BWFigCaptureDeviceVendor : NSObject
+ (instancetype)sharedVendor;
- (id)deviceForType:(NSString *)type;
@end

@interface BWFigCaptureDevice : NSObject
- (BOOL)setTorchManualParameters:(float)white1
                           white2:(float)white2
                           amber1:(float)amber1
                           amber2:(float)amber2;
@end

static NSTimer *gBreatheTimer = nil;
static NSTimer *gAutoOffTimer = nil;
static BWFigCaptureDevice *gTorchDevice = nil;
static CFAbsoluteTime gStartTime = 0;

static BWFigCaptureDevice *GetTorchDevice(void) {
    if (gTorchDevice) return gTorchDevice;
    Class vendorClass = NSClassFromString(@"BWFigCaptureDeviceVendor");
    if (!vendorClass) {
        NSLog(@"[LEDBreathe] Không tìm thấy BWFigCaptureDeviceVendor");
        return nil;
    }
    id vendor = [vendorClass sharedVendor];
    if (!vendor) {
        NSLog(@"[LEDBreathe] sharedVendor trả về nil");
        return nil;
    }
    id device = [vendor deviceForType:@"Torch"];
    if (!device) {
        NSLog(@"[LEDBreathe] deviceForType:Torch trả về nil");
        return nil;
    }
    gTorchDevice = device;
    return gTorchDevice;
}

static void ApplyBreatheFrame(void) {
    BWFigCaptureDevice *device = GetTorchDevice();
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

    BOOL ok = [device setTorchManualParameters:white1
                                          white2:white2
                                          amber1:amber1
                                          amber2:amber2];
    if (!ok) {
        NSLog(@"[LEDBreathe] setTorchManualParameters thất bại (app khác đang giữ quyền điều khiển LED?)");
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
    BWFigCaptureDevice *device = GetTorchDevice();
    if (device) {
        [device setTorchManualParameters:0 white2:0 amber1:0 amber2:0];
    }
    NSLog(@"[LEDBreathe] Đã dừng animation và tắt LED.");
}

static void StartBreathing(void) {
    if (gBreatheTimer) {
        NSLog(@"[LEDBreathe] Animation đã đang chạy, bỏ qua.");
        return;
    }
    BWFigCaptureDevice *device = GetTorchDevice();
    if (!device) {
        NSLog(@"[LEDBreathe] Không lấy được torch device, không thể bắt đầu.");
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

    NSLog(@"[LEDBreathe] Bắt đầu animation breathing");
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

%ctor {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    if (![processName isEqualToString:@"mediaserverd"]) {
        return;
    }

    NSLog(@"[LEDBreathe] Tweak loaded trong mediaserverd.");

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
}
