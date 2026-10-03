module main

import api
import cli
import config
import log
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
		log.debug(err.str())
		exit(1)
	}
}

fn interactive_mode() ! {
	cfg := config.load_config() or {
		log.error('Failed to load config: ${err}')
		exit(1)
	}
	client := api.new_client(config_to_api(cfg)) or {
		log.error('Failed to create API client: ${err}')
		exit(1)
	}
	check_server_availability(client) or {
		log.error('Failed to check server availability: ${err}')
		exit(1)
	}

	println('JarVis, ready to help:')
	input := readline.read_line('> ')!
	if input.trim_space() == '' {
		return
	}
	if input == 'exit' || input == 'quit' {
		return
	}
	ask(client, input) or {
		log.error('Failed to stream completion: ${err}')
		exit(1)
	}
}

fn ask(client api.Client, prompt string) ! {
	client.stream_completion(prompt, print_chunk) or {
		return error('${err}. Check your configuration in ${config.file_path()}')
	}
	println('')
}

fn print_chunk(chunk string) {
	print(chunk)
	flush_stdout()
}

fn config_to_api(cfg config.Settings) api.Config {
	return api.Config{
		api_host:  cfg.api_host
		api_port:  cfg.api_port
		api_key:   cfg.api_key
		api_model: cfg.api_model
		api_tls:   cfg.api_tls
	}
}

fn main() {
	mut app := cli.Command{
		name:        'jarvis'
		description: 'CLI assistant using OpenAI compatible API'
		version:     '0.2.0'
		posix_mode:  true
		flags:       [
			cli.Flag{
				name:        'verbose'
				abbrev:      'v'
				description: 'Enable verbose mode'
				flag:        .bool
			},
		]
		execute:     fn (cmd cli.Command) ! {
			mut cfg := config.load_config()!

			verbose := cmd.flags.get_bool('verbose') or { false }
			if verbose {
				log.set_level(.debug)
				log.debug('Verbose mode enabled')
			}

			client := api.new_client(config_to_api(cfg))!
			check_server_availability(client)!

			if cmd.args.len == 0 {
				interactive_mode()!
				return
			}
			request := cmd.args.join(' ')
			ask(client, request)!
		}
		commands:    [
			cli.Command{
				name:        'list'
				description: 'List available models'
				execute:     fn (cmd cli.Command) ! {
					cfg := config.load_config()!
					client := api.new_client(config_to_api(cfg))!
					models := client.list_models()!
					display_models_list(models)
				}
			},
			cli.Command{
				name:          'switch'
				description:   'Switch to a different model'
				required_args: 1
				execute:       fn (cmd cli.Command) ! {
					mut cfg := config.load_config()!
					client := api.new_client(config_to_api(cfg))!

					new_model := cmd.args[0]
					client.validate_model(new_model) or {
						display_models_list(client.list_models()!)
						return err
					}

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
