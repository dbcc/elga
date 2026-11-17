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
	color_range: u8,
	// Color range GET reply payload length; zero means four bytes, -1 none.
	color_range_reply_length: int,
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
	// Replace this many data reads with the non-RTICE frame seen on hardware.
	foreign_replies_remaining: int,
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
		if f.fault == .Data_Write && (command == EDID_COMMAND_SET_MODE || command == EDID_COMMAND_SET_COLOR_RANGE) do return false
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
		case EDID_COMMAND_GET_COLOR_RANGE:
			if data_length != 10 || bytes[8] != COLOR_RANGE_SELECTOR do return false
			payload := f.color_range_reply_length if f.color_range_reply_length != 0 else 4
			if payload < 0 do payload = 0
			f.response_length = u16(payload+5)
			f.response[1] = u8(payload+2)
			if payload > 0 do f.response[4] = f.color_range
		case EDID_COMMAND_SET_COLOR_RANGE:
			if data_length != 11 || bytes[8] != COLOR_RANGE_SELECTOR do return false
			if f.fault != .Mismatch do f.color_range = bytes[9]
			// The card acknowledges with an empty body.
			f.response_length = 3
			f.response[1] = 0
		case:
			return false
		}
		f.response[f.response_length-1] = edid_checksum(f.response[:f.response_length-1])
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
		if f.foreign_replies_remaining > 0 && f.response_length == 9 {
			f.foreign_replies_remaining -= 1
			stray := [9]u8{0x64, 4, 0xf0, 0x0c, 6, 0, 0, 0, 0}
			copy(destination[:9], stray[:])
		}
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
	r := Renderer{ready = true, capture_ready = 1, capture_running = true, capture_generation = 11, edid = {status = .Ready, mode_known = 1, mode = .Display}}
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	if !testing.expect(t, r.capture_event != nil) do return
	defer win32.CloseHandle(r.capture_event)
	testing.expect(t, renderer_request_edid_refresh(&r))
	testing.expect(t, !renderer_request_edid_refresh(&r))
	testing.expect(t, !renderer_request_edid_mode(&r, .Merged))
	testing.expect_value(t, r.edid.request_kind, EDID_Request_Kind.Refresh)

	r.edid.request_kind = .None
	r.edid.status = .Ready
	r.edid.mode = .Display
	renderer_publish_edid_result(&r, EDID_Result{request_id = 99, generation = 10, mode = .Merged, mode_known = true})
	testing.expect_value(t, r.edid.mode, EDID_Mode.Display)
	testing.expect_value(t, r.edid.result_pending, u32(0))

	r.edid.status = .Error
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
	testing.expect_value(t, r.edid.result_pending, u32(1))
	renderer_handle_edid_result(&r, 12, 4)
	testing.expect_value(t, r.edid.result_pending, u32(1))
	renderer_handle_edid_result(&r, 12, 5)
	testing.expect_value(t, r.edid.result_pending, u32(0))
	testing.expect_value(t, r.edid.mode, EDID_Mode.Merged)
	testing.expect_value(t, r.edid.status, EDID_Availability.Ready)
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
	r := Renderer{ready = true, capture_running = true, edid = {operation_active = 1}}
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
	testing.expect_value(t, r.edid.mode_known, u32(0))
	testing.expect_value(t, r.edid.verification_required, u32(1))
	testing.expect_value(t, r.edid.status, EDID_Availability.Reconnecting)
	testing.expect_value(t, r.edid.notice, EDID_Protocol_Error.Readback_Failed)

	r.edid.result_pending = 0
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 2,
		generation = 3,
		mode = .Merged,
		mode_known = true,
	})
	testing.expect_value(t, r.edid.verification_required, u32(0))
	testing.expect_value(t, r.edid.mode_known, u32(1))
	testing.expect_value(t, r.edid.mode, EDID_Mode.Merged)
}

