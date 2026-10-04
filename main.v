module main

import api
import cli
import config
import log
import os
import term
import time

// list_models returns the models of the API server. When the server cannot be
// reached, it exits with a checklist; the raw error is only shown in verbose mode.
fn list_models(client api.Client) ![]string {
	return client.list_models() or {
		if err is api.RequestError {
			eprintln(term.bright_red('\nError: Cannot connect to API server'))
			eprintln(term.gray('Please check:'))
			eprintln(term.gray('  1. Server is running'))
			eprintln(term.gray('  2. Server URL: ${client.config.api_host}:${client.config.api_port}'))
			eprintln(term.gray('  3. Configuration in ${config.file_path()} is correct'))
			log.debug(err.msg())
			exit(1)
		}
		return err
	}
}

// check_server_availability exits with guidance when the API server cannot be
// reached, or when it does not have the configured model.
fn check_server_availability(client api.Client) ! {
	models := list_models(client)!
	if client.config.api_model !in models {
		eprintln(term.bright_red('\nError: The model "${client.config.api_model}" is not available on ${client.config.api_host}:${client.config.api_port}'))
		display_models_list(models)
		eprintln(term.gray('Choose one with: jarvis switch <model>'))
		exit(1)
	}
}

fn C._exit(code int)

// quit_on_interrupt ends the interactive mode on Ctrl-C. It must not wait on any
// output (stdout may be a full pipe, or a suspended terminal): it writes nothing
// and skips the stdio buffers, the answers being flushed as they are printed.
fn quit_on_interrupt(_ os.Signal) {
	C._exit(0)
}

// interactive_mode asks the questions typed by the user, one after the other,
// until `exit`, `quit`, the end of input (Ctrl-D) or Ctrl-C.
fn interactive_mode(client api.Client) {
	os.signal_opt(.int, quit_on_interrupt) or {}
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
	printed   bool      // some of the answer was printed
	responded bool      // the model started answering or reasoning
	thinking  bool      // `Thinking...` is shown on stderr
	started   time.Time // when the model started thinking
	shown     i64       // seconds shown in `Thinking...`
}

// show_thinking shows on stderr, when it is a terminal, how long the model has
// been thinking (reasoning models think before answering).
fn (mut o Output) show_thinking() {
	if o.printed || os.is_atty(2) == 0 {
		return
	}
	if !o.thinking {
		o.thinking = true
		o.started = time.now()
		o.shown = -1
	}
	seconds := i64(time.since(o.started).seconds())
	if seconds != o.shown {
		o.shown = seconds
		eprint('\r${term.dim('Thinking... ${seconds}s')}')
		flush_stderr()
	}
}

fn (mut o Output) clear_thinking() {
	if o.thinking {
		o.thinking = false
		eprint('\r\x1b[2K')
		flush_stderr()
	}
}

fn ask(client api.Client, prompt string) ! {
	mut output := &Output{}
	client.stream_completion_with_reasoning(prompt, fn [mut output] (_ string) {
		output.responded = true
		output.show_thinking()
	}, fn [mut output] (chunk string) {
		output.responded = true
		output.clear_thinking()
		print(chunk)
		flush_stdout()
		output.printed = true
	}) or {
		output.clear_thinking()
		// The error starts on its own line after a partial answer
		if output.printed {
			println('')
		}
		// Once the model has started, the configuration was fine
		if !output.responded && needs_config_hint(err) {
			return error('${err}. Check your configuration in ${config.file_path()}')
		}
		// A reasoning model may spend its whole budget on its reasoning
		if err is api.FinishError && err.reason == 'length' && !err.received {
			return error('${err.msg()}. With a reasoning model, set reasoning_effort = "none" in ${config.file_path()} to get an answer without reasoning')
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
		api_host:         cfg.api_host
		api_port:         cfg.api_port
		api_key:          cfg.api_key
		api_model:        cfg.api_model
		api_tls:          cfg.api_tls
		api_ca_file:      cfg.api_ca_file
		api_insecure:     cfg.api_insecure
		reasoning_effort: cfg.reasoning_effort
		max_tokens:       cfg.max_tokens
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

// split_arguments splits the arguments into the leading flags and the rest, which
// starts with the first word. All the flags are booleans, and vlib's cli also
// accepts a boolean flag followed by its value (`-v true`, `--help false`): that
// value goes with the flags.
fn split_arguments(args []string) ([]string, []string) {
	mut i := 0
	for i < args.len && args[i].starts_with('-') {
		if !args[i].contains('=') && i + 1 < args.len && args[i + 1] in ['true', 'false'] {
			i++
		}
		i++
	}
	return args[..i], args[i..]
}

// reject_flag_commands exits with guidance when the first word is `help`,
// `version` or `man`, which are flags only: as commands, they would be sent to the
// model as a question.
fn reject_flag_commands(word string) {
	flag := match word {
		'help' { '--help' }
		'version' { '--version' }
		'man' { '--man' }
		else { return }
	}
	eprintln('`${word}` is not a command: use `jarvis ${flag}`')
	exit(1)
}

fn main() {
	mut app := cli.Command{
		name:        'jarvis'
		description: 'CLI assistant using OpenAI compatible API'
		version:     '0.2.0'
		posix_mode:  true
		// Help, version and manpage as flags only, not also as commands
		defaults:    struct {
			help:    cli.CommandFlag{
				command: false
			}
			version: cli.CommandFlag{
				command: false
			}
			man:     cli.CommandFlag{
				command: false
			}
		}
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
			check_server_availability(client)!

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
					display_models_list(list_models(client)!)
				}
			},
			cli.Command{
				name:          'switch'
				description:   'Switch to a different model'
				usage:         '<model>'
				required_args: 1
				execute:       fn (cmd cli.Command) ! {
					mut cfg, client := setup(cmd)!

					new_model := cmd.args[0]
					models := list_models(client)!
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

	_, rest := split_arguments(os.args[1..])
	if rest.len > 0 {
		reject_flag_commands(rest[0])
		// Only the first word may select a command. vlib's cli looks for a command
		// in every argument: without this, `jarvis tell me how to switch <model>`
		// would switch the model instead of asking the question. (Then
		// `jarvis --help <words>` shows the help without the commands: guessing
		// whether vlib will show the help would risk letting a command run.)
		if rest[0] !in app.commands.map(it.name) {
			app.commands = []
		}
	}
	app.setup()
	app.parse(os.args)
}
