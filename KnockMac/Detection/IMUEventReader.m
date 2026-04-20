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

// kIOHIDEventTypeAccelerometer = 13 on macOS 26.x. Reading the type from the
// event itself keeps us resilient if Apple renumbers the enum in a future release.
static void hidEventCallback(void *target, void *refcon,
                             IOHIDServiceClientRef sender, IOHIDEventRef event) {
    if (!refcon || !event) return;
    IMUEventReaderRef reader = (IMUEventReaderRef)refcon;
    IMUSampleCallback cb = reader->callback;
    if (!cb) return;

    // Field encoding: (eventType << 16) | axisIndex.
    uint32_t type = IOHIDEventGetType(event);
    double x = IOHIDEventGetFloatValue(event, (type << 16) | 0);
    double y = IOHIDEventGetFloatValue(event, (type << 16) | 1);
    double z = IOHIDEventGetFloatValue(event, (type << 16) | 2);

    cb(x, y, z, reader->context);
}

// Walk the service list, find page=0xff00 usage=3, and write properties
// that wake the SPU streaming pipeline. Returns 1 if kicked, 0 otherwise.
static int kickIMUService(IOHIDEventSystemClientRef client) {
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    int32_t intervalUs = 8000; // 125 Hz native rate
    CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &intervalUs);

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
            IOHIDServiceClientSetProperty(svc, CFSTR("ReportInterval"), nv);
            IOHIDServiceClientSetProperty(svc, CFSTR("BatchInterval"),  nv);
            IOHIDServiceClientSetProperty(svc, CFSTR("Activated"),       nv);
            IOHIDServiceClientSetProperty(svc, CFSTR("ClientPolicy"),    nv);
            kicked = 1;
            break;
        }
    }

    CFRelease(nv);
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
