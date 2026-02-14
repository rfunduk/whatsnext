package main

import "core:fmt"
import "core:strings"

import mhd "lib:microhttpd"

Stories_Page :: struct {
	page_title:  string,
	stories:     []Story,
	has_stories: bool,
}

route_stories_list :: proc(connection: mhd.Connection) -> mhd.Result {
	stories := db_list_stories()
	data := Stories_Page {
		page_title  = "Stories",
		stories     = stories[:],
		has_stories = len(stories) > 0,
	}
	html, ok := render_template("templates/stories/list.mustache", data)
	if !ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_create_story :: proc(connection: mhd.Connection) -> mhd.Result {
	story_id, story_slug, ok := db_create_story()
	if !ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to create story\n", "text/plain")
	}
	_, step_ok := db_create_default_step(story_id)
	if !step_ok {
		return respond(
			connection,
			.INTERNAL_SERVER_ERROR,
			"Failed to create default step\n",
			"text/plain",
		)
	}
	location := strings.clone_to_cstring(fmt.aprintf("/stories/%s", story_slug))
	return redirect(connection, location)
}

Story_Show_Page :: struct {
	page_title:        string,
	story_slug:        string,
	story_title:       string,
	story_description: string,
	published:         bool,
	steps:             []Step_View,
	has_breadcrumbs:   bool,
	bc_story_title:    string,
	is_flowchart:      bool,
	flowchart_defn:    string,
}

Chapters_Data :: struct {
	story_slug:     string,
	steps:          []Step_View,
	is_flowchart:   bool,
	flowchart_defn: string,
}

Step_View :: struct {
	id:           i64,
	slug:         string,
	story_slug:   string,
	display_name: string,
	is_default:   bool,
	is_orphan:    bool,
}

route_story_show :: proc(connection: mhd.Connection, story_slug: string) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok {
		return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain")
	}

	steps := db_list_steps(story.id)
	choices := db_list_choices(story.id)
	ordered := order_steps(story.slug, steps[:], choices[:])

	page_title := story.title
	if len(page_title) == 0 {
		page_title = DEFAULT_STORY_TITLE
	}

	bc_title := story.title
	if len(bc_title) == 0 {
		bc_title = DEFAULT_STORY_TITLE
	}

	is_fc := story.chapter_view == "flowchart" && len(steps) > 0

	data := Story_Show_Page {
		page_title        = page_title,
		story_slug        = story.slug,
		story_title       = story.title,
		story_description = story.description,
		published         = story.published,
		steps             = ordered,
		has_breadcrumbs   = true,
		bc_story_title    = bc_title,
		is_flowchart      = is_fc,
		flowchart_defn    = is_fc ? build_flowchart_defn(story.slug, steps[:], choices[:]) : "",
	}

	html, tmpl_ok := render_template("templates/stories/show.mustache", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_save_story :: proc(connection: mhd.Connection, story_slug: string, pc: ^Post_Context) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok {
		return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain")
	}

	title := post_value(pc, "title")
	description := post_value(pc, "description")
	if !db_update_story(story.id, title, description) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to save\n", "text/plain")
	}
	location := strings.clone_to_cstring(fmt.aprintf("/stories/%s", story.slug))
	return redirect(connection, location)
}

route_update_chapter_view :: proc(connection: mhd.Connection, story_slug: string, pc: ^Post_Context) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok {
		return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain")
	}

	view := post_value(pc, "chapter_view")
	if view != "list" && view != "flowchart" {
		view = "list"
	}
	db_update_chapter_view(story.id, view)

	steps := db_list_steps(story.id)
	choices := db_list_choices(story.id)
	ordered := order_steps(story.slug, steps[:], choices[:])
	is_fc := view == "flowchart" && len(steps) > 0

	data := Chapters_Data {
		story_slug     = story.slug,
		steps          = ordered,
		is_flowchart   = is_fc,
		flowchart_defn = is_fc ? build_flowchart_defn(story.slug, steps[:], choices[:]) : "",
	}

	html, tmpl_ok := render_partial("_chapters", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

Story_Delete_Data :: struct {
	story_slug:     string,
	story_name:     string,
	step_count:     i64,
	choice_count:   i64,
	plural_steps:   bool,
	plural_choices: bool,
}

route_story_delete_confirm :: proc(connection: mhd.Connection, story_slug: string) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	story_name := story.title
	if len(story_name) == 0 { story_name = DEFAULT_STORY_TITLE }

	steps := db_list_steps(story.id)
	choices := db_list_choices(story.id)

	data := Story_Delete_Data {
		story_slug     = story.slug,
		story_name     = story_name,
		step_count     = i64(len(steps)),
		choice_count   = i64(len(choices)),
		plural_steps   = len(steps) != 1,
		plural_choices = len(choices) != 1,
	}

	html, tmpl_ok := render_partial("_story_delete", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_delete_story :: proc(connection: mhd.Connection, story_slug: string) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	if !db_delete_story(story.id) {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to delete story\n", "text/plain")
	}
	return redirect(connection, "/")
}

route_create_step :: proc(connection: mhd.Connection, story_slug: string) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	_, step_slug, step_ok := db_create_step(story.id)
	if !step_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to create step\n", "text/plain")
	}
	location := strings.clone_to_cstring(fmt.aprintf("/stories/%s/steps/%s", story.slug, step_slug))
	return redirect(connection, location)
}

