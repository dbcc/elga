package main

import "core:time"

EDID_Mode :: enum u32 {
	Internal,
	Display,
	Merged,
}

EDID_Availability :: enum u32 {
	Unavailable,
	Reading,
	Ready,
	Applying,
	Reconnecting,
	Unknown,
	Error,
	Applied_Capture_Unavailable,
}

EDID_Request_Kind :: enum u32 {
	None,
	Refresh,
	Set,
}

EDID_Protocol_Error :: enum u32 {
	None,
	Cancelled,
	Unsupported,
	Transfer_Failed,
	Invalid_Transfer_Count,
	Response_Timeout,
	Response_Too_Large,
	Unexpected_Response_Length,
	Protocol_Version,
	Unknown_Mode,
	Length_Write_Failed,
	Write_Failed,
	Readback_Failed,
	Readback_Mismatch,
	Response_Header,
	Response_Checksum,
	Device_Rejected,
}

edid_protocol_error_text :: proc(error: EDID_Protocol_Error) -> cstring {
	switch error {
	case .None:                       return "none"
	case .Cancelled:                  return "operation cancelled"
	case .Unsupported:                return "extension unavailable"
	case .Transfer_Failed:            return "device transfer failed"
	case .Invalid_Transfer_Count:     return "invalid device transfer count"
	case .Response_Timeout:           return "device response timed out"
	case .Response_Too_Large:         return "device response was too large"
	case .Unexpected_Response_Length: return "unexpected device response length"
	case .Protocol_Version:           return "unsupported protocol version"
	case .Unknown_Mode:               return "card returned an unknown mode"
	case .Length_Write_Failed:         return "request-length write failed"
	case .Write_Failed:                return "request-data write failed"
	case .Readback_Failed:             return "mode readback failed"
	case .Readback_Mismatch:           return "mode readback did not match"
	case .Response_Header:            return "unexpected device response header"
	case .Response_Checksum:          return "device response checksum failed"
	case .Device_Rejected:            return "device rejected the request"
	}
	return "unknown EDID error"
}

EDID_Set_Disposition :: enum u32 {
	Not_Applied,
	Applied,
	Applied_Mismatch,
	May_Have_Applied,
}

edid_requires_reconnect :: proc(disposition: EDID_Set_Disposition) -> bool {
	return disposition == .Applied || disposition == .Applied_Mismatch || disposition == .May_Have_Applied
}

EDID_Result :: struct {
	request_id: u32,
	generation: u32,
	mode: EDID_Mode,
	mode_known: bool,
	error: EDID_Protocol_Error,
	disposition: EDID_Set_Disposition,
}

EDID_Property_Proc :: proc(
	ctx: rawptr,
	property_id, flags: u32,
	data: rawptr,
	data_length: u32,
	bytes_returned: ^u32,
) -> bool

EDID_Cancelled_Proc :: proc(ctx: rawptr) -> bool

EDID_Transport :: struct {
	ctx: rawptr,
	property: EDID_Property_Proc,
	cancelled: EDID_Cancelled_Proc,
	poll_delay: time.Duration,
	poll_limit: u32,
}

EDID_COMMAND_PROTOCOL_VERSION :: u32(0x67)
EDID_COMMAND_SET_MODE         :: u32(0x4d)
EDID_COMMAND_GET_MODE         :: u32(0x4e)
EDID_PROTOCOL_VERSION         :: u8(4)
EDID_PROPERTY_DATA            :: u32(1)
EDID_PROPERTY_LENGTH          :: u32(2)
EDID_PROPERTY_GET             :: u32(1)
EDID_PROPERTY_SET             :: u32(2)
EDID_MAX_TRANSFER             :: u32(512)
EDID_DEFAULT_POLL_LIMIT       :: u32(100)
EDID_DEFAULT_POLL_DELAY       :: 10*time.Millisecond
EDID_READ_ATTEMPTS            :: 3

edid_mode_device_value :: proc(mode: EDID_Mode) -> (u32, bool) {
	switch mode {
	case .Internal: return 0, true
	case .Display:  return 1, true
	case .Merged:   return 4, true
	}
	return 0, false
}

edid_mode_from_device :: proc(value: u8) -> (EDID_Mode, bool) {
	switch value {
	case 0: return .Internal, true
	case 1: return .Display, true
	case 4: return .Merged, true
	}
	return .Internal, false
}

