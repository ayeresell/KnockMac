// Full IMU diagnostic — tries every way I know to get accelerometer data
// from the Apple Silicon SPU on macOS 26.
//
// Compile:
//   clang -framework Foundation -framework IOKit -framework CoreGraphics \
//     /Users/anton/Desktop/Xcode/KnockMac/scripts/imu_full_diagnostic.m \
//     -o /tmp/imu_full_diagnostic
//
// Run:
//   /tmp/imu_full_diagnostic
//
// PERMISSIONS REQUIRED (granted to the parent process — Terminal/Xcode/Claude):
//   System Settings > Privacy & Security > Input Monitoring > [parent app] = ON
//
// Inheritance: TCC attributes our HID requests to the responsible/parent
// process. If Terminal has Input Monitoring, this binary inherits it.
// If neither parent nor binary has it, every HID test below silently fails.
//
// Phase 0 explicitly checks Input Monitoring via CGPreflightListenEventAccess
// and refuses to proceed with a useful warning if missing.
//
// Each test runs ~5 seconds. Total runtime ~90 seconds.
// Move/shake the laptop continuously during the run to maximize chance of
// motion-triggered events firing.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>

// CoreGraphics declares these in CGEventTypes.h — explicit forward decl in case the import doesn't pull them through.
extern bool CGPreflightListenEventAccess(void);
extern bool CGRequestListenEventAccess(void);
extern bool CGPreflightScreenCaptureAccess(void);

// ===== Private API declarations (IOHIDEventSystemClient) =====
typedef struct __IOHIDEventSystemClient * IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      * IOHIDServiceClientRef;
typedef struct __IOHIDEvent              * IOHIDEventRef;

typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                    IOHIDServiceClientRef sender,
                                                    IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void   IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern void   IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
                                                          IOHIDEventSystemClientEventCallback callback,
                                                          void *target, void *refcon);
extern void   IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
extern void   IOHIDEventSystemClientUnscheduleFromDispatchQueue(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef  IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef service);
extern CFTypeRef  IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern Boolean    IOHIDServiceClientSetProperty(IOHIDServiceClientRef service, CFStringRef key, CFTypeRef value);
extern uint32_t   IOHIDEventGetType(IOHIDEventRef event);
extern uint64_t   IOHIDEventGetTimeStamp(IOHIDEventRef event);
extern double     IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
extern CFIndex    IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);
extern CFIndex    IOHIDEventGetDataLength(IOHIDEventRef event);
extern uint8_t *  IOHIDEventGetDataValue(IOHIDEventRef event, uint32_t field);
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef event);

// ===== Constants =====
#define IMU_VENDOR       0x05AC
#define IMU_PRODUCT      0x8104
#define IMU_USAGE_PAGE   0xff00
#define IMU_USAGE        0x3
#define ALS_USAGE_PAGE   0xff0c    // Control: known-working sensor cluster
#define TEST_DURATION_S  5.0

// ===== Test result aggregation =====
typedef struct { const char *name; int events; } TestResult;
static TestResult g_results[32];
static int g_resultCount = 0;
static void record(const char *name, int events) {
    g_results[g_resultCount++] = (TestResult){name, events};
    printf("  >>> %s: %d event(s)\n", name, events);
}

// Common run-for-N-seconds helper using main dispatch queue
static void runForSeconds(double seconds, void (^cleanup)(void)) {
    __block BOOL done = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (cleanup) cleanup();
        done = YES;
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRun();
    while (!done) usleep(1000);
}

