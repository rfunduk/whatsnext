package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"

import mhd "lib:microhttpd"

USE_TRACKING_ALLOCATOR :: #config(USE_TRACKING_ALLOCATOR, false)
global_context: runtime.Context

main :: proc() {
	context.logger = log.create_file_logger(
		os.stderr,
		.Debug when ODIN_DEBUG else .Info,
		{.Level, .Time, .Terminal_Color},
	)

	when USE_TRACKING_ALLOCATOR {
		default_allocator := context.allocator
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		defer {
			if len(tracking_allocator.allocation_map) > 0 {
				fmt.eprintfln("=== %d allocations not freed ===", len(tracking_allocator.allocation_map))
				for _, entry in tracking_allocator.allocation_map {
					fmt.eprintfln("  %v bytes at %v", entry.size, entry.location)
				}
			}
			if len(tracking_allocator.bad_free_array) > 0 {
				fmt.eprintfln("=== %d bad frees ===", len(tracking_allocator.bad_free_array))
				for entry in tracking_allocator.bad_free_array {
					fmt.eprintfln("  at %v", entry.location)
				}
			}
			mem.tracking_allocator_destroy(&tracking_allocator)
		}
	} else {
		_ = fmt.Info
		_ = mem.Tracking_Allocator
	}

	global_context = context

	Options :: struct {
		db_path: string `args:"pos=0" usage:"Path to SQLite database file."`,
	}

	opt := Options{db_path = "whatsnext.db"}
	flags.parse_or_exit(&opt, os.args)

	os.make_directory("uploads")

	load_templates()
	defer cleanup_templates()

	if !db_open(opt.db_path) { return }
	defer db_close()

	daemon := server_start()
	if daemon == nil { return }
	defer mhd.stop_daemon(daemon)

	server_wait()
}
