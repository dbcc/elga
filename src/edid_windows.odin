package main

import "core:fmt"
import win32 "core:sys/windows"
import "core:sync"

IID_IKsTopologyInfo := &win32.GUID{0x720d4ac0, 0x7533, 0x11d0, {0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0x00, 0x00}}
IID_IKsControl := &win32.GUID{0x28f54685, 0x06fd, 0x11d2, {0xb2, 0x7a, 0x00, 0xa0, 0xc9, 0x22, 0x31, 0x96}}
EDID_EXTENSION_PROPERTY_SET := win32.GUID{0x961073c7, 0x49f7, 0x44f2, {0xab, 0x42, 0xe9, 0x40, 0x40, 0x59, 0x40, 0xc2}}

KS_PROPERTY_TYPE_GET           :: u32(0x0000_0001)
KS_PROPERTY_TYPE_SET           :: u32(0x0000_0002)
KS_PROPERTY_TYPE_BASICSUPPORT  :: u32(0x0000_0200)
KS_PROPERTY_TYPE_TOPOLOGY      :: u32(0x1000_0000)

KS_Node_Property :: struct {
	set: win32.GUID,
	id: u32,
	flags: u32,
	node_id: u32,
	reserved: u32,
}
#assert(size_of(KS_Node_Property) == 32)

IKsTopologyInfo :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IKsTopologyInfo_VTable,
}
IKsTopologyInfo_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	GetNumCategories: proc "system" (this: ^IKsTopologyInfo, count: ^u32) -> win32.HRESULT,
	GetCategory: proc "system" (this: ^IKsTopologyInfo, index: u32, category: ^win32.GUID) -> win32.HRESULT,
	GetNumConnections: proc "system" (this: ^IKsTopologyInfo, count: ^u32) -> win32.HRESULT,
	GetConnectionInfo: rawptr,
	GetNodeName: rawptr,
	GetNumNodes: proc "system" (this: ^IKsTopologyInfo, count: ^u32) -> win32.HRESULT,
	GetNodeType: proc "system" (this: ^IKsTopologyInfo, node: u32, node_type: ^win32.GUID) -> win32.HRESULT,
	CreateNodeInstance: proc "system" (this: ^IKsTopologyInfo, node: u32, iid: ^win32.GUID, object: ^rawptr) -> win32.HRESULT,
}

IKsControl :: struct #raw_union {
	#subtype unknown: win32.IUnknown,
	using vtable: ^IKsControl_VTable,
}
IKsControl_VTable :: struct {
	using unknown_vtable: win32.IUnknown_VTable,
	KsProperty: proc "system" (this: ^IKsControl, property: ^KS_Node_Property, property_length: u32, data: rawptr, data_length: u32, bytes_returned: ^u32) -> win32.HRESULT,
	KsMethod: rawptr,
	KsEvent: rawptr,
}

EDID_Windows_Controller :: struct {
	// Borrowed from the active capture session. The capture worker closes this
	// controller before releasing the media source.
	source: ^IMFMediaSource,
	node_id: u32,
	renderer: ^Renderer,
}

edid_windows_property :: proc(ctx: rawptr, property_id, flags: u32, data: rawptr, data_length: u32, bytes_returned: ^u32) -> bool {
	controller := cast(^EDID_Windows_Controller)ctx
	if controller == nil || controller.source == nil do return false

	// Match the vendor transport's lifetime exactly: each KS property call gets
	// a fresh topology interface and node instance, then releases both.
	topology: ^IKsTopologyInfo
	hr := controller.source.QueryInterface(controller.source, IID_IKsTopologyInfo, cast(^rawptr)&topology)
	if failed(hr) {
		fmt.eprintf("EDID topology query failed: node=%d property=%d hr=0x%08x\n", controller.node_id, property_id, u32(hr))
		return false
	}
	defer com_release(topology)
	control: ^IKsControl
	hr = topology.CreateNodeInstance(topology, controller.node_id, IID_IKsControl, cast(^rawptr)&control)
	if failed(hr) {
		fmt.eprintf("EDID node open failed: node=%d property=%d hr=0x%08x\n", controller.node_id, property_id, u32(hr))
		return false
	}
	defer com_release(control)
	property := KS_Node_Property{
		set = EDID_EXTENSION_PROPERTY_SET,
		id = property_id,
		flags = flags | KS_PROPERTY_TYPE_TOPOLOGY,
		node_id = controller.node_id,
	}
	hr = control.KsProperty(control, &property, size_of(property), data, data_length, bytes_returned)
	if failed(hr) {
		fmt.eprintf("EDID KS transfer failed: node=%d property=%d flags=0x%08x size=%d hr=0x%08x\n", controller.node_id, property_id, flags, data_length, u32(hr))
	}
	return !failed(hr)
}

