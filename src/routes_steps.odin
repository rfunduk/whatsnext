package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import mhd "lib:microhttpd"

Step_Show_Page :: struct {
	page_title:      string,
	story_slug:      string,
	step_slug:       string,
	internal_name:   string,
	body:            string,
	is_default:      bool,
	image_top:       string,
	image_bottom:    string,
	incoming:        []Choice_View,
	outgoing:        []Choice_View,
	available_steps: []Step_Option,
	has_incoming:    bool,
	has_outgoing:    bool,
	has_breadcrumbs: bool,
	bc_story_title:  string,
	bc_step_title:   string,
}

Step_Edit_Data :: struct {
	story_slug:    string,
	step_slug:     string,
	internal_name: string,
	body:          string,
	is_default:    bool,
	image_top:     string,
	image_bottom:  string,
	saved:         bool,
}

Step_Choices_Data :: struct {
	story_slug:      string,
	step_slug:       string,
	incoming:        []Choice_View,
	outgoing:        []Choice_View,
	available_steps: []Step_Option,
	has_incoming:    bool,
	has_outgoing:    bool,
}

Step_Option :: struct {
	id:           i64,
	display_name: string,
}

Step_Delete_Data :: struct {
	story_slug:   string,
	step_slug:    string,
	step_name:    string,
	is_default:   bool,
	incoming:     []Step_Delete_Choice,
	outgoing:     []Step_Delete_Choice,
	has_incoming: bool,
	has_outgoing: bool,
}

Step_Delete_Choice :: struct {
	prompt:      string,
	source_name: string,
	dest_name:   string,
}

build_choices_data :: proc(story: Story, step: Step) -> Step_Choices_Data {
	incoming, outgoing := db_get_choices_for_step(step.id, story.slug, step.slug)

	// Get all steps in this story for the dropdown
	all_steps := db_list_steps(story.id)

	// Build slug->id map, then build set of destination step IDs already used
	slug_to_id := make(map[string]i64)
	for s in all_steps { slug_to_id[s.slug] = s.id }

	used := make(map[i64]bool)
	for c in outgoing {
		if id, ok := slug_to_id[c.step_slug]; ok { used[id] = true }
	}

	available := make([dynamic]Step_Option)
	for s in all_steps {
		if s.id == step.id { continue }
		if s.id in used { continue }
		name := s.internal_name
		if len(name) == 0 {
			name = DEFAULT_STEP_NAME
		}
		append(&available, Step_Option{id = s.id, display_name = name})
	}

	return Step_Choices_Data {
		story_slug = story.slug,
		step_slug = step.slug,
		incoming = incoming[:],
		outgoing = outgoing[:],
		available_steps = available[:],
		has_incoming = len(incoming) > 0,
		has_outgoing = len(outgoing) > 0,
	}
}

