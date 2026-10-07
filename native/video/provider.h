#pragma once
#include "video_api.h"
#include <d3d11_4.h>
#include <wrl/client.h>
#include <memory>

using Microsoft::WRL::ComPtr;
struct Provider {
    virtual ~Provider() = default;
    virtual VideoCaps caps() const = 0;
    virtual bool start(const VideoConfig&) = 0;
    virtual bool upscale(ID3D11Texture2D*, ID3D11Texture2D*) = 0;
    // previous input is cached by FRUC. Never call twice for the same input.
    virtual bool interpolate(ID3D11Texture2D*, int64_t inputTime, int64_t outputTime,
                             ID3D11Texture2D* output, bool& repeated) = 0;
    virtual void resetFruc() = 0;
};
std::unique_ptr<Provider> makeProvider(ID3D11Device*, ID3D11DeviceContext*);
int64_t videoNow();
