module api

struct Events {
mut:
	data []string
}

// parse feeds `body` to a parser in pieces of `step` bytes, then ends the body.
fn parse(body string, step int) ![]string {
	mut events := &Events{}
	on_event := fn [mut events] (data string) ! {
		events.data << data
	}
	mut parser := EventStreamParser{}
	bytes := body.bytes()
	for i := 0; i < bytes.len; i += step {
		end := if i + step < bytes.len { i + step } else { bytes.len }
		parser.feed(bytes[i..end], on_event)!
	}
	parser.finish(on_event)!
	return events.data
}

fn test_events_in_any_pieces() {
	body := 'data: {"a":1}\n\ndata: {"b":"é"}\r\n\r\ndata: [DONE]\n\n'
	for step in [1, 2, 3, 7, 4096] {
		assert parse(body, step)! == ['{"a":1}', '{"b":"é"}']
	}
}

fn test_multiline_event() {
	body := 'data: {\ndata: "a": 1\ndata: }\n\ndata:{"b":2}\n\n'
	for step in [1, 5, 4096] {
		assert parse(body, step)! == ['{\n"a": 1\n}', '{"b":2}']
	}
}

fn test_ignores_comments_and_other_fields() {
	body := ': keep-alive\n\nevent: message\nid: 1\ndata: {"a":1}\nretry: 10\n\n'
	assert parse(body, 3)! == ['{"a":1}']
}

fn test_stops_on_done() {
	body := 'data: {"a":1}\n\ndata: [DONE]\n\ndata: {"b":2}\n\n'
	assert parse(body, 4096)! == ['{"a":1}']
	assert parse(body, 1)! == ['{"a":1}']
}

fn test_last_event_without_blank_line() {
	assert parse('data: {"a":1}', 4)! == ['{"a":1}']
	assert parse('data: {"a":1}\n', 4)! == ['{"a":1}']
}

fn test_callback_error_is_returned() {
	mut parser := EventStreamParser{}
	parser.feed('data: x\n\n'.bytes(), fn (data string) ! {
		return error('bad event: ${data}')
	}) or {
		assert err.msg() == 'bad event: x'
		return
	}
	assert false
}
