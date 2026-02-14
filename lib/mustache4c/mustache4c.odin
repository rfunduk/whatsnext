package mustache4c_wrapper

import m "bindings"

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strings"

Template :: m.Template

@(private)
Provider_Data :: struct {
	root:     ^any,
	ctx:      runtime.Context,
	partials: map[string]Template,
}

@(private)
Layout_Provider_Data :: struct {
	using base: Provider_Data,
	content:    string,
}

@(private)
Renderer_Data :: struct {
	sb:  ^strings.Builder,
	ctx: runtime.Context,
}

@(private)
CONTENT_SENTINEL :: rawptr(uintptr(1))

// --- Callbacks ---

@(private)
cb_get_root :: proc "c" (provider_data: rawptr) -> rawptr {
	pd := cast(^Provider_Data)provider_data
	return pd.root
}

@(private)
box :: proc(val: any, ctx: ^runtime.Context) -> rawptr {
	context = ctx^
	a := new(any)
	a^ = val
	return a
}

@(private)
cb_get_child_by_name :: proc "c" (
	node: rawptr,
	name: [^]u8,
	size: c.size_t,
	provider_data: rawptr,
) -> rawptr {
	pd := cast(^Provider_Data)provider_data
	context = pd.ctx

	a := cast(^any)node
	if a == nil { return nil }

	key := string(name[:size])
	child := get_field(a^, key)
	if child == nil { return nil }
	if is_falsy(child) { return nil }
	return box(child, &pd.ctx)
}

@(private)
cb_get_child_by_index :: proc "c" (node: rawptr, index: c.uint, provider_data: rawptr) -> rawptr {
	pd := cast(^Provider_Data)provider_data
	context = pd.ctx

	a := cast(^any)node
	if a == nil { return nil }

	base := runtime.type_info_base(type_info_of(a.id))
	#partial switch info in base.variant {
	case runtime.Type_Info_Slice:
		raw := cast(^runtime.Raw_Slice)a.data
		if raw == nil || int(index) >= raw.len { return nil }
		elem := reflect.index(a^, int(index))
		return box(elem, &pd.ctx)
	case runtime.Type_Info_Dynamic_Array:
		raw := cast(^runtime.Raw_Dynamic_Array)a.data
		if raw == nil || int(index) >= raw.len { return nil }
		elem := reflect.index(a^, int(index))
		return box(elem, &pd.ctx)
	case:
		// Scalar: index 0 returns self (for section iteration over a truthy value).
		if index == 0 { return node }
		return nil
	}
}

@(private)
cb_dump :: proc "c" (
	node: rawptr,
	out_fn: m.Dump_Out_Fn,
	renderer_data: rawptr,
	provider_data: rawptr,
) -> c.int {
	pd := cast(^Provider_Data)provider_data
	context = pd.ctx

	a := cast(^any)node
	if a == nil { return 0 }

	s := value_to_string(a^)
	if len(s) > 0 {
		return out_fn(raw_data(s), len(s), renderer_data)
	}
	return 0
}

@(private)
cb_get_partial :: proc "c" (name: [^]u8, size: c.size_t, provider_data: rawptr) -> m.Template {
	pd := cast(^Provider_Data)provider_data
	context = pd.ctx

	key := string(name[:size])
	t, ok := pd.partials[key]
	if !ok { return nil }
	return t
}

@(private)
cb_layout_get_child_by_name :: proc "c" (
	node: rawptr,
	name: [^]u8,
	size: c.size_t,
	provider_data: rawptr,
) -> rawptr {
	lpd := cast(^Layout_Provider_Data)provider_data
	context = lpd.ctx

	key := string(name[:size])
	if key == "content" { return CONTENT_SENTINEL }
	return cb_get_child_by_name(node, name, size, provider_data)
}

@(private)
cb_layout_dump :: proc "c" (
	node: rawptr,
	out_fn: m.Dump_Out_Fn,
	renderer_data: rawptr,
	provider_data: rawptr,
) -> c.int {
	lpd := cast(^Layout_Provider_Data)provider_data
	context = lpd.ctx

	if node == CONTENT_SENTINEL {
		if len(lpd.content) > 0 { return out_fn(raw_data(lpd.content), len(lpd.content), renderer_data) }
		return 0
	}
	return cb_dump(node, out_fn, renderer_data, provider_data)
}

@(private)
cb_layout_get_child_by_index :: proc "c" (node: rawptr, index: c.uint, provider_data: rawptr) -> rawptr {
	if node == CONTENT_SENTINEL {
		if index == 0 { return CONTENT_SENTINEL }
		return nil
	}
	return cb_get_child_by_index(node, index, provider_data)
}

@(private)
cb_out_verbatim :: proc "c" (output: [^]u8, size: c.size_t, renderer_data: rawptr) -> c.int {
	rd := cast(^Renderer_Data)renderer_data
	context = rd.ctx
	strings.write_bytes(rd.sb, output[:size])
	return 0
}

@(private)
cb_out_escaped :: proc "c" (output: [^]u8, size: c.size_t, renderer_data: rawptr) -> c.int {
	rd := cast(^Renderer_Data)renderer_data
	context = rd.ctx
	s := string(output[:size])
	for ch in s {
		switch ch {
		case '&':
			strings.write_string(rd.sb, "&amp;")
		case '<':
			strings.write_string(rd.sb, "&lt;")
		case '>':
			strings.write_string(rd.sb, "&gt;")
		case '"':
			strings.write_string(rd.sb, "&quot;")
		case:
			strings.write_rune(rd.sb, ch)
		}
	}
	return 0
}

