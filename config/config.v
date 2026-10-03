// Package config loads and saves the JarVis configuration file,
// ~/.config/jarvis/config.toml.
module config

import log
import os
import toml

// Settings is the content of the JarVis configuration file. It is named after
// api.Config on purpose: V mixes up generic instantiations (toml.decode) of
// same-named structs from different modules.
pub struct Settings {
pub mut:
	api_host  string
	api_port  string
	api_key   string
	api_model string
	api_tls   bool
}

const config_dir = os.join_path(os.home_dir(), '.config', 'jarvis')
const config_file = os.join_path(config_dir, 'config.toml')

// file_path returns the path of the JarVis configuration file.
pub fn file_path() string {
	return config_file
}

// load_config reads the configuration file, creating it with default values first
// when it does not exist.
pub fn load_config() !Settings {
	if !os.exists(config_file) {
		create_default_config()!
	}

	content := os.read_file(config_file)!
	return toml.decode[Settings](content)!
}

fn create_default_config() ! {
	if !os.exists(config_dir) {
		os.mkdir_all(config_dir)!
	}

	default_config := Settings{
		api_host:  'localhost'
		api_port:  '11434'
		api_key:   ''
		api_model: 'qwen2.5-coder'
		api_tls:   false
	}

	content := toml.encode(default_config)
	log.debug('Created default config file: ${config_file}')
	os.write_file(config_file, content)!
}

// save_config writes `cfg` to the configuration file.
pub fn save_config(cfg Settings) ! {
	content := toml.encode(cfg)
	os.write_file(config_file, content)!
}
