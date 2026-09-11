package main

import "core:testing"
import win32 "core:sys/windows"

EDID_Test_Fault :: enum {
	None,
	Length_Write,
	Data_Write,
	Timeout,
	Oversize,
	Truncated,
	Fixed_Transfer,
	Length_Count_Zero,
	Mismatch,
}

EDID_Test_Transport :: struct {
	mode: u8,
	version: u8,
	fault: EDID_Test_Fault,
	expected_length: u16,
	response: [EDID_MAX_TRANSFER]u8,
	response_length: u16,
	commands: [16]u32,
	command_lengths: [16]u16,
	command_bytes: [16][16]u8,
	command_count: int,
	cancelled: bool,
	timeout_polls_remaining: u32,
}

edid_test_cancelled :: proc(ctx: rawptr) -> bool {
	f := cast(^EDID_Test_Transport)ctx
	return f.cancelled
}

edid_test_property :: proc(ctx: rawptr, property_id, flags: u32, data: rawptr, data_length: u32, bytes_returned: ^u32) -> bool {
	f := cast(^EDID_Test_Transport)ctx
	if flags == EDID_PROPERTY_SET && property_id == EDID_PROPERTY_LENGTH {
		if f.fault == .Length_Write && f.command_count >= 2 do return false
		if data_length != 2 do return false
		f.expected_length = (cast(^u16)data)^
		bytes_returned^ = 0
		return true
	}
	if flags == EDID_PROPERTY_SET && property_id == EDID_PROPERTY_DATA {
		if data_length != u32(f.expected_length) || data_length < 9 do return false
		bytes := cast([^]u8)data
		command := u32(bytes[4]) | u32(bytes[5])<<8 | u32(bytes[6])<<16 | u32(bytes[7])<<24
		if bytes[0] != edid_service(command) || u32(bytes[1])+3 != data_length ||
		   bytes[2] != 0 || bytes[3] != 0 || edid_checksum(bytes[:data_length]) != 0 {
			return false
		}
		if f.fault == .Data_Write && command == EDID_COMMAND_SET_MODE do return false
		index := f.command_count
		f.commands[index] = command
		f.command_lengths[index] = u16(data_length)
		copy(f.command_bytes[index][:], bytes[:min(int(data_length), len(f.command_bytes[index]))])
		f.command_count += 1
		f.response_length = 9
		f.response = {}
		f.response[0] = bytes[0]
		f.response[1] = 6
		switch command {
		case EDID_COMMAND_PROTOCOL_VERSION:
			f.response[4] = f.version
		case EDID_COMMAND_GET_MODE:
			f.response[4] = f.mode
		case EDID_COMMAND_SET_MODE:
			if data_length != 13 do return false
			if f.fault != .Mismatch do f.mode = bytes[8]
			f.response[4] = f.mode
		case:
			return false
		}
		f.response[8] = edid_checksum(f.response[:8])
		bytes_returned^ = 0
		return true
	}
	if flags == EDID_PROPERTY_GET && property_id == EDID_PROPERTY_LENGTH {
		if data_length != 2 do return false
		length := f.response_length
		if f.timeout_polls_remaining > 0 {
			f.timeout_polls_remaining -= 1
			length = 0
		}
		if f.fault == .Timeout do length = 0
		if f.fault == .Oversize do length = u16(EDID_MAX_TRANSFER+1)
		(cast(^u16)data)^ = length
		bytes_returned^ = 2
		if f.fault == .Length_Count_Zero do bytes_returned^ = 0
		return true
	}
	if flags == EDID_PROPERTY_GET && property_id == EDID_PROPERTY_DATA {
		if data_length != EDID_MAX_TRANSFER do return false
		destination := cast([^]u8)data
		copy(destination[:int(f.response_length)], f.response[:f.response_length])
		bytes_returned^ = u32(f.response_length)
		if f.fault == .Truncated do bytes_returned^ = 0
		if f.fault == .Fixed_Transfer do bytes_returned^ = EDID_MAX_TRANSFER
		return true
	}
	return false
}

@(test)
edid_protocol_retries_read_only_timeout_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{mode = 4, version = 4, timeout_polls_remaining = 2}
	transport := edid_test_transport(&fixture)
	mode, error := edid_read_mode(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, mode, EDID_Mode.Merged)
	testing.expect_value(t, fixture.command_count, 3)
	testing.expect_value(t, fixture.commands[0], EDID_COMMAND_PROTOCOL_VERSION)
	testing.expect_value(t, fixture.commands[1], EDID_COMMAND_PROTOCOL_VERSION)
	testing.expect_value(t, fixture.commands[2], EDID_COMMAND_GET_MODE)
}

