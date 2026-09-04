package main

import win32 "core:sys/windows"

foreign import mfplat_lib "system:mfplat.lib"
foreign import mf_lib "system:mf.lib"
foreign import mfreadwrite_lib "system:mfreadwrite.lib"

@(default_calling_convention="system")
foreign mfplat_lib {
	MFStartup :: proc(version, flags: u32) -> win32.HRESULT ---
	MFShutdown :: proc() -> win32.HRESULT ---
	MFCreateAttributes :: proc(attributes: ^^IMFAttributes, initial_size: u32) -> win32.HRESULT ---
	MFCreateMediaType :: proc(media_type: ^^IMFMediaType) -> win32.HRESULT ---
	MFCreateDXGIDeviceManager :: proc(reset_token: ^u32, manager: ^^IMFDXGIDeviceManager) -> win32.HRESULT ---
}

@(default_calling_convention="system")
foreign mf_lib {
	MFEnumDeviceSources :: proc(attributes: ^IMFAttributes, devices: ^^^IMFActivate, count: ^u32) -> win32.HRESULT ---
}

@(default_calling_convention="system")
foreign mfreadwrite_lib {
	MFCreateSourceReaderFromMediaSource :: proc(source: ^IMFMediaSource, attributes: ^IMFAttributes, reader: ^^IMFSourceReader) -> win32.HRESULT ---
}

MF_VERSION :: 131184
MFSTARTUP_FULL :: 0
MF_SOURCE_READER_FIRST_VIDEO_STREAM :: u32(0xffff_fffc)
MF_SOURCE_READER_ALL_STREAMS :: u32(0xffff_fffe)

IID_IMFMediaSource := &win32.GUID{0x279a808d, 0xaec7, 0x40c8, {0x9c, 0x6b, 0xa6, 0xb4, 0x92, 0xc7, 0x8a, 0x66}}
IID_IMFDXGIBuffer := &win32.GUID{0xe7174cfa, 0x1c9e, 0x48b1, {0x88, 0x66, 0x62, 0x62, 0x26, 0xbf, 0xc2, 0x58}}
IID_IMFSourceReaderEx := &win32.GUID{0x7b981cf0, 0x560e, 0x4116, {0x98, 0x75, 0xb0, 0x99, 0x89, 0x5f, 0x23, 0xd7}}
IID_IUnknown_Value := win32.GUID{0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IMFSourceReaderCallback_Value := win32.GUID{0xdeec8d99, 0xfa1d, 0x4d82, {0x84, 0xc2, 0x2c, 0x89, 0x69, 0x94, 0x48, 0x67}}

MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE := win32.GUID{0xc60ac5fe, 0x252a, 0x478f, {0xa0, 0xef, 0xbc, 0x8f, 0xa5, 0xf7, 0xca, 0xd3}}
MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID := win32.GUID{0x8ac3587a, 0x4ae7, 0x42d8, {0x99, 0xe0, 0x0a, 0x60, 0x13, 0xee, 0xf9, 0x0f}}
MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME := win32.GUID{0x60d0e559, 0x52f8, 0x4fa2, {0xbb, 0xce, 0xac, 0xdb, 0x34, 0xa8, 0xec, 0x01}}
MF_SOURCE_READER_D3D_MANAGER := win32.GUID{0xec822da2, 0xe1e9, 0x4b29, {0xa0, 0xd8, 0x56, 0x3c, 0x71, 0x9f, 0x52, 0x69}}
MF_SOURCE_READER_ASYNC_CALLBACK := win32.GUID{0x1e3dbeac, 0xbb43, 0x4c35, {0xb5, 0x07, 0xcd, 0x64, 0x44, 0x64, 0xc9, 0x65}}
MF_LOW_LATENCY := win32.GUID{0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}}
MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS := win32.GUID{0xa634a91c, 0x822b, 0x41b9, {0xa4, 0x94, 0x4d, 0xe4, 0x64, 0x36, 0x12, 0xb0}}
MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING := win32.GUID{0x0f81da2c, 0xb537, 0x4672, {0xa8, 0xb2, 0xa6, 0x81, 0xb1, 0x73, 0x07, 0xa3}}
MF_MT_MAJOR_TYPE := win32.GUID{0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}}
MF_MT_SUBTYPE := win32.GUID{0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}}
MF_MT_FRAME_SIZE := win32.GUID{0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}}
MF_MT_FRAME_RATE := win32.GUID{0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}}
MF_MT_VIDEO_NOMINAL_RANGE := win32.GUID{0xc21b8ee5, 0xb956, 0x4071, {0x8d, 0xaf, 0x32, 0x5e, 0xdf, 0x5c, 0xab, 0x11}}
MF_MT_YUV_MATRIX := win32.GUID{0x3e23d450, 0x2c75, 0x4d25, {0xa0, 0x0e, 0xb9, 0x16, 0x70, 0xd1, 0x23, 0x27}}
MF_MT_DEFAULT_STRIDE := win32.GUID{0x644b4e48, 0x1e02, 0x4516, {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}}
MFMediaType_Video := win32.GUID{0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_NV12 := win32.GUID{0x3231564e, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_P010 := win32.GUID{0x30313050, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_YUY2 := win32.GUID{0x32595559, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_I420 := win32.GUID{0x30323449, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_RGB24 := win32.GUID{0x00000014, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_ARGB32 := win32.GUID{0x00000015, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
MFVideoFormat_MJPG := win32.GUID{0x47504a4d, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

IMFAttributes :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFAttributes_VTable,
}
IMFAttributes_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	GetItem: rawptr,
	GetItemType: rawptr,
	CompareItem: rawptr,
	Compare: rawptr,
	GetUINT32: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: ^u32) -> win32.HRESULT,
	GetUINT64: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: ^u64) -> win32.HRESULT,
	GetDouble: rawptr,
	GetGUID: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: ^win32.GUID) -> win32.HRESULT,
	GetStringLength: rawptr,
	GetString: rawptr,
	GetAllocatedString: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: ^^u16, length: ^u32) -> win32.HRESULT,
	GetBlobSize: rawptr,
	GetBlob: rawptr,
	GetAllocatedBlob: rawptr,
	GetUnknown: rawptr,
	SetItem: rawptr,
	DeleteItem: rawptr,
	DeleteAllItems: rawptr,
	SetUINT32: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: u32) -> win32.HRESULT,
	SetUINT64: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: u64) -> win32.HRESULT,
	SetDouble: rawptr,
	SetGUID: proc "system" (this: ^IMFAttributes, key, value: ^win32.GUID) -> win32.HRESULT,
	SetString: rawptr,
	SetBlob: rawptr,
	SetUnknown: proc "system" (this: ^IMFAttributes, key: ^win32.GUID, value: ^win32.IUnknown) -> win32.HRESULT,
	LockStore: rawptr,
	UnlockStore: rawptr,
	GetCount: rawptr,
	GetItemByIndex: rawptr,
	CopyAllItems: rawptr,
}

