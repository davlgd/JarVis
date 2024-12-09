module config

import os
import toml

pub struct Config {
pub mut:
    api_host  string
    api_port  string
    api_key   string
    api_model string
	api_tls   bool
}

const config_dir = os.join_path(os.home_dir(), '.config', 'jarvis')
const config_file = os.join_path(config_dir, 'config.toml')

pub fn load_config() !Config {
    if !os.exists(config_file) {
        create_default_config()!
    }

    content := os.read_file(config_file)!
    config := toml.decode[Config](content)!
    return config
}

fn create_default_config() ! {
    if !os.exists(config_dir) {
        os.mkdir_all(config_dir)!
    }

    default_config := Config{
        api_host: 'localhost'
        api_port: '11434'
        api_key: ''
        api_model: 'qwen2.5-coder'
		api_tls: false
    }

    content := toml.encode(default_config)
    os.write_file(config_file, content)!
}

pub fn save_config(config Config) ! {
    content := toml.encode(config)
    os.write_file(config_file, content)!
}
