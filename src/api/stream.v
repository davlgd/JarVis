module api

import net.ssl
import net

struct StreamReader {
mut:
    tcp_conn &net.TcpConn
    ssl_conn ?&ssl.SSLConn
    use_tls  bool
}

fn new_stream_reader(host string, port string, use_tls bool) !&StreamReader {
    mut tcp_conn := net.dial_tcp('${host}:${port}')!

    return &StreamReader{
        tcp_conn: tcp_conn
        ssl_conn: if use_tls {
            mut conn := ssl.new_ssl_conn()!
            conn.connect(mut tcp_conn, host)!
            conn
        } else {
            none
        }
        use_tls: use_tls
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

fn (mut sr StreamReader) read_stream(callback fn (string) !) ! {
    mut headers_done := false
    mut line := ''
    mut buffer := []u8{len: 4096}

    for {
        n := if sr.use_tls {
            if mut conn := sr.ssl_conn {
                conn.read(mut buffer)!
            } else {
                0
            }
        } else {
            sr.tcp_conn.read(mut buffer)!
        }

        if n <= 0 {
            break
        }

        chunk := buffer[..n].bytestr()

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