IMFMediaType :: struct #raw_union {
	#subtype attributes: IMFAttributes,
	using vtable: ^IMFMediaType_VTable,
}
IMFMediaType_VTable :: struct {
	using attributes_vtable: IMFAttributes_VTable,
	GetMajorType: rawptr,
	IsCompressedFormat: rawptr,
	IsEqual: rawptr,
	GetRepresentation: rawptr,
	FreeRepresentation: rawptr,
}

IMFActivate :: struct #raw_union {
	#subtype attributes: IMFAttributes,
	using vtable: ^IMFActivate_VTable,
}
IMFActivate_VTable :: struct {
	using attributes_vtable: IMFAttributes_VTable,
	ActivateObject: proc "system" (this: ^IMFActivate, riid: ^win32.GUID, object: ^rawptr) -> win32.HRESULT,
	ShutdownObject: rawptr,
	DetachObject: rawptr,
}

IMFMediaSource :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFMediaSource_VTable,
}
IMFMediaSource_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	media_event_generator_methods: [4]rawptr,
	GetCharacteristics: rawptr,
	CreatePresentationDescriptor: rawptr,
	Start: rawptr,
	Stop: rawptr,
	Pause: rawptr,
	Shutdown: proc "system" (this: ^IMFMediaSource) -> win32.HRESULT,
}

IMFSourceReader :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFSourceReader_VTable,
}
IMFSourceReader_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	GetStreamSelection: rawptr,
	SetStreamSelection: proc "system" (this: ^IMFSourceReader, stream: u32, selected: win32.BOOL) -> win32.HRESULT,
	GetNativeMediaType: proc "system" (this: ^IMFSourceReader, stream, index: u32, media_type: ^^IMFMediaType) -> win32.HRESULT,
	GetCurrentMediaType: proc "system" (this: ^IMFSourceReader, stream: u32, media_type: ^^IMFMediaType) -> win32.HRESULT,
	SetCurrentMediaType: proc "system" (this: ^IMFSourceReader, stream: u32, reserved: ^u32, media_type: ^IMFMediaType) -> win32.HRESULT,
	SetCurrentPosition: rawptr,
	ReadSample: proc "system" (this: ^IMFSourceReader, stream, flags: u32, actual_stream, stream_flags: ^u32, timestamp: ^i64, sample: ^^IMFSample) -> win32.HRESULT,
	Flush: proc "system" (this: ^IMFSourceReader, stream: u32) -> win32.HRESULT,
	GetServiceForStream: rawptr,
	GetPresentationAttribute: rawptr,
}

