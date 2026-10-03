module api

import net
import time

// serve answers one connection on a local port with `parts`, written one by one
// with a pause in between so that the client reads them separately.
fn serve(mut listener net.TcpListener, parts []string) {
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
}

fn complete_from(parts []string) !string {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		listener.close() or {}
	}
	port := listener.addr()!.port()!
	spawn serve(mut listener, parts)
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
