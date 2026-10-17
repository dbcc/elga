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

// HDMI input range conversion applied by the card.
Color_Range :: enum u32 {
	Auto,
	Expand,
	Shrink,
}

EDID_Request_Kind :: enum u32 {
	None,
	// Reads both the EDID mode and the color range.
	Refresh,
	Set,
	Set_Color_Range,
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
	Unknown_Color_Range,
}

@(rodata)
EDID_ERROR_TEXT := [EDID_Protocol_Error]cstring{
	.None                       = "none",
	.Cancelled                  = "operation cancelled",
	.Unsupported                = "extension unavailable",
	.Transfer_Failed            = "device transfer failed",
	.Invalid_Transfer_Count     = "invalid device transfer count",
	.Response_Timeout           = "device response timed out",
	.Response_Too_Large         = "device response was too large",
	.Unexpected_Response_Length = "unexpected device response length",
	.Protocol_Version           = "unsupported protocol version",
	.Unknown_Mode               = "card returned an unknown mode",
	.Length_Write_Failed        = "request-length write failed",
	.Write_Failed               = "request-data write failed",
	.Readback_Failed            = "mode readback failed",
	.Readback_Mismatch          = "mode readback did not match",
	.Response_Header            = "unexpected device response header",
	.Response_Checksum          = "device response checksum failed",
	.Device_Rejected            = "device rejected the request",
	.Unknown_Color_Range        = "card returned an unknown color range",
}

@(rodata)
EDID_MODE_NAME := [EDID_Mode]cstring{
	.Internal = "Internal",
	.Display  = "Display",
	.Merged   = "Merged (recommended)",
}

// The card's protocol values for each mode.
@(rodata)
EDID_MODE_DEVICE_VALUE := [EDID_Mode]u8{
	.Internal = 0,
	.Display  = 1,
	.Merged   = 4,
}

@(rodata)
COLOR_RANGE_NAME := [Color_Range]cstring{
	.Auto   = "Auto (recommended)",
	.Expand = "Expand",
	.Shrink = "Shrink",
}

