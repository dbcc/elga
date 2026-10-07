#define NOMINMAX
#include "provider.h"
#include "timing.h"
#include <d3dcompiler.h>
#include <array>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <new>

int64_t videoNow() {
    LARGE_INTEGER q{}, f{}; QueryPerformanceCounter(&q); QueryPerformanceFrequency(&f);
    return q.QuadPart / f.QuadPart * elga::second + q.QuadPart % f.QuadPart * elga::second / f.QuadPart;
}
namespace {
constexpr size_t inputs = 3, outputs = 8;
struct Shared {
    ComPtr<ID3D11Texture2D> ui, gpu;
    ComPtr<IDXGIKeyedMutex> uiMutex, gpuMutex;
    bool create(ID3D11Device* a, ID3D11Device* b, UINT w, UINT h, DXGI_FORMAT format) {
        D3D11_TEXTURE2D_DESC d{};
        d.Width=w; d.Height=h; d.MipLevels=1; d.ArraySize=1; d.Format=format;
        d.SampleDesc.Count=1; d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
        if(format==DXGI_FORMAT_R8G8B8A8_UNORM) d.BindFlags|=D3D11_BIND_UNORDERED_ACCESS;
        d.MiscFlags=D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX|D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
        ComPtr<IDXGIResource1> resource; ComPtr<ID3D11Device1> device;
        HANDLE handle{};
        if (FAILED(a->CreateTexture2D(&d,nullptr,&ui)) || FAILED(ui.As(&resource)) ||
            FAILED(ui.As(&uiMutex)) || FAILED(b->QueryInterface(IID_PPV_ARGS(&device))) ||
            FAILED(resource->CreateSharedHandle(nullptr,DXGI_SHARED_RESOURCE_READ|DXGI_SHARED_RESOURCE_WRITE,nullptr,&handle))) return false;
        HRESULT hr=device->OpenSharedResource1(handle,IID_PPV_ARGS(&gpu)); CloseHandle(handle);
        return SUCCEEDED(hr) && SUCCEEDED(gpu.As(&gpuMutex));
    }
};
struct Input { Shared texture; uint32_t state=0; VideoFrame frame{}; };
struct Output { Shared texture; uint32_t state=5; VideoOutput frame{}; }; // 5 = unused pool entry
struct Work {
    VideoConfig config{};
    VideoStatus status{}; // Protected by Session::mutex; belongs to this generation.
    int64_t presentedDeadline=INT64_MIN;
    std::array<Input,inputs> in;
    std::array<Output,outputs> out;
};
struct Graphics {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> ps, flip;
    ComPtr<ID3D11ComputeShader> compare;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11Buffer> difference, readback;
    ComPtr<ID3D11UnorderedAccessView> differenceView;
    ComPtr<ID3D11Texture2D> current, previous, generated;
    static bool compile(const char* code,const char* entry,const char* profile,ComPtr<ID3DBlob>& blob) {
        return SUCCEEDED(D3DCompile(code,strlen(code),nullptr,nullptr,nullptr,entry,profile,D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&blob,nullptr));
    }
    bool texture(UINT w,UINT h,ComPtr<ID3D11Texture2D>& out) {
        D3D11_TEXTURE2D_DESC d{}; d.Width=w; d.Height=h; d.MipLevels=1; d.ArraySize=1;
        d.Format=DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count=1;
        d.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET|D3D11_BIND_UNORDERED_ACCESS;
        return SUCCEEDED(device->CreateTexture2D(&d,nullptr,&out));
    }
    bool init(ID3D11Device* ui,UINT w,UINT h,bool fruc,bool detectRepeats) {
        ComPtr<IDXGIDevice> dx; ComPtr<IDXGIAdapter> adapter;
        if (FAILED(ui->QueryInterface(IID_PPV_ARGS(&dx))) || FAILED(dx->GetAdapter(&adapter))) return false;
        D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
        if (FAILED(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    &level,1,D3D11_SDK_VERSION,&device,nullptr,&context))) return false;
        const char* shader=R"(
            struct V { float4 p:SV_Position; float2 uv:TEXCOORD0; };
            V VS(uint id:SV_VertexID) { V v; v.uv=float2((id<<1)&2,id&2); v.p=float4(v.uv*float2(2,-2)+float2(-1,1),0,1); return v; }
            Texture2D<float4> src:register(t0); SamplerState samp:register(s0);
            float4 PS(V v):SV_Target { return float4(src.Sample(samp,v.uv).rgb,1); }
            float4 Flip(V v):SV_Target { return float4(src.Sample(samp,float2(v.uv.x,1-v.uv.y)).rgb,1); }
        )";
        const char* cs=R"(
            Texture2D<float4> a:register(t0); Texture2D<float4> b:register(t1);
            RWByteAddressBuffer different:register(u0);
            groupshared uint changed;
            [numthreads(16,16,1)] void CS(uint3 p:SV_DispatchThreadID,uint lane:SV_GroupIndex) {
                if(lane==0) changed=0;
                GroupMemoryBarrierWithGroupSync();
                uint w,h; a.GetDimensions(w,h);
                if(p.x<w && p.y<h && any(a.Load(int3(p.xy,0)).rgb!=b.Load(int3(p.xy,0)).rgb)) {
                    InterlockedOr(changed,1);
                }
                GroupMemoryBarrierWithGroupSync();
                if(lane==0 && changed!=0) { uint old; different.InterlockedOr(0,1,old); }
            }
        )";
        ComPtr<ID3DBlob> blob;
        if (!compile(shader,"VS","vs_5_0",blob) || FAILED(device->CreateVertexShader(blob->GetBufferPointer(),blob->GetBufferSize(),nullptr,&vs))) return false;
        blob.Reset();
        if (!compile(shader,"PS","ps_5_0",blob) || FAILED(device->CreatePixelShader(blob->GetBufferPointer(),blob->GetBufferSize(),nullptr,&ps))) return false;
        blob.Reset();
        if (!compile(shader,"Flip","ps_5_0",blob) || FAILED(device->CreatePixelShader(blob->GetBufferPointer(),blob->GetBufferSize(),nullptr,&flip))) return false;
        D3D11_SAMPLER_DESC sd{}; sd.Filter=D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP; sd.MaxLOD=D3D11_FLOAT32_MAX;
        if (FAILED(device->CreateSamplerState(&sd,&sampler))) return false;
        if(!texture(w,h,current) || (fruc && !texture(w,h,generated))) return false;
        if(!detectRepeats) return true;
        blob.Reset();
        if (!compile(cs,"CS","cs_5_0",blob) || FAILED(device->CreateComputeShader(blob->GetBufferPointer(),blob->GetBufferSize(),nullptr,&compare))) return false;
        D3D11_BUFFER_DESC bd{}; bd.ByteWidth=4; bd.BindFlags=D3D11_BIND_UNORDERED_ACCESS;
        bd.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
        if (FAILED(device->CreateBuffer(&bd,nullptr,&difference))) return false;
        D3D11_UNORDERED_ACCESS_VIEW_DESC ud{}; ud.Format=DXGI_FORMAT_R32_TYPELESS;
        ud.ViewDimension=D3D11_UAV_DIMENSION_BUFFER; ud.Buffer.NumElements=1; ud.Buffer.Flags=D3D11_BUFFER_UAV_FLAG_RAW;
        if (FAILED(device->CreateUnorderedAccessView(difference.Get(),&ud,&differenceView))) return false;
        bd.BindFlags=0; bd.MiscFlags=0; bd.Usage=D3D11_USAGE_STAGING; bd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        return SUCCEEDED(device->CreateBuffer(&bd,nullptr,&readback)) && texture(w,h,previous);
    }
    bool blit(ID3D11Texture2D* from,ID3D11Texture2D* to,bool flipped=false) {
        // Views are preallocated in the session table during setup.
        auto* srv=view(from); auto* rtv=target(to); if(!srv || !rtv) return false;
        D3D11_TEXTURE2D_DESC d{}; to->GetDesc(&d);
        D3D11_VIEWPORT vp{0,0,float(d.Width),float(d.Height),0,1};
        context->ClearState(); context->RSSetViewports(1,&vp);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vs.Get(),nullptr,0); context->PSSetShader(flipped?flip.Get():ps.Get(),nullptr,0);
        context->PSSetSamplers(0,1,sampler.GetAddressOf()); context->PSSetShaderResources(0,1,&srv);
        context->OMSetRenderTargets(1,&rtv,nullptr); context->Draw(3,0); context->ClearState(); return true;
    }
    struct Views { ID3D11Texture2D* texture=nullptr; ComPtr<ID3D11ShaderResourceView> srv; ComPtr<ID3D11RenderTargetView> rtv; };
    std::array<Views,32> views{};
    Views* get(ID3D11Texture2D* t) { for(auto& v:views) if(v.texture==t) return &v; for(auto& v:views) if(!v.texture) {v.texture=t; return &v;} return nullptr; }
    ID3D11ShaderResourceView* view(ID3D11Texture2D* t) { auto* v=get(t); if(!v) return nullptr; if(!v->srv) device->CreateShaderResourceView(t,nullptr,&v->srv); return v->srv.Get(); }
    ID3D11RenderTargetView* target(ID3D11Texture2D* t) { auto* v=get(t); if(!v) return nullptr; if(!v->rtv) device->CreateRenderTargetView(t,nullptr,&v->rtv); return v->rtv.Get(); }
    bool same(bool& result) {
        UINT zero[4]{}; context->ClearUnorderedAccessViewUint(differenceView.Get(),zero);
        ID3D11ShaderResourceView* resources[]={view(current.Get()),view(previous.Get())};
        if(!resources[0] || !resources[1]) return false;
        context->CSSetShader(compare.Get(),nullptr,0); context->CSSetShaderResources(0,2,resources);
        context->CSSetUnorderedAccessViews(0,1,differenceView.GetAddressOf(),nullptr);
        D3D11_TEXTURE2D_DESC d{}; current->GetDesc(&d); context->Dispatch((d.Width+15)/16,(d.Height+15)/16,1);
        context->ClearState(); context->CopyResource(readback.Get(),difference.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if(FAILED(context->Map(readback.Get(),0,D3D11_MAP_READ,0,&mapped))) return false;
        result=*static_cast<const UINT*>(mapped.pData)==0; context->Unmap(readback.Get(),0); return true;
    }
};
struct Session {
    ComPtr<ID3D11Device> ui;
    HWND window{}; UINT message{};
    std::mutex mutex;
    std::condition_variable wake;
    bool stop=false, changed=false;
    VideoConfig desired{};
    VideoStatus idleStatus{};
    uint32_t paused=0, vsrPauseReason=ReasonNone, frucPauseReason=ReasonNone;
    std::shared_ptr<Work> work;
    // Leased outputs survive configure until the UI explicitly releases them.
    std::shared_ptr<Work> leaseWork;
    uint64_t leaseToken=0, nextToken=1;
    std::thread thread;
    void notify() { if(window) PostMessageW(window,message,0,0); }
    void run();
    // Caller holds mutex. Failures persist through resize/reconfigure until an
    // explicit settings retry, independently for each feature.
    void pause(const std::shared_ptr<Work>& w,uint32_t feature,uint32_t reason) {
        if(feature==ELGA_VSR) { w->status.vsrState=VideoPaused; w->status.vsrReason=reason; }
        else { w->status.frucState=VideoPaused; w->status.frucReason=reason; }
        if(desired.retry==w->config.retry && (desired.requested&feature)) {
            paused|=feature;
            if(feature==ELGA_VSR) vsrPauseReason=reason; else frucPauseReason=reason;
        }
    }
    // Mark stale outputs immediately, including textures still in GPU flight.
    // Reclaim their keyed mutexes later without blocking either thread.
    void discardQueued(const std::shared_ptr<Work>& w) {
        std::lock_guard<std::mutex> lock(mutex);
        ++w->status.history;
        w->presentedDeadline=INT64_MIN;
        for(auto& o:w->out) if(o.state==1) o.state=4;
    }
    void publish(const std::shared_ptr<Work>& w,Graphics& g,Provider& p,ID3D11Texture2D* source,
                 const VideoFrame& frame,int64_t deadline,bool generated,bool vsr);
};
void Session::publish(const std::shared_ptr<Work>& w,Graphics& g,Provider& p,ID3D11Texture2D* source,
                      const VideoFrame& frame,int64_t deadline,bool generated,bool vsr) {
    Output* out=nullptr;
    { std::lock_guard<std::mutex> lock(mutex);
      if(changed || stop || work!=w) return;
      auto& status=w->status;
      for(auto& o:w->out) if(o.state==4 && o.texture.gpuMutex->AcquireSync(1,0)==S_OK) {
          o.texture.gpuMutex->ReleaseSync(0); o.state=0;
      }
      for(auto& o:w->out) if(o.state==0) { o.state=3; out=&o; break; }
      if(!out) { ++status.missed; return; } }
    bool owned=out->texture.gpuMutex->AcquireSync(0,100)==S_OK;
    bool ok=false;
    if(owned) {
        if(vsr) ok=p.upscale(source,out->texture.gpu.Get());
        else {
            D3D11_TEXTURE2D_DESC a{},b{}; source->GetDesc(&a); out->texture.gpu->GetDesc(&b);
            if(a.Width==b.Width && a.Height==b.Height) { g.context->CopyResource(out->texture.gpu.Get(),source); ok=true; }
            else ok=g.blit(source,out->texture.gpu.Get());
        }
    }
    if(owned) { g.context->Flush(); out->texture.gpuMutex->ReleaseSync(ok?1:0); }
    { std::lock_guard<std::mutex> lock(mutex);
      auto& status=w->status;
      if(!ok) {
          out->state=0;
          if(vsr) pause(w,ELGA_VSR,ReasonSDK);
          else pause(w,ELGA_FRUC,ReasonDevice);
          if(status.frucState!=VideoActive) status.delay=0;
          ++status.missed;
      } else {
          out->frame={out->texture.ui.Get(),nextToken++,frame.sequence,deadline,frame.generation,uint32_t(generated),0,0};
          out->state=1; ++status.produced;
      } }
    notify();
}
void Session::run() {
    CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    std::shared_ptr<Work> w;
    std::unique_ptr<Graphics> g;
    std::unique_ptr<Provider> p;
    elga::Cadence cadence; elga::FixedCadence fixedCadence; elga::Timeline timeline;
    bool havePrevious=false, frucSeeded=false;
    int64_t previousTime=0; unsigned late=0;
    for(;;) {
        VideoConfig config{}; bool reconfigure=false; Input* in=nullptr;
        { std::unique_lock<std::mutex> lock(mutex);
          wake.wait(lock,[&] { if(stop||changed) return true; if(work) for(auto& i:work->in) if(i.state==1) return true; return false; });
          if(stop) break;
          if(changed) { config=desired; changed=false; reconfigure=true; work.reset(); }
          else if(w) { for(auto& i:w->in) if(i.state==1 && (!in || i.frame.sequence<in->frame.sequence)) in=&i; if(in) in->state=2; }
        }
        if(reconfigure) {
            p.reset(); g.reset(); w.reset(); havePrevious=frucSeeded=false; late=0; timeline.reset();
            VideoConfig activeConfig=config;
            bool upscaleNeeded=config.outputWidth>config.width && config.outputHeight>config.height;
            { std::lock_guard<std::mutex> lock(mutex);
              if(changed || desired.generation!=config.generation) continue;
              activeConfig.requested&=~paused;
            }
            if(!upscaleNeeded) activeConfig.requested&=~ELGA_VSR;
            if(!config.requested || !config.width || !config.height) { notify(); continue; }
            auto next=std::make_shared<Work>(); next->config=config;
            g=std::make_unique<Graphics>();
            bool ok=activeConfig.requested && g->init(ui.Get(),config.width,config.height,(activeConfig.requested&ELGA_FRUC)!=0,(activeConfig.requested&ELGA_FRUC)!=0 && config.gameFps!=30);
            VideoCaps caps{};
            if(ok) { p=makeProvider(g->device.Get(),g->context.Get()); ok=p->start(activeConfig); caps=p->caps(); }
            bool sr=ok && (activeConfig.requested&caps.supported&ELGA_VSR) && config.outputWidth>config.width && config.outputHeight>config.height;
            UINT ow=sr?config.outputWidth:config.width, oh=sr?config.outputHeight:config.height;
            bool any=ok && (activeConfig.requested&caps.supported) && (sr || (activeConfig.requested&caps.supported&ELGA_FRUC));
            if(any) {
                for(auto& i:next->in) ok=ok && i.texture.create(ui.Get(),g->device.Get(),config.width,config.height,DXGI_FORMAT_B8G8R8A8_UNORM);
                size_t count=(activeConfig.requested&ELGA_FRUC)?outputs:inputs;
                for(size_t index=0;index<count;++index) {
                    auto& o=next->out[index];
                    ok=ok && o.texture.create(ui.Get(),g->device.Get(),ow,oh,DXGI_FORMAT_R8G8B8A8_UNORM);
                    o.state=0;
                }
                // Allocate views during setup, never in the frame-processing loop.
                for(auto& i:next->in) ok=ok && g->view(i.texture.gpu.Get());
                for(auto& o:next->out) if(o.texture.gpu) ok=ok && g->target(o.texture.gpu.Get());
                for(auto* t:{g->current.Get(),g->previous.Get(),g->generated.Get()}) if(t) ok=ok && g->view(t) && g->target(t);
            }
            cadence.reset(config.fpsNum?elga::second*config.fpsDen/config.fpsNum:elga::second/60);
            fixedCadence.reset(cadence.nominal);
            { std::lock_guard<std::mutex> lock(mutex);
              if(changed || desired.generation!=config.generation) continue;
              auto& status=next->status;
              status.history=1;
              auto set=[&](uint32_t bit,uint32_t& state,uint32_t& reason,uint32_t unavailable) {
                  state=!(config.requested&bit)?VideoOff: (paused&bit)?VideoPaused: !(caps.supported&bit)?VideoUnavailable: !ok?VideoPaused:VideoActive;
                  reason=(paused&bit)?(bit==ELGA_VSR?vsrPauseReason:frucPauseReason):state==VideoUnavailable?unavailable:state==VideoPaused?ReasonDevice:ReasonNone;
              };
              set(ELGA_VSR,status.vsrState,status.vsrReason,caps.vsrReason);
              set(ELGA_FRUC,status.frucState,status.frucReason,caps.frucReason);
              if((config.requested&ELGA_VSR) && !(paused&ELGA_VSR) && !upscaleNeeded) {
                  status.vsrState=VideoNotNeeded; status.vsrReason=ReasonSize;
              }
              if(status.frucState==VideoActive) { status.frucState=VideoStarting; status.frucReason=ReasonReset; }
              if(any&&ok) work=w=next;
              idleStatus=status;
            }
            if(!w) { p.reset(); g.reset(); }
            notify(); continue;
        }
        if(!in || !g || !p) continue;
        auto& status=w->status;
        VideoFrame frame=in->frame;
        int64_t started=videoNow();
        bool manualCadence=w->config.gameFps==30;
        bool skipRepeat=false;
        if(manualCadence && !timeline.discontinuity(frame.timestamp,cadence.nominal,fixedCadence.period)) {
            std::lock_guard<std::mutex> lock(mutex);
            if(status.frucState==VideoActive) {
                auto selection=fixedCadence;
                skipRepeat=!selection.accept(frame.timestamp);
            }
        }
        bool owns=in->texture.gpuMutex->AcquireSync(1,100)==S_OK;
        bool copied=owns && (skipRepeat || g->blit(in->texture.gpu.Get(),g->current.Get(),frame.flipped!=0));
        if(owns) { if(!skipRepeat) g->context->Flush(); in->texture.gpuMutex->ReleaseSync(0); }
        { std::lock_guard<std::mutex> lock(mutex); in->state=0; }
        if(!copied) {
            discardQueued(w);
            std::lock_guard<std::mutex> lock(mutex);
            if(w->config.requested&ELGA_VSR) pause(w,ELGA_VSR,ReasonDevice);
            if(w->config.requested&ELGA_FRUC) pause(w,ELGA_FRUC,ReasonDevice);
            status.delay=0; notify(); continue;
        }
        // The explicit 30 FPS override does not need to convert the second HDMI
        // repeat to RGBA. Return its slot without issuing another full-frame pass.
        if(skipRepeat) { timeline.observe(frame.timestamp,frame.arrival); continue; }
        bool equal=false;
        bool inspectCadence=false;
        { std::lock_guard<std::mutex> lock(mutex);
          inspectCadence=!manualCadence && (w->config.requested&p->caps().supported&ELGA_FRUC)!=0 && status.frucState!=VideoPaused;
        }
        if(inspectCadence && havePrevious && !g->same(equal)) equal=false;
        bool discontinuity=timeline.discontinuity(frame.timestamp,cadence.nominal,manualCadence?fixedCadence.period:0);
        bool cadenceChanged=inspectCadence && cadence.observe(frame.timestamp,havePrevious&&equal);
        if(discontinuity || cadenceChanged) {
            timeline.reset(); p->resetFruc(); frucSeeded=false; havePrevious=false;
            fixedCadence.reset(cadence.nominal);
            // Pending frames have the old temporal spacing. Return their shared
            // textures before resetting the clock; leased frames remain valid.
            discardQueued(w);
        }
        int64_t sourcePeriod=manualCadence?fixedCadence.period:cadence.period();
        timeline.observe(frame.timestamp,frame.arrival);
        bool sr=false,fg=false;
        { std::lock_guard<std::mutex> lock(mutex);
          sr=status.vsrState==VideoActive;
          if((w->config.requested&ELGA_FRUC) && status.frucState!=VideoUnavailable && status.frucState!=VideoPaused) {
              fg=elga::displayCanDouble(w->config.refreshHz,sourcePeriod) && sourcePeriod*2<=2500000;
              status.frucState=fg?VideoActive:VideoNotNeeded; status.frucReason=fg?ReasonNone:ReasonDisplay;
          }
          status.sourceHz=double(elga::second)/sourcePeriod; status.delay=fg?sourcePeriod*2:0;
        }
        // Once a repeat pattern is locked, consume duplicates without advancing
        // FRUC. Static scenes hold the last output and do not invent motion.
        if(fg && havePrevious && equal) continue;
        if(fg && manualCadence) {
            if(!fixedCadence.accept(frame.timestamp)) continue;
            frame.timestamp=fixedCadence.timestamp();
        }
        if(havePrevious && !equal && frame.timestamp-previousTime>sourcePeriod*3/2) {
            // A whole game frame was lost. Prime interpolation again without
            // flushing valid scheduled output or changing the audio delay.
            p->resetFruc(); frucSeeded=false;
        }
        int64_t delay=fg?sourcePeriod*2:0;
        if(fg) {
            bool repeated=false;
            int64_t middle=frucSeeded?(previousTime+frame.timestamp)/2:frame.timestamp;
            bool success=p->interpolate(g->current.Get(),frame.timestamp,middle,g->generated.Get(),repeated);
            if(success && frucSeeded && !repeated)
                publish(w,*g,*p,g->generated.Get(),frame,timeline.due(middle,delay),true,sr);
            if(!success) {
                discardQueued(w);
                std::lock_guard<std::mutex> lock(mutex);
                pause(w,ELGA_FRUC,ReasonSDK); status.delay=0; fg=false; delay=0;
            }
            frucSeeded=success;
        }
        // Generated-frame upscaling may have just failed; immediately retain
        // the original through the independent interpolation/fallback path.
        { std::lock_guard<std::mutex> lock(mutex); sr=status.vsrState==VideoActive; }
        publish(w,*g,*p,g->current.Get(),frame,fg?timeline.due(frame.timestamp,delay):videoNow(),false,sr);
        if(inspectCadence) g->context->CopyResource(g->previous.Get(),g->current.Get());
        havePrevious=true; previousTime=frame.timestamp;
        int64_t elapsed=videoNow()-started;
        { std::lock_guard<std::mutex> lock(mutex);
          status.processingMs=double(elapsed)/10000;
          if(elapsed>sourcePeriod) { ++late; ++status.missed; } else late=0;
          if(late>=30) {
              if(sr) pause(w,ELGA_VSR,ReasonLate);
              else if(fg) pause(w,ELGA_FRUC,ReasonLate);
              if(status.frucState!=VideoActive) {
                  status.delay=0;
                  ++status.history;
                  for(auto& o:w->out) if(o.state==1) o.state=4;
              }
              late=0;
          }
        }
    }
    p.reset(); g.reset(); w.reset();
    CoUninitialize();
}
    void __cdecl query(ID3D11Device* device,VideoCaps* caps) {
    if(!caps) return; *caps={0,ReasonRuntime,ReasonRuntime,0};
    ComPtr<IDXGIDevice> dx; ComPtr<IDXGIAdapter> adapter; DXGI_ADAPTER_DESC desc{};
    if(!device || FAILED(device->QueryInterface(IID_PPV_ARGS(&dx))) || FAILED(dx->GetAdapter(&adapter)) || FAILED(adapter->GetDesc(&desc))) return;
    if(desc.VendorId!=0x10de) { caps->vsrReason=caps->frucReason=ReasonAdapter; return; }
    // Actual feature creation/capability probing runs on the worker. Do not
    // initialize SDKs or block the UI just to open the Settings menu.
    *caps={ELGA_VSR|ELGA_FRUC,ReasonNone,ReasonNone,0};
}
void* __cdecl create(ID3D11Device* device,void* window,uint32_t message) {
    if(!device) return nullptr;
    try { auto s=std::make_unique<Session>(); s->ui=device; s->window=static_cast<HWND>(window); s->message=message;
          s->thread=std::thread([p=s.get()] { try {p->run();} catch(...) { std::lock_guard<std::mutex> lock(p->mutex); p->work.reset(); p->idleStatus.vsrState=p->idleStatus.frucState=VideoPaused; p->idleStatus.vsrReason=p->idleStatus.frucReason=ReasonDevice; p->idleStatus.delay=0; p->notify(); } }); return s.release(); }
    catch(...) { return nullptr; }
}
void __cdecl configure(void* ptr,const VideoConfig* config) {
    if(!ptr||!config) return; auto& s=*static_cast<Session*>(ptr);
    { std::lock_guard<std::mutex> lock(s.mutex);
      if(config->retry!=s.desired.retry) s.paused=0;
      s.desired=*config; s.changed=true; s.work.reset(); s.idleStatus={};
      s.idleStatus.vsrState=(config->requested&ELGA_VSR)?VideoStarting:VideoOff;
      s.idleStatus.frucState=(config->requested&ELGA_FRUC)?VideoStarting:VideoOff; }
    s.wake.notify_one();
}
uint32_t __cdecl submit(void* ptr,ID3D11DeviceContext* ctx,ID3D11Texture2D* texture,const VideoFrame* frame) {
    if(!ptr||!ctx||!texture||!frame) return 0; auto& s=*static_cast<Session*>(ptr);
    std::unique_lock<std::mutex> lock(s.mutex,std::try_to_lock);
    if(!lock || s.changed || !s.work || frame->generation!=s.work->config.generation) return 0;
    D3D11_TEXTURE2D_DESC d{}; texture->GetDesc(&d);
    if(d.Width!=s.work->config.width||d.Height!=s.work->config.height||d.Format!=DXGI_FORMAT_B8G8R8A8_UNORM) return 0;
    for(auto& i:s.work->in) if(i.state==0 && i.texture.uiMutex->AcquireSync(0,0)==S_OK) {
        ctx->CopyResource(i.texture.ui.Get(),texture); ctx->Flush(); i.texture.uiMutex->ReleaseSync(1);
        i.frame=*frame; i.state=1; ++s.work->status.submitted; s.wake.notify_one(); return 1;
    }
    ++s.work->status.missed; return 0;
}
uint32_t __cdecl poll(void* ptr,int64_t now,VideoOutput* output,VideoStatus* status) {
    if(!ptr||!output||!status) return 0; auto& s=*static_cast<Session*>(ptr);
    std::unique_lock<std::mutex> lock(s.mutex,std::try_to_lock); if(!lock) return 0;
    *status=s.work?s.work->status:s.idleStatus; status->nextDeadline=0;
    if(s.changed || !s.work || s.leaseToken) return 0;
    Output* chosen=nullptr;
    for(auto& o:s.work->out) if(o.state==1 && o.frame.deadline<=s.work->presentedDeadline) o.state=4;
    for(auto& o:s.work->out) if(o.state==4 && o.texture.uiMutex->AcquireSync(1,0)==S_OK) {
        o.texture.uiMutex->ReleaseSync(0); o.state=0;
    }
    for(auto& o:s.work->out) if(o.state==1) {
        if(o.frame.deadline<=now) {
            if(chosen && o.frame.deadline<=chosen->frame.deadline) continue;
            if(o.texture.uiMutex->AcquireSync(1,0)!=S_OK) {
                int64_t retry=now+10000;
                if(!status->nextDeadline || retry<status->nextDeadline) status->nextDeadline=retry;
                continue;
            }
            // Keep the most recent completed output. A newer in-flight texture
            // must not starve all older completed frames on a busy GPU.
            if(chosen) chosen->texture.uiMutex->ReleaseSync(1);
            chosen=&o;
        }
        else if(!status->nextDeadline || o.frame.deadline<status->nextDeadline) status->nextDeadline=o.frame.deadline;
    }
    for(auto& o:s.work->out) if(chosen && o.state==1 && &o!=chosen && o.frame.deadline<=chosen->frame.deadline) {
        if(o.texture.uiMutex->AcquireSync(1,0)==S_OK) { o.texture.uiMutex->ReleaseSync(0); o.state=0; ++s.work->status.missed; }
    }
    if(!chosen) return 0;
    s.work->presentedDeadline=chosen->frame.deadline;
    chosen->state=2; *output=chosen->frame; s.leaseWork=s.work; s.leaseToken=output->token; return 1;
}
void __cdecl release(void* ptr,uint64_t token) {
    if(!ptr||!token) return; auto& s=*static_cast<Session*>(ptr);
    std::lock_guard<std::mutex> lock(s.mutex);
    if(token!=s.leaseToken || !s.leaseWork) return;
    for(auto& o:s.leaseWork->out) if(o.frame.token==token && o.state==2) { o.texture.uiMutex->ReleaseSync(0); o.state=0; break; }
    s.leaseToken=0; s.leaseWork.reset();
}
void __cdecl destroy(void* ptr) {
    if(!ptr) return; auto* s=static_cast<Session*>(ptr);
    { std::lock_guard<std::mutex> lock(s->mutex); s->stop=true; }
    s->wake.notify_one(); if(s->thread.joinable()) s->thread.join(); release(s,s->leaseToken); delete s;
}
}
extern "C" __declspec(dllexport) uint32_t __cdecl elga_video_get_api(uint32_t version,uint32_t size,VideoAPI* api) {
    if(version!=ELGA_VIDEO_ABI || size!=sizeof(VideoAPI) || !api) return 0;
    *api={ELGA_VIDEO_ABI,sizeof(VideoAPI),query,create,configure,submit,poll,release,destroy}; return 1;
}
