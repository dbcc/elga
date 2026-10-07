// Deliberately synthetic provider, linked ONLY into elga-video-test.dll.
// It never ships in the NVIDIA add-on and does not claim to perform inference.
#include "provider.h"
#include <cstdlib>
struct TestProvider final : Provider {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    VideoConfig config{};
    TestProvider(ID3D11Device* d,ID3D11DeviceContext* c):device(d),context(c) {}
    VideoCaps caps() const override { return {3,0,0,0}; }
    bool start(const VideoConfig& c) override {
        config=c;
        wchar_t enteredName[128]{}, releaseName[128]{};
        if(GetEnvironmentVariableW(L"ELGA_TEST_START_ENTERED",enteredName,128) && GetEnvironmentVariableW(L"ELGA_TEST_START_RELEASE",releaseName,128)) {
            HANDLE entered=OpenEventW(EVENT_MODIFY_STATE,FALSE,enteredName);
            HANDLE release=OpenEventW(SYNCHRONIZE,FALSE,releaseName);
            if(entered) { SetEvent(entered); CloseHandle(entered); }
            if(release) { WaitForSingleObject(release,5000); CloseHandle(release); }
        }
        return true;
    }
    bool upscale(ID3D11Texture2D*,ID3D11Texture2D* to) override {
        if(GetEnvironmentVariableW(L"ELGA_TEST_FAIL_VSR",nullptr,0)) return false;
        if(GetEnvironmentVariableW(L"ELGA_TEST_SLOW_VSR",nullptr,0)) Sleep(20);
        ComPtr<ID3D11RenderTargetView> target;
        if(FAILED(device->CreateRenderTargetView(to,nullptr,&target))) return false;
        const float color[]={0.25f,0.5f,0.75f,1}; context->ClearRenderTargetView(target.Get(),color); return true;
    }
    bool interpolate(ID3D11Texture2D* from,int64_t,int64_t,ID3D11Texture2D* to,bool& repeated) override {
        if(GetEnvironmentVariableW(L"ELGA_TEST_FAIL_FRUC",nullptr,0)) return false;
        repeated=GetEnvironmentVariableW(L"ELGA_TEST_REPEAT",nullptr,0)!=0;
        context->CopyResource(to,from); return true;
    }
    void resetFruc() override {}
};
std::unique_ptr<Provider> makeProvider(ID3D11Device* d,ID3D11DeviceContext* c) {return std::make_unique<TestProvider>(d,c);}