@(test)
color_range_read_and_mapping_test :: proc(t: ^testing.T) {
	values := [3]u8{0, 3, 4}
	expected := [3]Color_Range{.Auto, .Expand, .Shrink}
	for value, index in values {
		fixture := EDID_Test_Transport{version = 4, color_range = value}
		transport := edid_test_transport(&fixture)
		range, error := edid_read_color_range(&transport)
		testing.expect_value(t, error, EDID_Protocol_Error.None)
		testing.expect_value(t, range, expected[index])
		testing.expect_value(t, fixture.command_count, 2)
		testing.expect_value(t, fixture.commands[0], EDID_COMMAND_PROTOCOL_VERSION)
		testing.expect_value(t, fixture.commands[1], EDID_COMMAND_GET_COLOR_RANGE)
	}
	// Written independently of the encoder: service A1, selector 1, checksum.
	request := [10]u8{0xa1, 7, 0, 0, 0x91, 0, 0, 0, 1, 0xc6}
	fixture := EDID_Test_Transport{version = 4}
	transport := edid_test_transport(&fixture)
	_, error := edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, fixture.command_lengths[1], u16(len(request)))
	for value, i in request do testing.expect_value(t, fixture.command_bytes[1][i], value)
}

@(test)
color_range_reply_length_and_value_validation_test :: proc(t: ^testing.T) {
	// The vendor reads only the first byte, so a one-byte reply is accepted.
	fixture := EDID_Test_Transport{version = 4, color_range = 4, color_range_reply_length = 1}
	transport := edid_test_transport(&fixture)
	range, error := edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, range, Color_Range.Shrink)

	fixture = {version = 4, color_range = 3, color_range_reply_length = -1}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Unexpected_Response_Length)

	fixture = {version = 4, color_range = 3, color_range_reply_length = 5}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Unexpected_Response_Length)

	fixture = {version = 4, color_range = 2}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Unknown_Color_Range)

	fixture = {version = 3, color_range = 0}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Protocol_Version)
	testing.expect_value(t, fixture.command_count, 1)
}

@(test)
color_range_set_uses_framed_value_and_readback_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{version = 4, color_range = 0}
	transport := edid_test_transport(&fixture)
	actual, known, disposition, error := edid_set_color_range(&transport, .Expand)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect(t, known)
	testing.expect_value(t, actual, Color_Range.Expand)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Applied)
	testing.expect_value(t, fixture.command_count, 5)
	testing.expect_value(t, fixture.commands[2], EDID_COMMAND_SET_COLOR_RANGE)
	testing.expect_value(t, fixture.commands[4], EDID_COMMAND_GET_COLOR_RANGE)
	expected := [11]u8{0xa1, 8, 0, 0, 0x7c, 0, 0, 0, 1, 3, 0xd7}
	testing.expect_value(t, fixture.command_lengths[2], u16(len(expected)))
	for value, i in expected do testing.expect_value(t, fixture.command_bytes[2][i], value)

	fixture = {version = 4, color_range = 4}
	transport = edid_test_transport(&fixture)
	_, _, disposition, error = edid_set_color_range(&transport, .Shrink)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Not_Applied)
	testing.expect_value(t, fixture.command_count, 2)
}

@(test)
color_range_distinguishes_failed_and_uncertain_writes_test :: proc(t: ^testing.T) {
	fixture := EDID_Test_Transport{version = 4, color_range = 0, fault = .Length_Write}
	transport := edid_test_transport(&fixture)
	actual, known, disposition, error := edid_set_color_range(&transport, .Shrink)
	testing.expect(t, known)
	testing.expect_value(t, actual, Color_Range.Auto)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Not_Applied)
	testing.expect_value(t, error, EDID_Protocol_Error.Length_Write_Failed)

	fixture = {version = 4, color_range = 0, fault = .Data_Write}
	transport = edid_test_transport(&fixture)
	_, known, disposition, error = edid_set_color_range(&transport, .Shrink)
	testing.expect(t, !known)
	testing.expect_value(t, disposition, EDID_Set_Disposition.May_Have_Applied)
	testing.expect_value(t, error, EDID_Protocol_Error.Write_Failed)

	fixture = {version = 4, color_range = 0, fault = .Mismatch}
	transport = edid_test_transport(&fixture)
	actual, known, disposition, error = edid_set_color_range(&transport, .Shrink)
	testing.expect(t, known)
	testing.expect_value(t, actual, Color_Range.Auto)
	testing.expect_value(t, disposition, EDID_Set_Disposition.Applied_Mismatch)
	testing.expect_value(t, error, EDID_Protocol_Error.Readback_Mismatch)
}

