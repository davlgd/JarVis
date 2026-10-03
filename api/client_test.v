module api

import net
import time

// serve answers one connection on a local port with `parts`, written one by one
// with a pause in between so that the client reads them separately.
fn serve(mut listener net.TcpListener, parts []string) {
	serve_and_hold(mut listener, parts, 0)
}

// serve_and_hold is serve, keeping the connection open for `hold` afterwards.
fn serve_and_hold(mut listener net.TcpListener, parts []string, hold time.Duration) {
	mut conn := listener.accept() or { return }
	defer {
		conn.close() or {}
	}
	mut buffer := []u8{len: 4096}
	conn.read(mut buffer) or { return }
	for part in parts {
		conn.write_string(part) or { return }
		time.sleep(50 * time.millisecond)
	}
	time.sleep(hold)
}

fn complete_from(parts []string) !string {
	return complete_from_held(parts, 0)
}

fn complete_from_held(parts []string, hold time.Duration) !string {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		listener.close() or {}
	}
	port := listener.addr()!.port()!
	spawn serve_and_hold(mut listener, parts, hold)
	client := new_client(Config{
		api_host:  '127.0.0.1'
		api_port:  port.str()
		api_model: 'test'
	})!
	return client.complete('hi')!
}

const event = 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'

fn test_status_line_split_across_reads() {
	headers := 'Content-Type: text/event-stream\r\nContent-Length: ${event.len}\r\n\r\n'
	for split in ['HTTP/1.1 2', 'HTTP/1.1 20', 'HTTP/1.1 200'] {
		rest := 'HTTP/1.1 200 OK\r\n'[split.len..]
		assert complete_from([split, rest + headers, event])! == 'hello'
	}
}

fn test_error_status_split_across_reads() {
	body := '{"error":"model not found"}'
	headers := 'Content-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n'
	for split in ['HTTP/1.1 4', 'HTTP/1.1 404'] {
		rest := 'HTTP/1.1 404 Not Found\r\n'[split.len..]
		complete_from([split, rest + headers, body]) or {
			assert err.msg() == 'Chat completion API error (404): ${body}'
			continue
		}
		assert false, 'no error for split "${split}"'
	}
}

fn test_error_event_after_content() {
	body := 'data: {"choices":[{"delta":{"content":"hel"}}]}\n\ndata: {"error":{"message":"generation failed","type":"server_error","code":null}}\n\ndata: [DONE]\n\n'
	headers := 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n'
	complete_from([headers, body]) or {
		assert err.msg() == 'Chat completion API error: generation failed'
		return
	}
	assert false
}

fn test_error_status_split_across_reads_with_event_body() {
	headers := 'Content-Type: text/event-stream\r\nContent-Length: ${event.len}\r\n\r\n'
	for split in ['HTTP/1.1 4', 'HTTP/1.1 42', 'HTTP/1.1 429'] {
		rest := 'HTTP/1.1 429 Too Many Requests\r\n'[split.len..]
		complete_from([split, rest + headers, event]) or {
			assert err.msg().starts_with('Chat completion API error (429)')
			continue
		}
		assert false, 'no error for split "${split}"'
	}
}

fn test_status_line_split_with_connection_left_open() {
	// Chunked body without its last chunk: only `[DONE]` ends the answer, and
	// the server keeps the connection open for longer than the test should take.
	for split in ['HTTP/1.1 2', 'HTTP/1.1 20'] {
		rest := 'HTTP/1.1 200 OK\r\n'[split.len..]
		headers := 'Content-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n'
		chunk := '${event.len:x}\r\n${event}\r\n'
		started := time.now()
		assert complete_from_held([split, rest + headers, chunk], 5 * time.second)! == 'hello'
		assert time.since(started) < 3 * time.second
	}
}

fn test_stream_ended_mid_answer() {
	headers := 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n'
	content := 'data: {"choices":[{"delta":{"content":"partial"}}]}'
	for body in ['${content}\n\n', content] {
		complete_from([headers, body]) or {
			assert err.msg() == 'The stream ended before the answer was complete'
			continue
		}
		assert false, 'no error for body "${body}"'
	}
}

fn test_finish_reason_without_done() {
	headers := 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n'
	body := 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
	assert complete_from([headers, body])! == 'hello'
}
