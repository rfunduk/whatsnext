package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import mhd "lib:microhttpd"

SLUG_ALPHABET :: "abcdefghklmnopqrstuvwxyz"
SLUG_LENGTH :: 8

generate_slug :: proc() -> string {
	alphabet := SLUG_ALPHABET
	buf: [SLUG_LENGTH]u8
	for i in 0 ..< SLUG_LENGTH {
		buf[i] = alphabet[rand.uint32() % u32(len(alphabet))]
	}
	return strings.clone_from_bytes(buf[:])
}

RESERVED_SLUGS :: [?]string{"static", "uploads", "stories"}

is_valid_slug :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	for reserved in RESERVED_SLUGS {
		if s == reserved { return false }
	}
	for ch in s {
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-') { return false }
	}
	return true
}

// Fixed-size form field storage for POST data, allocated with libc per request.
MAX_FORM_FIELDS :: 8
MAX_FIELD_KEY :: 64
MAX_FIELD_VALUE :: 4096
MAX_FILE_SIZE :: 5 * 1024 * 1024

Form_Field :: struct {
	key:       [MAX_FIELD_KEY]u8,
	key_len:   int,
	value:     [MAX_FIELD_VALUE]u8,
	value_len: int,
}

File_Upload :: struct {
	key:          [MAX_FIELD_KEY]u8,
	key_len:      int,
	content_type: [64]u8,
	ct_len:       int,
	data:         [^]u8,
	size:         u64,
	capacity:     u64,
}

Post_Context :: struct {
	pp:          mhd.Post_Processor,
	fields:      [MAX_FORM_FIELDS]Form_Field,
	field_count: int,
	files:       [2]File_Upload,
	file_count:  int,
}

post_iterator :: proc "c" (
	cls: rawptr,
	kind: mhd.Value_Kind,
	key: cstring,
	filename: cstring,
	content_type: cstring,
	transfer_encoding: cstring,
	data: [^]u8,
	off: u64,
	size: c.size_t,
) -> mhd.Result {
	context = global_context
	pc := cast(^Post_Context)cls
	if size == 0 { return .YES }

	key_str := string(key)

	// Route file uploads separately
	if filename != nil && len(string(filename)) > 0 {
		if off + u64(size) > MAX_FILE_SIZE {
			log.warnf("File upload '%s' exceeds %d byte limit", key_str, MAX_FILE_SIZE)
			return .NO
		}

		file: ^File_Upload = nil
		for i in 0 ..< pc.file_count {
			f := &pc.files[i]
			if string(f.key[:f.key_len]) == key_str {
				file = f
				break
			}
		}

		if file == nil && pc.file_count < len(pc.files) {
			file = &pc.files[pc.file_count]
			n := min(len(key_str), MAX_FIELD_KEY)
			mem.copy(&file.key[0], raw_data(key_str), n)
			file.key_len = n
			if content_type != nil {
				ct := string(content_type)
				ct_n := min(len(ct), len(file.content_type))
				mem.copy(&file.content_type[0], raw_data(ct), ct_n)
				file.ct_len = ct_n
			}
			pc.file_count += 1
		}

		if file != nil {
			needed := off + u64(size)
			if needed > file.capacity {
				new_cap := max(needed, file.capacity * 2, 4096)
				new_data := cast([^]u8)libc.realloc(file.data, uint(new_cap))
				if new_data == nil {
					log.errorf("Failed to allocate %d bytes for file upload", new_cap)
					return .NO
				}
				file.data = new_data
				file.capacity = new_cap
			}
			mem.copy(&file.data[off], data, int(size))
			new_size := off + u64(size)
			if new_size > file.size { file.size = new_size }
		}

		return .YES
	}

	// Regular form field handling
	field: ^Form_Field = nil
	for i in 0 ..< pc.field_count {
		f := &pc.fields[i]
		if string(f.key[:f.key_len]) == key_str {
			field = f
			break
		}
	}

	if field == nil && pc.field_count < MAX_FORM_FIELDS {
		field = &pc.fields[pc.field_count]
		n := min(len(key_str), MAX_FIELD_KEY)
		mem.copy(&field.key[0], raw_data(key_str), n)
		field.key_len = n
		pc.field_count += 1
	}

	if field != nil {
		start := int(off)
		n := min(int(size), MAX_FIELD_VALUE - start)
		if n > 0 {
			mem.copy(&field.value[start], data, n)
			end := start + n
			if end > field.value_len { field.value_len = end }
		}
	}

	return .YES
}

post_value :: proc(pc: ^Post_Context, key: string) -> string {
	if pc == nil { return "" }
	for i in 0 ..< pc.field_count {
		f := &pc.fields[i]
		if string(f.key[:f.key_len]) == key { return string(f.value[:f.value_len]) }
	}
	return ""
}