// ============================================================
// PHASE 0: Environment + REAL permission check
// ============================================================
static int phase0_environment(void) {
    printf("\n========== PHASE 0: Environment & Permissions ==========\n");
    printf("Process: pid=%d euid=%d ruid=%d\n", getpid(), geteuid(), getuid());
    char *parent = getenv("__CFBundleIdentifier");
    printf("Parent bundle id (from env): %s\n", parent ? parent : "(none)");

    // 1. Process responsible parent — get full process ancestry via ps
    char psCmd[128];
    snprintf(psCmd, sizeof(psCmd), "ps -o pid,ppid,comm -p %d", getppid());
    printf("Parent process: ");
    fflush(stdout);
    system(psCmd);

    // 2. THE permission check. Input Monitoring (kTCCServiceListenEvent) gates
    //    all IOHIDDevice access in macOS for non-keyboard/mouse usage pages.
    bool hasInputMonitoring = CGPreflightListenEventAccess();
    printf("\n[CGPreflightListenEventAccess]   Input Monitoring: %s\n",
           hasInputMonitoring ? "GRANTED ✅" : "DENIED ❌");
    bool hasScreenCapture = CGPreflightScreenCaptureAccess();
    printf("[CGPreflightScreenCaptureAccess] Screen Recording: %s\n",
           hasScreenCapture ? "GRANTED ✅" : "DENIED  (not needed for IMU, FYI)");

    if (!hasInputMonitoring) {
        printf("\n>>> WARNING <<<\n");
        printf("Input Monitoring is NOT granted to this process or its parent.\n");
        printf("All IOHIDDevice tests below will silently return 0 events even on healthy hardware.\n");
        printf("To fix:\n");
        printf("  1) Open System Settings > Privacy & Security > Input Monitoring\n");
        printf("  2) Add the app that launched this binary (Terminal/iTerm/Xcode/Claude)\n");
        printf("  3) Toggle ON, then RELAUNCH this probe\n\n");
        printf("Attempting to trigger TCC prompt now (may show a system dialog)...\n");
        bool granted = CGRequestListenEventAccess();
        printf("CGRequestListenEventAccess returned: %s\n", granted ? "true" : "false");
        printf("If a prompt appeared, grant access then RE-RUN this probe (TCC requires relaunch).\n");
        return 1; // signal "do not proceed"
    }
    return 0;
}

// ============================================================
// PHASE 1: Discovery — what does the system see?
// ============================================================
static void phase1_discovery(void) {
    printf("\n========== PHASE 1: Discovery ==========\n");

    // 1a. All HID devices matching our vendor (regardless of usage)
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *m = @{ @kIOHIDVendorIDKey: @(IMU_VENDOR), @kIOHIDProductIDKey: @(IMU_PRODUCT) };
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)m);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef devs = IOHIDManagerCopyDevices(mgr);

    if (!devs) {
        printf("  ❌ NO devices match vendor=0x%x product=0x%x — IMU not even enumerating!\n",
               IMU_VENDOR, IMU_PRODUCT);
        IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
        CFRelease(mgr);
        return;
    }

    CFIndex n = CFSetGetCount(devs);
    printf("  Found %ld SPU device(s) [vendor=0x%x product=0x%x]:\n", n, IMU_VENDOR, IMU_PRODUCT);
    IOHIDDeviceRef *arr = malloc(n * sizeof(IOHIDDeviceRef));
    CFSetGetValues(devs, (const void **)arr);
    for (CFIndex i = 0; i < n; i++) {
        long page=0, usage=0, size=0, interval=0;
        CFNumberRef p = (CFNumberRef)IOHIDDeviceGetProperty(arr[i], CFSTR(kIOHIDPrimaryUsagePageKey));
        CFNumberRef u = (CFNumberRef)IOHIDDeviceGetProperty(arr[i], CFSTR(kIOHIDPrimaryUsageKey));
        CFNumberRef s = (CFNumberRef)IOHIDDeviceGetProperty(arr[i], CFSTR(kIOHIDMaxInputReportSizeKey));
        CFNumberRef ri = (CFNumberRef)IOHIDDeviceGetProperty(arr[i], CFSTR(kIOHIDReportIntervalKey));
        if (p)  CFNumberGetValue(p, kCFNumberLongType, &page);
        if (u)  CFNumberGetValue(u, kCFNumberLongType, &usage);
        if (s)  CFNumberGetValue(s, kCFNumberLongType, &size);
        if (ri) CFNumberGetValue(ri, kCFNumberLongType, &interval);
        printf("    [%ld] page=0x%lx usage=0x%lx maxInputReportSize=%ldb reportInterval=%ldus%s\n",
               i, page, usage, size, interval,
               (page == IMU_USAGE_PAGE && usage == IMU_USAGE) ? "  <-- target IMU" : "");
    }
    free(arr);
    CFRelease(devs);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);
}

