// Bridge to private IOHIDEventSystemClient API for reading the Apple Silicon
// SPU accelerometer on macOS 26+. The public IOHIDDevice path no longer
// receives input reports for the IMU on macOS 26.4+ (verified via diagnostic),
// so we go through the same path Apple's own sensor consumers use.
//
// The IOHIDEventSystemClient API requires a "kick" — writing properties to
// the IOHIDServiceClient — to wake the SPU streaming pipeline. After the kick,
// IOHIDEvents of type kIOHIDEventTypeAccelerometer (= 13 on macOS 26) arrive
// at ~140 Hz with x/y/z in units of g.
//
// Instance-based: each reader owns its own IOHIDEventSystemClient, so multiple
// readers (e.g. main + onboarding calibration) can coexist.

#ifndef IMUEventReader_h
#define IMUEventReader_h

#ifdef __cplusplus
extern "C" {
#endif

/// Called for every accelerometer sample. x/y/z are in units of g.
/// Always invoked on the main dispatch queue.
typedef void (*IMUSampleCallback)(double x, double y, double z, void *context);

/// Opaque handle returned by IMUEventReaderCreate.
typedef struct IMUEventReader * IMUEventReaderRef;

/// Creates a new reader and starts streaming. Returns NULL on failure.
/// On success, callback fires for every accelerometer event on the main queue
/// until IMUEventReaderDestroy is called.
IMUEventReaderRef _Nullable IMUEventReaderCreate(IMUSampleCallback _Nonnull cb,
                                                 void * _Nullable context);

/// Stops streaming and releases the reader. Safe to call with NULL.
void IMUEventReaderDestroy(IMUEventReaderRef _Nullable reader);

#ifdef __cplusplus
}
#endif

#endif
