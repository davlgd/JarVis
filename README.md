# JarVis, your personal CLI assistant

JarVis is a CLI assistant that uses any OpenAI compatible API to help you with your daily tasks. You can list available models, switch between them, directly ask a question, or use the interactive mode.

## Build

You'll need [V](https://vlang.io/) to build and install JarVis:

```bash
tools/build
```

## Configure

You can configure JarVis by editing the `~/.config/jarvis/config.toml` file, for example:

```toml
api_host = "localhost"
api_port = "11434"
api_key = ""
api_model = "qwen2.5-coder"
api_tls = false
```

## Usage

```bash
jarvis
jarvis --help
jarvis --list
jarvis --switch llama3.3
jarvis "Learn me something interesting about a programming language of your choice"
```

## Use it as a V module

JarVis can also be used as a library in your own V programs. Install it:

```bash
v install --git https://github.com/davlgd/JarVis
```

Then import `jarvis.api` to talk to any OpenAI compatible API:

```v
import jarvis.api

fn main() {
	client := api.new_client(api.Config{
		api_host:  'localhost'
		api_port:  '11434'
		api_model: 'qwen2.5-coder'
		// optional: api_key, api_tls, system_prompt, temperature
	})!

	// List the models available on the server, check one exists
	println(client.list_models()!)
	client.validate_model('qwen2.5-coder')!

	// Get the whole answer at once...
	answer := client.complete('What is V?')!
	println(answer)

	// ...or stream it as it is generated
	client.stream_completion('What is V?', fn (chunk string) {
		print(chunk)
	})!
	println('')
}
```

The `jarvis.config` module reads and writes the JarVis configuration file (`config.load_config()`, `config.save_config()`), if you want to share it with the CLI.

## Licence

This project is licensed under the MIT License - see the [LICENCE](LICENCE) file for details.
