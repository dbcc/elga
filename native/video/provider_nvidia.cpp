#define NOMINMAX
#include "provider.h"
#include <wintrust.h>
#include <softpub.h>
#include <string>
#include <vector>
#include <cstdio>
static void diagnostic(const char* text, unsigned code=0) {
    if(GetEnvironmentVariableW(L"ELGA_VIDEO_DIAGNOSTICS",nullptr,0)) { std::fprintf(stderr,"NVIDIA: %s (0x%X)\n",text,code); std::fflush(stderr); }
}
#ifdef ELGA_WITH_VSR
#include <nvsdk_ngx.h>
#include <nvsdk_ngx_defs_vsr.h>
#endif
#ifdef ELGA_WITH_FRUC
#include <NvOFFRUC.h>
#endif

namespace {
std::wstring runtimeDirectory() {
    HMODULE module{};
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&runtimeDirectory),&module)) return {};
    wchar_t path[32768]{}; DWORD n=GetModuleFileNameW(module,path,_countof(path));
    if(!n||n>=_countof(path)) return {};
    std::wstring result(path,n); return result.substr(0,result.find_last_of(L"\\/"));
}
bool signedByNvidia(const std::wstring& path) {
    WINTRUST_FILE_INFO file{sizeof(file)}; file.pcwszFilePath=path.c_str();
    WINTRUST_DATA data{sizeof(data)};
    data.dwUIChoice=WTD_UI_NONE; data.fdwRevocationChecks=WTD_REVOKE_NONE;
    data.dwUnionChoice=WTD_CHOICE_FILE; data.pFile=&file; data.dwStateAction=WTD_STATEACTION_VERIFY;
    data.dwProvFlags=WTD_CACHE_ONLY_URL_RETRIEVAL;
    GUID action=WINTRUST_ACTION_GENERIC_VERIFY_V2;
    bool ok=WinVerifyTrust(nullptr,&action,&data)==ERROR_SUCCESS;
    if(ok) {
        auto* provider=WTHelperProvDataFromStateData(data.hWVTStateData);
        auto* signer=provider?WTHelperGetProvSignerFromChain(provider,0,FALSE,0):nullptr;
        wchar_t name[256]{};
        ok=signer && signer->csCertChain && CertGetNameStringW(signer->pasCertChain[0].pCert,CERT_NAME_SIMPLE_DISPLAY_TYPE,0,nullptr,name,_countof(name))>1
            && std::wstring(name).find(L"NVIDIA")!=std::wstring::npos;
    }
    data.dwStateAction=WTD_STATEACTION_CLOSE; WinVerifyTrust(nullptr,&action,&data); return ok;
}
struct Nvidia final : Provider {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    VideoCaps available{0,ReasonRuntime,ReasonRuntime,0};
    VideoConfig config{};
    std::wstring directory=runtimeDirectory();
    std::vector<HMODULE> modules;
#ifdef ELGA_WITH_VSR
    bool ngx=false;
    NVSDK_NGX_Handle* vsr=nullptr;
    NVSDK_NGX_Parameter* params=nullptr;
#endif
#ifdef ELGA_WITH_FRUC
    NvOFFRUCHandle fruc{};
    PtrToFuncNvOFFRUCCreate createFruc{};
    PtrToFuncNvOFFRUCRegisterResource registerFruc{};
    PtrToFuncNvOFFRUCUnregisterResource unregisterFruc{};
    PtrToFuncNvOFFRUCProcess processFruc{};
    PtrToFuncNvOFFRUCDestroy destroyFruc{};
    ComPtr<ID3D11Texture2D> frucInput[2], frucOutput;
    unsigned frucIndex=0;
    ComPtr<ID3D11DeviceContext4> context4;
    ComPtr<ID3D11Fence> fence;
    HANDLE fenceEvent=nullptr;
    uint64_t fenceValue=0;
    bool registered=false;
    bool frucSeeded=false;
    int64_t frucLastInput=0;
    double frucClock=0;
#endif
    Nvidia(ID3D11Device* d,ID3D11DeviceContext* c):device(d),context(c) {}
    bool load(const wchar_t* filename) {
        auto path=directory+L"\\"+filename;
        if(directory.empty()||!signedByNvidia(path)) return false;
        HMODULE module=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!module) return false; modules.push_back(module); return true;
    }
    VideoCaps caps() const override { return available; }
    bool start(const VideoConfig& cfg) override {
        config=cfg;
        ComPtr<IDXGIDevice> dx; ComPtr<IDXGIAdapter> adapter; DXGI_ADAPTER_DESC desc{};
        if(FAILED(device.As(&dx))||FAILED(dx->GetAdapter(&adapter))||FAILED(adapter->GetDesc(&desc))||desc.VendorId!=0x10de) {
            available={0,ReasonAdapter,ReasonAdapter,0}; return true;
        }
#ifdef ELGA_WITH_VSR
        if((cfg.requested&ELGA_VSR) && load(L"nvngx_vsr.dll")) {
            available.vsrReason=ReasonSDK;
            const wchar_t* search=directory.c_str();
            NVSDK_NGX_FeatureCommonInfo info{}; info.PathListInfo.Path=&search; info.PathListInfo.Length=1;
            // Application ID 0 is NVIDIA's documented development default.
            // Release packaging supplies the application's registered ID.
            diagnostic("NGX initializing");
            auto initResult=NVSDK_NGX_D3D11_Init(ELGA_NGX_APP_ID,directory.c_str(),device.Get(),&info);
            diagnostic("NGX initialized",initResult);
            ngx=NVSDK_NGX_SUCCEED(initResult);
            int supported=0;
            if(ngx && NVSDK_NGX_SUCCEED(NVSDK_NGX_D3D11_GetCapabilityParameters(&params)) &&
               NVSDK_NGX_SUCCEED(params->Get(NVSDK_NGX_Parameter_VSR_Available,&supported)) && supported) {
                if(NVSDK_NGX_SUCCEED(NVSDK_NGX_D3D11_CreateFeature(context.Get(),NVSDK_NGX_Feature_VSR,params,&vsr))) {
                    available.supported|=ELGA_VSR; available.vsrReason=ReasonNone;
                }
            }
        }
#endif
#ifdef ELGA_WITH_FRUC
        if((cfg.requested&ELGA_FRUC) && load(L"cudart64_110.dll") && load(L"NvOFFRUC.dll")) {
            HMODULE module=modules.back();
            createFruc=reinterpret_cast<PtrToFuncNvOFFRUCCreate>(GetProcAddress(module,"NvOFFRUCCreate"));
            registerFruc=reinterpret_cast<PtrToFuncNvOFFRUCRegisterResource>(GetProcAddress(module,"NvOFFRUCRegisterResource"));
            unregisterFruc=reinterpret_cast<PtrToFuncNvOFFRUCUnregisterResource>(GetProcAddress(module,"NvOFFRUCUnregisterResource"));
            processFruc=reinterpret_cast<PtrToFuncNvOFFRUCProcess>(GetProcAddress(module,"NvOFFRUCProcess"));
            destroyFruc=reinterpret_cast<PtrToFuncNvOFFRUCDestroy>(GetProcAddress(module,"NvOFFRUCDestroy"));
            available.frucReason=ReasonSDK;
            if(createFruc&&registerFruc&&unregisterFruc&&processFruc&&destroyFruc&&initFruc()) {
                available.supported|=ELGA_FRUC; available.frucReason=ReasonNone;
            }
        }
#endif
        return true;
    }
    bool upscale(ID3D11Texture2D* input,ID3D11Texture2D* output) override {
#ifdef ELGA_WITH_VSR
        if(!vsr||!params) return false;
        D3D11_TEXTURE2D_DESC a{},b{}; input->GetDesc(&a); output->GetDesc(&b);
        params->Set(NVSDK_NGX_Parameter_Input1,static_cast<ID3D11Resource*>(input));
        params->Set(NVSDK_NGX_Parameter_Output,static_cast<ID3D11Resource*>(output));
        params->Set(NVSDK_NGX_Parameter_Rect_X,0u); params->Set(NVSDK_NGX_Parameter_Rect_Y,0u);
        params->Set(NVSDK_NGX_Parameter_Rect_W,a.Width); params->Set(NVSDK_NGX_Parameter_Rect_H,a.Height);
        params->Set(NVSDK_NGX_Parameter_OutRect_X,0u); params->Set(NVSDK_NGX_Parameter_OutRect_Y,0u);
        params->Set(NVSDK_NGX_Parameter_OutRect_W,b.Width); params->Set(NVSDK_NGX_Parameter_OutRect_H,b.Height);
        params->Set(NVSDK_NGX_Parameter_VSR_QualityLevel,unsigned(NVSDK_NGX_VSR_Quality_Medium));
        return NVSDK_NGX_SUCCEED(NVSDK_NGX_D3D11_EvaluateFeature(context.Get(),vsr,params,nullptr));
#else
        (void)input; (void)output; return false;
#endif
    }