// The card's protocol values for each color range setting.
@(rodata)
COLOR_RANGE_DEVICE_VALUE := [Color_Range]u8{
	.Auto   = 0,
	.Expand = 3,
	.Shrink = 4,
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
	kind: EDID_Request_Kind,
	mode: EDID_Mode,
	mode_known: bool,
	error: EDID_Protocol_Error,
	disposition: EDID_Set_Disposition,
	// Color range outcome. It never requires a capture reconnect.
	color_range: Color_Range,
	color_range_known: bool,
	color_range_error: EDID_Protocol_Error,
	color_range_disposition: EDID_Set_Disposition,
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
EDID_COMMAND_SET_COLOR_RANGE  :: u32(0x7c)
EDID_COMMAND_GET_COLOR_RANGE  :: u32(0x91)
// Elgato's driver sends this as the first payload byte of both color range
// commands; the setting itself is the second SET byte and the first GET byte.
COLOR_RANGE_SELECTOR          :: u8(1)
EDID_PROTOCOL_VERSION         :: u8(4)
EDID_PROPERTY_DATA            :: u32(1)
EDID_PROPERTY_LENGTH          :: u32(2)
EDID_PROPERTY_GET             :: u32(1)
EDID_PROPERTY_SET             :: u32(2)
EDID_MAX_TRANSFER             :: u32(512)
EDID_DEFAULT_POLL_LIMIT       :: u32(100)
EDID_DEFAULT_POLL_DELAY       :: 10*time.Millisecond
EDID_READ_ATTEMPTS            :: 3

edid_mode_from_device :: proc(value: u8) -> (EDID_Mode, bool) {
	for device_value, mode in EDID_MODE_DEVICE_VALUE {
		if device_value == value do return mode, true
	}
	return .Internal, false
}

color_range_from_device :: proc(value: u8) -> (Color_Range, bool) {
	for device_value, range in COLOR_RANGE_DEVICE_VALUE {
		if device_value == value do return range, true
	}
	return .Auto, false
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

// Decodes a reply whose payload must fill output exactly.
edid_decode_response :: proc(command: u32, response, output: []u8) -> EDID_Protocol_Error {
	length, error := edid_decode_reply(command, response, output)
	if error == .None && length != len(output) do return .Unexpected_Response_Length
	return error
}

// Decodes a reply payload of at most len(output) bytes and returns its length.
edid_decode_reply :: proc(command: u32, response, output: []u8) -> (int, EDID_Protocol_Error) {
	if len(response) < 3 do return 0, .Unexpected_Response_Length
	if response[1] >= 0x80 || int(response[1])+3 != len(response) do return 0, .Unexpected_Response_Length
	if edid_checksum(response) != 0 do return 0, .Response_Checksum
	service := edid_service(command)
	if response[0] == ~service do return 0, .Device_Rejected
	if response[0] != service do return 0, .Response_Header
	// A bare acknowledgement, such as the color range SET reply A1 00 5F,
	// has an empty body: no prefix bytes and no payload.
	if response[1] == 0 do return 0, .None
	length := len(response)-5
	if length < 0 || length > len(output) do return 0, .Unexpected_Response_Length
	copy(output, response[4:len(response)-1])
	return length, .None
}

// Runs a command whose reply payload must fill output exactly.
edid_command :: proc(
	transport: ^EDID_Transport,
	command: u32,
	input: []u8,
	output: []u8,
) -> EDID_Protocol_Error {
	length, error := edid_command_reply(transport, command, input, output)
	if error == .None && length != len(output) do return .Unexpected_Response_Length
	return error
}

// Properties 2 and 1 carry the outer frame's length and bytes respectively.
// Returns the reply payload length, which may be shorter than output.
edid_command_reply :: proc(
	transport: ^EDID_Transport,
	command: u32,
	input: []u8,
	output: []u8,
) -> (int, EDID_Protocol_Error) {
	if len(output) > int(EDID_MAX_TRANSFER) {
		return 0, .Response_Too_Large
	}
	packet: [EDID_MAX_TRANSFER]u8
	encoded_length, encode_error := edid_encode_request(command, input, packet[:])
	if encode_error != .None do return 0, encode_error
	packet_length := u16(encoded_length)
	error := edid_property_write(transport, EDID_PROPERTY_LENGTH, &packet_length, size_of(packet_length))
	if error == .Cancelled do return 0, error
	if error != .None do return 0, .Length_Write_Failed
	error = edid_property_write(transport, EDID_PROPERTY_DATA, &packet[0], u32(packet_length))
	if error != .None do return 0, .Write_Failed

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
		if edid_transport_cancelled(transport) do return 0, .Cancelled
		if !transport.property(transport.ctx, EDID_PROPERTY_LENGTH, EDID_PROPERTY_GET, &response_length, size_of(response_length), &returned) {
			return 0, .Transfer_Failed
		}
		if returned != 0 && returned != size_of(response_length) do return 0, .Invalid_Transfer_Count
		if response_length != 0 do break
		if edid_transport_cancelled(transport) do return 0, .Cancelled
		if poll_delay > 0 do time.sleep(poll_delay)
	}
	if response_length == 0 do return 0, .Response_Timeout
	if response_length > u16(EDID_MAX_TRANSFER) do return 0, .Response_Too_Large
	response: [EDID_MAX_TRANSFER]u8
	returned: u32
	if edid_transport_cancelled(transport) do return 0, .Cancelled
	if !transport.property(transport.ctx, EDID_PROPERTY_DATA, EDID_PROPERTY_GET, &response[0], EDID_MAX_TRANSFER, &returned) {
		return 0, .Transfer_Failed
	}
	// The XU control itself is a fixed 512-byte transfer on some driver builds;
	// property 2 defines how many leading bytes are meaningful. Accept either
	// an exact byte count or the fixed transfer, but never a short/oversized one.
	if returned < u32(response_length) || returned > EDID_MAX_TRANSFER do return 0, .Invalid_Transfer_Count
	return edid_decode_reply(command, response[:response_length], output)
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
// so an uncertain write can never be issued twice. A malformed reply is retried
// too: shortly after streaming starts, the card has answered a protocol query
// with a frame that was not RTICE (64 04 F0 0C 06 00 00 00 00).
edid_query_command :: proc(transport: ^EDID_Transport, command: u32, output: []u8) -> EDID_Protocol_Error {
	length, error := edid_query_reply(transport, command, nil, output)
	if error == .None && length != len(output) do return .Unexpected_Response_Length
	return error
}

EDID_RETRYABLE_ERRORS :: bit_set[EDID_Protocol_Error]{
	.Response_Timeout, .Transfer_Failed, .Length_Write_Failed, .Write_Failed,
	.Response_Header, .Response_Checksum, .Unexpected_Response_Length,
}

// edid_command_reply returns a zero length with every error.
edid_query_reply :: proc(transport: ^EDID_Transport, command: u32, input, output: []u8) -> (length: int, error: EDID_Protocol_Error) {
	for _ in 0..<EDID_READ_ATTEMPTS {
		length, error = edid_command_reply(transport, command, input, output)
		if error not_in EDID_RETRYABLE_ERRORS do break
	}
	return
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
	// The little-endian u32 mode value.
	payload := [4]u8{EDID_MODE_DEVICE_VALUE[requested], 0, 0, 0}
	response: [4]u8
	error = edid_command(transport, EDID_COMMAND_SET_MODE, payload[:], response[:])
	if error == .Length_Write_Failed do return current, true, .Not_Applied, error
	if error != .None do return .Internal, false, .May_Have_Applied, error
	actual, readback_error := edid_read_mode(transport)
	if readback_error != .None do return .Internal, false, .May_Have_Applied, .Readback_Failed
	if actual != requested do return actual, true, .Applied_Mismatch, .Readback_Mismatch
	return actual, true, .Applied, .None
}

// The vendor reads only the first reply byte; a wider reply is tolerated.
edid_read_color_range :: proc(transport: ^EDID_Transport) -> (Color_Range, EDID_Protocol_Error) {
	error := edid_validate_protocol(transport)
	if error != .None do return .Auto, error
	input := [1]u8{COLOR_RANGE_SELECTOR}
	response: [4]u8
	length: int
	length, error = edid_query_reply(transport, EDID_COMMAND_GET_COLOR_RANGE, input[:], response[:])
	if error != .None do return .Auto, error
	if length == 0 do return .Auto, .Unexpected_Response_Length
	range, known := color_range_from_device(response[0])
	if !known do return .Auto, .Unknown_Color_Range
	return range, .None
}

// Mirrors edid_set_mode: one write, never retried, confirmed by a separate read.
edid_set_color_range :: proc(transport: ^EDID_Transport, requested: Color_Range) -> (Color_Range, bool, EDID_Set_Disposition, EDID_Protocol_Error) {
	current, error := edid_read_color_range(transport)
	if error != .None do return .Auto, false, .Not_Applied, error
	if current == requested do return current, true, .Not_Applied, .None
	payload := [2]u8{COLOR_RANGE_SELECTOR, COLOR_RANGE_DEVICE_VALUE[requested]}
	// The vendor ignores this reply's payload; only its framing is checked.
	response: [16]u8
	_, error = edid_command_reply(transport, EDID_COMMAND_SET_COLOR_RANGE, payload[:], response[:])
	if error == .Length_Write_Failed do return current, true, .Not_Applied, error
	if error != .None do return .Auto, false, .May_Have_Applied, error
	actual, readback_error := edid_read_color_range(transport)
	if readback_error != .None do return .Auto, false, .May_Have_Applied, .Readback_Failed
	if actual != requested do return actual, true, .Applied_Mismatch, .Readback_Mismatch
	return actual, true, .Applied, .None
}
