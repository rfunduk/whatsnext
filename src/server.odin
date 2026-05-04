package main

import "core:c"
import "core:c/libc"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

import mhd "lib:microhttpd"

PORT :: 8020

running: bool = true

sigint_handler :: proc "c" (_: posix.Signal) { running = false }

server_start :: proc() -> mhd.Daemon {
	posix.signal(.SIGINT, sigint_handler)

	cores := os.get_processor_core_count()
	log.infof("Starting server on :%d with %d threads", PORT, cores)

	daemon := mhd.start_daemon(
		{.USE_INTERNAL_POLLING_THREAD},
		PORT,
		nil,
		nil,
		handle_request,
		nil,
		mhd.Option.THREAD_POOL_SIZE,
		c.uint(cores),
		mhd.Option.CONNECTION_TIMEOUT,
		c.uint(30),
		mhd.Option.END,
	)

	if daemon == nil {
		log.errorf("Failed to start server")
		return nil
	}

	log.infof("Listening on http://0.0.0.0:%d", PORT)
	return daemon
}

server_wait :: proc() {
	for running { posix.pause() }
	log.infof("Shutting down.")
}

handle_request :: proc "c" (
	cls: rawptr,
	connection: mhd.Connection,
	url: cstring,
	method: cstring,
	version: cstring,
	upload_data: [^]u8,
	upload_data_size: ^c.size_t,
	req_cls: ^rawptr,
) -> mhd.Result {
	context = global_context

	method_str := string(method)

	// POST multi-call handling: first call creates post processor,
	// subsequent calls feed data to it, final call falls through to routing.
	if method_str == "POST" {
		if req_cls^ == nil {
			pc := cast(^Post_Context)libc.calloc(1, size_of(Post_Context))
			pc.pp = mhd.create_post_processor(connection, 4096, post_iterator, pc)
			req_cls^ = cast(rawptr)pc
			return .YES
		}
		if upload_data_size^ != 0 {
			pc := cast(^Post_Context)req_cls^
			if pc.pp != nil { mhd.post_process(pc.pp, upload_data, upload_data_size^) }
			upload_data_size^ = 0
			return .YES
		}
	}

	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil {
		return respond(connection, .INTERNAL_SERVER_ERROR, "Allocator error\n", "text/plain")
	}
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	pc := cast(^Post_Context)req_cls^
	defer {
		if pc != nil {
			for i in 0 ..< pc.file_count {
				if pc.files[i].data != nil { libc.free(pc.files[i].data) }
			}
			if pc.pp != nil { mhd.destroy_post_processor(pc.pp) }
			libc.free(pc)
		}
	}

	url_str := string(url)

	if strings.has_prefix(url_str, "/static/") {
		log.debugf("%s %s", method_str, url_str)
		return serve_static(connection, url_str[len("/static/"):])
	}

	if strings.has_prefix(url_str, "/uploads/") {
		log.debugf("%s %s", method_str, url_str)
		return serve_upload(connection, url_str[len("/uploads/"):])
	}

	log.infof("%s %s", method_str, url_str)

	if url_str == "/" {
		return route_stories_list(connection)
	}

	if url_str == "/stories" && method_str == "POST" {
		return route_create_story(connection)
	}

	if strings.has_prefix(url_str, "/stories/") {
		rest := url_str[len("/stories/"):]
		slash_idx := strings.index(rest, "/")
		story_slug := rest if slash_idx < 0 else rest[:slash_idx]

		if len(story_slug) > 0 {
			if slash_idx < 0 {
				if method_str == "POST" {
					return route_save_story(connection, story_slug, pc)
				}
				return route_story_show(connection, story_slug)
			}

			sub_path := rest[slash_idx:]
			if sub_path == "/steps" && method_str == "POST" {
				return route_create_step(connection, story_slug)
			}
			if sub_path == "/delete" {
				if method_str == "POST" {
					return route_delete_story(connection, story_slug)
				}
				return route_story_delete_confirm(connection, story_slug)
			}
			if sub_path == "/settings" {
				if method_str == "POST" {
					return route_save_settings(connection, story_slug, pc)
				}
				return route_story_settings(connection, story_slug)
			}
			if sub_path == "/chapter-view" && method_str == "POST" {
				return route_update_chapter_view(connection, story_slug, pc)
			}
			if strings.has_prefix(sub_path, "/pdf/") {
				pdf_type := sub_path[len("/pdf/"):]
				return route_download_pdf(connection, story_slug, pdf_type)
			}

			if strings.has_prefix(sub_path, "/steps/") {
				steps_rest := sub_path[len("/steps/"):]
				step_slash := strings.index(steps_rest, "/")
				step_slug := steps_rest if step_slash < 0 else steps_rest[:step_slash]

				if len(step_slug) > 0 {
					if step_slash < 0 {
						if method_str == "POST" {
							return route_save_step(connection, story_slug, step_slug, pc)
						}
						return route_step_show(connection, story_slug, step_slug)
					}

					step_sub := steps_rest[step_slash:]
					if step_sub == "/delete" {
						if method_str == "POST" {
							return route_delete_step(connection, story_slug, step_slug)
						}
						return route_step_delete_confirm(connection, story_slug, step_slug)
					}
					if step_sub == "/make-default" {
						if method_str == "POST" {
							return route_make_default_step(connection, story_slug, step_slug)
						}
						return route_step_make_default_confirm(connection, story_slug, step_slug)
					}
					if step_sub == "/choices" && method_str == "POST" {
						return route_create_choice(connection, story_slug, step_slug, pc)
					}
					if step_sub == "/choices/reorder" && method_str == "POST" {
						return route_reorder_choices(connection, story_slug, step_slug, pc)
					}

					if strings.has_prefix(step_sub, "/choices/") {
						choices_rest := step_sub[len("/choices/"):]
						choice_slash := strings.index(choices_rest, "/")
						choice_id_str := choices_rest if choice_slash < 0 else choices_rest[:choice_slash]

						choice_id, choice_ok := strconv.parse_int(choice_id_str)
						if choice_ok && method_str == "POST" {
							cid := i64(choice_id)
							if choice_slash >= 0 {
								choice_action := choices_rest[choice_slash:]
								if choice_action == "/delete" {
									return route_delete_choice(connection, story_slug, step_slug, cid)
								}
							}
							return route_update_choice(connection, story_slug, step_slug, cid, pc)
						}
					}
				}
			}
		}
	}

	log.warnf("404 %s %s", method_str, url_str)
	return respond(connection, .NOT_FOUND, "Not found\n", "text/plain")
}
