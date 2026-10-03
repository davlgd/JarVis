module api

struct Events {
mut:
	data []string
}

// parse feeds `response` to a parser in pieces of `step` bytes, then ends the stream.
fn parse(response string, step int) ![]string {
	mut events := &Events{}
	callback := fn [mut events] (data string) ! {
		events.data << data
	}
	mut parser := EventStreamParser{}
	bytes := response.bytes()
	for i := 0; i < bytes.len && !parser.done; i += step {
		end := if i + step < bytes.len { i + step } else { bytes.len }
		parser.feed(bytes[i..end], callback)!
	}
	if !parser.done {
		parser.finish(callback)!
	}
	return events.data
}

fn chunked(body string, size int) string {
	mut out := ''
	for i := 0; i < body.len; i += size {
		part := body#[i..i + size]
		out += '${part.len:x}\r\n${part}\r\n'
	}
	return out + '0\r\n\r\n'
}

const events_body = 'data: {"a":1}\n\ndata: {"b":"é"}\n\ndata: [DONE]\n\n'

fn test_plain_body_in_any_pieces() {
	response := 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n${events_body}'
	for step in [1, 2, 3, 7, 4096] {
		assert parse(response, step)! == ['{"a":1}', '{"b":"é"}']
	}
}

fn test_chunked_body_split_inside_events() {
	response := 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + chunked(events_body, 5)
	for step in [1, 3, 11, 4096] {
		assert parse(response, step)! == ['{"a":1}', '{"b":"é"}']
	}
}

fn test_stops_on_done() {
	response := 'HTTP/1.1 200 OK\r\n\r\ndata: {"a":1}\n\ndata: [DONE]\n\ndata: {"b":2}\n\n'
	assert parse(response, 4096)! == ['{"a":1}']
}

fn test_last_line_without_newline() {
	response := 'HTTP/1.1 200 OK\r\n\r\ndata: {"a":1}'
	assert parse(response, 4)! == ['{"a":1}']
}

fn test_http_error() {
	response := 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"error":"model not found"}'
	parse(response, 4096) or {
		assert err.msg() == 'API error (404): {"error":"model not found"}'
		return
	}
	assert false
}

fn test_closed_before_headers() {
	parse('HTTP/1.1 200 OK\r\n', 4096) or {
		assert err.msg().contains('before the response headers')
		return
	}
	assert false
}