Story_Settings_Data :: struct {
	story_slug: string,
	story_name: string,
	slug:       string,
	published:  bool,
	error:      string,
}

route_story_settings :: proc(connection: mhd.Connection, story_slug: string) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	story_name := story.title
	if len(story_name) == 0 { story_name = DEFAULT_STORY_TITLE }

	data := Story_Settings_Data {
		story_slug = story.slug,
		story_name = story_name,
		slug       = story.slug,
		published  = story.published,
	}

	html, tmpl_ok := render_partial("_story_settings", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

route_save_settings :: proc(connection: mhd.Connection, story_slug: string, pc: ^Post_Context) -> mhd.Result {
	story, ok := db_get_story_by_slug(story_slug)
	if !ok { return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain") }

	published_str := post_value(pc, "published")
	published := published_str == "1"
	db_update_published(story.id, published)

	new_slug := post_value(pc, "slug")
	redirect_slug := story.slug
	if len(new_slug) > 0 && new_slug != story.slug {
		if !is_valid_slug(new_slug) {
			return render_settings_error(connection, story, new_slug, published, "Only lowercase letters, numbers, and dashes allowed.")
		}
		if !db_update_story_slug(story.id, new_slug) {
			return render_settings_error(connection, story, new_slug, published, "That slug is already taken.")
		}
		redirect_slug = new_slug
	}

	body := fmt.aprintf(`<script>me('#modal').close();window.location='/stories/%s';</script>`, redirect_slug)
	return respond(connection, .OK, body)
}

render_settings_error :: proc(connection: mhd.Connection, story: Story, slug: string, published: bool, error: string) -> mhd.Result {
	story_name := story.title
	if len(story_name) == 0 { story_name = DEFAULT_STORY_TITLE }

	data := Story_Settings_Data {
		story_slug = story.slug,
		story_name = story_name,
		slug       = slug,
		published  = published,
		error      = error,
	}

	html, tmpl_ok := render_partial("_story_settings", data)
	if !tmpl_ok {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Template error\n", "text/plain")
	}
	return respond(connection, .OK, html)
}

// Order steps: DFS from default step following choices, then orphans.
order_steps :: proc(story_slug: string, steps: []Step, choices: []Choice) -> []Step_View {
	result := make([dynamic]Step_View)
	visited := make(map[i64]bool)

	// Track which steps have incoming choices (for orphan detection)
	has_incoming := make(map[i64]bool)
	for choice in choices {
		has_incoming[choice.dest_step_id] = true
	}

	// DFS from default step
	for step in steps {
		if step.is_default {
			order_steps_dfs(step.id, story_slug, steps, choices, has_incoming, &visited, &result)
			break
		}
	}

	// Append unvisited steps (orphans and unreachable)
	for step in steps {
		if step.id not_in visited {
			name := step.internal_name
			if len(name) == 0 {
				name = DEFAULT_STEP_NAME
			}
			append(
				&result,
				Step_View {
					id = step.id,
					slug = step.slug,
					story_slug = story_slug,
					display_name = name,
					is_default = step.is_default,
					is_orphan = !step.is_default && (step.id not_in has_incoming),
				},
			)
		}
	}

	return result[:]
}

order_steps_dfs :: proc(
	step_id: i64,
	story_slug: string,
	steps: []Step,
	choices: []Choice,
	has_incoming: map[i64]bool,
	visited: ^map[i64]bool,
	result: ^[dynamic]Step_View,
) {
	if step_id in visited^ { return }
	visited[step_id] = true

	// Find the step
	step: Step
	found := false
	for s in steps {
		if s.id == step_id {
			step = s
			found = true
			break
		}
	}
	if !found { return }

	name := step.internal_name
	if len(name) == 0 {
		name = DEFAULT_STEP_NAME
	}

	append(
		result,
		Step_View {
			id = step.id,
			slug = step.slug,
			story_slug = story_slug,
			display_name = name,
			is_default = step.is_default,
			is_orphan = !step.is_default && (step_id not_in has_incoming),
		},
	)

	// Follow outgoing choices
	for choice in choices {
		if choice.source_step_id == step_id {
			order_steps_dfs(choice.dest_step_id, story_slug, steps, choices, has_incoming, visited, result)
		}
	}
}