IMFSourceReaderEx :: struct #raw_union {
	#subtype reader: IMFSourceReader,
	using vtable: ^IMFSourceReaderEx_VTable,
}
IMFSourceReaderEx_VTable :: struct {
	using reader_vtable: IMFSourceReader_VTable,
	SetNativeMediaType: proc "system" (this: ^IMFSourceReaderEx, stream: u32, media_type: ^IMFMediaType, stream_flags: ^u32) -> win32.HRESULT,
	AddTransformForStream: rawptr,
	RemoveAllTransformsForStream: rawptr,
	GetTransformForStream: rawptr,
}

IMFSourceReaderCallback :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFSourceReaderCallback_VTable,
}
IMFSourceReaderCallback_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	OnReadSample: proc "system" (this: ^IMFSourceReaderCallback, status: win32.HRESULT, stream, flags: u32, timestamp: i64, sample: ^IMFSample) -> win32.HRESULT,
	OnFlush: proc "system" (this: ^IMFSourceReaderCallback, stream: u32) -> win32.HRESULT,
	OnEvent: proc "system" (this: ^IMFSourceReaderCallback, stream: u32, event: rawptr) -> win32.HRESULT,
}

IMFSample :: struct #raw_union {
	#subtype attributes: IMFAttributes,
	using vtable: ^IMFSample_VTable,
}
IMFSample_VTable :: struct {
	using attributes_vtable: IMFAttributes_VTable,
	GetSampleFlags: rawptr,
	SetSampleFlags: rawptr,
	GetSampleTime: rawptr,
	SetSampleTime: rawptr,
	GetSampleDuration: rawptr,
	SetSampleDuration: rawptr,
	GetBufferCount: proc "system" (this: ^IMFSample, count: ^u32) -> win32.HRESULT,
	GetBufferByIndex: proc "system" (this: ^IMFSample, index: u32, buffer: ^^IMFMediaBuffer) -> win32.HRESULT,
	ConvertToContiguousBuffer: proc "system" (this: ^IMFSample, buffer: ^^IMFMediaBuffer) -> win32.HRESULT,
	AddBuffer: proc "system" (this: ^IMFSample, buffer: ^IMFMediaBuffer) -> win32.HRESULT,
	RemoveBufferByIndex: rawptr,
	RemoveAllBuffers: rawptr,
	GetTotalLength: rawptr,
	CopyToBuffer: rawptr,
}

IMFMediaBuffer :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFMediaBuffer_VTable,
}
IMFMediaBuffer_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	Lock: proc "system" (this: ^IMFMediaBuffer, buffer: ^^u8, max_length, current_length: ^u32) -> win32.HRESULT,
	Unlock: proc "system" (this: ^IMFMediaBuffer) -> win32.HRESULT,
	GetCurrentLength: proc "system" (this: ^IMFMediaBuffer, current_length: ^u32) -> win32.HRESULT,
	SetCurrentLength: proc "system" (this: ^IMFMediaBuffer, length: u32) -> win32.HRESULT,
	GetMaxLength: rawptr,
}

IMFDXGIBuffer :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFDXGIBuffer_VTable,
}
IMFDXGIBuffer_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	GetResource: proc "system" (this: ^IMFDXGIBuffer, riid: ^win32.GUID, object: ^rawptr) -> win32.HRESULT,
	GetSubresourceIndex: proc "system" (this: ^IMFDXGIBuffer, index: ^u32) -> win32.HRESULT,
	GetUnknown: rawptr,
	SetUnknown: rawptr,
}

IMFDXGIDeviceManager :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IMFDXGIDeviceManager_VTable,
}
IMFDXGIDeviceManager_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	CloseDeviceHandle: rawptr,
	GetVideoService: rawptr,
	LockDevice: rawptr,
	OpenDeviceHandle: rawptr,
	ResetDevice: proc "system" (this: ^IMFDXGIDeviceManager, device: ^win32.IUnknown, token: u32) -> win32.HRESULT,
	TestDevice: rawptr,
	UnlockDevice: rawptr,
}
