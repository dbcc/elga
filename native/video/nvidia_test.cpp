#define NOMINMAX
#include "provider.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#define REQUIRE(x) do { if(!(x)) { std::fprintf(stderr,"line %d: %s (error %lu)\n",__LINE__,#x,GetLastError()); std::exit(1); } } while(0)
static int64_t now() { LARGE_INTEGER q{},f{}; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f); return q.QuadPart/f.QuadPart*10000000+q.QuadPart%f.QuadPart*10000000/f.QuadPart; }
static void until(int64_t target) {
    static HANDLE timer=CreateWaitableTimerExW(nullptr,nullptr,2,TIMER_ALL_ACCESS);
    REQUIRE(timer); if(target<=now()) return;
    LARGE_INTEGER due{}; due.QuadPart=now()-target;
    REQUIRE(SetWaitableTimer(timer,&due,0,nullptr,nullptr,FALSE)); REQUIRE(WaitForSingleObject(timer,1000)==WAIT_OBJECT_0);
}
int main(int argc,char** argv) {
    REQUIRE(argc==2 || argc==3);
    HMODULE module=LoadLibraryExA(argv[1],nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32); REQUIRE(module);
    auto get=reinterpret_cast<GetVideoAPI>(GetProcAddress(module,"elga_video_get_api")); REQUIRE(get);
    VideoAPI api{}; REQUIRE(get(ELGA_VIDEO_ABI,sizeof(api),&api));
    ComPtr<IDXGIFactory1> factory; REQUIRE(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
    ComPtr<IDXGIAdapter1> adapter;
    for(UINT i=0;;++i) { REQUIRE(factory->EnumAdapters1(i,&adapter)!=DXGI_ERROR_NOT_FOUND); DXGI_ADAPTER_DESC1 d{}; adapter->GetDesc1(&d); if(d.VendorId==0x10de) { std::printf("GPU: %ls\n",d.Description); break; } adapter.Reset(); }
    ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
    REQUIRE(SUCCEEDED(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,&level,1,D3D11_SDK_VERSION,&device,nullptr,&context)));
    void* session=api.create(device.Get(),nullptr,0); REQUIRE(session);
    struct Case { unsigned w,h,ow,oh,features,fps,manual; const char* name; bool repeats=false, restart=false; };
    const Case cases[]={
        {1280,720,1920,1080,1,60,0,"720p VSR"},
        {1920,1080,3840,2160,1,60,0,"1080p VSR"},
        {1280,720,1280,720,2,30,0,"30 -> 60"},
        {1280,720,1280,720,2,60,0,"60 -> 120"},
        {1280,720,1280,720,2,60,30,"30 in 60 override"},
        {1280,720,1920,1080,3,60,30,"30 in 60 combined"},
        {1920,1080,1920,1080,2,30,0,"1080p 30 -> 60"},
        {1920,1080,1920,1080,2,60,0,"1080p 60 -> 120"},
        {1920,1080,2560,1440,3,60,30,"1080p 30 in 60 combined"},
        {1280,720,1280,720,2,60,0,"30 in 60 automatic",true},
        {1280,720,1280,720,2,60,30,"timestamp restart recovery",false,true},
        {3840,2160,3840,2160,2,60,30,"4K 30 in 60 override"},
    };
    uint64_t sequence=1; uint32_t generation=0; bool all=true;
    for(const auto& test:cases) {
        if(argc==3 && &test-cases!=std::atoi(argv[2])) continue;
        D3D11_TEXTURE2D_DESC desc{}; desc.Width=test.w; desc.Height=test.h; desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
        desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM; desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        ComPtr<ID3D11Texture2D> input; REQUIRE(SUCCEEDED(device->CreateTexture2D(&desc,nullptr,&input)));
        // Preallocate a scrolling texture atlas; CPU image generation during
        // playback would block polling and create artificial presentation misses.
        std::vector<uint32_t> pixels(size_t(test.w)*2*test.h);
        for(unsigned y=0;y<test.h;++y) for(unsigned x=0;x<test.w*2;++x) {
            unsigned hash=((x%test.w)/16)*2654435761u+(y/16)*2246822519u;
            hash^=hash>>13; hash*=1274126177u;
            unsigned shade=32+(hash>>24)*3/4;
            pixels[size_t(y)*test.w*2+x]=0xff000000|shade*0x010101;
        }
        D3D11_TEXTURE2D_DESC atlasDesc=desc; atlasDesc.Width*=2;
        D3D11_SUBRESOURCE_DATA initial{pixels.data(),test.w*8,0};
        ComPtr<ID3D11Texture2D> atlas; REQUIRE(SUCCEEDED(device->CreateTexture2D(&atlasDesc,&initial,&atlas)));
        VideoConfig config{test.w,test.h,test.ow,test.oh,test.features,++generation,test.fps,1,test.repeats?60.:144.,test.manual,0}; api.configure(session,&config);
        VideoStatus status{}; VideoOutput output{};
        int64_t limit=now()+120*10000000LL;
        do { if(api.poll(session,now(),&output,&status)) api.release(session,output.token); Sleep(10); }
        while(now()<limit && ((test.features&1 && status.vsrState==VideoStarting) || (test.features&2 && status.frucState==VideoStarting && status.frucReason!=ReasonReset)));
        std::printf("%s init: SR %u/%u FG %u/%u\n",test.name,status.vsrState,status.vsrReason,status.frucState,status.frucReason); std::fflush(stdout);
        if((test.features&1 && status.vsrState!=VideoActive) || (test.features&2 && (status.frucState!=VideoStarting || status.frucReason!=ReasonReset))) { all=false; break; }
        int64_t base=now(), period=10000000/test.fps;
        unsigned originals=0,generated=0,samples=0; double totalMs=0,maxMs=0;
        bool pixelsRead=false;
        for(unsigned n=0;n<test.fps*3;++n) {
            unsigned motion=(test.manual || test.repeats)?n/2:n;
            unsigned offset=(motion*4)%test.w;
            D3D11_BOX crop{offset,0,0,offset+test.w,test.h,1};
            context->CopySubresourceRegion(input.Get(),0,0,0,0,atlas.Get(),0,&crop);
            VideoFrame frame{sequence++,int64_t(test.restart?n%test.fps:n)*period,now(),generation,0}; api.submit(session,context.Get(),input.Get(),&frame);
            for(int k=0;k<4;++k) {
                if(api.poll(session,now(),&output,&status)) {
                    REQUIRE(output.generation==generation); REQUIRE(output.deadline<=now());
                    if(output.generated) ++generated; else ++originals;
                    if(!pixelsRead && (output.generated || test.features==1)) {
                        D3D11_TEXTURE2D_DESC rd{}; output.texture->GetDesc(&rd);
                        REQUIRE(rd.Width==test.ow && rd.Height==test.oh);
                        rd.Usage=D3D11_USAGE_STAGING; rd.CPUAccessFlags=D3D11_CPU_ACCESS_READ; rd.BindFlags=rd.MiscFlags=0;
                        ComPtr<ID3D11Texture2D> staging; REQUIRE(SUCCEEDED(device->CreateTexture2D(&rd,nullptr,&staging)));
                        context->CopyResource(staging.Get(),output.texture);
                        D3D11_MAPPED_SUBRESOURCE mapped{}; REQUIRE(SUCCEEDED(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)));
                        unsigned low=255,high=0;
                        for(unsigned y=0;y<rd.Height;++y) for(unsigned x=0;x<rd.Width;++x) { unsigned v=static_cast<unsigned char*>(mapped.pData)[size_t(y)*mapped.RowPitch+x*4]; low=std::min(low,v); high=std::max(high,v); }
                        REQUIRE(high>low+30); context->Unmap(staging.Get(),0); pixelsRead=true;
                    }
                    api.release(session,output.token);
                    totalMs+=status.processingMs; maxMs=std::max(maxMs,status.processingMs); ++samples;
                }
                until(base+(int64_t(n)*4+k+1)*period/4);
            }
        }
        double sourceRate=(test.manual || test.repeats)?30:test.fps;
        double minimum=sourceRate*(test.repeats?1.5:2.5);
        bool pass=pixelsRead && originals>minimum && (!(test.features&2) || generated>minimum) && (!(test.features&1) || status.vsrState==VideoActive) && (!(test.features&2) || status.frucState==VideoActive);
        if(test.restart) pass=pass && status.history>=3;
        all &= pass;
        std::printf("%s: %s, %u original / %u generated in 3s, source %.2f, delay %.2f ms, worker mean %.2f / max %.2f ms, misses %llu; SR %u/%u FG %u/%u\n",test.name,pass?"PASS":"FAIL",originals,generated,status.sourceHz,status.delay/10000.,samples?totalMs/samples:0,maxMs,status.missed,status.vsrState,status.vsrReason,status.frucState,status.frucReason); std::fflush(stdout);
    }
    api.destroy(session); FreeLibrary(module); return all?0:1;
}
