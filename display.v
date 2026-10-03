module main

import term

fn display_models_list(models []string) {
	list := models.map('${term.gray('  -')} ${term.gray(it)}').join('\n')
	println('🔎 ${models.len} models available:\n${list}')
}