edid_mode_name :: proc(mode: EDID_Mode) -> cstring {
	switch mode {
	case .Internal: return "Internal"
	case .Display:  return "Display"
	case .Merged:   return "Merged (recommended)"
	}
	return "Unknown"
}

edid_transport_cancelled :: proc(transport: ^EDID_Transport) -> bool {
	return transport != nil && transport.cancelled != nil && transport.cancelled(transport.ctx)
}

edid_property_write :: proc(
	transport: ^EDID_Transport,
	property_id: u32,
	data: rawptr,
	data_length: u32,
) -> EDID_Protocol_Error {
	if transport == nil || transport.property == nil do return .Unsupported
	if edid_transport_cancelled(transport) do return .Cancelled
	returned: u32
	if !transport.property(transport.ctx, property_id, EDID_PROPERTY_SET, data, data_length, &returned) {
		return .Transfer_Failed
	}
	if returned > data_length do return .Invalid_Transfer_Count
	return .None
}

// RTICE wraps the inner AT command in a service byte, body length, two zero
// bytes, and an additive checksum. Identification uses service A0; EDID uses
// A1. The raw little-endian command alone is not a valid USB request.
edid_service :: proc(command: u32) -> u8 {
	return 0xa0 if command == EDID_COMMAND_PROTOCOL_VERSION else 0xa1
}

edid_checksum :: proc(bytes: []u8) -> u8 {
	sum: u8
	for value in bytes do sum += value
	return 0-sum
}

edid_encode_request :: proc(command: u32, input, packet: []u8) -> (int, EDID_Protocol_Error) {
	// Only the short RTICE framing is needed by these commands. Do not silently
	// encode a long request using the short length field.
	if len(input) > 120 || len(packet) < len(input)+9 do return 0, .Response_Too_Large
	packet_length := len(input)+9
	packet[0] = edid_service(command)
	packet[1] = u8(len(input)+6)
	packet[2], packet[3] = 0, 0
	packet[4] = u8(command)
	packet[5] = u8(command >> 8)
	packet[6] = u8(command >> 16)
	packet[7] = u8(command >> 24)
	copy(packet[8:], input)
	packet[packet_length-1] = edid_checksum(packet[:packet_length-1])
	return packet_length, .None
}

edid_decode_response :: proc(command: u32, response, output: []u8) -> EDID_Protocol_Error {
	if len(response) < 3 do return .Unexpected_Response_Length
	if response[1] >= 0x80 || int(response[1])+3 != len(response) do return .Unexpected_Response_Length
	if edid_checksum(response) != 0 do return .Response_Checksum
	service := edid_service(command)
	if response[0] == ~service do return .Device_Rejected
	if response[0] != service do return .Response_Header
	if len(response) != len(output)+5 do return .Unexpected_Response_Length
	copy(output, response[4:len(response)-1])
	return .None
}

