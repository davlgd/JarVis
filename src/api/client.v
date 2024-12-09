module api

import net.http
import json
import os

const config_file = os.join_path(os.home_dir(), '.config', 'jarvis', 'config.toml')

pub struct Client {
    config Config
}

pub struct Config {
pub:
    api_host  string
    api_port  string
    api_key   string
    api_model string
    api_tls   bool
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
    if config.api_key.len == 0 {
        return error('API key non configurée dans ${config_file}')
    }
    return Client{
        config: config
    }
}

pub fn (c Client) stream_completion(prompt string) ! {
    protocol := if c.config.api_tls { 'https' } else { 'http' }
    url := '${protocol}://${c.config.api_host}:${c.config.api_port}/v1/chat/completions'
    println('Envoi de la requête à ${url}...')

    request := CompletionRequest{
        model: c.config.api_model
        messages: [
            Message{
                role: 'system'
                content: 'Tu es un assistant qui aide à produire du code de qualité.'
            },
            Message{
                role: 'user'
                content: prompt
            }
        ]
        temperature: 1.0
        stream: true
    }

    request_data := json.encode(request)
    mut req := http.Request{
        method: .post
        url: url
        data: request_data
    }

    req.add_header(.authorization, 'Bearer ${c.config.api_key}')
    req.add_header(.content_type, 'application/json')

    mut response_received := false

    mut resp := req.do()!

    if resp.status_code != 200 {
        return error('Erreur API (${resp.status_code}): ${resp.body}\nVérifiez votre configuration dans ${config_file}')
    }

    mut lines := resp.body.split('\n')
    for line in lines {
        if !line.starts_with('data: ') {
            continue
        }

        line_data := line[6..]
        if line_data == '[DONE]' || line_data.len == 0 {
            continue
        }

        chat_response := json.decode(ChatResponse, line_data) or {
            eprintln('Erreur de décodage: ${err}')
            continue
        }

        if chat_response.choices.len > 0 {
            if chat_response.choices[0].finish_reason == 'stop' {
                break
            }
            if chat_response.choices[0].delta.content.len > 0 {
                content := chat_response.choices[0].delta.content
                print(content)
                flush_stdout()
                response_received = true
            }
        }
    }

    if !response_received {
        return error('Aucune réponse reçue de l\'API. Vérifiez votre configuration dans ${config_file}\nVérifiez aussi que votre API key est valide et que vous avez accès au modèle ${c.config.api_model}')
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
    println('Récupération des modèles depuis ${url}...')

    mut req := http.new_request(.get, url, '')
    req.header.add(http.CommonHeader.authorization, 'Bearer ${c.config.api_key}')

    resp := req.do()!

    if resp.status_code != 200 {
        return error('Erreur API (${resp.status_code}): ${resp.body}\nVérifiez votre configuration dans ${config_file}')
    }

    models := json.decode(ModelsResponse, resp.body)!
    return models.data.map(it.id)
}

fn flush_stdout() {
    unsafe {
        C.fflush(C.stdout)
    }
}