@(test)
color_range_result_leaves_edid_mode_and_capture_alone_test :: proc(t: ^testing.T) {
	r := Renderer{capture_generation = 4, edid = {
		status = .Ready,
		mode = .Display,
		mode_known = 1,
	}}
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 1,
		generation = 4,
		kind = .Set_Color_Range,
		color_range = .Auto,
		color_range_known = true,
		color_range_error = .Readback_Mismatch,
		color_range_disposition = .Applied_Mismatch,
	})
	testing.expect_value(t, r.edid.status, EDID_Availability.Ready)
	testing.expect_value(t, r.edid.mode, EDID_Mode.Display)
	testing.expect_value(t, r.edid.mode_known, u32(1))
	testing.expect_value(t, r.edid.result_disposition, EDID_Set_Disposition.Not_Applied)
	testing.expect_value(t, r.edid.color_range_status, EDID_Availability.Ready)
	testing.expect_value(t, r.edid.color_range, Color_Range.Auto)
	testing.expect_value(t, r.edid.color_range_error, EDID_Protocol_Error.Readback_Mismatch)

	r.edid.result_pending = 0
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 2,
		generation = 4,
		kind = .Set_Color_Range,
		color_range_error = .Write_Failed,
		color_range_disposition = .May_Have_Applied,
	})
	testing.expect_value(t, r.edid.color_range_status, EDID_Availability.Unknown)
	testing.expect_value(t, r.edid.color_range_known, u32(0))
	testing.expect_value(t, r.edid.status, EDID_Availability.Ready)

	r.edid.result_pending = 0
	renderer_publish_edid_result(&r, EDID_Result{
		request_id = 3,
		generation = 4,
		kind = .Set,
		mode = .Merged,
		mode_known = true,
		disposition = .Applied,
	})
	testing.expect_value(t, r.edid.color_range_status, EDID_Availability.Unknown)
	testing.expect_value(t, r.edid.status, EDID_Availability.Reconnecting)
}

@(test)
color_range_request_uses_shared_mailbox_test :: proc(t: ^testing.T) {
	r := Renderer{ready = true, capture_ready = 1, capture_running = true, capture_generation = 2, edid = {
		status = .Ready,
		color_range_status = .Ready,
		color_range_known = 1,
		color_range = .Auto,
	}}
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	if !testing.expect(t, r.capture_event != nil) do return
	defer win32.CloseHandle(r.capture_event)
	testing.expect(t, renderer_request_color_range(&r, .Auto))
	testing.expect_value(t, r.edid.request_kind, EDID_Request_Kind.None)

	testing.expect(t, renderer_request_color_range(&r, .Expand))
	testing.expect_value(t, r.edid.request_kind, EDID_Request_Kind.Set_Color_Range)
	testing.expect_value(t, r.edid.requested_color_range, Color_Range.Expand)
	testing.expect_value(t, r.edid.color_range_status, EDID_Availability.Applying)
	testing.expect_value(t, r.edid.status, EDID_Availability.Ready)
	// One request at a time, shared with EDID mode changes.
	testing.expect(t, !renderer_request_color_range(&r, .Shrink))
	testing.expect(t, !renderer_request_edid_mode(&r, .Display))
	testing.expect(t, !renderer_request_edid_refresh(&r))

	r.edid.request_kind = .None
	r.edid.color_range_status = .Error
	testing.expect(t, !renderer_request_color_range(&r, .Shrink))
	testing.expect(t, renderer_request_edid_refresh(&r))
	testing.expect_value(t, r.edid.color_range_status, EDID_Availability.Reading)
	testing.expect_value(t, r.edid.status, EDID_Availability.Reading)
}