edid_windows_cancelled :: proc(ctx: rawptr) -> bool {
	controller := cast(^EDID_Windows_Controller)ctx
	return controller == nil || controller.renderer == nil || !sync.atomic_load_explicit(&controller.renderer.capture_running, .Acquire)
}

edid_windows_property_support :: proc(control: ^IKsControl, node_id, property_id: u32) -> bool {
	property := KS_Node_Property{
		set = EDID_EXTENSION_PROPERTY_SET,
		id = property_id,
		flags = KS_PROPERTY_TYPE_BASICSUPPORT | KS_PROPERTY_TYPE_TOPOLOGY,
		node_id = node_id,
	}
	support: u32
	returned: u32
	hr := control.KsProperty(control, &property, size_of(property), &support, size_of(support), &returned)
	return !failed(hr) && returned == size_of(support) &&
		(support & (KS_PROPERTY_TYPE_GET | KS_PROPERTY_TYPE_SET)) == (KS_PROPERTY_TYPE_GET | KS_PROPERTY_TYPE_SET)
}

// Finds the extension unit node that speaks the EDID protocol. A node that
// exposes the properties but fails validation is still returned, with its error.
edid_windows_open :: proc(source: ^IMFMediaSource, r: ^Renderer) -> (EDID_Windows_Controller, EDID_Mode, EDID_Protocol_Error, bool) {
	if source == nil do return {}, .Internal, .Unsupported, false
	topology: ^IKsTopologyInfo
	if failed(source.QueryInterface(source, IID_IKsTopologyInfo, cast(^rawptr)&topology)) do return {}, .Internal, .Unsupported, false
	defer com_release(topology)
	node_count: u32
	if failed(topology.GetNumNodes(topology, &node_count)) do return {}, .Internal, .Unsupported, false

	fallback: Maybe(EDID_Windows_Controller)
	fallback_error := EDID_Protocol_Error.Unsupported
	for node_id in 0..<node_count {
		control: ^IKsControl
		if failed(topology.CreateNodeInstance(topology, node_id, IID_IKsControl, cast(^rawptr)&control)) do continue
		supported := edid_windows_property_support(control, node_id, EDID_PROPERTY_LENGTH) &&
			edid_windows_property_support(control, node_id, EDID_PROPERTY_DATA)
		// Validation uses the same fresh-control-per-transfer behavior as all
		// later requests; the instance used for support probing is not reused.
		com_release(control)
		if !supported do continue
		controller := EDID_Windows_Controller{source = source, node_id = node_id, renderer = r}
		transport := edid_windows_transport(&controller)
		mode, protocol_error := edid_read_mode(&transport)
		if protocol_error == .None do return controller, mode, .None, true
		fmt.eprintf("EDID protocol validation failed: node=%d error=%s\n", node_id, EDID_ERROR_TEXT[protocol_error])
		if fallback == nil {
			fallback = controller
			fallback_error = protocol_error
		}
	}
	if controller, found := fallback.?; found do return controller, .Internal, fallback_error, true
	return {}, .Internal, .Unsupported, false
}

edid_windows_transport :: proc(controller: ^EDID_Windows_Controller) -> EDID_Transport {
	return EDID_Transport{
		ctx = controller,
		property = edid_windows_property,
		cancelled = edid_windows_cancelled,
	}
}