#ifdef ELGA_WITH_FRUC
    bool initFruc() {
        ComPtr<ID3D11Device5> device5;
        if(FAILED(device.As(&device5))||FAILED(context.As(&context4))) return false;
        if(!fence && FAILED(device5->CreateFence(0,D3D11_FENCE_FLAG_SHARED,IID_PPV_ARGS(&fence)))) return false;
        if(!fenceEvent) fenceEvent=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        if(!fenceEvent) return false;
        if(!frucInput[0]) {
            D3D11_TEXTURE2D_DESC d{}; d.Width=config.width; d.Height=config.height;
            d.MipLevels=d.ArraySize=d.SampleDesc.Count=1; d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
            d.MiscFlags=D3D11_RESOURCE_MISC_SHARED|D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
            if(FAILED(device->CreateTexture2D(&d,nullptr,&frucInput[0]))||FAILED(device->CreateTexture2D(&d,nullptr,&frucInput[1]))||FAILED(device->CreateTexture2D(&d,nullptr,&frucOutput))) return false;
        }
        NvOFFRUC_CREATE_PARAM create{}; create.pDevice=device.Get(); create.uiWidth=config.width; create.uiHeight=config.height;
        create.eResourceType=DirectX11Resource;
        create.eSurfaceFormat=ARGBSurface;
        diagnostic("FRUC creating");
        auto created=createFruc(&create,&fruc); diagnostic("FRUC created",created);
        if(created!=NvOFFRUC_SUCCESS) return false;
        NvOFFRUC_REGISTER_RESOURCE_PARAM resources{};
        resources.pArrResource[0]=frucInput[0].Get(); resources.pArrResource[1]=frucInput[1].Get(); resources.pArrResource[2]=frucOutput.Get(); resources.uiCount=3;
        resources.pD3D11FenceObj=fence.Get();
        auto registration=registerFruc(fruc,&resources); diagnostic("FRUC registered",registration);
        registered=registration==NvOFFRUC_SUCCESS; return registered;
    }
    void closeFruc() {
        if(fruc && registered) {
            NvOFFRUC_UNREGISTER_RESOURCE_PARAM resources{};
            resources.pArrResource[0]=frucInput[0].Get(); resources.pArrResource[1]=frucInput[1].Get(); resources.pArrResource[2]=frucOutput.Get(); resources.uiCount=3;
            unregisterFruc(fruc,&resources); registered=false;
        }
        if(fruc) { destroyFruc(fruc); fruc={}; }
        frucInput[0].Reset(); frucInput[1].Reset(); frucOutput.Reset();
        fence.Reset(); fenceValue=0; frucIndex=0;
    }
