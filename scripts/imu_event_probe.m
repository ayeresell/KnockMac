// Probe via IOHIDEventSystemClient (private API path that ALS uses).
// If the IMU is alive but raw IOHIDDevice path is broken on macOS 26,
// this should still receive events.
//
// Compile:
//   clang -framework Foundation -framework IOKit \
//     /Users/anton/Desktop/Xcode/KnockMac/scripts/imu_event_probe.m \
//     -o /tmp/imu_event_probe
//
// Run:
//   /tmp/imu_event_probe

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

// --- Private opaque types ---
typedef struct __IOHIDEventSystemClient * IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient      * IOHIDServiceClientRef;
typedef struct __IOHIDEvent              * IOHIDEventRef;

typedef void (*IOHIDEventSystemClientEventCallback)(void *target,
                                                    void *refcon,
                                                    IOHIDServiceClientRef sender,
                                                    IOHIDEventRef event);

// --- Private function declarations (from IOKit private headers) ---
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client,
                                              CFDictionaryRef matching);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
                                                        IOHIDEventSystemClientEventCallback callback,
                                                        void *target,
                                                        void *refcon);
extern void IOHIDEventSystemClientScheduleWithDispatchQueue(IOHIDEventSystemClientRef client,
                                                            dispatch_queue_t queue);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);

extern uint32_t IOHIDEventGetType(IOHIDEventRef event);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef event);
extern double   IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
extern CFTypeRef IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef service);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);

static int eventCount = 0;

static void eventCallback(void *target, void *refcon,
                          IOHIDServiceClientRef sender, IOHIDEventRef event) {
    eventCount++;
    if (eventCount <= 5 || eventCount % 100 == 0) {
        uint32_t type = IOHIDEventGetType(event);
        uint64_t ts = IOHIDEventGetTimeStamp(event);
        printf("[evprobe] Event #%d type=%u ts=%llu sender=%p\n",
               eventCount, type, ts, sender);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) {
            printf("[evprobe] Failed to create IOHIDEventSystemClient\n");
            return 1;
        }
        printf("[evprobe] Client created\n");

        // First — list ALL services this client can see, with usage info
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services) {
            CFIndex n = CFArrayGetCount(services);
            printf("[evprobe] Client sees %ld service(s):\n", n);
            for (CFIndex i = 0; i < n; i++) {
                IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
                CFTypeRef rid  = IOHIDServiceClientGetRegistryID(svc);
                CFTypeRef page = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
                CFTypeRef usage = IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
                CFTypeRef ioclass = IOHIDServiceClientCopyProperty(svc, CFSTR("IOClass"));
                long pageVal = 0, usageVal = 0;
                if (page) CFNumberGetValue((CFNumberRef)page, kCFNumberLongType, &pageVal);
                if (usage) CFNumberGetValue((CFNumberRef)usage, kCFNumberLongType, &usageVal);
                char classBuf[128] = {0};
                if (ioclass) CFStringGetCString((CFStringRef)ioclass, classBuf, sizeof(classBuf), kCFStringEncodingUTF8);
                long ridVal = 0;
                if (rid) CFNumberGetValue((CFNumberRef)rid, kCFNumberLongType, &ridVal);
                printf("  - regID=0x%lx page=0x%lx usage=0x%lx class=%s%s\n",
                       ridVal, pageVal, usageVal, classBuf,
                       (pageVal == 0xff00 && usageVal == 3) ? "  <-- IMU" : "");
                if (page) CFRelease(page);
                if (usage) CFRelease(usage);
                if (ioclass) CFRelease(ioclass);
            }
            CFRelease(services);
        } else {
            printf("[evprobe] CopyServices returned NULL\n");
        }

        // Now subscribe to IMU events specifically
        NSDictionary *matching = @{
            @"PrimaryUsagePage": @(0xff00),
            @"PrimaryUsage": @(3),
        };
        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        printf("[evprobe] Matching set: PrimaryUsagePage=0xff00 PrimaryUsage=3\n");

        IOHIDEventSystemClientRegisterEventCallback(client, eventCallback, NULL, NULL);
        IOHIDEventSystemClientScheduleWithDispatchQueue(client, dispatch_get_main_queue());
        printf("[evprobe] Subscribed. Listening for 10s — try moving the laptop.\n");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            printf("[evprobe] === Summary: %d event(s) received ===\n", eventCount);
            exit(0);
        });

        dispatch_main();
    }
    return 0;
}