// ============================================================
// PHASE 2: Control — subscribe to ALS via Event System
// If this gets events, our event-system rig works (so 0 events on IMU
// is meaningful). If this gets 0 events too, the rig is broken and we
// can't conclude anything about IMU from event-system probes.
// ============================================================
static int g_alsCount;
static void alsEventCallback(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_alsCount++;
}
static void phase2_control_als(void) {
    printf("\n========== PHASE 2: CONTROL — ALS via Event System ==========\n");
    printf("  (ALS is on page 0x%x — known to work; cover/uncover your screen for events)\n", ALS_USAGE_PAGE);
    g_alsCount = 0;
    IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    NSDictionary *m = @{ @"PrimaryUsagePage": @(ALS_USAGE_PAGE) };
    IOHIDEventSystemClientSetMatching(cli, (__bridge CFDictionaryRef)m);
    IOHIDEventSystemClientRegisterEventCallback(cli, alsEventCallback, NULL, NULL);
    IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(cli, dispatch_get_main_queue());
    });
    CFRelease(cli);
    record("CONTROL: ALS via Event System (page 0xff0c)", g_alsCount);
}

// ============================================================
// PHASE 3: IMU via raw IOHIDDevice + InputReportCallback (current production path)
// ============================================================
static int g_rawReportCount;
static void rawReportCallback(void *ctx, IOReturn res, void *sender,
                              IOHIDReportType type, uint32_t reportID,
                              uint8_t *report, CFIndex length) {
    g_rawReportCount++;
}
static IOHIDDeviceRef findIMUDevice(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *m = @{
        @kIOHIDVendorIDKey: @(IMU_VENDOR),
        @kIOHIDProductIDKey: @(IMU_PRODUCT),
        @kIOHIDDeviceUsagePageKey: @(IMU_USAGE_PAGE),
        @kIOHIDDeviceUsageKey: @(IMU_USAGE),
    };
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)m);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set || CFSetGetCount(set) == 0) {
        if (set) CFRelease(set);
        IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
        CFRelease(mgr);
        return NULL;
    }
    IOHIDDeviceRef devs[8];
    CFSetGetValues(set, (const void **)devs);
    IOHIDDeviceRef pick = devs[0];
    CFRetain(pick);
    CFRelease(set);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);
    return pick;
}
static void phase3_raw_report(void) {
    printf("\n========== PHASE 3: IMU raw IOHIDDevice + InputReportCallback ==========\n");
    g_rawReportCount = 0;
    IOHIDDeviceRef dev = findIMUDevice();
    if (!dev) { record("RAW report (open none)", -1); return; }
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    printf("  IOHIDDeviceOpen result=0x%x\n", r);
    if (r != kIOReturnSuccess) { CFRelease(dev); record("RAW report (open none)", -1); return; }
    uint8_t *buf = malloc(64);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, rawReportCallback, NULL);
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    });
    free(buf);
    CFRelease(dev);
    record("RAW report callback (open=none)", g_rawReportCount);
}

// ============================================================
// PHASE 4: IMU via raw IOHIDDevice with Seize
// ============================================================
static void phase4_seize(void) {
    printf("\n========== PHASE 4: IMU raw IOHIDDevice with SEIZE ==========\n");
    g_rawReportCount = 0;
    IOHIDDeviceRef dev = findIMUDevice();
    if (!dev) { record("RAW report (seize)", -1); return; }
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeSeizeDevice);
    printf("  IOHIDDeviceOpen(seize) result=0x%x\n", r);
    if (r != kIOReturnSuccess) {
        IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
        printf("  Falling back to non-seize open\n");
    }
    uint8_t *buf = malloc(64);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, rawReportCallback, NULL);
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    });
    free(buf);
    CFRelease(dev);
    record("RAW report callback (open=seize)", g_rawReportCount);
}

