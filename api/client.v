// Package api is a client for any OpenAI compatible API: list models, check one is
// available, and get chat completions, streamed or not.
module api

import json2
import net.http
import os
import strings

// default_system_prompt is the system prompt used when Config.system_prompt is not set.
pub const default_system_prompt = 'You are a helpful assistant named Jarvis, who helps developers to make their life easier every day through the CLI.
You make clear, concise, and structured answers, easy to read in a command line interface.'

// default_temperature is the sampling temperature used when Config.temperature is not set.
pub const default_temperature = 1.0

// Config describes the API server to talk to and how to query it.
pub struct Config {
pub:
	api_host  string
	api_port  string
	api_key   string
	api_model string
	api_tls   bool
	// With api_tls, the server certificate is checked against api_ca_file, a PEM
	// bundle of trusted CA certificates (default: the system bundle), unless
	// api_insecure is set (e.g. for a server with a self-signed certificate).
	api_ca_file   string
	api_insecure  bool
	system_prompt string = default_system_prompt
	temperature   f64    = default_temperature
}

// System bundles of trusted CA certificates, by platform
const ca_bundles = [
	'/etc/ssl/cert.pem', // macOS, Alpine, Arch
	'/etc/ssl/certs/ca-certificates.crt', // Debian, Ubuntu
	'/etc/pki/tls/certs/ca-bundle.crt', // Fedora, RHEL
	'/etc/ssl/ca-bundle.pem', // openSUSE
	'/usr/local/share/certs/ca-root-nss.crt', // FreeBSD
]

pub struct Client {
pub:
	config Config
}

struct Message {
	role    string
	content string
}

struct CompletionRequest {
	model       string
	messages    []Message
	temperature f64
	stream      bool
}

struct ChatDelta {
	content string
}

struct ChatChoice {
	delta         ChatDelta
	finish_reason string
}

struct ChatError {
	message string
}

struct ChatResponse {
	id      string
	object  string
	created int
	model   string
	choices []ChatChoice
	error   ChatError
}

// ApiError is an error status (non-200) returned by the API server.
pub struct ApiError {
	Error
pub:
	operation string // `Models` or `Chat completion`
	status    int
	body      string
}

// msg returns the operation, the status code and the body of the response.
pub fn (e ApiError) msg() string {
	return '${e.operation} API error (${e.status}): ${e.body}'
}

// RequestError is a request that got no response from the API server (e.g. the
// server cannot be reached).
pub struct RequestError {
	Error
pub:
	operation string // `Models` or `Chat completion`
	reason    string
}

// msg returns the operation and why it failed.
pub fn (e RequestError) msg() string {
	return '${e.operation} request failed: ${e.reason}'
}

// new_client returns a client for the API described by `config`.
pub fn new_client(config Config) !Client {
	return Client{
		config: config
	}
}

// stream_completion sends `prompt` to the configured model and calls `on_chunk` with
// each piece of the answer as soon as it is received.
pub fn (c Client) stream_completion(prompt string, on_chunk fn (string)) ! {
	request := CompletionRequest{
		model:       c.config.api_model
		messages:    [
			Message{
				role:    'system'
				content: c.config.system_prompt
			},
			Message{
				role:    'user'
				content: prompt
			},
		]
		temperature: c.config.temperature
		stream:      true
	}

	mut req := c.new_request(.post, '/v1/chat/completions', json2.encode(request))!
	req.add_header(.content_type, 'application/json')
	req.add_header(.accept, 'text/event-stream')
	// The body is parsed as it arrives, before net.http could decompress it.
	// Without this header, any content coding is acceptable (RFC 9110, 12.5.3).
	req.add_header(.accept_encoding, 'identity')
	// A retry would replay an answer already partly given to `on_chunk`
	req.max_retries = 1
	// The events are handled as they arrive: only keep the start of the body in
	// the response, enough for the diagnostic of an error status
	req.stop_copying_limit = max_error_body

	mut state := &StreamState{}
	on_event := fn [mut state, on_chunk] (data string) ! {
		chat_response := json2.decode[ChatResponse](data) or {
			return error('Invalid event from the API (${err}): ${data}')
		}
		// An error met while generating the answer is sent as an event
		if chat_response.error.message.len > 0 {
			return error('Chat completion API error: ${chat_response.error.message}')
		}
		if chat_response.choices.len > 0 {
			if chat_response.choices[0].finish_reason.len > 0 {
				state.finish_reason = chat_response.choices[0].finish_reason
			}
			content := chat_response.choices[0].delta.content
			if content.len > 0 {
				on_chunk(content)
				state.received = true
			}
		}
	}
	// net.http takes the status passed to on_progress_body from the first socket
	// read only: when that read ends inside the status code, it is a truncated
	// number (e.g. `2` for `200`). on_progress gets the raw response bytes first,
	// so the whole status line is read there.
	req.on_progress = fn [mut state] (_ &http.Request, chunk []u8, _ u64) ! {
		state.read_status(chunk)
	}
	// net.http handles the HTTP framing (chunked encoding, Content-Length, end of
	// the connection) and gives the decoded body as it arrives.
	req.on_progress_body = fn [mut state, on_event] (_ &http.Request, chunk []u8, _ u64, _ u64, status int) ! {
		// An error body is read from the response once complete
		if state.status_or(status) != 200 {
			return
		}
		state.parser.feed(chunk, on_event) or {
			state.failure = err.msg()
			return err
		}
		// Do not wait for the server to close the connection after `[DONE]`
		if state.parser.done {
			return error(stream_done)
		}
	}

	resp := req.do() or {
		// An error from the event handling, as is
		if state.failure.len > 0 {
			return error(state.failure)
		}
		if !state.parser.done {
			return RequestError{
				operation: 'Chat completion'
				reason:    err.msg()
			}
		}
		http.Response{
			status_code: 200
		}
	}
	if resp.status_code != 200 {
		return ApiError{
			operation: 'Chat completion'
			status:    resp.status_code
			body:      resp.body.trim_space()
		}
	}
	// Without `[DONE]` nor a finish reason, the connection ended mid-answer
	if !state.parser.done && state.finish_reason == '' {
		return error('The stream ended before the answer was complete')
	}
	// The answer was stopped by the server rather than finished by the model
	match state.finish_reason {
		'length' {
			if !state.received {
				return error('The model reached its length limit before answering (finish_reason: length)')
			}
			return error('The answer was cut by the length limit (finish_reason: length)')
		}
		'content_filter' {
			return error('The answer was blocked by the content filter (finish_reason: content_filter)')
		}
		else {}
	}

	if !state.received {
		return error('No response received from the API')
	}
}