is_htmx :: proc(connection: mhd.Connection) -> bool {
	val := mhd.lookup_connection_value(connection, {.HEADER_KIND}, "HX-Request")
	if val == nil { return false }
	boosted := mhd.lookup_connection_value(connection, {.HEADER_KIND}, "HX-Boosted")
	return boosted == nil
}

respond :: proc(
	connection: mhd.Connection,
	status: mhd.Status,
	body: string,
	content_type: cstring = "text/html; charset=utf-8",
	mode: mhd.Response_Memory_Mode = .MUST_COPY,
) -> mhd.Result {
	response := mhd.create_response_from_buffer(len(body), raw_data(body), mode)
	defer mhd.destroy_response(response)
	mhd.add_response_header(response, "Content-Type", content_type)
	mhd.add_response_header(response, "Connection", "keep-alive")
	when ODIN_DEBUG {
		mhd.add_response_header(response, "Cache-Control", "no-cache, no-store, must-revalidate")
	}
	return mhd.queue_response(connection, status, response)
}

redirect :: proc(connection: mhd.Connection, location: cstring) -> mhd.Result {
	response := mhd.create_response_from_buffer(0, nil, .PERSISTENT)
	defer mhd.destroy_response(response)
	mhd.add_response_header(response, "Location", location)
	return mhd.queue_response(connection, .FOUND, response)
}

post_file :: proc(pc: ^Post_Context, key: string) -> (data: []u8, content_type: string, ok: bool) {
	if pc == nil { return nil, "", false }
	for i in 0 ..< pc.file_count {
		f := &pc.files[i]
		if string(f.key[:f.key_len]) == key && f.size > 0 {
			return f.data[:f.size], string(f.content_type[:f.ct_len]), true
		}
	}
	return nil, "", false
}

validate_image :: proc(content_type: string, data: []u8) -> (ext: string, ok: bool) {
	if len(data) < 4 { return "", false }
	// Check magic bytes
	if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
		return ".png", true
	}
	if data[0] == 0xFF && data[1] == 0xD8 {
		return ".jpg", true
	}
	return "", false
}

save_upload :: proc(
	step_id: i64,
	position: string,
	data: []u8,
	ext: string,
) -> (
	filename: string,
	ok: bool,
) {
	filename = fmt.aprintf("%d_%s%s", step_id, position, ext)
	full_path, _ := filepath.join({config.data_dir, "uploads", filename}, context.temp_allocator)
	if write_err := os.write_entire_file(full_path, data); write_err != nil {
		log.errorf("Failed to write upload file: %s", full_path)
		return "", false
	}
	return filename, true
}

delete_upload :: proc(filename: string) {
	if len(filename) == 0 { return }
	full_path, _ := filepath.join({config.data_dir, "uploads", filename}, context.temp_allocator)
	os.remove(full_path)
}

serve_upload :: proc(connection: mhd.Connection, path: string) -> mhd.Result {
	if strings.contains(path, "..") || strings.contains(path, "/") {
		return respond(connection, .FORBIDDEN, "Forbidden\n", "text/plain")
	}

	ext := filepath.ext(path)
	if ext != ".png" && ext != ".jpg" && ext != ".jpeg" {
		return respond(connection, .FORBIDDEN, "Forbidden\n", "text/plain")
	}

	full_path, _ := filepath.join({config.data_dir, "uploads", path}, context.temp_allocator)
	data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
	if read_err != nil { return respond(connection, .NOT_FOUND, "Not found\n", "text/plain") }

	return respond(connection, .OK, string(data), guess_content_type(path))
}

serve_static :: proc(connection: mhd.Connection, path: string) -> mhd.Result {
	if strings.contains(path, "..") || strings.has_prefix(path, "/") {
		return respond(connection, .FORBIDDEN, "Forbidden\n", "text/plain")
	}

	full_path := fmt.tprintf("static/%s", path)
	data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
	if read_err != nil { return respond(connection, .NOT_FOUND, "Not found\n", "text/plain") }

	return respond(connection, .OK, string(data), guess_content_type(path))
}

guess_content_type :: proc(path: string) -> cstring {
	ext := filepath.ext(path)
	switch ext {
	case ".css":
		return "text/css"
	case ".js":
		return "application/javascript"
	case ".html":
		return "text/html"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".svg":
		return "image/svg+xml"
	case ".ico":
		return "image/x-icon"
	case ".pdf":
		return "application/pdf"
	}
	return "application/octet-stream"
}