// ============================================================
// PHASE 5: IMU via IOHIDDevice + Element InputValue callback
// ============================================================
static int g_valueCount;
static void valueCallback(void *ctx, IOReturn res, void *sender, IOHIDValueRef value) {
    g_valueCount++;
}
static void phase5_element_value(void) {
    printf("\n========== PHASE 5: IMU IOHIDDevice + InputValueCallback ==========\n");
    g_valueCount = 0;
    IOHIDDeviceRef dev = findIMUDevice();
    if (!dev) { record("InputValue callback", -1); return; }
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) { CFRelease(dev); record("InputValue callback", -1); return; }
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputValueCallback(dev, valueCallback, NULL);
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDDeviceRegisterInputValueCallback(dev, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    });
    CFRelease(dev);
    record("InputValue (element-level) callback", g_valueCount);
}

// ============================================================
// PHASE 6: IMU via IOHIDQueue (lower-level alternative)
// ============================================================
static int g_queueCount;
static void queueValueCallback(void *ctx, IOReturn res, void *sender) {
    IOHIDQueueRef q = (IOHIDQueueRef)sender;
    while (1) {
        IOHIDValueRef v = IOHIDQueueCopyNextValueWithTimeout(q, 0);
        if (!v) break;
        g_queueCount++;
        CFRelease(v);
    }
}
static void phase6_queue(void) {
    printf("\n========== PHASE 6: IMU via IOHIDQueue API ==========\n");
    g_queueCount = 0;
    IOHIDDeviceRef dev = findIMUDevice();
    if (!dev) { record("IOHIDQueue", -1); return; }
    if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        CFRelease(dev); record("IOHIDQueue", -1); return;
    }
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    printf("  Device has %ld element(s)\n", elements ? CFArrayGetCount(elements) : 0);
    IOHIDQueueRef q = IOHIDQueueCreate(kCFAllocatorDefault, dev, 64, kIOHIDOptionsTypeNone);
    if (elements) {
        for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
            IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
            IOHIDQueueAddElement(q, e);
        }
        CFRelease(elements);
    }
    IOHIDQueueRegisterValueAvailableCallback(q, queueValueCallback, NULL);
    IOHIDQueueScheduleWithRunLoop(q, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDQueueStart(q);
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDQueueStop(q);
        IOHIDQueueUnscheduleFromRunLoop(q, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    });
    CFRelease(q);
    CFRelease(dev);
    record("IOHIDQueue (all elements)", g_queueCount);
}

// ============================================================
// PHASE 7: IMU via IOHIDEventSystemClient with matching
// ============================================================
static int g_evCount;
static void evCallback(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_evCount++;
}
static void phase7_event_system_matching(void) {
    printf("\n========== PHASE 7: IOHIDEventSystemClient (matching IMU) ==========\n");
    g_evCount = 0;
    IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    NSDictionary *m = @{
        @"PrimaryUsagePage": @(IMU_USAGE_PAGE),
        @"PrimaryUsage": @(IMU_USAGE),
    };
    IOHIDEventSystemClientSetMatching(cli, (__bridge CFDictionaryRef)m);
    IOHIDEventSystemClientRegisterEventCallback(cli, evCallback, NULL, NULL);
    IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(cli, dispatch_get_main_queue());
    });
    CFRelease(cli);
    record("Event System (matching page 0xff00 usage 3)", g_evCount);
}

// ============================================================
// PHASE 8: IMU via IOHIDEventSystemClient WITHOUT matching (fire hose)
// Subscribe to all events from all services. If any IMU event exists,
// it'll come through here.
// ============================================================
static int g_fireHoseCount;
static int g_fireHoseImuCount;
static void fireHoseCallback(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_fireHoseCount++;
    CFTypeRef pageR = IOHIDServiceClientCopyProperty(s, CFSTR("PrimaryUsagePage"));
    CFTypeRef usageR = IOHIDServiceClientCopyProperty(s, CFSTR("PrimaryUsage"));
    long page = 0, usage = 0;
    if (pageR)  { CFNumberGetValue((CFNumberRef)pageR, kCFNumberLongType, &page); CFRelease(pageR); }
    if (usageR) { CFNumberGetValue((CFNumberRef)usageR, kCFNumberLongType, &usage); CFRelease(usageR); }
    if (page == IMU_USAGE_PAGE && usage == IMU_USAGE) g_fireHoseImuCount++;
}
static void phase8_fire_hose(void) {
    printf("\n========== PHASE 8: Event System fire-hose (no matching) ==========\n");
    g_fireHoseCount = 0;
    g_fireHoseImuCount = 0;
    IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    // No matching = receive everything
    IOHIDEventSystemClientRegisterEventCallback(cli, fireHoseCallback, NULL, NULL);
    IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(cli, dispatch_get_main_queue());
    });
    CFRelease(cli);
    printf("  Total events from ALL services: %d\n", g_fireHoseCount);
    record("Event System fire-hose (any IMU events)", g_fireHoseImuCount);
}

