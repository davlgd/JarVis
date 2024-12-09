module display

import term

pub fn models_list(models []string) {
    list := models.map('${term.gray("  -")} ${term.gray(it)}').join('\n')
    println('🔎 ${models.len} models available:\n${list}')
}
