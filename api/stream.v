module api

// EventStreamParser splits a server-sent events body into events. The body can
// be fed in pieces of any size: lines and events may be split across pieces.
struct EventStreamParser {
mut:
	buffer  []u8     // received bytes not split into lines yet
	data    []string // data fields of the event being read
	skip_lf bool     // the last line ended with CR: a LF right after it belongs to it
	done    bool     // `data: [DONE]` was received
}

// feed parses `bytes` and calls `on_event` with the data of each complete event.
fn (mut p EventStreamParser) feed(bytes []u8, on_event fn (string) !) ! {
	if p.done {
		return
	}
	p.buffer << bytes
	for !p.done {
		if p.skip_lf && p.buffer.len > 0 {
			if p.buffer[0] == `\n` {
				p.buffer = p.buffer[1..].clone()
			}
			p.skip_lf = false
		}
		// Lines end with CRLF, LF or CR
		mut end := -1
		for i, b in p.buffer {
			if b == `\n` || b == `\r` {
				end = i
				break
			}
		}
		if end < 0 {
			return
		}
		line := p.buffer[..end].bytestr()
		p.skip_lf = p.buffer[end] == `\r`
		p.buffer = p.buffer[end + 1..].clone()
		p.parse_line(line, on_event)!
	}
}

// finish handles the end of the body: what is left is the last line and event.
fn (mut p EventStreamParser) finish(on_event fn (string) !) ! {
	if p.done {
		return
	}
	if p.buffer.len > 0 {
		line := p.buffer.bytestr()
		p.buffer.clear()
		p.parse_line(line, on_event)!
	}
	p.dispatch(on_event)!
}

fn (mut p EventStreamParser) parse_line(line string, on_event fn (string) !) ! {
	// A blank line ends the event
	if line.len == 0 {
		p.dispatch(on_event)!
		return
	}
	// Comment
	if line.starts_with(':') {
		return
	}
	field := line.all_before(':')
	if field != 'data' {
		return
	}
	mut value := if line.contains(':') { line.all_after(':') } else { '' }
	if value.starts_with(' ') {
		value = value[1..]
	}
	p.data << value
}

// dispatch calls `on_event` with the data fields of the current event, joined by
// newlines, as the server-sent events specification describes.
fn (mut p EventStreamParser) dispatch(on_event fn (string) !) ! {
	if p.data.len == 0 {
		return
	}
	event := p.data.join('\n')
	p.data.clear()
	if event == '[DONE]' {
		p.done = true
		return
	}
	on_event(event)!
}
