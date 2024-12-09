module main

import os
import cli
import config
import api

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
            if cmd.args.len == 0 {
                cmd.execute_help()
                return
            }
            request := cmd.args.join(' ')
            cfg := config.load_config()!
            client := api.new_client(config_to_api(cfg))!
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
                    for model in models {
                        println(model)
                    }
                }
            },
            cli.Command{
                name: 'switch'
                description: 'Switch to a different model'
                required_args: 1
                execute: fn (cmd cli.Command) ! {
                    mut cfg := config.load_config()!
                    cfg.api_model = cmd.args[0]
                    config.save_config(cfg)!
                    println('Switched to model: ${cfg.api_model}')
                }
            },
        ]
    }

    app.setup()
    app.parse(os.args)
}