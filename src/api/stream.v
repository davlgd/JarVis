module api

import net.ssl
import net

struct StreamReader {
mut:
    tcp_conn &net.TcpConn
    ssl_conn &ssl.SSLConn
    buffer   []u8
    line     string
}

fn new_stream_reader(host string, port string) !&StreamReader {
    mut tcp_conn := net.dial_tcp('${host}:${port}')!
    mut ssl_conn := ssl.new_ssl_conn()!
    ssl_conn.connect(mut tcp_conn, host)!

    return &StreamReader{
        tcp_conn: tcp_conn
        ssl_conn: ssl_conn
        buffer: []u8{len: 4096}
        line: ''
    }
}

fn (mut sr StreamReader) send_request(request_str string) ! {
    sr.ssl_conn.write_string(request_str)!
}

fn (mut sr StreamReader) close() {
    sr.ssl_conn.shutdown() or {}
    sr.tcp_conn.close() or {}
}

fn (mut sr StreamReader) read_stream(callback fn (string) !) ! {
    mut headers_done := false
    mut line := ''

    for {
        n := sr.ssl_conn.read(mut sr.buffer)!
        if n <= 0 {
            break
        }

        chunk := sr.buffer[..n].bytestr()

        if !headers_done {
            if chunk.contains('\r\n\r\n') {
                parts := chunk.split('\r\n\r\n')
                if parts.len > 1 {
                    headers_done = true
                    line = parts[1]
                }
            }
            continue
        }

        line += chunk

        for line.contains('\n') {
            pos := line.index('\n') or { continue }
            current_line := line[..pos].trim_space()
            line = line[pos + 1..]

            if !current_line.starts_with('data: ') {
                continue
            }

            line_data := current_line[6..]
            if line_data == '[DONE]' || line_data.len == 0 {
                continue
            }

            callback(line_data)!
        }
    }
}