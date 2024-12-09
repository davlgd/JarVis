module main

import cli
import config
import api
import display
import os
import readline
import term

fn check_server_availability(client api.Client) ! {
    client.list_models() or {
        eprintln(term.bright_red('\nError: Cannot connect to API server'))
        eprintln(term.gray('Please check:'))
        eprintln(term.gray('  1. Server is running'))
        eprintln(term.gray('  2. Server URL: ${client.config.api_host}:${client.config.api_port}'))
        eprintln(term.gray('  3. Configuration in ~/.config/jarvis/config.toml is correct'))
        exit(1)
    }
}

fn interactive_mode() ! {
    cfg := config.load_config()!
    client := api.new_client(config_to_api(cfg))!
    check_server_availability(client)!

    println('JarVis, ready to help:')
    input := readline.read_line('> ')!
    if input.trim_space() == '' {
        return
    }
    if input == 'exit' || input == 'quit' {
        return
    }
    client.stream_completion(input)!
}

fn config_to_api(cfg config.Config) api.Config {
    return api.Config{
        api_host: cfg.api_host
        api_port: cfg.api_port
        api_key: cfg.api_key
        api_model: cfg.api_model
        api_tls: cfg.api_tls
    }
}

fn main() {
    mut app := cli.Command{
        name: 'jarvis'
        description: 'CLI assistant using OpenAI compatible API'
        version: '0.1.0'
        posix_mode: true
        execute: fn (cmd cli.Command) ! {
            cfg := config.load_config()!
            client := api.new_client(config_to_api(cfg))!
            check_server_availability(client)!

            if cmd.args.len == 0 {
                interactive_mode()!
                return
            }
            request := cmd.args.join(' ')
            client.stream_completion(request)!
        }
        commands: [
            cli.Command{
                name: 'list'
                description: 'List available models'
                execute: fn (cmd cli.Command) ! {
                    cfg := config.load_config()!
                    client := api.new_client(config_to_api(cfg))!
                    models := client.list_models()!
                    display.models_list(models)
                }
            },
            cli.Command{
                name: 'switch'
                description: 'Switch to a different model'
                required_args: 1
                execute: fn (cmd cli.Command) ! {
                    mut cfg := config.load_config()!
                    client := api.new_client(config_to_api(cfg))!

                    new_model := cmd.args[0]
                    client.validate_model(new_model)!

                    cfg.api_model = new_model
                    config.save_config(cfg)!
                    println('Switched to model: ${cfg.api_model}')
                }
            },
        ]
    }

    app.setup()
    app.parse(os.args)
}
