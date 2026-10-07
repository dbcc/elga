#pragma once
#include <stdint.h>

// Versioned x64 C ABI. No STL, SDK types, exceptions, or allocated strings cross
// this boundary. All entry points except worker internals run on the UI thread.
struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
enum : uint32_t { ELGA_VIDEO_ABI = 3, ELGA_VSR = 1, ELGA_FRUC = 2 };
enum VideoState : uint32_t { VideoOff, VideoStarting, VideoActive, VideoNotNeeded, VideoUnavailable, VideoPaused };
enum VideoReason : uint32_t { ReasonNone, ReasonRuntime, ReasonAdapter, ReasonSDK, ReasonDisplay, ReasonSize, ReasonLate, ReasonReset, ReasonDevice };
struct VideoConfig {
    uint32_t width, height, outputWidth, outputHeight;
    uint32_t requested, generation, fpsNum, fpsDen;
    double refreshHz;
    uint32_t gameFps, retry; // 0 = automatic cadence; 30 = manual 30 FPS sampling
};
struct VideoFrame {
    uint64_t sequence;
    int64_t timestamp; // Media Foundation 100 ns units
    int64_t arrival;   // monotonic 100 ns units (QueryPerformanceCounter)
    uint32_t generation, flipped;
};
struct VideoOutput {
    ID3D11Texture2D* texture; // borrowed, valid until release(token)
    uint64_t token, sequence;
    int64_t deadline;
    uint32_t generation, generated, flipped, reserved;
};
struct VideoStatus {
    uint32_t vsrState, vsrReason, frucState, frucReason;
    uint64_t missed, submitted, produced;
    double processingMs, sourceHz;
    int64_t delay; // additional audio delay, 100 ns units
    int64_t nextDeadline;
    uint64_t history; // changes when queued video/audio history must be discarded
};
struct VideoCaps { uint32_t supported, vsrReason, frucReason, reserved; };
struct VideoAPI {
    uint32_t version, size;
    void (__cdecl* query)(ID3D11Device*, VideoCaps*);
    void* (__cdecl* create)(ID3D11Device*, void* notifyWindow, uint32_t notifyMessage);
    void (__cdecl* configure)(void*, const VideoConfig*); // asynchronous reset
    uint32_t (__cdecl* submit)(void*, ID3D11DeviceContext*, ID3D11Texture2D*, const VideoFrame*); // nonblocking
    uint32_t (__cdecl* poll)(void*, int64_t now, VideoOutput*, VideoStatus*); // nonblocking
    void (__cdecl* release)(void*, uint64_t token);
    void (__cdecl* destroy)(void*); // joins worker; shutdown only
};
using GetVideoAPI = uint32_t (__cdecl*)(uint32_t version, uint32_t size, VideoAPI*);