const stream_done = 'end of the event stream'

const max_error_body = 64 * 1024

struct StreamState {
mut:
	parser        EventStreamParser
	head          []u8   // start of the raw response, until the status line is complete
	status        int    // status code read from the status line, 0 while unknown
	failure       string // error met while handling the events
	finish_reason string // finish reason given by a choice, if any
	received      bool
}

// read_status reads the status code from the status line of the raw response.
fn (mut s StreamState) read_status(chunk []u8) {
	if s.status != 0 || s.head.len > 1024 {
		return
	}
	s.head << chunk
	end := s.head.index(`\n`)
	if end < 0 {
		return
	}
	// `HTTP/1.1 200 OK`
	fields := s.head[..end].bytestr().trim_space().split(' ')
	if fields.len >= 2 && fields[0].starts_with('HTTP/') && fields[1].len == 3 {
		s.status = fields[1].int()
	}
	s.head = []u8{}
}

// status_or returns the status code read from the status line, or `fallback`
// when it is unknown (e.g. with HTTP/2, where on_progress gets the body only).
fn (s &StreamState) status_or(fallback int) int {
	return if s.status != 0 { s.status } else { fallback }
}

struct Answer {
mut:
	text strings.Builder = strings.new_builder(1024)
}

// complete sends `prompt` to the configured model and returns the whole answer.
pub fn (c Client) complete(prompt string) !string {
	mut answer := &Answer{}
	c.stream_completion(prompt, fn [mut answer] (chunk string) {
		answer.text.write_string(chunk)
	})!
	return answer.text.str()
}

struct ModelsResponse {
	data []Model
}

struct Model {
	id string
}

fn (c Client) new_request(method http.Method, path string, data string) !http.Request {
	protocol := if c.config.api_tls { 'https' } else { 'http' }
	mut req := http.new_request(method, '${protocol}://${c.config.api_host}:${c.config.api_port}${path}',
		data)
	if c.config.api_key.len > 0 {
		req.add_header(.authorization, 'Bearer ${c.config.api_key}')
	}
	// A redirect would forward the API key and the prompt to wherever it points:
	// it is reported as an error (non-200 status) instead.
	req.allow_redirect = false
	// The API key must only reach a server whose certificate is valid
	if c.config.api_tls && !c.config.api_insecure {
		req.validate = true
		$if windows && !no_vschannel ? {
			// net.http uses SChannel, which checks certificates against the Windows
			// certificate store and has no use for a PEM bundle
			if c.config.api_ca_file != '' {
				return error('api_ca_file is not supported with the Windows certificate store (SChannel): add the CA certificate to the store instead')
			}
		} $else {
			req.verify = if c.config.api_ca_file != '' {
				c.config.api_ca_file
			} else {
				find_ca_bundle()!
			}
		}
	}
	return req
}

// find_ca_bundle returns the path of the system bundle of trusted CA certificates.
fn find_ca_bundle() !string {
	env_file := os.getenv('SSL_CERT_FILE')
	if env_file != '' {
		return env_file
	}
	for path in ca_bundles {
		if os.is_file(path) {
			return path
		}
	}
	return error('No CA bundle found to check the server certificate: set api_ca_file (or SSL_CERT_FILE)')
}

// list_models returns the ids of the models available on the API server.
pub fn (c Client) list_models() ![]string {
	req := c.new_request(.get, '/v1/models', '')!
	resp := req.do() or {
		return RequestError{
			operation: 'Models'
			reason:    err.msg()
		}
	}

	if resp.status_code != 200 {
		return ApiError{
			operation: 'Models'
			status:    resp.status_code
			body:      resp.body
		}
	}

	models := json2.decode[ModelsResponse](resp.body)!
	return models.data.map(it.id)
}

// is_model_supported reports whether `model_name` is available on the API server.
pub fn (c Client) is_model_supported(model_name string) !bool {
	models := c.list_models()!
	return model_name in models
}

// validate_model returns an error when `model_name` is not available on the API server.
pub fn (c Client) validate_model(model_name string) ! {
	if !c.is_model_supported(model_name)! {
		return error('The model "${model_name}" is not supported.')
	}
}