// ============================================================
// PHASE 9: Try all 4 SPU usages (3, 5, 9, 255)
// Maybe IMU data moved to a different usage in macOS 26.
// ============================================================
static int g_perUsageCount;
static void perUsageCallback(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_perUsageCount++;
}
static void phase9_all_usages(void) {
    printf("\n========== PHASE 9: All SPU page=0xff00 usages ==========\n");
    int usages[] = {3, 5, 9, 0xff};
    for (int i = 0; i < 4; i++) {
        g_perUsageCount = 0;
        IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        NSDictionary *m = @{
            @"PrimaryUsagePage": @(IMU_USAGE_PAGE),
            @"PrimaryUsage": @(usages[i]),
        };
        IOHIDEventSystemClientSetMatching(cli, (__bridge CFDictionaryRef)m);
        IOHIDEventSystemClientRegisterEventCallback(cli, perUsageCallback, NULL, NULL);
        IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
        runForSeconds(2.5, ^{
            IOHIDEventSystemClientUnscheduleFromDispatchQueue(cli, dispatch_get_main_queue());
        });
        CFRelease(cli);
        char nameBuf[80];
        snprintf(nameBuf, sizeof(nameBuf), "Event System page=0xff00 usage=0x%x", usages[i]);
        record(nameBuf, g_perUsageCount);
    }
}

// ============================================================
// PHASE 10: Property kick — try to enable streaming via service properties
// ============================================================
static int g_kickCount;
static void kickCallback(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_kickCount++;
    if (g_kickCount <= 3) {
        uint32_t type = IOHIDEventGetType(e);
        uint64_t ts = IOHIDEventGetTimeStamp(e);
        printf("    Event #%d type=%u (", g_kickCount, type);
        switch (type) {
            case 1:  printf("VendorDefined"); break;
            case 2:  printf("Button"); break;
            case 3:  printf("Keyboard"); break;
            case 11: printf("Accelerometer"); break;
            case 12: printf("Gyro"); break;
            case 14: printf("MotionActivity"); break;
            default: printf("type%u", type); break;
        }
        printf(") ts=%llu", ts);
        // Try as accelerometer (type 13 in macOS 26): fields are (type<<16)|axis
        double x = IOHIDEventGetFloatValue(e, (type << 16) | 0);
        double y = IOHIDEventGetFloatValue(e, (type << 16) | 1);
        double z = IOHIDEventGetFloatValue(e, (type << 16) | 2);
        CFIndex ix = IOHIDEventGetIntegerValue(e, (type << 16) | 0);
        CFIndex iy = IOHIDEventGetIntegerValue(e, (type << 16) | 1);
        CFIndex iz = IOHIDEventGetIntegerValue(e, (type << 16) | 2);
        printf("\n      float xyz = (%.4f, %.4f, %.4f)", x, y, z);
        printf("\n      int   xyz = (%ld, %ld, %ld)\n", ix, iy, iz);
    }
}
static void phase10_property_kick(void) {
    printf("\n========== PHASE 10: Property kick on IMU service ==========\n");
    IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(cli);
    if (!services) { printf("  No services from event system\n"); CFRelease(cli); return; }

    IOHIDServiceClientRef imu = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef pageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
        CFTypeRef usageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
        long page = 0, usage = 0;
        if (pageR) { CFNumberGetValue((CFNumberRef)pageR, kCFNumberLongType, &page); CFRelease(pageR); }
        if (usageR) { CFNumberGetValue((CFNumberRef)usageR, kCFNumberLongType, &usage); CFRelease(usageR); }
        if (page == IMU_USAGE_PAGE && usage == IMU_USAGE) { imu = svc; CFRetain(imu); break; }
    }
    CFRelease(services);
    if (!imu) { printf("  IMU service not found in Event System\n"); CFRelease(cli); return; }
    printf("  Found IMU service. Trying to write streaming-enable properties...\n");

    int32_t interval = 8000;
    CFNumberRef intRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &interval);
    int32_t batch = 0;
    CFNumberRef batchRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &batch);

    const char *propsToTry[] = {
        "ReportInterval", "BatchInterval", "MaxReportLatency",
        "ClientUsageMask", "Activated", "ClientPolicy",
        "EventSystemHIDClientHints", "ReportLatency",
    };
    for (int i = 0; i < (int)(sizeof(propsToTry)/sizeof(*propsToTry)); i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, propsToTry[i], kCFStringEncodingUTF8);
        Boolean ok = IOHIDServiceClientSetProperty(imu, key, intRef);
        printf("    SetProperty(%s, %d) = %s\n", propsToTry[i], interval, ok ? "OK" : "fail");
        CFRelease(key);
    }

    // Now subscribe and listen
    g_kickCount = 0;
    NSDictionary *m = @{ @"PrimaryUsagePage": @(IMU_USAGE_PAGE), @"PrimaryUsage": @(IMU_USAGE) };
    IOHIDEventSystemClientSetMatching(cli, (__bridge CFDictionaryRef)m);
    IOHIDEventSystemClientRegisterEventCallback(cli, kickCallback, NULL, NULL);
    IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(cli, dispatch_get_main_queue());
    });
    CFRelease(intRef);
    CFRelease(batchRef);
    CFRelease(imu);
    CFRelease(cli);
    record("Property kick + Event System listen", g_kickCount);
}

