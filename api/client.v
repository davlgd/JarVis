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

const timeout_seconds = 30

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

	request_data := json2.encode(request)

	mut headers := []string{}
	headers << 'POST /v1/chat/completions HTTP/1.1'
	headers << 'Host: ${c.config.api_host}'
	if c.config.api_key.len > 0 {
		headers << 'Authorization: Bearer ${c.config.api_key}'
	}
	headers << 'Content-Type: application/json'
	headers << 'Accept: text/event-stream'
	headers << 'Content-Length: ${request_data.len}'
	headers << 'Connection: close'
	headers << ''
	headers << request_data

	request_str := headers.join('\r\n')

	mut stream := new_stream_reader(c.config.api_host, c.config.api_port, c.config.api_tls)!
	defer { stream.close() }

	stream.send_request(request_str) or { return error('Failed to send request: ${err}') }

	mut response_received := []bool{len: 1, init: false}

	stream.read_stream(fn [response_received, on_chunk] (line_data string) ! {
		chat_response := json2.decode[ChatResponse](line_data) or {
			return error('Invalid event from the API (${err}): ${line_data}')
		}

		if chat_response.choices.len > 0 {
			if chat_response.choices[0].finish_reason == 'stop' {
				return
			}
			if chat_response.choices[0].delta.content.len > 0 {
				on_chunk(chat_response.choices[0].delta.content)
				unsafe {
					response_received[0] = true
				}
			}
		}
	}) or { return error('Stream read error: ${err}') }

	if !response_received[0] {
		return error('No response received from the API')
	}
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

// list_models returns the ids of the models available on the API server.
pub fn (c Client) list_models() ![]string {
	protocol := if c.config.api_tls { 'https' } else { 'http' }
	url := '${protocol}://${c.config.api_host}:${c.config.api_port}/v1/models'

	mut req := http.new_request(.get, url, '')
	if c.config.api_key.len > 0 {
		req.header.add(http.CommonHeader.authorization, 'Bearer ${c.config.api_key}')
	}

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