@(test)
color_range_live_wire_fixtures_test :: proc(t: ^testing.T) {
	// Captured on the connected PID 009B card, 2026-10-17, written
	// independently of the encoder and mock transport.
	get_request := [10]u8{0xa1, 7, 0, 0, 0x91, 0, 0, 0, 1, 0xc6}
	set_auto_request := [11]u8{0xa1, 8, 0, 0, 0x7c, 0, 0, 0, 1, 0, 0xda}
	expand_reply := [9]u8{0xa1, 6, 0, 0, 3, 0, 0, 0, 0x56}
	auto_reply := [9]u8{0xa1, 6, 0, 0, 0, 0, 0, 0, 0x59}
	set_reply := [3]u8{0xa1, 0, 0x5f}

	selector := [1]u8{COLOR_RANGE_SELECTOR}
	get_packet: [10]u8
	length, error := edid_encode_request(EDID_COMMAND_GET_COLOR_RANGE, selector[:], get_packet[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, len(get_request))
	testing.expect_value(t, get_packet, get_request)
	payload := [2]u8{COLOR_RANGE_SELECTOR, COLOR_RANGE_DEVICE_VALUE[.Auto]}
	set_packet: [11]u8
	length, error = edid_encode_request(EDID_COMMAND_SET_COLOR_RANGE, payload[:], set_packet[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, len(set_auto_request))
	testing.expect_value(t, set_packet, set_auto_request)

	output: [4]u8
	length, error = edid_decode_reply(EDID_COMMAND_GET_COLOR_RANGE, expand_reply[:], output[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, 4)
	range, known := color_range_from_device(output[0])
	testing.expect(t, known)
	testing.expect_value(t, range, Color_Range.Expand)
	length, error = edid_decode_reply(EDID_COMMAND_GET_COLOR_RANGE, auto_reply[:], output[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, output[0], COLOR_RANGE_DEVICE_VALUE[.Auto])
	length, error = edid_decode_reply(EDID_COMMAND_SET_COLOR_RANGE, set_reply[:], output[:])
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, length, 0)
	// An exact-length caller still rejects the empty acknowledgement.
	testing.expect_value(t, edid_decode_response(EDID_COMMAND_GET_MODE, set_reply[:], output[:]), EDID_Protocol_Error.Unexpected_Response_Length)
	corrupted := set_reply
	corrupted[2] = 0x60
	_, error = edid_decode_reply(EDID_COMMAND_SET_COLOR_RANGE, corrupted[:], output[:])
	testing.expect_value(t, error, EDID_Protocol_Error.Response_Checksum)
}

@(test)
edid_read_retries_foreign_reply_test :: proc(t: ^testing.T) {
	// Captured 2026-10-17 in place of a protocol-version reply.
	fixture := EDID_Test_Transport{version = 4, color_range = 3, foreign_replies_remaining = 1}
	transport := edid_test_transport(&fixture)
	range, error := edid_read_color_range(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.None)
	testing.expect_value(t, range, Color_Range.Expand)
	testing.expect_value(t, fixture.command_count, 3)
	testing.expect_value(t, fixture.commands[1], EDID_COMMAND_PROTOCOL_VERSION)

	fixture = {mode = 4, version = 4, foreign_replies_remaining = 3}
	transport = edid_test_transport(&fixture)
	_, error = edid_read_mode(&transport)
	testing.expect_value(t, error, EDID_Protocol_Error.Unexpected_Response_Length)
	testing.expect_value(t, fixture.command_count, 3)
}