// ============================================================
// PHASE 11: Direct IORegistry read — does the device expose
// any property that updates with sensor data?
// ============================================================
static void phase11_registry_poll(void) {
    printf("\n========== PHASE 11: IORegistry direct property poll ==========\n");
    io_iterator_t iter;
    CFMutableDictionaryRef m = IOServiceMatching("AppleSPUHIDDevice");
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &iter) != KERN_SUCCESS) {
        printf("  IOServiceGetMatchingServices failed\n");
        return;
    }
    int devIdx = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        CFTypeRef pageR = IORegistryEntryCreateCFProperty(svc, CFSTR("PrimaryUsagePage"), NULL, 0);
        CFTypeRef usageR = IORegistryEntryCreateCFProperty(svc, CFSTR("PrimaryUsage"), NULL, 0);
        long page = 0, usage = 0;
        if (pageR) { CFNumberGetValue((CFNumberRef)pageR, kCFNumberLongType, &page); CFRelease(pageR); }
        if (usageR) { CFNumberGetValue((CFNumberRef)usageR, kCFNumberLongType, &usage); CFRelease(usageR); }
        if (page == IMU_USAGE_PAGE && usage == IMU_USAGE) {
            printf("  IMU device idx=%d — polling DebugState 5x at 1s intervals:\n", devIdx);
            for (int i = 0; i < 5; i++) {
                CFTypeRef ds = IORegistryEntryCreateCFProperty(svc, CFSTR("DebugState"), NULL, 0);
                if (ds) {
                    CFStringRef desc = CFCopyDescription(ds);
                    char buf[512];
                    CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8);
                    printf("    [%d] DebugState = %s\n", i, buf);
                    CFRelease(desc);
                    CFRelease(ds);
                }
                sleep(1);
            }
        }
        IOObjectRelease(svc);
        devIdx++;
    }
    IOObjectRelease(iter);
}