route_step_show :: proc(connection: mhd.Connection, story_slug: string, step_slug: string) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	choices_data := build_choices_data(story, step)

	page_title := step.internal_name
	if len(page_title) == 0 { page_title = DEFAULT_STEP_NAME }

	bc_story := story.title
	if len(bc_story) == 0 { bc_story = DEFAULT_STORY_TITLE }

	data := Step_Show_Page {
		page_title      = page_title,
		story_slug      = story.slug,
		step_slug       = step.slug,
		internal_name   = step.internal_name,
		body            = step.content,
		is_default      = step.is_default,
		image_top       = step.image_top,
		image_bottom    = step.image_bottom,
		incoming        = choices_data.incoming,
		outgoing        = choices_data.outgoing,
		available_steps = choices_data.available_steps,
		has_incoming    = choices_data.has_incoming,
		has_outgoing    = choices_data.has_outgoing,
		has_breadcrumbs = true,
		bc_story_title  = bc_story,
		bc_step_title   = page_title,
	}

	html, tmpl_ok := render_template("templates/steps/show.mustache", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_save_step :: proc(
	connection: mhd.Connection,
	story_slug: string,
	step_slug: string,
	pc: ^Post_Context,
) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	internal_name := post_value(pc, "internal_name")
	content := post_value(pc, "content")

	if !db_update_step(step.id, internal_name, content) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to save step\n", "text/plain")
	}

	// Handle image uploads
	for position in ([2]string{"top", "bottom"}) {
		field_name := position == "top" ? "image_top" : "image_bottom"
		delete_field := position == "top" ? "delete_image_top" : "delete_image_bottom"
		old_image := position == "top" ? step.image_top : step.image_bottom

		// Check for delete checkbox
		if post_value(pc, delete_field) == "1" {
			delete_upload(old_image)
			db_update_step_image(step.id, position, "")
			continue
		}

		// Check for new upload
		file_data, ct, file_ok := post_file(pc, field_name)
		if file_ok {
			ext, valid := validate_image(ct, file_data)
			if valid {
				delete_upload(old_image)
				if filename, save_ok := save_upload(step.id, position, file_data, ext); save_ok {
					db_update_step_image(step.id, position, filename)
				}
			}
		}
	}

	// Reload step to get updated image fields
	step, ok = db_get_step_by_slug(step_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	if !is_htmx(connection) {
		return step_redirect(connection, story.slug, step.slug)
	}

	data := Step_Edit_Data {
		story_slug    = story.slug,
		step_slug     = step.slug,
		internal_name = step.internal_name,
		body          = step.content,
		is_default    = step.is_default,
		image_top     = step.image_top,
		image_bottom  = step.image_bottom,
		saved         = true,
	}

	html, tmpl_ok := render_partial("_step_edit", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

step_redirect :: proc(connection: mhd.Connection, story_slug: string, step_slug: string) -> mhd.Result {
	location := strings.clone_to_cstring(fmt.aprintf("/stories/%s/steps/%s", story_slug, step_slug))
	return redirect(connection, location)
}

route_create_choice :: proc(
	connection: mhd.Connection,
	story_slug: string,
	step_slug: string,
	pc: ^Post_Context,
) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	dest_str := post_value(pc, "dest_step_id")
	prompt := post_value(pc, "prompt")

	dest_step_id: i64
	if dest_str == "new" {
		new_id, _, new_ok := db_create_step(story.id)
		if !new_ok {
			return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to create step\n", "text/plain")
		}
		dest_step_id = new_id
	} else {
		parsed, parse_ok := strconv.parse_int(dest_str)
		if !parse_ok {
			return respond(connection, .BAD_REQUEST, "Invalid destination\n", "text/plain")
		}
		dest_step_id = i64(parsed)
	}

	_, choice_ok := db_create_choice(story.id, step.id, dest_step_id, prompt)
	if !choice_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to create choice\n", "text/plain")
	}

	if !is_htmx(connection) {
		return step_redirect(connection, story.slug, step.slug)
	}

	choices_data := build_choices_data(story, step)
	html, tmpl_ok := render_partial("_step_choices", choices_data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_update_choice :: proc(
	connection: mhd.Connection,
	story_slug: string,
	step_slug: string,
	choice_id: i64,
	pc: ^Post_Context,
) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	prompt := post_value(pc, "prompt")

	if !db_update_choice(choice_id, step.id, prompt) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to update choice\n", "text/plain")
	}

	if !is_htmx(connection) {
		return step_redirect(connection, story.slug, step.slug)
	}

	choices_data := build_choices_data(story, step)
	html, tmpl_ok := render_partial("_step_choices", choices_data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_delete_choice :: proc(
	connection: mhd.Connection,
	story_slug: string,
	step_slug: string,
	choice_id: i64,
) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	if !db_delete_choice(choice_id, step.id) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to delete choice\n", "text/plain")
	}

	if !is_htmx(connection) {
		return step_redirect(connection, story.slug, step.slug)
	}

	choices_data := build_choices_data(story, step)
	html, tmpl_ok := render_partial("_step_choices", choices_data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_reorder_choices :: proc(
	connection: mhd.Connection,
	story_slug: string,
	step_slug: string,
	pc: ^Post_Context,
) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	order_str := post_value(pc, "order")
	if len(order_str) > 0 {
		parts := strings.split(order_str, ",")
		ids := make([dynamic]i64)
		for p in parts {
			id, parse_ok := strconv.parse_int(strings.trim_space(p))
			if parse_ok {
				append(&ids, i64(id))
			}
		}
		if len(ids) > 0 {
			db_reorder_choices(step.id, ids[:])
		}
	}

	if !is_htmx(connection) {
		return step_redirect(connection, story.slug, step.slug)
	}

	choices_data := build_choices_data(story, step)
	html, tmpl_ok := render_partial("_step_choices", choices_data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_step_delete_confirm :: proc(connection: mhd.Connection, story_slug: string, step_slug: string) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	step_name := step.internal_name
	if len(step_name) == 0 { step_name = DEFAULT_STEP_NAME }

	incoming_raw, outgoing_raw := db_get_choices_for_step(step.id, story.slug, step.slug)

	incoming := make([dynamic]Step_Delete_Choice)
	for c in incoming_raw {
		prompt := c.prompt
		if len(prompt) == 0 { prompt = "(no prompt)" }
		append(&incoming, Step_Delete_Choice{prompt = prompt, source_name = c.step_name})
	}

	outgoing := make([dynamic]Step_Delete_Choice)
	for c in outgoing_raw {
		prompt := c.prompt
		if len(prompt) == 0 { prompt = "(no prompt)" }
		append(&outgoing, Step_Delete_Choice{prompt = prompt, dest_name = c.step_name})
	}

	data := Step_Delete_Data {
		story_slug   = story.slug,
		step_slug    = step.slug,
		step_name    = step_name,
		is_default   = step.is_default,
		incoming     = incoming[:],
		outgoing     = outgoing[:],
		has_incoming = len(incoming) > 0,
		has_outgoing = len(outgoing) > 0,
	}

	html, tmpl_ok := render_partial("_step_delete", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_delete_step :: proc(connection: mhd.Connection, story_slug: string, step_slug: string) -> mhd.Result {
	story, story_ok := db_get_story_by_slug(story_slug)
	if !story_ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	step, ok := db_get_step_by_slug(step_slug)
	if !ok || step.story_id != story.id { return respond(connection, .NOT_FOUND, "Step not found\n", "text/plain") }

	if step.is_default {
		return respond(connection, .BAD_REQUEST, "Cannot delete the default step\n", "text/plain")
	}

	if !db_delete_step(step.id) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to delete step\n", "text/plain")
	}

	location := strings.clone_to_cstring(fmt.aprintf("/stories/%s", story_slug))
	return redirect(connection, location)
}