// Properties 2 and 1 carry the outer frame's length and bytes respectively.
edid_command :: proc(
	transport: ^EDID_Transport,
	command: u32,
	input: []u8,
	output: []u8,
) -> EDID_Protocol_Error {
	if len(output) > int(EDID_MAX_TRANSFER) {
		return .Response_Too_Large
	}
	packet: [EDID_MAX_TRANSFER]u8
	encoded_length, encode_error := edid_encode_request(command, input, packet[:])
	if encode_error != .None do return encode_error
	packet_length := u16(encoded_length)
	error := edid_property_write(transport, EDID_PROPERTY_LENGTH, &packet_length, size_of(packet_length))
	if error == .Cancelled do return error
	if error != .None do return .Length_Write_Failed
	error = edid_property_write(transport, EDID_PROPERTY_DATA, &packet[0], u32(packet_length))
	if error != .None do return .Write_Failed

	poll_limit := transport.poll_limit
	if poll_limit == 0 do poll_limit = EDID_DEFAULT_POLL_LIMIT
	poll_delay := transport.poll_delay
	if poll_delay == 0 do poll_delay = EDID_DEFAULT_POLL_DELAY
	response_length: u16
	for _ in 0..<poll_limit {
		// The inspected vendor transport deliberately ignores BytesReturned for
		// this two-byte readiness query and trusts the populated length field.
		// Match that tolerance, but reject partial or oversized nonzero counts.
		returned: u32
		if edid_transport_cancelled(transport) do return .Cancelled
		if !transport.property(transport.ctx, EDID_PROPERTY_LENGTH, EDID_PROPERTY_GET, &response_length, size_of(response_length), &returned) {
			return .Transfer_Failed
		}
		if returned != 0 && returned != size_of(response_length) do return .Invalid_Transfer_Count
		if response_length != 0 do break
		if edid_transport_cancelled(transport) do return .Cancelled
		if poll_delay > 0 do time.sleep(poll_delay)
	}
	if response_length == 0 do return .Response_Timeout
	if response_length > u16(EDID_MAX_TRANSFER) do return .Response_Too_Large
	response: [EDID_MAX_TRANSFER]u8
	returned: u32
	if edid_transport_cancelled(transport) do return .Cancelled
	if !transport.property(transport.ctx, EDID_PROPERTY_DATA, EDID_PROPERTY_GET, &response[0], EDID_MAX_TRANSFER, &returned) {
		return .Transfer_Failed
	}
	// The XU control itself is a fixed 512-byte transfer on some driver builds;
	// property 2 defines how many leading bytes are meaningful. Accept either
	// an exact byte count or the fixed transfer, but never a short/oversized one.
	if returned < u32(response_length) || returned > EDID_MAX_TRANSFER do return .Invalid_Transfer_Count
	return edid_decode_response(command, response[:response_length], output)
}

edid_validate_protocol :: proc(transport: ^EDID_Transport) -> EDID_Protocol_Error {
	response: [4]u8
	error := edid_query_command(transport, EDID_COMMAND_PROTOCOL_VERSION, response[:])
	if error != .None do return error
	if response != ([4]u8{EDID_PROTOCOL_VERSION, 0, 0, 0}) do return .Protocol_Version
	return .None
}

// The vendor read path makes three attempts. Retrying identification and GET
// commands is safe; SET deliberately continues to call edid_command directly
// so an uncertain write can never be issued twice.
edid_query_command :: proc(transport: ^EDID_Transport, command: u32, output: []u8) -> EDID_Protocol_Error {
	error := EDID_Protocol_Error.None
	for _ in 0..<EDID_READ_ATTEMPTS {
		error = edid_command(transport, command, nil, output)
		if error == .None || error == .Cancelled do return error
		if error != .Response_Timeout && error != .Transfer_Failed &&
		   error != .Length_Write_Failed && error != .Write_Failed {
			return error
		}
	}
	return error
}

edid_read_mode :: proc(transport: ^EDID_Transport) -> (EDID_Mode, EDID_Protocol_Error) {
	error := edid_validate_protocol(transport)
	if error != .None do return .Internal, error
	response: [4]u8
	error = edid_query_command(transport, EDID_COMMAND_GET_MODE, response[:])
	if error != .None do return .Internal, error
	if response[1] != 0 || response[2] != 0 || response[3] != 0 do return .Internal, .Unknown_Mode
	mode, known := edid_mode_from_device(response[0])
	if !known do return .Internal, .Unknown_Mode
	return mode, .None
}

edid_set_mode :: proc(transport: ^EDID_Transport, requested: EDID_Mode) -> (EDID_Mode, bool, EDID_Set_Disposition, EDID_Protocol_Error) {
	current, error := edid_read_mode(transport)
	if error != .None do return .Internal, false, .Not_Applied, error
	if current == requested do return current, true, .Not_Applied, .None
	device_value, valid := edid_mode_device_value(requested)
	if !valid do return current, true, .Not_Applied, .Unknown_Mode
	payload := [4]u8{u8(device_value), u8(device_value>>8), u8(device_value>>16), u8(device_value>>24)}
	response: [4]u8
	error = edid_command(transport, EDID_COMMAND_SET_MODE, payload[:], response[:])
	if error == .Length_Write_Failed do return current, true, .Not_Applied, error
	if error != .None do return .Internal, false, .May_Have_Applied, error
	actual, readback_error := edid_read_mode(transport)
	if readback_error != .None do return .Internal, false, .May_Have_Applied, .Readback_Failed
	if actual != requested do return actual, true, .Applied_Mismatch, .Readback_Mismatch
	return actual, true, .Applied, .None
}
