package mustache4c

import "core:c"

MUSTACHE4C_LIB :: #config(MUSTACHE4C_LIB, "libmustache4c.a")

foreign import lib {MUSTACHE4C_LIB}

Template :: rawptr

Parser :: struct {
	parse_error: proc "c" (err_code: c.int, msg: cstring, line: c.uint, column: c.uint, parser_data: rawptr),
}

Renderer :: struct {
	out_verbatim: proc "c" (output: [^]u8, size: c.size_t, renderer_data: rawptr) -> c.int,
	out_escaped:  proc "c" (output: [^]u8, size: c.size_t, renderer_data: rawptr) -> c.int,
}

// out_fn is the callback the `dump` implementation calls to emit output.
Dump_Out_Fn :: #type proc "c" (output: [^]u8, size: c.size_t, renderer_data: rawptr) -> c.int

Data_Provider :: struct {
	dump:               proc "c" (
		node: rawptr,
		out_fn: Dump_Out_Fn,
		renderer_data: rawptr,
		provider_data: rawptr,
	) -> c.int,
	get_root:           proc "c" (provider_data: rawptr) -> rawptr,
	get_child_by_name:  proc "c" (
		node: rawptr,
		name: [^]u8,
		size: c.size_t,
		provider_data: rawptr,
	) -> rawptr,
	get_child_by_index: proc "c" (node: rawptr, index: c.uint, provider_data: rawptr) -> rawptr,
	get_partial:        proc "c" (name: [^]u8, size: c.size_t, provider_data: rawptr) -> Template,
}

@(default_calling_convention = "c", link_prefix = "mustache_")
foreign lib {
	compile :: proc(templ_data: [^]u8, templ_size: c.size_t, parser: ^Parser, parser_data: rawptr, flags: c.uint) -> Template ---
	release :: proc(t: Template) ---
	process :: proc(t: Template, renderer: ^Renderer, renderer_data: rawptr, provider: ^Data_Provider, provider_data: rawptr) -> c.int ---
}
