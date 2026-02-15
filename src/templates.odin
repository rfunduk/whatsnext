package main

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import mustache "lib:mustache4c"

partial_strings: map[string]string
compiled_partials: map[string]mustache.Template
compiled_layout: mustache.Template
layout_bytes: []u8
dir_entries: [2][]os.File_Info
dir_entry_count: int

load_templates :: proc() {
	layout_bytes = os.read_entire_file("templates/layout.mustache") or_else {}
	if len(layout_bytes) == 0 {
		log.errorf("Failed to load layout template")
		return
	}

	partial_strings = make(map[string]string)
	load_partials_from_dir("templates/partials")
	load_partials_from_dir("templates/steps")
	log.infof("Loaded %d partials", len(partial_strings))

	compiled_partials = mustache.compile_partials(partial_strings)
	compiled_layout = mustache.compile(string(layout_bytes))
	if compiled_layout == nil {
		log.errorf("Failed to compile layout template")
	}
}

cleanup_templates :: proc() {
	mustache.release_partials(compiled_partials)
	mustache.release(compiled_layout)
	for _, value in partial_strings { delete(transmute([]u8)value) }
	delete(partial_strings)
	delete(layout_bytes)
	for i in 0 ..< dir_entry_count {
		for entry in dir_entries[i] { delete(entry.fullpath) }
		delete(dir_entries[i])
	}
}

load_partials_from_dir :: proc(dir: string) {
	dh, open_err := os.open(dir)
	if open_err != nil {
		log.warnf("Could not open partials dir: %s", dir)
		return
	}
	defer os.close(dh)

	entries, read_err := os.read_dir(dh, -1)
	if read_err != nil { return }

	if dir_entry_count < len(dir_entries) {
		dir_entries[dir_entry_count] = entries
		dir_entry_count += 1
	}

	for entry in entries {
		if !strings.has_prefix(entry.name, "_") { continue }
		if !strings.has_suffix(entry.name, ".mustache") { continue }

		path := filepath.join({dir, entry.name})
		defer delete(path)
		bytes, ok := os.read_entire_file(path)
		if !ok {
			log.warnf("Failed to read partial: %s", path)
			continue
		}

		key := strings.trim_suffix(entry.name, ".mustache")
		partial_strings[key] = string(bytes)
		log.debugf("Loaded partial: %s", key)
	}
}

// In debug builds, reloads and recompiles all partials from disk (caller must release).
// In release builds, returns the startup-cached compiled map.
current_partials :: proc() -> map[string]mustache.Template {
	when ODIN_DEBUG {
		raw := make(map[string]string)
		for dir in ([2]string{"templates/partials", "templates/steps"}) {
			dh, open_err := os.open(dir)
			if open_err != nil { continue }
			defer os.close(dh)
			entries, read_err := os.read_dir(dh, -1)
			if read_err != nil { continue }
			defer {
				for entry in entries { delete(entry.fullpath) }
				delete(entries)
			}
			for entry in entries {
				if !strings.has_prefix(entry.name, "_") { continue }
				if !strings.has_suffix(entry.name, ".mustache") { continue }
				path := filepath.join({dir, entry.name})
				defer delete(path)
				bytes, ok := os.read_entire_file(path)
				if !ok { continue }
				key := strings.trim_suffix(entry.name, ".mustache")
				raw[key] = string(bytes)
			}
		}
		compiled := mustache.compile_partials(raw)
		// Compiled bytecode copies source strings, so free the raw data.
		for _, value in raw { delete(transmute([]u8)value) }
		delete(raw)
		return compiled
	} else {
		return compiled_partials
	}
}

// In debug builds, reloads and recompiles layout from disk (caller must release).
// In release builds, returns the startup-cached compiled layout.
current_layout :: proc() -> mustache.Template {
	when ODIN_DEBUG {
		bytes, ok := os.read_entire_file("templates/layout.mustache")
		if !ok { return nil }
		compiled := mustache.compile(string(bytes))
		delete(bytes)
		return compiled
	} else {
		return compiled_layout
	}
}

render_partial :: proc(partial_name: string, data: any) -> (string, bool) {
	p := current_partials()
	when ODIN_DEBUG {
		defer mustache.release_partials(p)
	}

	t, found := p[partial_name]
	if !found {
		log.errorf("Partial not found: %s", partial_name)
		return "", false
	}

	output, ok := mustache.render(t, data, p)
	if !ok {
		log.errorf("Failed to render partial %s", partial_name)
		return "", false
	}

	return output, true
}

render_template :: proc(template_path: string, data: any) -> (string, bool) {
	bytes, ok := os.read_entire_file(template_path)
	if !ok {
		log.errorf("Failed to load template: %s", template_path)
		return "", false
	}

	t := mustache.compile(string(bytes))
	if t == nil {
		log.errorf("Failed to compile template: %s", template_path)
		return "", false
	}
	defer mustache.release(t)

	p := current_partials()
	l := current_layout()
	when ODIN_DEBUG {
		defer mustache.release_partials(p)
		defer mustache.release(l)
	}

	if l == nil {
		log.errorf("Layout template not available")
		return "", false
	}

	output, ok2 := mustache.render_in_layout(t, data, l, p)
	if !ok2 {
		log.errorf("Failed to render template %s", template_path)
		return "", false
	}

	return output, true
}