edid_test_transport :: proc(f: ^EDID_Test_Transport) -> EDID_Transport {
	return EDID_Transport{ctx = f, property = edid_test_property, cancelled = edid_test_cancelled, poll_limit = 2, poll_delay = 0}
}

EDID_Test_KS_Control :: struct {
	using vtable: ^IKsControl_VTable,
	support: u32,
	returned: u32,
}

edid_test_ks_property :: proc "system" (this: ^IKsControl, property: ^KS_Node_Property, property_length: u32, data: rawptr, data_length: u32, bytes_returned: ^u32) -> win32.HRESULT {
	f := cast(^EDID_Test_KS_Control)this
	if property_length != size_of(KS_Node_Property) || property.set != EDID_EXTENSION_PROPERTY_SET ||
	   property.flags != KS_PROPERTY_TYPE_BASICSUPPORT | KS_PROPERTY_TYPE_TOPOLOGY || data_length != 4 {
		return win32.HRESULT(-1)
	}
	(cast(^u32)data)^ = f.support
	bytes_returned^ = f.returned
	return win32.HRESULT(win32.S_OK)
}

@(test)
edid_protocol_read_and_mode_mapping_test :: proc(t: ^testing.T) {
	values := [3]u8{0, 1, 4}
	for value in values {
		fixture := EDID_Test_Transport{mode = value, version = 4}
		transport := edid_test_transport(&fixture)
		mode, error := edid_read_mode(&transport)
		expected, known := edid_mode_from_device(value)
		testing.expect(t, known)
		testing.expect_value(t, error, EDID_Protocol_Error.None)
		testing.expect_value(t, mode, expected)
		testing.expect_value(t, fixture.command_count, 2)
		testing.expect_value(t, fixture.commands[0], EDID_COMMAND_PROTOCOL_VERSION)
		testing.expect_value(t, fixture.commands[1], EDID_COMMAND_GET_MODE)
		testing.expect_value(t, fixture.command_lengths[0], u16(9))
	}
}

@(test)
edid_protocol_set_uses_framed_raw_value_and_readback_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{mode = 1, version = 4}
	transport := edid_test_transport(&fixture)
	actual, known, disposition, error := edid_set_mode(&transport, .Merged)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect(t, known)
	testing.expect_value(t, actual, EDID_Mode.Merged)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Applied)
	testing.expect_value(t, fixture.command_count, 5)
	testing.expect_value(t, fixture.commands[2], EDID_COMMAND_SET_MODE)
	testing.expect_value(t, fixture.command_lengths[2], u16(13))
	expected := [13]u8{0xa1, 0x0a, 0, 0, 0x4d, 0, 0, 0, 4, 0, 0, 0, 4}
	for value, i in expected do testing.expect_value(t, fixture.command_bytes[2][i], value)
}

@(test)
edid_live_wire_fixtures_test :: proc(t: ^testing.T) {
	// Captured on the connected PID 009B card, 2026-09-11. These literals are
	// deliberately independent of the mock transport's packet construction.
	version_request := [9]u8{0xa0, 6, 0, 0, 0x67, 0, 0, 0, 0xf3}
	mode_request := [9]u8{0xa1, 6, 0, 0, 0x4e, 0, 0, 0, 0x0b}
	version_response := [9]u8{0xa0, 6, 0, 0, 4, 0, 0, 0, 0x56}
	mode_response := [9]u8{0xa1, 6, 0, 0, 4, 0, 0, 0, 0x55}
	packet: [9]u8
	length, error := edid_encode_request(EDID_COMMAND_PROTOCOL_VERSION, nil, packet[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, len(version_request))
	testing.expect_value(t, packet, version_request)
	length, error = edid_encode_request(EDID_COMMAND_GET_MODE, nil, packet[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, len(mode_request))
	testing.expect_value(t, packet, mode_request)
	output: [4]u8
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_PROTOCOL_VERSION, version_response[:], output[:]), EDID_Protocol_Error.None)
	testing.expect_value(t, output, [4]u8{4, 0, 0, 0})
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, mode_response[:], output[:]), EDID_Protocol_Error.None)
	testing.expect_value(t, output, [4]u8{4, 0, 0, 0})
	for mode in ([3]u8{0, 1, 4}) {
		// Captured SET and subsequent GET returned the same four-byte mode.
		reply := [9]u8{0xa1, 6, 0, 0, mode, 0, 0, 0, 0x59-mode}
		testing.expect_value(t, edid_decode_response(EDID_COMMAND_SET_MODE, reply[:], output[:]), EDID_Protocol_Error.None)
		testing.expect_value(t, output, [4]u8{mode, 0, 0, 0})
	}
}

