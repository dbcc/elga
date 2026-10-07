#define NOMINMAX
#include "provider.h"
#include "timing.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#define REQUIRE(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s (error %lu)\n",__LINE__,#x,GetLastError()); std::exit(1); } } while(0)
static int64_t now() { LARGE_INTEGER q{},f{}; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f); return q.QuadPart/f.QuadPart*10000000+q.QuadPart%f.QuadPart*10000000/f.QuadPart; }
static void preciseUntil(int64_t target) {
    static HANDLE timer=CreateWaitableTimerExW(nullptr,nullptr,2,TIMER_ALL_ACCESS);
    REQUIRE(timer); int64_t remaining=target-now(); if(remaining<=0) return;
    LARGE_INTEGER due{}; due.QuadPart=-remaining;
    REQUIRE(SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)); WaitForSingleObject(timer,1000);
}
static void preciseSleep(int ms) { preciseUntil(now()+int64_t(ms)*10000); }
int main(int argc,char** argv) {
    REQUIRE(argc==2);
    HMODULE module=LoadLibraryExA(argv[1],nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32); REQUIRE(module);
    auto get=reinterpret_cast<GetVideoAPI>(GetProcAddress(module,"elga_video_get_api")); REQUIRE(get);
    VideoAPI api{}; REQUIRE(!get(1,sizeof(api),&api)); REQUIRE(!get(ELGA_VIDEO_ABI,sizeof(api)-1,&api)); REQUIRE(get(ELGA_VIDEO_ABI,sizeof(api),&api));
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
    REQUIRE(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context)));
    void* session=api.create(device.Get(),nullptr,0); REQUIRE(session);
    D3D11_TEXTURE2D_DESC desc{}; desc.Width=64; desc.Height=36; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
    ComPtr<ID3D11Texture2D> input; REQUIRE(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&input)));
    std::vector<uint32_t> pixels(64*36,0xff884422);
    uint64_t sequence=1;
    static_assert(sizeof(VideoAPI)==64 && sizeof(VideoConfig)==48 && sizeof(VideoFrame)==32 && sizeof(VideoOutput)==48 && sizeof(VideoStatus)==80,"x64 ABI changed");
    for(uint32_t requested=1;requested<=3;++requested) {
        VideoConfig config{64,36,128,72,requested,requested,60,1,144}; api.configure(session,&config);
        VideoStatus status{}; VideoOutput output{}; int64_t base=now();
        unsigned originals=0,generated=0; bool staleRejected=false, pixelsChecked=false;
        for(int n=0;n<110;++n) {
            pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),64*4,0);
            VideoFrame frame{sequence++,n*166667LL,now(),requested,0};
            VideoFrame stale=frame; stale.generation=999;
            REQUIRE(api.submit(session,context.Get(),input.Get(),&stale)==0); staleRejected=true;
            api.submit(session,context.Get(),input.Get(),&frame);
            for(int k=0;k<4;++k) {
                if(api.poll(session,now(),&output,&status)) {
                    REQUIRE(output.generation==requested); REQUIRE(output.deadline<=now()); REQUIRE(output.texture);
                    D3D11_TEXTURE2D_DESC actual{}; output.texture->GetDesc(&actual);
                    REQUIRE(actual.Width==((requested&ELGA_VSR)?128u:64u));
                    if(!pixelsChecked) {
                        D3D11_TEXTURE2D_DESC rd=actual; rd.Usage=D3D11_USAGE_STAGING;
                        rd.CPUAccessFlags=D3D11_CPU_ACCESS_READ; rd.BindFlags=rd.MiscFlags=0;
                        ComPtr<ID3D11Texture2D> readback; REQUIRE(SUCCEEDED(device->CreateTexture2D(&rd,nullptr,&readback)));
                        context->CopyResource(readback.Get(),output.texture);
                        D3D11_MAPPED_SUBRESOURCE mapped{}; REQUIRE(SUCCEEDED(context->Map(readback.Get(),0,D3D11_MAP_READ,0,&mapped)));
                        auto* pixel=static_cast<const unsigned char*>(mapped.pData)+4; // unchanged second pixel
                        if(requested&ELGA_VSR) { REQUIRE(pixel[0]>=63 && pixel[0]<=64); REQUIRE(pixel[1]>=127 && pixel[1]<=128); REQUIRE(pixel[2]>=191 && pixel[2]<=192); }
                        else { REQUIRE(pixel[0]==0x88 && pixel[1]==0x44 && pixel[2]==0x22); }
                        REQUIRE(pixel[3]==255); context->Unmap(readback.Get(),0); pixelsChecked=true;
                    }
                    if(output.generated) ++generated; else ++originals;
                    // Hold the lease across one reset to verify the old pool's lifetime.
                    if(n==109) api.configure(session,&config);
                    api.release(session,output.token);
                }
                preciseUntil(base+(int64_t(n)*4+k+1)*166667/4);
            }
        }
        std::printf("combination %u: %u original, %u generated, %.2f ms processing\n",requested,originals,generated,status.processingMs);
        REQUIRE(staleRejected && pixelsChecked); REQUIRE(originals>80); REQUIRE(!(requested&ELGA_FRUC)||generated>80);
        (void)base;
    }
    // Failure of VSR must not disable an independently enabled FRUC session.
    SetEnvironmentVariableW(L"ELGA_TEST_FAIL_VSR",L"1");
    VideoConfig config{64,36,128,72,3,9,60,1,144}; api.configure(session,&config);
    VideoStatus status{}; VideoOutput output{};
    for(int n=0;n<90;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),9,0}; api.submit(session,context.Get(),input.Get(),&frame);
        if(api.poll(session,now(),&output,&status)) api.release(session,output.token);
        preciseSleep(17);
    }
    REQUIRE(status.vsrState==VideoPaused); REQUIRE(status.frucState==VideoActive);
    SetEnvironmentVariableW(L"ELGA_TEST_FAIL_VSR",nullptr);
    SetEnvironmentVariableW(L"ELGA_TEST_FAIL_FRUC",L"1");
    config.generation=10; ++config.retry; api.configure(session,&config);
    for(int n=0;n<30;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),10,0}; api.submit(session,context.Get(),input.Get(),&frame);
        if(api.poll(session,now(),&output,&status)) api.release(session,output.token);
        preciseSleep(17);
    }
    REQUIRE(status.frucState==VideoPaused && status.vsrState==VideoActive && status.delay==0);
    SetEnvironmentVariableW(L"ELGA_TEST_FAIL_FRUC",nullptr);
    // End-to-end GPU comparison: a 30 FPS source carried by 60 Hz HDMI can
    // interpolate on a 60 Hz display after acquiring the repeating cadence.
    config={64,36,64,36,2,11,60,1,60}; api.configure(session,&config);
    unsigned interpolated=0; int64_t duplicateBase=now();
    for(int n=0;n<160;++n) {
        // Last pixel also exercises the partial compute-shader group at an edge.
        pixels.back()=0xff000000|unsigned(n/2); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),11,0}; api.submit(session,context.Get(),input.Get(),&frame);
        for(int k=0;k<4;++k) {
            if(api.poll(session,now(),&output,&status)) { interpolated+=output.generated; api.release(session,output.token); }
            preciseUntil(duplicateBase+(int64_t(n)*4+k+1)*166667/4);
        }
    }
    REQUIRE(status.sourceHz>29 && status.sourceHz<31 && status.frucState==VideoActive);
    REQUIRE(status.delay>660000 && status.delay<670000); REQUIRE(interpolated>10);
    // Force 30 FPS even when every captured frame differs (capture noise/HUD).
    // This must start immediately on a 60 Hz display, without cadence acquisition.
    config={64,36,64,36,2,13,60,1,60,30,0}; api.configure(session,&config);
    unsigned forcedOriginals=0, forcedGenerated=0; int64_t forcedBase=now();
    for(int n=0;n<90;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),13,0}; api.submit(session,context.Get(),input.Get(),&frame);
        for(int k=0;k<4;++k) {
            if(api.poll(session,now(),&output,&status)) {
                REQUIRE(output.generation==13);
                if(output.generated) ++forcedGenerated; else ++forcedOriginals;
                api.release(session,output.token);
            }
            preciseUntil(forcedBase+(int64_t(n)*4+k+1)*166667/4);
        }
    }
    REQUIRE(status.sourceHz>29 && status.sourceHz<31 && status.frucState==VideoActive);
    REQUIRE(status.delay>660000 && status.delay<670000);
    REQUIRE(forcedOriginals>30 && forcedOriginals<=45 && forcedGenerated>30 && forcedGenerated<=44);
    // Lost HDMI callbacks must preserve manual sampling phase, output spacing,
    // and audio history. Frame 3 replaces missing frame 2; a whole game-frame
    // gap before frame 8 primes FRUC but keeps the existing playback clock.
    config={64,36,64,36,2,14,60,1,60,30,0}; api.configure(session,&config);
    int64_t gapBase=now()+elga::second;
    const int64_t tick=elga::second/60;
    uint64_t produced=0;
    for(int n : {0,1,3,4,5,8}) {
        VideoFrame frame{sequence++,n*tick,gapBase+n*tick,14,0};
        int64_t deadline=now()+2*elga::second;
        while(!api.submit(session,context.Get(),input.Get(),&frame)) { REQUIRE(now()<deadline); Sleep(1); }
        if(n==1 || n==5) { Sleep(5); continue; }
        produced += (n==0 || n==8)?1:2;
        do { REQUIRE(!api.poll(session,1,&output,&status)); REQUIRE(now()<deadline); Sleep(1); } while(status.produced<produced);
        REQUIRE(status.history==1 && status.delay==4*tick);
    }
    for(int slot : {0,1,2,3,4,8}) {
        REQUIRE(api.poll(session,gapBase+(slot+4)*tick,&output,&status));
        REQUIRE(output.deadline==gapBase+(slot+4)*tick);
        REQUIRE(output.generated==uint32_t(slot==1 || slot==3));
        api.release(session,output.token);
    }
    SetEnvironmentVariableW(L"ELGA_TEST_REPEAT",L"1");
    config={64,36,64,36,2,12,60,1,144}; api.configure(session,&config);
    for(int n=0;n<30;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),12,0}; api.submit(session,context.Get(),input.Get(),&frame);
        if(api.poll(session,now(),&output,&status)) { REQUIRE(!output.generated); api.release(session,output.token); }
        preciseSleep(17);
    }
    SetEnvironmentVariableW(L"ELGA_TEST_REPEAT",nullptr);
    // Pausing only VSR for sustained misses must retain FRUC's audio delay.
    SetEnvironmentVariableW(L"ELGA_TEST_SLOW_VSR",L"1");
    config={64,36,128,72,3,20,60,1,144}; api.configure(session,&config);
    bool observedPause=false;
    for(int n=0;n<100 && !observedPause;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),20,0}; api.submit(session,context.Get(),input.Get(),&frame);
        for(int k=0;k<5;++k) {
            if(api.poll(session,now(),&output,&status)) api.release(session,output.token);
            if(status.vsrState==VideoPaused) {
                REQUIRE(status.vsrReason==ReasonLate && status.frucState==VideoActive && status.delay>330000);
                observedPause=true; break;
            }
            preciseSleep(10);
        }
    }
    REQUIRE(observedPause); SetEnvironmentVariableW(L"ELGA_TEST_SLOW_VSR",nullptr);
    // Resizing cannot silently retry a paused effect. The other feature keeps working.
    ++config.generation; config.outputWidth=192; api.configure(session,&config);
    for(int n=0;n<20;++n) {
        pixels[0]=0xff000000|unsigned(n); context->UpdateSubresource(input.Get(),0,nullptr,pixels.data(),256,0);
        VideoFrame frame{sequence++,n*166667LL,now(),config.generation,0}; api.submit(session,context.Get(),input.Get(),&frame);
        if(api.poll(session,now(),&output,&status)) api.release(session,output.token);
        preciseSleep(17);
    }
    REQUIRE(status.vsrState==VideoPaused && status.vsrReason==ReasonLate && status.frucState==VideoActive);

    // Block old setup, disable everything, then complete that old setup. No old
    // state/resources may be published after configure() returns for the reset.
    wchar_t enteredName[128]{}, releaseName[128]{};
    swprintf_s(enteredName,L"Local\\ElgaTestEntered%lu",GetCurrentProcessId());
    swprintf_s(releaseName,L"Local\\ElgaTestRelease%lu",GetCurrentProcessId());
    HANDLE entered=CreateEventW(nullptr,TRUE,FALSE,enteredName), release=CreateEventW(nullptr,TRUE,FALSE,releaseName);
    REQUIRE(entered && release);
    SetEnvironmentVariableW(L"ELGA_TEST_START_ENTERED",enteredName); SetEnvironmentVariableW(L"ELGA_TEST_START_RELEASE",releaseName);
    config={64,36,128,72,1,22,60,1,144,0,1}; api.configure(session,&config);
    REQUIRE(WaitForSingleObject(entered,5000)==WAIT_OBJECT_0);
    config.requested=0; ++config.generation; api.configure(session,&config);
    REQUIRE(SetEvent(release));
    for(int n=0;n<100;++n) {
        REQUIRE(api.poll(session,now(),&output,&status)==0);
        REQUIRE(status.vsrState==VideoOff && status.frucState==VideoOff && status.delay==0);
        Sleep(2);
    }
    CloseHandle(entered); CloseHandle(release);
    SetEnvironmentVariableW(L"ELGA_TEST_START_ENTERED",nullptr); SetEnvironmentVariableW(L"ELGA_TEST_START_RELEASE",nullptr);

    // A timestamp restart invalidates future outputs even before they become due.
    config={64,36,64,36,2,30,60,1,144,30,2}; api.configure(session,&config);
    for(int n=0;n<3;++n) {
        VideoFrame frame{sequence++,n*166667LL,now(),30,0};
        int64_t timeout=now()+2*10000000LL;
        while(!api.submit(session,context.Get(),input.Get(),&frame)) { REQUIRE(now()<timeout); Sleep(1); }
        Sleep(5);
    }
    int64_t timeout=now()+2*10000000LL;
    do { REQUIRE(!api.poll(session,1,&output,&status)); REQUIRE(now()<timeout); Sleep(1); } while(status.produced<3);
    uint64_t previousHistory=status.history;
    VideoFrame restarted{sequence++,0,now(),30,0}; REQUIRE(api.submit(session,context.Get(),input.Get(),&restarted));
    do { REQUIRE(!api.poll(session,1,&output,&status)); REQUIRE(now()<timeout); Sleep(1); } while(status.history==previousHistory || status.produced<4);
    REQUIRE(api.poll(session,now()+10000000,&output,&status));
    REQUIRE(output.sequence==restarted.sequence && !output.generated); api.release(session,output.token);
    config.requested=0; ++config.generation; api.configure(session,&config);
    Sleep(100); REQUIRE(api.poll(session,now(),&output,&status)==0); REQUIRE(status.delay==0);
    api.destroy(session); FreeLibrary(module);
    std::puts("Synthetic D3D11 backend tests passed (no NVIDIA inference tested)");
}
