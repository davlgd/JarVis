module api

import json2
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

fn test_long_answer_and_long_error_body() {
	mut body := ''
	for _ in 0 .. 3000 {
		body += 'data: {"choices":[{"delta":{"content":"word "}}]}\n\n'
	}
	body += 'data: [DONE]\n\n'
	headers := 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n'
	assert body.len > max_error_body
	assert complete_from([headers, body])! == 'word '.repeat(3000)

	error_body := 'x'.repeat(max_error_body + 10)
	error_headers := 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: ${error_body.len}\r\n\r\n'
	complete_from([error_headers, error_body]) or {
		assert err.msg() == 'Chat completion API error (500): ${error_body[..max_error_body]}'
		return
	}
	assert false
}

fn sse_response(body string) []string {
	return [
		'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n',
		body,
	]
}

fn test_optional_request_fields_are_only_sent_when_set() {
	plain := json2.encode(CompletionRequest{
		model: 'm'
	})
	assert !plain.contains('reasoning_effort')
	assert !plain.contains('max_tokens')
	set := json2.encode(CompletionRequest{
		model:            'm'
		reasoning_effort: 'none'
		max_tokens:       2048
	})
	assert set.contains('"reasoning_effort":"none"')
	assert set.contains('"max_tokens":2048')
}

fn test_length_limit() {
	reasoning := 'data: {"choices":[{"delta":{"content":"","reasoning":"hmm"}}]}\n\n'
	stop := 'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\ndata: [DONE]\n\n'
	complete_from(sse_response(reasoning + stop)) or {
		assert err.msg() == 'The model reached its length limit before answering (finish_reason: length)'
		assert err is FinishError
		if err is FinishError {
			assert err.reason == 'length'
			assert !err.received
		}
		return
	}
	assert false
}

fn test_answer_cut_by_length_limit() {
	content := 'data: {"choices":[{"delta":{"content":"hel"}}]}\n\n'
	stop := 'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\ndata: [DONE]\n\n'
	complete_from(sse_response(content + stop)) or {
		assert err.msg() == 'The answer was cut by the length limit (finish_reason: length)'
		return
	}
	assert false
}

fn test_content_filter() {
	stop := 'data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}\n\ndata: [DONE]\n\n'
	complete_from(sse_response(stop)) or {
		assert err.msg() == 'The answer was blocked by the content filter (finish_reason: content_filter)'
		return
	}
	assert false
}

fn test_api_error_has_its_status() {
	body := '{"error":"model not found"}'
	complete_from(['HTTP/1.1 404 Not Found\r\nContent-Length: ${body.len}\r\n\r\n', body]) or {
		assert err is ApiError
		if err is ApiError {
			assert err.status == 404
			assert err.body == body
		}
		return
	}
	assert false
}

fn test_unreachable_server_is_a_request_error() {
	// A port with nothing listening on it
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close()!
	client := new_client(Config{
		api_host:  '127.0.0.1'
		api_port:  port.str()
		api_model: 'test'
	})!
	if _ := client.list_models() {
		assert false, 'list_models succeeded'
	} else {
		assert err is RequestError
		assert err.msg().starts_with('Models request failed: ')
	}
	if _ := client.complete('hi') {
		assert false, 'complete succeeded'
	} else {
		assert err is RequestError
		assert err.msg().starts_with('Chat completion request failed: ')
	}
}

struct Received {
mut:
	reasoning []string
	content   []string
}

fn test_reasoning_is_given_to_its_callback() {
	body := 'data: {"choices":[{"delta":{"content":"","reasoning":"think "}}]}\n\n' +
		'data: {"choices":[{"delta":{"content":"","reasoning_content":"more"}}]}\n\n' +
		'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n'
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		listener.close() or {}
	}
	port := listener.addr()!.port()!
	spawn serve(mut listener, sse_response(body))
	client := new_client(Config{
		api_host:  '127.0.0.1'
		api_port:  port.str()
		api_model: 'test'
	})!
	mut received := &Received{}
	client.stream_completion_with_reasoning('hi', fn [mut received] (reasoning string) {
		received.reasoning << reasoning
	}, fn [mut received] (chunk string) {
		received.content << chunk
	})!
	assert received.reasoning == ['think ', 'more']
	assert received.content == ['hello']
}
