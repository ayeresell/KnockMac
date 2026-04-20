// Focused probe: property kick via IOHIDEventSystemClient + listen.
// This is the only path that delivers IMU events on this machine.
// Prints x/y/z for the first 5 events and total count after 5s.
//
// Compile:
//   clang -framework Foundation -framework IOKit \
//     /Users/anton/Desktop/Xcode/KnockMac/scripts/imu_kick_probe.m \
//     -o /tmp/imu_kick_probe
//
// Run:
//   /tmp/imu_kick_probe

#import <Foundation/Foundation.h>

// Private API
typedef struct __IOHIDEventSystemClient * IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      * IOHIDServiceClientRef;
typedef struct __IOHIDEvent              * IOHIDEventRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                    IOHIDServiceClientRef sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef,
                                                        IOHIDEventSystemClientEventCallback,
                                                        void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef, dispatch_queue_t);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef, CFStringRef, CFTypeRef);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef);
extern double   IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t field);
extern CFIndex  IOHIDEventGetIntegerValue(IOHIDEventRef, uint32_t field);

#define IMU_PAGE  0xff00
#define IMU_USAGE 0x3
#define DURATION  5.0

static int g_count;

static void cb(void *t, void *r, IOHIDServiceClientRef s, IOHIDEventRef e) {
    g_count++;
    if (g_count <= 5) {
        uint32_t type = IOHIDEventGetType(e);
        double x = IOHIDEventGetFloatValue(e, (type << 16) | 0);
        double y = IOHIDEventGetFloatValue(e, (type << 16) | 1);
        double z = IOHIDEventGetFloatValue(e, (type << 16) | 2);
        CFIndex ix = IOHIDEventGetIntegerValue(e, (type << 16) | 0);
        CFIndex iy = IOHIDEventGetIntegerValue(e, (type << 16) | 1);
        CFIndex iz = IOHIDEventGetIntegerValue(e, (type << 16) | 2);
        printf("  Event #%d type=%u  float=(%.4f, %.4f, %.4f)  int=(%ld, %ld, %ld)\n",
               g_count, type, x, y, z, ix, iy, iz);
    }
}

int main(void) {
    @autoreleasepool {
        IOHIDEventSystemClientRef cli = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!cli) { printf("CreateClient failed\n"); return 1; }

        // Step 1: kick the IMU service
        CFArrayRef services = IOHIDEventSystemClientCopyServices(cli);
        if (!services) { printf("CopyServices returned NULL\n"); CFRelease(cli); return 1; }
        int32_t v = 8000;
        CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
        int kicked = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef p = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
            CFTypeRef u = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
            long page = 0, usage = 0;
            if (p) { CFNumberGetValue((CFNumberRef)p, kCFNumberLongType, &page); CFRelease(p); }
            if (u) { CFNumberGetValue((CFNumberRef)u, kCFNumberLongType, &usage); CFRelease(u); }
            if (page == IMU_PAGE && usage == IMU_USAGE) {
                IOHIDServiceClientSetProperty(svc, CFSTR("ReportInterval"), nv);
                IOHIDServiceClientSetProperty(svc, CFSTR("BatchInterval"), nv);
                IOHIDServiceClientSetProperty(svc, CFSTR("Activated"), nv);
                IOHIDServiceClientSetProperty(svc, CFSTR("ClientPolicy"), nv);
                kicked = 1;
                printf("Kicked IMU service (page=0xff00 usage=3)\n");
                break;
            }
        }
        CFRelease(nv);
        CFRelease(services);
        if (!kicked) { printf("IMU service not found\n"); CFRelease(cli); return 1; }

        // Step 2: subscribe and listen
        NSDictionary *m = @{ @"PrimaryUsagePage": @(IMU_PAGE), @"PrimaryUsage": @(IMU_USAGE) };
        IOHIDEventSystemClientSetMatching(cli, (__bridge CFDictionaryRef)m);
        IOHIDEventSystemClientRegisterEventCallback(cli, cb, NULL, NULL);
        IOHIDEventSystemClientScheduleWithDispatchQueue(cli, dispatch_get_main_queue());
        printf("Listening for %.0fs (move the laptop for variation)...\n", DURATION);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DURATION * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            printf("=== Total events: %d in %.0fs (~%.0f Hz) ===\n",
                   g_count, DURATION, g_count / DURATION);
            exit(0);
        });
        dispatch_main();
    }
    return 0;
}
