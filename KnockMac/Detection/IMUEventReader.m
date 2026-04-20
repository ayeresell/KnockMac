#import "IMUEventReader.h"
#import <Foundation/Foundation.h>

// Private IOHIDEventSystemClient API forward declarations.
// These symbols are exported from IOKit.framework but not in any public header.
typedef struct __IOHIDEventSystemClient * IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      * IOHIDServiceClientRef;
typedef struct __IOHIDEvent              * IOHIDEventRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                    IOHIDServiceClientRef sender,
                                                    IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef,
                                                        IOHIDEventSystemClientEventCallback,
                                                        void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef, dispatch_queue_t);
extern void IOHIDEventSystemClientUnscheduleFromDispatchQueue(IOHIDEventSystemClientRef, dispatch_queue_t);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef, CFStringRef, CFTypeRef);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t field);

#define IMU_PAGE_FF00     0xff00
#define IMU_USAGE_ACCEL   0x3

struct IMUEventReader {
    IOHIDEventSystemClientRef client;
    IMUSampleCallback         callback;
    void                      *context;
};

// Adaptive peak-hold: quiet samples forward as-is (native timing / noise).
// When a sample crosses PEAK_TRIGGER_DEV we open a PEAK_HOLD_SEC window,
// track the max-deviation sample within it, and emit that max sample once
// the window closes. Counters the sampling aliasing that otherwise lets
// the detector see 0.04-0.06 g "apparent peaks" for knocks whose real peak
// is 0.10-0.14 g but happened to straddle sample boundaries.
// kIOHIDEventTypeAccelerometer is 13 on macOS 26.x; we read type from the
// event itself to stay resilient if Apple renumbers the enum later.
#define PEAK_TRIGGER_DEV 0.020
#define PEAK_HOLD_SEC    0.040

static inline double imu_magnitude(double x, double y, double z) {
    return sqrt(x * x + y * y + z * z);
}

static void emit(IMUEventReaderRef reader, double x, double y, double z) {
    IMUSampleCallback cb = reader->callback;
    if (cb) cb(x, y, z, reader->context);
}

static void hidEventCallback(void *target, void *refcon,
                             IOHIDServiceClientRef sender, IOHIDEventRef event) {
    if (!refcon || !event) return;
    IMUEventReaderRef reader = (IMUEventReaderRef)refcon;
    if (!reader->callback) return;

    double nowWall = CFAbsoluteTimeGetCurrent();

    // Field encoding: (eventType << 16) | axisIndex.
    uint32_t type = IOHIDEventGetType(event);
    double x = IOHIDEventGetFloatValue(event, (type << 16) | 0);
    double y = IOHIDEventGetFloatValue(event, (type << 16) | 1);
    double z = IOHIDEventGetFloatValue(event, (type << 16) | 2);
    double dev = fabs(imu_magnitude(x, y, z) - 1.0);

    static int holdActive = 0;
    static double holdStart = 0;
    static double bestX = 0, bestY = 0, bestZ = 0;
    static double bestDev = -1.0;

    // Close an active hold if the window has elapsed.
    if (holdActive && (nowWall - holdStart) >= PEAK_HOLD_SEC) {
        emit(reader, bestX, bestY, bestZ);
        holdActive = 0;
        bestDev = -1.0;
    }

    if (holdActive) {
        // Track max-deviation inside the current window; don't forward yet.
        if (dev > bestDev) {
            bestDev = dev;
            bestX = x; bestY = y; bestZ = z;
        }
    } else if (dev > PEAK_TRIGGER_DEV) {
        // Start a new peak-hold window seeded with this sample.
        holdActive = 1;
        holdStart = nowWall;
        bestDev = dev;
        bestX = x; bestY = y; bestZ = z;
    } else {
        // Quiet sample: forward directly.
        emit(reader, x, y, z);
    }
}

// Walk the service list, find page=0xff00 usage=3, and write properties
// that wake the SPU streaming pipeline. Returns 1 if kicked, 0 otherwise.
static int kickIMUService(IOHIDEventSystemClientRef client) {
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    // ReportInterval = 1 ms → 1000 Hz requested. SPU may cap lower, but we
    // ask for the fastest possible so peak-hold in hidEventCallback has the
    // densest data to find the true max for each knock.
    // BatchInterval = 0 → no bunching.
    int32_t reportUs = 1000;
    int32_t batchUs  = 0;
    CFNumberRef reportNv = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &reportUs);
    CFNumberRef batchNv  = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &batchUs);

    int kicked = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef pageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
        CFTypeRef usageR = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
        long page = 0, usage = 0;
        if (pageR)  { CFNumberGetValue((CFNumberRef)pageR, kCFNumberLongType, &page); CFRelease(pageR); }
        if (usageR) { CFNumberGetValue((CFNumberRef)usageR, kCFNumberLongType, &usage); CFRelease(usageR); }
        if (page == IMU_PAGE_FF00 && usage == IMU_USAGE_ACCEL) {
            // Empirically: writing these four properties is the only reliable
            // way to start the IMU stream on macOS 26.x. Most are no-ops on
            // their own, but the combination triggers the SPU pipeline.
            IOHIDServiceClientSetProperty(svc, CFSTR("ReportInterval"), reportNv);
            IOHIDServiceClientSetProperty(svc, CFSTR("BatchInterval"),  batchNv);
            IOHIDServiceClientSetProperty(svc, CFSTR("Activated"),       reportNv);
            IOHIDServiceClientSetProperty(svc, CFSTR("ClientPolicy"),    reportNv);
            kicked = 1;
            break;
        }
    }

    CFRelease(reportNv);
    CFRelease(batchNv);
    CFRelease(services);
    return kicked;
}

IMUEventReaderRef IMUEventReaderCreate(IMUSampleCallback cb, void *context) {
    if (!cb) return NULL;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;

    if (!kickIMUService(client)) {
        CFRelease(client);
        return NULL;
    }

    IMUEventReaderRef reader = (IMUEventReaderRef)calloc(1, sizeof(struct IMUEventReader));
    reader->client   = client;
    reader->callback = cb;
    reader->context  = context;

    NSDictionary *match = @{
        @"PrimaryUsagePage": @(IMU_PAGE_FF00),
        @"PrimaryUsage":     @(IMU_USAGE_ACCEL),
    };
    IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)match);
    IOHIDEventSystemClientRegisterEventCallback(client, hidEventCallback, NULL, reader);
    IOHIDEventSystemClientScheduleWithDispatchQueue(client, dispatch_get_main_queue());

    return reader;
}

void IMUEventReaderDestroy(IMUEventReaderRef reader) {
    if (!reader) return;
    // Enforce same-queue destroy. If this ever trips, we'd be racing the
    // callback dispatched on main and the destroy running elsewhere.
    dispatch_assert_queue(dispatch_get_main_queue());

    // Null the callback first so any event already queued on main (but not yet
    // executed) sees cb == NULL when it runs and bails out before deref'ing
    // the about-to-be-freed reader.
    reader->callback = NULL;
    reader->context  = NULL;

    if (reader->client) {
        IOHIDEventSystemClientUnscheduleFromDispatchQueue(reader->client, dispatch_get_main_queue());
        CFRelease(reader->client);
        reader->client = NULL;
    }
    free(reader);
}
