// Bridge to private IOHIDEventSystemClient API for reading the Apple Silicon
// SPU accelerometer on macOS 26+. The public IOHIDDevice path no longer
// receives input reports for the IMU on macOS 26.4+ (verified via diagnostic),
// so we go through the same path Apple's own sensor consumers use.
//
// The IOHIDEventSystemClient API requires a "kick" — writing properties to
// the IOHIDServiceClient — to wake the SPU streaming pipeline. After the kick,
// IOHIDEvents of type kIOHIDEventTypeAccelerometer (= 13 on macOS 26) arrive
// at ~140 Hz with x/y/z in units of g.

#ifndef IMUEventReader_h
#define IMUEventReader_h

#ifdef __cplusplus
extern "C" {
#endif

/// Called for every accelerometer sample. x/y/z are in units of g.
/// Always invoked on the main dispatch queue.
typedef void (*IMUSampleCallback)(double x, double y, double z, void *context);

/// Starts streaming. Returns 0 on success, negative on failure:
///   -1: already running
///   -2: IOHIDEventSystemClientCreate failed
///   -3: IOHIDEventSystemClientCopyServices returned NULL
///   -4: IMU service (page=0xff00 usage=3) not found
int IMUEventStartStreaming(IMUSampleCallback cb, void *context);

/// Stops streaming and releases the client. Safe to call multiple times.
void IMUEventStopStreaming(void);

#ifdef __cplusplus
}
#endif

#endif
