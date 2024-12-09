module api

import net.http
import json
import os
import display

const config_file = os.join_path(os.home_dir(), '.config', 'jarvis', 'config.toml')
const system_prompt = 'You are a helpful assistant named Jarvis, who helps developers to make their life easier every day through the CLI. You make clear, concise, and structured answers, easy to read in a command line interface.'
const temperature = 1.0

pub struct Config {
pub:
    api_host  string
    api_port  string
    api_key   string
    api_model string
    api_tls   bool
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

struct ChatChoice {
    delta struct {
        content string
    }
    finish_reason string
}

struct ChatResponse {
    id      string
    object  string
    created int
    model   string
    choices []ChatChoice
}

pub fn new_client(config Config) !Client {
    return Client{
        config: config
    }
}

pub fn (c Client) stream_completion(prompt string) ! {
    request := CompletionRequest{
        model: c.config.api_model
        messages: [
            Message{
                role: 'system'
                content: system_prompt
            },
            Message{
                role: 'user'
                content: prompt
            }
        ]
        temperature: temperature
        stream: true
    }

    request_data := json.encode(request)

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

    stream.send_request(request_str)!

    mut response_received := []bool{len: 1, init: false}

    stream.read_stream(fn [response_received] (line_data string) ! {
        chat_response := json.decode(ChatResponse, line_data) or {
            eprintln('Decoding error: ${err}')
            return
        }

        if chat_response.choices.len > 0 {
            if chat_response.choices[0].finish_reason == 'stop' {
                return
            }
            if chat_response.choices[0].delta.content.len > 0 {
                content := chat_response.choices[0].delta.content
                print(content)
                flush_stdout()
                unsafe {
                    response_received[0] = true
                }
            }
        }
    })!

    if !response_received[0] {
        return error('Aucune réponse reçue de l\'API. Vérifiez votre configuration dans ${config_file}')
    }

    println('')
}

struct ModelsResponse {
    data []Model
}

struct Model {
    id string
}

pub fn (c Client) list_models() ![]string {
    protocol := if c.config.api_tls { 'https' } else { 'http' }
    url := '${protocol}://${c.config.api_host}:${c.config.api_port}/v1/models'

    mut req := http.new_request(.get, url, '')
    if c.config.api_key.len > 0 {
        req.header.add(http.CommonHeader.authorization, 'Bearer ${c.config.api_key}')
    }

    resp := req.do()!

    if resp.status_code != 200 {
        return error('Erreur API (${resp.status_code}): ${resp.body}')
    }

    models := json.decode(ModelsResponse, resp.body)!
    return models.data.map(it.id)
}

pub fn (c Client) is_model_supported(model_name string) !bool {
    models := c.list_models()!
    return model_name in models
}

pub fn (c Client) validate_model(model_name string) ! {
    models := c.list_models()!
    if model_name !in models {
        mut error_msg := 'The model "${model_name}" is not supported.\n'
        display.models_list(models)
        return error(error_msg)
    }
}

fn flush_stdout() {
    unsafe {
        C.fflush(C.stdout)
    }
}
