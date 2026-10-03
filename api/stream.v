module api

import net
import net.ssl
import strconv
import time

struct StreamReader {
mut:
	tcp_conn &net.TcpConn
	ssl_conn ?&ssl.SSLConn
	use_tls  bool
}

fn new_stream_reader(host string, port string, use_tls bool) !&StreamReader {
	mut tcp_conn := net.dial_tcp('${host}:${port}')!
	tcp_conn.set_read_timeout(timeout_seconds * time.second)
	tcp_conn.set_write_timeout(timeout_seconds * time.second)

	return &StreamReader{
		tcp_conn: tcp_conn
		ssl_conn: if use_tls {
			mut conn := ssl.new_ssl_conn()!
			conn.connect(mut tcp_conn, host)!
			conn
		} else {
			none
		}
		use_tls:  use_tls
	}
}

fn (mut sr StreamReader) send_request(request_str string) ! {
	if sr.use_tls {
		if mut conn := sr.ssl_conn {
			conn.write_string(request_str)!
		}
	} else {
		sr.tcp_conn.write_string(request_str)!
	}
}

fn (mut sr StreamReader) close() {
	if sr.use_tls {
		if mut conn := sr.ssl_conn {
			conn.shutdown() or {}
		}
	}
	sr.tcp_conn.close() or {}
}

fn (mut sr StreamReader) read(mut buffer []u8) !int {
	if sr.use_tls {
		if mut conn := sr.ssl_conn {
			return conn.read(mut buffer)!
		}
		return 0
	}
	return sr.tcp_conn.read(mut buffer)!
}

// read_stream reads the HTTP response and calls `callback` with the data of each
// server-sent event, until `data: [DONE]` or the end of the connection.
fn (mut sr StreamReader) read_stream(callback fn (string) !) ! {
	mut parser := EventStreamParser{}
	mut buffer := []u8{len: 4096}
	for !parser.done {
		n := sr.read(mut buffer)!
		if n <= 0 {
			parser.finish(callback)!
			return
		}
		parser.feed(buffer[..n], callback)!
	}
}

// EventStreamParser turns the raw bytes of an HTTP response carrying server-sent
// events into event data. Bytes can be fed in pieces of any size: headers, chunks
// (chunked transfer encoding) and lines may be split across reads.
struct EventStreamParser {
mut:
	raw          []u8 // received bytes not decoded yet
	body         []u8 // decoded body bytes not split into lines yet
	headers_done bool
	status       int
	chunked      bool
	chunk_left   int  // bytes left in the current chunk
	chunk_crlf   bool // the CRLF ending the current chunk is still expected
	body_done    bool // the last chunk was received
	done         bool // `data: [DONE]` was received
}

fn (mut p EventStreamParser) feed(data []u8, callback fn (string) !) ! {
	p.raw << data
	if !p.headers_done {
		end := index_of(p.raw, '\r\n\r\n')
		if end < 0 {
			return
		}
		p.parse_headers(p.raw[..end].bytestr())!
		p.raw = p.raw[end + 4..].clone()
	}
	p.decode_body()!
	if p.status != 200 {
		return error('API error (${p.status}): ${p.body.bytestr().trim_space()}')
	}
	p.emit_lines(callback)!
}

// finish handles the end of the connection: what is left of the body is a last line.
fn (mut p EventStreamParser) finish(callback fn (string) !) ! {
	if !p.headers_done {
		return error('Connection closed before the response headers were received')
	}
	if p.status != 200 {
		return error('API error (${p.status}): ${p.body.bytestr().trim_space()}')
	}
	if !p.done && p.body.len > 0 {
		p.body << `\n`
		p.emit_lines(callback)!
	}
}

fn (mut p EventStreamParser) parse_headers(head string) ! {
	lines := head.split('\r\n')
	status_line := lines[0].split(' ')
	if status_line.len < 2 || !status_line[0].starts_with('HTTP/') {
		return error('Invalid HTTP response: ${lines[0]}')
	}
	p.status = status_line[1].int()
	for line in lines[1..] {
		name := line.all_before(':').trim_space().to_lower()
		value := line.all_after(':').trim_space().to_lower()
		if name == 'transfer-encoding' && value.contains('chunked') {
			p.chunked = true
		}
	}
	p.headers_done = true
}

// decode_body moves the received bytes to the body, removing the chunked transfer
// encoding framing when the response uses it.
fn (mut p EventStreamParser) decode_body() ! {
	if !p.chunked {
		p.body << p.raw
		p.raw.clear()
		return
	}
	for !p.body_done {
		if p.chunk_left > 0 {
			take := if p.chunk_left < p.raw.len { p.chunk_left } else { p.raw.len }
			p.body << p.raw[..take]
			p.raw = p.raw[take..].clone()
			p.chunk_left -= take
			if p.chunk_left > 0 {
				return
			}
			p.chunk_crlf = true
		}
		if p.chunk_crlf {
			if p.raw.len < 2 {
				return
			}
			p.raw = p.raw[2..].clone()
			p.chunk_crlf = false
		}
		end := index_of(p.raw, '\r\n')
		if end < 0 {
			return
		}
		size_line := p.raw[..end].bytestr().all_before(';').trim_space()
		size := strconv.parse_int(size_line, 16, 32) or {
			return error('Invalid chunk size: "${size_line}"')
		}
		p.raw = p.raw[end + 2..].clone()
		if size == 0 {
			p.body_done = true
			return
		}
		p.chunk_left = int(size)
	}
}

// emit_lines calls `callback` with the data of each complete `data:` line.
fn (mut p EventStreamParser) emit_lines(callback fn (string) !) ! {
	for !p.done {
		end := index_of(p.body, '\n')
		if end < 0 {
			return
		}
		line := p.body[..end].bytestr().trim_space()
		p.body = p.body[end + 1..].clone()

		if !line.starts_with('data:') {
			continue
		}
		data := line[5..].trim_space()
		// The server may keep the connection open after the last event:
		// stop on `[DONE]` instead of waiting for the read to time out.
		if data == '[DONE]' {
			p.done = true
			return
		}
		if data.len == 0 {
			continue
		}
		callback(data)!
	}
}

fn index_of(haystack []u8, needle string) int {
	if needle.len == 0 || haystack.len < needle.len {
		return -1
	}
	for i in 0 .. haystack.len - needle.len + 1 {
		mut found := true
		for j in 0 .. needle.len {
			if haystack[i + j] != needle[j] {
				found = false
				break
			}
		}
		if found {
			return i
		}
	}
	return -1
}