@(test)
edid_wire_rejects_corruption_and_bounds_test :: proc(t: ^testing.T) {
	valid := [9]u8{0xa1, 6, 0, 0, 4, 0, 0, 0, 0x55}
	output: [4]u8
	for length in 0..<len(valid) {
		testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, valid[:length], output[:]), EDID_Protocol_Error.Unexpected_Response_Length)
	}
	corrupted := valid
	corrupted[4] = 1
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, corrupted[:], output[:]), EDID_Protocol_Error.Response_Checksum)
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_PROTOCOL_VERSION, valid[:], output[:]), EDID_Protocol_Error.Response_Header)
	corrupted = valid
	corrupted[0] = 0x5e
	corrupted[8] = edid_checksum(corrupted[:8])
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, corrupted[:], output[:]), EDID_Protocol_Error.Device_Rejected)
	corrupted = valid
	corrupted[1] = 0x86
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, corrupted[:], output[:]), EDID_Protocol_Error.Unexpected_Response_Length)
	input: [121]u8
	packet: [EDID_MAX_TRANSFER]u8
	_, error := edid_encode_request(EDID_COMMAND_SET_MODE, input[:], packet[:])
	testing.expect_value(t, error, EDID_Protocol_Error.Response_Too_Large)
	_, error = edid_encode_request(EDID_COMMAND_SET_MODE, nil, packet[:8])
	testing.expect_value(t, error, EDID_Protocol_Error.Response_Too_Large)
}

@(test)
edid_protocol_rejects_unverified_and_malformed_responses_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{mode = 4, version = 3}
	transport := edid_test_transport(&fixture)
	_, error := edid_read_mode(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Protocol_Version)

	fixture = {mode = 7, version = 4}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_mode(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Unknown_Mode)

	fixture = {mode = 4, version = 4, fault = .Fixed_Transfer}
	transport = edid_test_transport(&fixture)
	fixed_mode, fixed_error := edid_read_mode(&transport)
	testing.expect_value(t, fixed_error, EDID_Protocol_Error.None)
	testing.expect_value(t, fixed_mode, EDID_Mode.Merged)

	fixture = {mode = 4, version = 4, fault = .Length_Count_Zero}
	transport = edid_test_transport(&fixture)
	zero_count_mode, zero_count_error := edid_read_mode(&transport)
	testing.expect_value(t, zero_count_error, EDID_Protocol_Error.None)
	testing.expect_value(t, zero_count_mode, EDID_Mode.Merged)

	faults := [3]EDID_Test_Fault{.Timeout, .Oversize, .Truncated}
	errors := [3]EDID_Protocol_Error{.Response_Timeout, .Response_Too_Large, .Invalid_Transfer_Count}
	for fault, index in faults {
		fixture = {mode = 4, version = 4, fault = fault}
		transport = edid_test_transport(&fixture)
		_, error = edid_read_mode(&transport)
		testing.expect_value(t, error, errors[index])
	}
}

@(test)
edid_protocol_cancellation_and_property_support_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{mode = 4, version = 4, cancelled = true}
	transport := edid_test_transport(&fixture)
	_, error := edid_read_mode(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Cancelled)
	testing.expect_value(t, fixture.command_count, 0)

	vtable := IKsControl_VTable{KsProperty = edid_test_ks_property}
	control := EDID_Test_KS_Control{
		vtable = &vtable,
		support = KS_PROPERTY_TYPE_GET | KS_PROPERTY_TYPE_SET,
		returned = 4,
	}
	testing.expect(t, edid_windows_property_support(cast(^IKsControl)&control, 9, EDID_PROPERTY_DATA))
	control.support = KS_PROPERTY_TYPE_GET
	testing.expect(t, !edid_windows_property_support(cast(^IKsControl)&control, 9, EDID_PROPERTY_DATA))
	control.support = KS_PROPERTY_TYPE_GET | KS_PROPERTY_TYPE_SET
	control.returned = 2
	testing.expect(t, !edid_windows_property_support(cast(^IKsControl)&control, 9, EDID_PROPERTY_DATA))
}