@(private)
cb_parse_error :: proc "c" (
	err_code: c.int,
	msg: cstring,
	line: c.uint,
	column: c.uint,
	parser_data: rawptr,
) {
	pd := cast(^Provider_Data)parser_data
	context = pd.ctx
	log.errorf("mustache4c parse error %d at %d:%d: %s", err_code, line, column, msg)
}

// --- Helpers ---

@(private)
get_field :: proc(obj: any, key: string) -> any {
	if obj.data == nil { return nil }

	base := runtime.type_info_base(type_info_of(obj.id))
	#partial switch info in base.variant {
	case runtime.Type_Info_Struct:
		return reflect.struct_field_value_by_name(obj, key)
	case:
		return nil
	}
}

@(private)
is_falsy :: proc(val: any) -> bool {
	if val.data == nil { return true }

	base := runtime.type_info_base(type_info_of(val.id))
	#partial switch info in base.variant {
	case runtime.Type_Info_Boolean:
		b, ok := reflect.as_bool(val)
		return ok && !b
	case runtime.Type_Info_String:
		s, ok := reflect.as_string(val)
		return ok && len(s) == 0
	case runtime.Type_Info_Slice:
		raw := cast(^runtime.Raw_Slice)val.data
		return raw == nil || raw.len == 0
	case runtime.Type_Info_Dynamic_Array:
		raw := cast(^runtime.Raw_Dynamic_Array)val.data
		return raw == nil || raw.len == 0
	case:
		return reflect.is_nil(val)
	}
}

@(private)
value_to_string :: proc(val: any) -> string {
	if val.data == nil { return "" }

	base := runtime.type_info_base(type_info_of(val.id))
	#partial switch info in base.variant {
	case runtime.Type_Info_String:
		s, ok := reflect.as_string(val)
		if ok { return s }
		return ""
	case runtime.Type_Info_Integer:
		return fmt.aprintf("%v", val)
	case runtime.Type_Info_Float:
		return fmt.aprintf("%v", val)
	case runtime.Type_Info_Boolean:
		b, ok := reflect.as_bool(val)
		if ok { return b ? "true" : "false" }
		return ""
	case:
		return fmt.aprintf("%v", val)
	}
}

@(private)
process_template :: proc(t: Template, provider: ^m.Data_Provider, provider_data: rawptr) -> (string, bool) {
	sb := strings.builder_make()
	rd := Renderer_Data {
		sb  = &sb,
		ctx = context,
	}
	renderer := m.Renderer {
		out_verbatim = cb_out_verbatim,
		out_escaped  = cb_out_escaped,
	}
	rc := m.process(t, &renderer, &rd, provider, provider_data)
	if rc != 0 {
		log.errorf("mustache4c: process failed with code %d", rc)
		return "", false
	}
	return strings.to_string(sb), true
}

// --- Public API ---

compile :: proc(template_str: string) -> Template {
	pd := Provider_Data{ctx = context}
	parser := m.Parser{parse_error = cb_parse_error}
	return m.compile(raw_data(template_str), len(template_str), &parser, &pd, 0)
}

release :: proc(t: Template) {
	if t != nil { m.release(t) }
}

compile_partials :: proc(partials_map: map[string]string) -> map[string]Template {
	compiled := make(map[string]Template)
	for key, tmpl_str in partials_map {
		t := compile(tmpl_str)
		if t != nil {
			compiled[key] = t
		} else {
			log.errorf("mustache4c: failed to compile partial '%s'", key)
		}
	}
	return compiled
}

release_partials :: proc(compiled: map[string]Template) {
	for _, t in compiled { release(t) }
	delete(compiled)
}

render :: proc(t: Template, data: any, compiled_partials: map[string]Template) -> (string, bool) {
	root := new(any)
	root^ = data
	pd := Provider_Data {
		root     = root,
		ctx      = context,
		partials = compiled_partials,
	}
	provider := m.Data_Provider {
		dump               = cb_dump,
		get_root           = cb_get_root,
		get_child_by_name  = cb_get_child_by_name,
		get_child_by_index = cb_get_child_by_index,
		get_partial        = cb_get_partial,
	}
	return process_template(t, &provider, &pd)
}

render_in_layout :: proc(
	t: Template,
	data: any,
	layout_tmpl: Template,
	compiled_partials: map[string]Template,
) -> (string, bool) {
	// Pass 1: render the page template.
	page_content, ok := render(t, data, compiled_partials)
	if !ok { return "", false }

	// Pass 2: render the layout with content injection.
	root := new(any)
	root^ = data
	lpd := Layout_Provider_Data {
		base    = Provider_Data{root = root, ctx = context, partials = compiled_partials},
		content = page_content,
	}
	provider := m.Data_Provider {
		dump               = cb_layout_dump,
		get_root           = cb_get_root,
		get_child_by_name  = cb_layout_get_child_by_name,
		get_child_by_index = cb_layout_get_child_by_index,
		get_partial        = cb_get_partial,
	}
	return process_template(layout_tmpl, &provider, &lpd)
}