#endif
    void resetFruc() override {
#ifdef ELGA_WITH_FRUC
        // Prime the next input with the SDK's state-only operation. Destroying
        // and re-registering the same D3D device fails in NvOFFRUC 5.0.7.
        // Keep SDK time monotonic even if Media Foundation timestamps restart.
        frucSeeded=false;
#endif
    }
    bool interpolate(ID3D11Texture2D* input,int64_t inputTime,int64_t outputTime,ID3D11Texture2D* output,bool& repeated) override {
        repeated=false;
#ifdef ELGA_WITH_FRUC
        if(!fruc||!registered) return false;
        auto* render=frucInput[frucIndex++%2].Get();
        context->CopyResource(render,input);
        if(FAILED(context4->Signal(fence.Get(),++fenceValue))) return false;
        context->Flush();
        NvOFFRUC_PROCESS_IN_PARAMS in{}; NvOFFRUC_PROCESS_OUT_PARAMS out{};
        double step=frucSeeded?double(inputTime-frucLastInput)/10000:1000./30;
        if(step<=0) return false;
        frucClock+=step;
        in.bSkipWarp=frucSeeded?0:1;
        in.stFrameDataInput.pFrame=render; in.stFrameDataInput.nTimeStamp=frucClock;
        in.uSyncWait.FenceWaitValue.uiFenceValueToWaitOn=fenceValue;
        out.stFrameDataOutput.pFrame=frucOutput.Get();
        out.stFrameDataOutput.nTimeStamp=frucClock-(frucSeeded?double(inputTime-outputTime)/10000:step/2);
        out.stFrameDataOutput.bHasFrameRepetitionOccurred=&repeated;
        out.uSyncSignal.FenceSignalValue.uiFenceValueToSignalOn=++fenceValue;
        auto result=processFruc(fruc,&in,&out);
        if(result!=NvOFFRUC_SUCCESS) { diagnostic("FRUC processing failed",result); return false; }
        // Wait on the worker's CPU event, never enqueue an unbounded GPU wait
        // that could freeze presentation if an SDK/driver fails to signal.
        if(FAILED(fence->SetEventOnCompletion(fenceValue,fenceEvent)) || WaitForSingleObject(fenceEvent,1000)!=WAIT_OBJECT_0) return false;
        if(fence->GetCompletedValue()==UINT64_MAX) return false;
        context->CopyResource(output,frucOutput.Get());
        repeated=repeated || !frucSeeded;
        frucSeeded=true; frucLastInput=inputTime;
        return true;
#else
        (void)input; (void)inputTime; (void)outputTime; (void)output; return false;
#endif
    }
    ~Nvidia() override {
        diagnostic("provider closing");
#ifdef ELGA_WITH_FRUC
        closeFruc();
        if(fenceEvent) CloseHandle(fenceEvent);
#endif
#ifdef ELGA_WITH_VSR
        if(vsr) NVSDK_NGX_D3D11_ReleaseFeature(vsr);
        if(params) NVSDK_NGX_D3D11_DestroyParameters(params);
        if(ngx) NVSDK_NGX_D3D11_Shutdown1(device.Get());
#endif
        context->ClearState(); context->Flush();
        for(auto it=modules.rbegin();it!=modules.rend();++it) FreeLibrary(*it);
        diagnostic("provider closed");
    }
};
}
std::unique_ptr<Provider> makeProvider(ID3D11Device* d,ID3D11DeviceContext* c) { return std::make_unique<Nvidia>(d,c); }