@(test)
edid_protocol_distinguishes_failed_and_uncertain_writes_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{mode = 1, version = 4, fault = .Length_Write}
	transport := edid_test_transport(&fixture)
	_, known, disposition, error := edid_set_mode(&transport, .Merged)
	testing.expect(t, known)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Not_Applied)
	testing.expect_value(t, error, EDID_Protocol_Error.Length_Write_Failed)

	fixture = {mode = 1, version = 4, fault = .Data_Write}
	transport = edid_test_transport(&fixture)
	_, known, disposition, error = edid_set_mode(&transport, .Merged)
	testing.expect(t, !known)
	testing.expect_value(t, disposition, EDID_Set_Disposition.May_Have_Applied)
	testing.expect_value(t, error, EDID_Protocol_Error.Write_Failed)

	fixture = {mode = 1, version = 4, fault = .Mismatch}
	transport = edid_test_transport(&fixture)
	actual: EDID_Mode
	actual, known, disposition, error = edid_set_mode(&transport, .Merged)
	testing.expect(t, known)
	testing.expect_value(t, actual, EDID_Mode.Display)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Applied_Mismatch)
	testing.expect_value(t, error, EDID_Protocol_Error.Readback_Mismatch)
}

@(test)
edid_mailbox_serializes_and_discards_stale_results_test :: proc(t: ^testing.T) {
	r := Renderer{ready = true, capture_ready = 1, capture_running = true, capture_generation = 11, edid_status = u32(EDID_Availability.Ready), edid_mode_known = 1, edid_mode = u32(EDID_Mode.Display)}
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	if !testing.expect(t, r.capture_event != nil) do return
	defer win32.CloseHandle(r.capture_event)
	testing.expect(t, renderer_request_edid_refresh(&r))
	testing.expect(t, !renderer_request_edid_refresh(&r))
	testing.expect(t, !renderer_request_edid_mode(&r, .Merged))
	testing.expect_value(t, EDID_Request_Kind(r.edid_request_kind), EDID_Request_Kind.Refresh)

	r.edid_request_kind = u32(EDID_Request_Kind.None)
	r.edid_status = u32(EDID_Availability.Ready)
	r.edid_mode = u32(EDID_Mode.Display)
	renderer_publish_edid_result(&r, EDID_Result{request_id = 99, generation = 10, mode = .Merged, mode_known = true})
	testing.expect_value(t, EDID_Mode(r.edid_mode), EDID_Mode.Display)
	testing.expect_value(t, r.edid_result_pending, u32(0))

	r.edid_status = u32(EDID_Availability.Error)
	testing.expect(t, renderer_request_edid_refresh(&r))
}

@(test)
edid_stale_message_preserves_pending_result_test :: proc(t: ^testing.T) {
	r := Renderer{capture_generation = 12}
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 5,
		generation = 12,
		mode = .Merged,
		mode_known = true,
	})
	renderer_handle_edid_result(&r, 11, 5)
	testing.expect_value(t, r.edid_result_pending, u32(1))
	renderer_handle_edid_result(&r, 12, 4)
	testing.expect_value(t, r.edid_result_pending, u32(1))
	renderer_handle_edid_result(&r, 12, 5)
	testing.expect_value(t, r.edid_result_pending, u32(0))
	testing.expect_value(t, EDID_Mode(r.edid_mode), EDID_Mode.Merged)
	testing.expect_value(t, EDID_Availability(r.edid_status), EDID_Availability.Ready)
}

@(test)
edid_reconnect_dispositions_test :: proc(t: ^testing.T) {
	testing.expect(t, !edid_requires_reconnect(.Not_Applied))
	testing.expect(t, edid_requires_reconnect(.Applied))
	testing.expect(t, edid_requires_reconnect(.Applied_Mismatch))
	testing.expect(t, edid_requires_reconnect(.May_Have_Applied))
}

@(test)
edid_active_operation_defers_minimize_test :: proc(t: ^testing.T) {
	r := Renderer{ready = true, capture_running = true, edid_operation_active = 1}
	renderer_suspend_capture(&r)
	testing.expect(t, r.suspend_requested)
	testing.expect(t, !r.capture_suspended)
	testing.expect(t, r.capture_running)
}

@(test)
edid_uncertain_write_requires_explicit_refresh_test :: proc(t: ^testing.T) {
	r := Renderer{capture_generation = 3}
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 1,
		generation = 3,
		error = .Readback_Failed,
		disposition = .May_Have_Applied,
	})
	testing.expect_value(t, r.edid_mode_known, u32(0))
	testing.expect_value(t, r.edid_verification_required, u32(1))
	testing.expect_value(t, EDID_Availability(r.edid_status), EDID_Availability.Reconnecting)
	testing.expect_value(t, EDID_Protocol_Error(r.edid_notice), EDID_Protocol_Error.Readback_Failed)

	r.edid_result_pending = 0
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 2,
		generation = 3,
		mode = .Merged,
		mode_known = true,
	})
	testing.expect_value(t, r.edid_verification_required, u32(0))
	testing.expect_value(t, r.edid_mode_known, u32(1))
	testing.expect_value(t, EDID_Mode(r.edid_mode), EDID_Mode.Merged)
}
