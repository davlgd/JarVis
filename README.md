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

## Licence

This project is licensed under the MIT License - see the [LICENCE](LICENCE) file for details.
