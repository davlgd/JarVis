// Package api is a client for any OpenAI compatible API: list models, check one is
// available, and get chat completions, streamed or not.
module api

import json2
import net.http
import strings

// default_system_prompt is the system prompt used when Config.system_prompt is not set.
pub const default_system_prompt = 'You are a helpful assistant named Jarvis, who helps developers to make their life easier every day through the CLI.
You make clear, concise, and structured answers, easy to read in a command line interface.'

// default_temperature is the sampling temperature used when Config.temperature is not set.
pub const default_temperature = 1.0

// Config describes the API server to talk to and how to query it.
pub struct Config {
pub:
	api_host      string
	api_port      string
	api_key       string
	api_model     string
	api_tls       bool
	system_prompt string = default_system_prompt
	temperature   f64    = default_temperature
}

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

struct ChatResponse {
	id      string
	object  string
	created int
	model   string
	choices []ChatChoice
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

	mut req := c.new_request(.post, '/v1/chat/completions', json2.encode(request))
	req.add_header(.content_type, 'application/json')
	req.add_header(.accept, 'text/event-stream')
	// A retry would replay an answer already partly given to `on_chunk`
	req.max_retries = 1

	mut state := &StreamState{}
	on_event := fn [mut state, on_chunk] (data string) ! {
		chat_response := json2.decode[ChatResponse](data) or {
			return error('Invalid event from the API (${err}): ${data}')
		}
		if chat_response.choices.len > 0 {
			content := chat_response.choices[0].delta.content
			if content.len > 0 {
				on_chunk(content)
				state.received = true
			}
		}
	}
	// net.http handles the HTTP framing (chunked encoding, Content-Length, end of
	// the connection) and gives the decoded body as it arrives.
	req.on_progress_body = fn [mut state, on_event] (_ &http.Request, chunk []u8, _ u64, _ u64, status int) ! {
		// An error body is read from the response once complete. net.http takes the
		// status from the first socket read only: when that read ends inside the
		// status code, `status` is a truncated number (e.g. `2` for `200`) that
		// cannot be trusted. The body is then parsed anyway: an error body holds no
		// events, and the status of the whole response is checked below.
		if status >= 100 && status != 200 {
			return
		}
		state.parser.feed(chunk, on_event)!
		// Do not wait for the server to close the connection after `[DONE]`
		if state.parser.done {
			return error(stream_done)
		}
	}

	resp := req.do() or {
		if !state.parser.done {
			return error('Chat completion request failed: ${err}')
		}
		http.Response{
			status_code: 200
		}
	}
	if resp.status_code != 200 {
		return error('Chat completion API error (${resp.status_code}): ${resp.body.trim_space()}')
	}
	state.parser.finish(on_event)!

	if !state.received {
		return error('No response received from the API')
	}
}

const stream_done = 'end of the event stream'

struct StreamState {
mut:
	parser   EventStreamParser
	received bool
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

fn (c Client) new_request(method http.Method, path string, data string) http.Request {
	protocol := if c.config.api_tls { 'https' } else { 'http' }
	mut req := http.new_request(method, '${protocol}://${c.config.api_host}:${c.config.api_port}${path}',
		data)
	if c.config.api_key.len > 0 {
		req.add_header(.authorization, 'Bearer ${c.config.api_key}')
	}
	// A redirect would forward the API key and the prompt to wherever it points:
	// it is reported as an error (non-200 status) instead.
	req.allow_redirect = false
	return req
}

// list_models returns the ids of the models available on the API server.
pub fn (c Client) list_models() ![]string {
	req := c.new_request(.get, '/v1/models', '')
	resp := req.do() or { return error('Models API error: ${err}') }

	if resp.status_code != 200 {
		return error('Models API error (${resp.status_code}): ${resp.body}')
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
