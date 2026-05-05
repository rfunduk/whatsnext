package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"

import mhd "lib:microhttpd"

USE_TRACKING_ALLOCATOR :: #config(USE_TRACKING_ALLOCATOR, false)
global_context: runtime.Context

Args :: struct {
	data_dir: string `args:"pos=0" usage:"Directory holding the SQLite database and uploads."`,
}

config := Args {
	data_dir = ".",
}

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

	flags.parse_or_exit(&config, os.args)

	os.make_directory(config.data_dir)

	uploads_dir, _ := filepath.join({config.data_dir, "uploads"}, context.temp_allocator)
	os.make_directory(uploads_dir)

	db_path, _ := filepath.join({config.data_dir, "whatsnext.db"}, context.temp_allocator)
	if !db_open(db_path) { return }
	defer db_close()

	pdf_generating = make(map[i64]bool)

	load_templates()
	defer cleanup_templates()

	daemon := server_start()
	if daemon == nil { return }
	defer mhd.stop_daemon(daemon)

	server_wait()
}