// ============================================================
// PHASE 12: Property Kick via Event System, then RAW IOHIDDevice listen
// This is THE critical test: if raw IOHIDDevice works AFTER kick, we
// just add a kick call to KnockMac's AccelerometerReader and we're done.
// If raw IOHIDDevice still gets 0 even after kick, we need to migrate
// the whole reader to Event System path.
// ============================================================
static void phase12_kick_then_raw(void) {
    printf("\n========== PHASE 12: Kick via Event System, then RAW listen ==========\n");

    // Step 1: kick via Event System SetProperty
    IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(cli);
    int kicked = 0;
    if (services) {
        int32_t interval = 8000;
        CFNumberRef intRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &interval);
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef pageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
            CFTypeRef usageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
            long page = 0, usage = 0;
            if (pageR) { CFNumberGetValue((CFNumberRef)pageR, kCFNumberLongType, &page); CFRelease(pageR); }
            if (usageR) { CFNumberGetValue((CFNumberRef)usageR, kCFNumberLongType, &usage); CFRelease(usageR); }
            if (page == IMU_USAGE_PAGE && usage == IMU_USAGE) {
                IOHIDServiceClientSetProperty(svc, CFSTR("ReportInterval"), intRef);
                IOHIDServiceClientSetProperty(svc, CFSTR("BatchInterval"), intRef);
                IOHIDServiceClientSetProperty(svc, CFSTR("Activated"), intRef);
                IOHIDServiceClientSetProperty(svc, CFSTR("ClientPolicy"), intRef);
                kicked = 1;
                printf("  Kicked IMU service via SetProperty (4 keys)\n");
                break;
            }
        }
        CFRelease(intRef);
        CFRelease(services);
    }
    CFRelease(cli);
    if (!kicked) { printf("  Failed to find IMU service to kick\n"); record("Kick + RAW", -1); return; }

    // Step 2: open device via raw IOHIDDevice and listen
    g_rawReportCount = 0;
    IOHIDDeviceRef dev = findIMUDevice();
    if (!dev) { record("Kick + RAW", -1); return; }
    if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        CFRelease(dev); record("Kick + RAW", -1); return;
    }
    uint8_t *buf = malloc(64);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, rawReportCallback, NULL);
    runForSeconds(TEST_DURATION_S, ^{
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    });
    free(buf);
    CFRelease(dev);
    record("Kick (Event System) + RAW IOHIDDevice listen", g_rawReportCount);
}

// ============================================================
// MAIN — run all phases and summarize
// ============================================================
int main(int argc, char **argv) {
    @autoreleasepool {
        printf("===================================================\n");
        printf("  IMU FULL DIAGNOSTIC — macOS Apple Silicon SPU\n");
        printf("  Target: vendor=0x%x product=0x%x page=0x%x usage=0x%x\n",
               IMU_VENDOR, IMU_PRODUCT, IMU_USAGE_PAGE, IMU_USAGE);
        printf("  Each test runs %.0fs. Total ~90s.\n", TEST_DURATION_S);
        printf("  >>> SHAKE THE LAPTOP CONTINUOUSLY DURING TESTS <<<\n");
        printf("===================================================\n");

        if (phase0_environment() != 0) {
            printf("\nABORTING: fix Input Monitoring permission first, then re-run.\n");
            return 2;
        }
        phase1_discovery();
        phase2_control_als();
        phase3_raw_report();
        phase4_seize();
        phase5_element_value();
        phase6_queue();
        phase7_event_system_matching();
        phase8_fire_hose();
        phase9_all_usages();
        phase10_property_kick();
        phase11_registry_poll();
        phase12_kick_then_raw();

        printf("\n===================================================\n");
        printf("  SUMMARY\n");
        printf("===================================================\n");
        for (int i = 0; i < g_resultCount; i++) {
            const char *marker = (g_results[i].events > 0) ? "✅" :
                                 (g_results[i].events < 0) ? "❌" : "⚪";
            printf("  %s %s: %d\n", marker, g_results[i].name, g_results[i].events);
        }
        printf("\n");
        printf("  Legend:\n");
        printf("  ✅ = events received (this path WORKS for the IMU)\n");
        printf("  ⚪ = 0 events (path is silent)\n");
        printf("  ❌ = setup error / device not found\n");
        printf("\n");
        printf("  Interpretation:\n");
        printf("  - If CONTROL (ALS) is ✅ but all IMU tests are ⚪:\n");
        printf("      Test rig works, IMU specifically dead at hardware/firmware.\n");
        printf("  - If CONTROL is ⚪:\n");
        printf("      Probe rig itself broken (likely Input Monitoring missing\n");
        printf("      from the parent process).\n");
        printf("  - If any IMU test is ✅:\n");
        printf("      That's the API we should migrate KnockMac to.\n");
    }
    return 0;
}
