package main

import "core:fmt"
import "core:strings"
import "core:sync"

import mhd "lib:microhttpd"

pdf_lock: sync.Mutex
pdf_generating: map[i64]bool

route_download_pdf :: proc(connection: mhd.Connection, story_slug: string, pdf_type: string) -> mhd.Result {
	format: Pdf_Format
	switch pdf_type {
	case "fullsize":
		format = .Fullsize
	case "booklet":
		format = .Booklet
	case:
		return respond(connection, .NOT_FOUND, "Not found\n", "text/plain")
	}

	story, ok := db_get_story_by_slug(story_slug)
	if !ok {
		return respond(connection, .NOT_FOUND, "Story not found\n", "text/plain")
	}

	// Per-story lock: reject concurrent PDF generation for the same story
	sync.lock(&pdf_lock)
	if story.id in pdf_generating {
		sync.unlock(&pdf_lock)
		return respond(connection, .TOO_MANY_REQUESTS, "PDF generation already in progress\n", "text/plain")
	}
	pdf_generating[story.id] = true
	sync.unlock(&pdf_lock)

	defer {
		sync.lock(&pdf_lock)
		delete_key(&pdf_generating, story.id)
		sync.unlock(&pdf_lock)
	}

	steps := db_list_steps(story.id)
	choices := db_list_choices(story.id)

	pdf_bytes := pdf_generate(story, steps[:], choices[:], format)
	if pdf_bytes == nil {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Failed to generate PDF\n", "text/plain")
	}

	title := story.title
	if len(title) == 0 {
		title = "story"
	}

	// Sanitize filename: replace spaces with dashes, keep alphanumeric + dash
	safe_title := strings.to_lower(title)
	safe_title, _ = strings.replace_all(safe_title, " ", "-")

	filename := fmt.aprintf(`inline; filename="%s-%s.pdf"`, safe_title, pdf_type)
	cfilename := strings.clone_to_cstring(filename)

	response := mhd.create_response_from_buffer(len(pdf_bytes), raw_data(pdf_bytes), .MUST_COPY)
	defer mhd.destroy_response(response)

	mhd.add_response_header(response, "Content-Type", "application/pdf")
	mhd.add_response_header(response, "Content-Disposition", cfilename)

	return mhd.queue_response(connection, .OK, response)
}
