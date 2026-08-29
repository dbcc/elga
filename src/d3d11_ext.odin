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
ID3D11Device3_UUID := &win32.GUID{0xa05c8c37, 0xd2c6, 0x4732, {0xb3, 0xa0, 0x9c, 0xe0, 0xb0, 0xdc, 0x9a, 0xe6}}

ID3D11Device3 :: struct #raw_union {
	#subtype device: d3d11.IDevice,
	using vtable: ^ID3D11Device3_VTable,
}

ID3D11Device3_VTable :: struct {
	using base: d3d11.IDevice_VTable,
	// ID3D11Device1
	GetImmediateContext1: rawptr,
	CreateDeferredContext1: rawptr,
	CreateBlendState1: rawptr,
	CreateRasterizerState1: rawptr,
	CreateDeviceContextState: rawptr,
	OpenSharedResource1: proc "system" (this: ^ID3D11Device3, handle: win32.HANDLE, riid: ^win32.GUID, resource: ^rawptr) -> win32.HRESULT,
}