// Build mermaid flowchart definition from steps and choices.
// Mirrors the original JS: default step first, edges from choices, orphans, click handlers.
build_flowchart_defn :: proc(story_slug: string, steps: []Step, choices: []Choice) -> string {
	if len(steps) == 0 { return "" }

	default_id: i64 = -1
	for step in steps {
		if step.is_default { default_id = step.id; break }
	}

	incoming := make(map[i64]bool)
	for c in choices { incoming[c.dest_step_id] = true }
	orphan := make(map[i64]bool)
	for s in steps {
		if !s.is_default && s.id not_in incoming { orphan[s.id] = true }
	}

	b := strings.builder_make()

	strings.write_string(&b, `%%{init:{'theme':'base','themeVariables':{`)
	strings.write_string(&b, `'primaryColor':'white',`)
	strings.write_string(&b, `'primaryTextColor':'#444444',`)
	strings.write_string(&b, `'primaryBorderColor':'#DDDDDD',`)
	strings.write_string(&b, `'lineColor':'rgb(234, 88, 12)',`)
	strings.write_string(&b, `'secondaryColor':'#111111',`)
	strings.write_string(&b, `'tertiaryColor':'#fff'`)
	strings.write_string(&b, `}}}%%`)
	strings.write_string(&b, "\nflowchart TD\n")

	added := make(map[i64]bool)

	// Default step first
	if default_id >= 0 {
		name := fc_step_name(steps, default_id)
		fc_node(&b, default_id, name, true, false)
		strings.write_byte(&b, '\n')
		added[default_id] = true
	}

	// Edges from choices
	for choice in choices {
		src_name := fc_step_name(steps, choice.source_step_id)
		dst_name := fc_step_name(steps, choice.dest_step_id)
		fc_node(
			&b,
			choice.source_step_id,
			src_name,
			choice.source_step_id == default_id,
			choice.source_step_id in orphan,
		)
		strings.write_string(&b, " --> ")
		fc_node(
			&b,
			choice.dest_step_id,
			dst_name,
			choice.dest_step_id == default_id,
			choice.dest_step_id in orphan,
		)
		strings.write_byte(&b, '\n')
		added[choice.source_step_id] = true
		added[choice.dest_step_id] = true
	}

	// Unreached steps (incl. orphans)
	for step in steps {
		if step.id not_in added {
			fc_node(&b, step.id, step.internal_name, step.id == default_id, step.id in orphan)
			strings.write_byte(&b, '\n')
		}
	}

	// Click handlers — link each node to its step page
	for step in steps {
		fmt.sbprintf(&b, "click %d href \"/stories/%s/steps/%s\"\n", step.id, story_slug, step.slug)
	}

	// Default step. Stroke colour set in CSS per mode.
	if default_id >= 0 {
		strings.write_string(&b, "classDef defaultStep stroke-width:1px\n")
		fmt.sbprintf(&b, "class %d defaultStep\n", default_id)
	}

	// Orphan steps: dashed border.
	if len(orphan) > 0 {
		strings.write_string(&b, "classDef orphanStep stroke-dasharray:5 3\n")
		for id in orphan {
			fmt.sbprintf(&b, "class %d orphanStep\n", id)
		}
	}

	return strings.to_string(b)
}

// Write a mermaid node. Default uses stadium shape `(["..."])` to mark entry point.
// Orphans get a red bold ∗ prefix in the label (sized correctly by mermaid).
fc_node :: proc(b: ^strings.Builder, id: i64, name: string, is_default: bool, is_orphan: bool) {
	label := name
	if len(label) == 0 { label = DEFAULT_STEP_NAME }
	open_shape, close_shape: string
	switch {
	case is_default:
		open_shape, close_shape = "{{\"", "\"}}"
	case:
		open_shape, close_shape = "[\"", "\"]"
	}
	fmt.sbprintf(b, "%d%s", id, open_shape)
	if is_default {
		strings.write_string(b, "<span title='Default chapter — readers start here.'>")
	}
	if is_orphan {
		strings.write_string(b, "<span title='No chapters lead to this one!'>")
	}
	for ch in label {
		switch ch {
		case '"':
			strings.write_byte(b, '\'')
		case ']':
			strings.write_string(b, "#93;")
		case '#':
			strings.write_string(b, "#35;")
		case '\n':
			strings.write_byte(b, ' ')
		case:
			strings.write_rune(b, ch)
		}
	}
	if is_orphan {
		strings.write_string(b, "</span>")
	}
	if is_default {
		strings.write_string(b, "</span>")
	}
	strings.write_string(b, close_shape)
}

// Look up a step's internal_name by id.
fc_step_name :: proc(steps: []Step, id: i64) -> string {
	for step in steps {
		if step.id == id { return step.internal_name }
	}
	return ""
}
