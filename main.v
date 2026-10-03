module main

import api
import cli
import config
import log
import os
import term

// check_server_availability exits with guidance when the API server cannot be
// reached, or when it does not have the configured model.
fn check_server_availability(client api.Client) {
	models := client.list_models() or {
		eprintln(term.bright_red('\nError: Cannot connect to API server'))
		eprintln(term.gray('Please check:'))
		eprintln(term.gray('  1. Server is running'))
		eprintln(term.gray('  2. Server URL: ${client.config.api_host}:${client.config.api_port}'))
		eprintln(term.gray('  3. Configuration in ${config.file_path()} is correct'))
		log.debug(err.str())
		exit(1)
	}
	if client.config.api_model !in models {
		eprintln(term.bright_red('\nError: The model "${client.config.api_model}" is not available on ${client.config.api_host}:${client.config.api_port}'))
		display_models_list(models)
		eprintln(term.gray('Choose one with: jarvis switch <model>'))
		exit(1)
	}
}

// interactive_mode asks the questions typed by the user, one after the other,
// until `exit`, `quit`, the end of input (Ctrl-D) or Ctrl-C.
fn interactive_mode(client api.Client) {
	os.signal_opt(.int, fn (_ os.Signal) {
		println('')
		exit(0)
	}) or {}
	println('JarVis, ready to help (exit, quit or Ctrl-D to leave):')
	for {
		// vlib's readline spins on the first key press (#3): read plain lines
		input := os.input_opt('> ') or {
			println('')
			return
		}
		question := input.trim_space()
		if question == '' {
			continue
		}
		if question in ['exit', 'quit'] {
			return
		}
		ask(client, question) or { eprintln(term.bright_red('Error: ${err}')) }
	}
}

struct Output {
mut:
	printed bool
}

fn ask(client api.Client, prompt string) ! {
	mut output := &Output{}
	client.stream_completion(prompt, fn [mut output] (chunk string) {
		print(chunk)
		flush_stdout()
		output.printed = true
	}) or {
		// The error starts on its own line after a partial answer
		if output.printed {
			println('')
		}
		if needs_config_hint(err) {
			return error('${err}. Check your configuration in ${config.file_path()}')
		}
		return err
	}
	println('')
}

// needs_config_hint reports whether `err` may come from a wrong configuration:
// unreachable server, rejected API key, unknown model or path.
fn needs_config_hint(err IError) bool {
	if err is api.RequestError {
		return true
	}
	if err is api.ApiError {
		return err.status in [401, 403, 404]
	}
	return false
}

fn config_to_api(cfg config.Settings) api.Config {
	return api.Config{
		api_host:     cfg.api_host
		api_port:     cfg.api_port
		api_key:      cfg.api_key
		api_model:    cfg.api_model
		api_tls:      cfg.api_tls
		api_ca_file:  cfg.api_ca_file
		api_insecure: cfg.api_insecure
	}
}

// setup enables the verbose mode when asked, then loads the configuration and
// creates the API client.
fn setup(cmd cli.Command) !(config.Settings, api.Client) {
	if cmd.flags.get_bool('verbose') or { false } {
		log.set_level(.debug)
		log.debug('Verbose mode enabled')
	}
	cfg := config.load_config()!
	client := api.new_client(config_to_api(cfg))!
	protocol := if cfg.api_tls { 'https' } else { 'http' }
	log.debug('API server: ${protocol}://${cfg.api_host}:${cfg.api_port}, model: ${cfg.api_model}')
	return cfg, client
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
				global:      true
			},
		]
		execute:     fn (cmd cli.Command) ! {
			_, client := setup(cmd)!
			check_server_availability(client)

			if cmd.args.len == 0 {
				interactive_mode(client)
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
					_, client := setup(cmd)!
					models := client.list_models()!
					display_models_list(models)
				}
			},
			cli.Command{
				name:          'switch'
				description:   'Switch to a different model'
				required_args: 1
				execute:       fn (cmd cli.Command) ! {
					mut cfg, client := setup(cmd)!

					new_model := cmd.args[0]
					models := client.list_models()!
					if new_model !in models {
						display_models_list(models)
						return error('The model "${new_model}" is not supported.')
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
