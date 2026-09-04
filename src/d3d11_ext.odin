package main

import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

// Odin's D3D11 bindings currently stop at ID3D11VideoContext. The Windows 8.1
// extension names the input and output DXGI color spaces explicitly, avoiding
// the legacy bitfield's driver-dependent matrix heuristics.
ID3D11VideoContext1_UUID := &win32.GUID{0xa7f026da, 0xa5f8, 0x4487, {0xa5, 0x64, 0x15, 0xe3, 0x43, 0x57, 0x65, 0x1e}}

ID3D11VideoContext1 :: struct #raw_union {
	#subtype ctx: d3d11.IVideoContext,
	using vtable: ^ID3D11VideoContext1_VTable,
}

ID3D11VideoContext1_VTable :: struct {
	using base: d3d11.IVideoContext_VTable,
	SubmitDecoderBuffers1: rawptr,
	GetDataForNewHardwareKey: rawptr,
	CheckCryptoSessionStatus: rawptr,
	DecoderEnableDownsampling: rawptr,
	DecoderUpdateDownsampling: rawptr,
	VideoProcessorSetOutputColorSpace1: proc "system" (this: ^ID3D11VideoContext1, processor: ^d3d11.IVideoProcessor, color_space: dxgi.COLOR_SPACE_TYPE),
	VideoProcessorSetOutputShaderUsage: rawptr,
	VideoProcessorGetOutputColorSpace1: rawptr,
	VideoProcessorGetOutputShaderUsage: rawptr,
	VideoProcessorSetStreamColorSpace1: proc "system" (this: ^ID3D11VideoContext1, processor: ^d3d11.IVideoProcessor, stream: u32, color_space: dxgi.COLOR_SPACE_TYPE),
	VideoProcessorSetStreamMirror: rawptr,
	VideoProcessorGetStreamColorSpace1: rawptr,
	VideoProcessorGetStreamMirror: rawptr,
	VideoProcessorGetBehaviorHints: rawptr,
}

// Odin's D3D11 package currently stops at ID3D11Device. Preserve the inherited
// vtable layout and expose only D3D11.1 shared-handle opening.
ID3D11Device1_UUID := &win32.GUID{0xa04bfb29, 0x08ef, 0x43d6, {0xa4, 0x9c, 0xa9, 0xbd, 0xbd, 0xcb, 0xe6, 0x86}}

ID3D11Device1 :: struct #raw_union {
	#subtype device: d3d11.IDevice,
	using vtable: ^ID3D11Device1_VTable,
}

ID3D11Device1_VTable :: struct {
	using base: d3d11.IDevice_VTable,
	// ID3D11Device1
	GetImmediateContext1: rawptr,
	CreateDeferredContext1: rawptr,
	CreateBlendState1: rawptr,
	CreateRasterizerState1: rawptr,
	CreateDeviceContextState: rawptr,
	OpenSharedResource1: proc "system" (this: ^ID3D11Device1, handle: win32.HANDLE, riid: ^win32.GUID, resource: ^rawptr) -> win32.HRESULT,
}

// Media Foundation and the capture callback share an immediate context.
ID3D10Multithread_UUID := &win32.GUID{0x9b7e4e00, 0x342c, 0x4106, {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}}

ID3D10Multithread :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^ID3D10Multithread_VTable,
}

ID3D10Multithread_VTable :: struct {
	using base: win32.IUnknown_VTable,
	Enter: rawptr,
	Leave: rawptr,
	SetMultithreadProtected: proc "system" (this: ^ID3D10Multithread, protect: win32.BOOL) -> win32.BOOL,
	GetMultithreadProtected: rawptr,
}
