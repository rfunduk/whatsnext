package main

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import sqlite "lib:sqlite3"
import sqlite_raw "lib:sqlite3/bindings"

db: ^sqlite.DB

db_open :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	_db, status := sqlite.open(cpath)
	if status != nil {
		log.errorf("Failed to open database: %s", sqlite.status_explain(status))
		return false
	}
	db = _db

	// Retry writes for up to 5 seconds if another thread holds the lock.
	sqlite.busy_timeout(db, 5000)

	for sql in SCHEMA {
		status = sqlite.sql_exec(db, sql)
		if status != nil {
			log.errorf("Failed to execute schema: %s", sqlite.status_explain(status))
			return false
		}
	}

	if !db_run_migrations() {
		return false
	}

	if !db_backfill_slugs() {
		return false
	}

	log.infof("Database opened: %s", path)
	return true
}

db_close :: proc() {
	if db != nil { sqlite.close(db) }
}

db_run_migrations :: proc() -> bool {
	// Create _migrations tracking table
	status := sqlite.sql_exec(
		db,
		`
			CREATE TABLE IF NOT EXISTS _migrations (
				name       TEXT PRIMARY KEY,
				applied_at TEXT NOT NULL DEFAULT (datetime('now'))
			)
		`,
	)
	if status != nil {
		log.errorf("Failed to create _migrations table: %s", sqlite.status_explain(status))
		return false
	}

	// Check if table was empty — fresh DB or first migration run.
	// In either case, schema already has everything, so skip execution.
	count_row, count_ok := sqlite.sql_one(db, `
		SELECT COUNT(*)
		FROM _migrations
	`, struct {
			count: i64,
		})
	is_fresh := !count_ok || count_row.count == 0

	// Read migrations directory
	fd, open_err := os.open("migrations")
	if open_err != os.ERROR_NONE {
		log.infof("No migrations directory, skipping")
		return true
	}
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != os.ERROR_NONE {
		log.errorf("Failed to read migrations directory")
		return false
	}
	defer {
		for entry in entries { delete(entry.fullpath) }
		delete(entries)
	}

	// Sort by filename for deterministic order
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	for entry in entries {
		if !strings.has_suffix(entry.name, ".sql") { continue }

		if is_fresh {
			// Fresh DB — schema already has everything, just record it
			status = sqlite.sql_exec(
				db,
				`
					INSERT OR IGNORE INTO _migrations (name)
					VALUES (?)
				`,
				entry.name,
			)
			if status != nil {
				log.errorf("Migration %s: failed to record: %s", entry.name, sqlite.status_explain(status))
				return false
			}
			log.infof("Migration %s: skipped (fresh database)", entry.name)
			continue
		}

		// Check if already applied
		check_row, check_ok := sqlite.sql_one(
			db,
			`
				SELECT COUNT(*)
				FROM _migrations
				WHERE name = ?
			`,
			struct {
				count: i64,
			},
			entry.name,
		)
		already_applied := check_ok && check_row.count > 0

		if already_applied {
			log.infof("Migration %s: already applied", entry.name)
			continue
		}

		// Read and execute migration file
		path := strings.concatenate({"migrations/", entry.name})
		defer delete(path)
		sql_data, read_file_err := os.read_entire_file_from_path(path, context.allocator)
		if read_file_err != nil {
			log.errorf("Migration %s: failed to read file", entry.name)
			return false
		}
		defer delete(sql_data)

		csql := strings.clone_to_cstring(string(sql_data))
		defer delete(csql)

		errmsg: cstring
		exec_status := sqlite_raw.exec(db, csql, nil, nil, &errmsg)
		if exec_status != nil {
			if errmsg != nil {
				log.errorf("Migration %s failed: %s", entry.name, errmsg)
				sqlite_raw.free(auto_cast errmsg)
			} else {
				log.errorf("Migration %s failed: %s", entry.name, sqlite.status_explain(exec_status))
			}
			return false
		}

		// Record as applied
		status = sqlite.sql_exec(db, `
			INSERT INTO _migrations (name)
			VALUES (?)
		`, entry.name)
		if status != nil {
			log.errorf("Migration %s: failed to record: %s", entry.name, sqlite.status_explain(status))
			return false
		}
		log.infof("Migration %s: applied", entry.name)
	}

	return true
}

db_backfill_slugs :: proc() -> bool {
	// Backfill stories with empty slugs
	for {
		row, ok := sqlite.sql_one(db, `
			SELECT id FROM stories WHERE slug = '' LIMIT 1
		`, struct {
				id: i64,
			})
		if !ok { break }
		slug := generate_slug()
		s := sqlite.sql_exec(db, `UPDATE stories SET slug = ? WHERE id = ?`, slug, row.id)
		if s != nil {
			log.errorf("Failed to backfill story slug: %s", sqlite.status_explain(s))
			return false
		}
		log.infof("Backfilled story %d with slug %s", row.id, slug)
	}

	// Backfill steps with empty slugs
	for {
		row, ok := sqlite.sql_one(db, `
			SELECT id FROM steps WHERE slug = '' LIMIT 1
		`, struct {
				id: i64,
			})
		if !ok { break }
		slug := generate_slug()
		s := sqlite.sql_exec(db, `UPDATE steps SET slug = ? WHERE id = ?`, slug, row.id)
		if s != nil {
			log.errorf("Failed to backfill step slug: %s", sqlite.status_explain(s))
			return false
		}
		log.infof("Backfilled step %d with slug %s", row.id, slug)
	}

	// Create unique indexes after all slugs are populated
	for sql in ([?]string {
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_stories_slug ON stories(slug)`,
			`CREATE UNIQUE INDEX IF NOT EXISTS idx_steps_slug ON steps(slug)`,
		}) {
		status := sqlite.sql_exec(db, sql)
		if status != nil {
			log.errorf("Failed to create slug index: %s", sqlite.status_explain(status))
			return false
		}
	}

	return true
}

db_list_stories :: proc() -> [dynamic]Story {
	stories := make([dynamic]Story)
	query, status := sqlite.sql_bind(
		db,
		`
			SELECT id, slug, title, description, cover,
					password_hash, chapter_view,
					created_at, updated_at
			FROM stories
			ORDER BY updated_at DESC
		`,
	)
	if status != nil { return stories }
	for story in sqlite.sql_row(db, query, Story) { append(&stories, story) }
	return stories
}

db_get_story :: proc(id: i64) -> (Story, bool) {
	return sqlite.sql_one(
		db,
		`
			SELECT id, slug, title, description, cover, password_hash,
					chapter_view, created_at, updated_at
			FROM stories
			WHERE id = ?
		`,
		Story,
		id,
	)
}

db_get_story_by_slug :: proc(slug: string) -> (Story, bool) {
	return sqlite.sql_one(
		db,
		`
			SELECT id, slug, title, description, cover, password_hash,
					chapter_view, created_at, updated_at
			FROM stories
			WHERE slug = ?
		`,
		Story,
		slug,
	)
}

db_get_step_by_slug :: proc(slug: string) -> (Step, bool) {
	return sqlite.sql_one(
		db,
		`
			SELECT id, slug, story_id, content, internal_name,
					image_top, image_bottom, is_default,
					created_at, updated_at
			FROM steps
			WHERE slug = ?
		`,
		Step,
		slug,
	)
}

db_list_steps :: proc(story_id: i64) -> [dynamic]Step {
	steps := make([dynamic]Step)
	query, status := sqlite.sql_bind(
		db,
		`
			SELECT id, slug, story_id, content, internal_name,
					image_top, image_bottom, is_default,
					created_at, updated_at
			FROM steps
			WHERE story_id = ?
			ORDER BY id
		`,
		story_id,
	)
	if status != nil { return steps }
	for step in sqlite.sql_row(db, query, Step) { append(&steps, step) }
	return steps
}

db_list_choices :: proc(story_id: i64) -> [dynamic]Choice {
	choices := make([dynamic]Choice)
	query, status := sqlite.sql_bind(
		db,
		`
			SELECT id, story_id, source_step_id, dest_step_id,
					prompt, created_at, updated_at
			FROM choices
			WHERE story_id = ?
			ORDER BY ord, id
		`,
		story_id,
	)
	if status != nil { return choices }
	for choice in sqlite.sql_row(db, query, Choice) { append(&choices, choice) }
	return choices
}

db_create_step :: proc(story_id: i64) -> (i64, string, bool) {
	for _ in 0 ..< 10 {
		slug := generate_slug()
		row, ok := sqlite.sql_one(
			db,
			`
				INSERT INTO steps (story_id, slug)
				VALUES (?, ?)
				RETURNING id
			`,
			struct {
				id: i64,
			},
			story_id,
			slug,
		)
		if ok {
			return row.id, slug, true
		}
		// sql_one returns false for both "no row" and errors.
		// Constraint errors (slug collision) are the retry case.
		// Other errors are logged by sql_bind, so just retry.
		continue
	}
	log.errorf("Failed to create step: slug collision after 10 attempts")
	return 0, "", false
}

db_update_story :: proc(id: i64, title: string, description: string) -> bool {
	status := sqlite.sql_exec(
		db,
		`
			UPDATE stories
			SET title = ?, description = ?, updated_at = datetime('now')
			WHERE id = ?
		`,
		title,
		description,
		id,
	)
	if status != nil {
		log.errorf("Failed to update story: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_update_chapter_view :: proc(id: i64, view: string) -> bool {
	status := sqlite.sql_exec(db, `
			UPDATE stories
			SET chapter_view = ?
			WHERE id = ?
		`, view, id)
	if status != nil {
		log.errorf("Failed to update chapter_view: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_delete_story :: proc(id: i64) -> bool {
	// Clean up image files for all steps before cascade delete
	steps := db_list_steps(id)
	for step in steps {
		delete_upload(step.image_top)
		delete_upload(step.image_bottom)
	}

	status := sqlite.sql_exec(db, `
		DELETE FROM stories
		WHERE id = ?
	`, id)
	if status != nil {
		log.errorf("Failed to delete story: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_create_story :: proc() -> (i64, string, bool) {
	for _ in 0 ..< 10 {
		slug := generate_slug()
		row, ok := sqlite.sql_one(
			db,
			`
				INSERT INTO stories (slug, chapter_view)
				VALUES (?, ?)
				RETURNING id
			`,
			struct {
				id: i64,
			},
			slug,
			DEFAULT_CHAPTER_VIEW,
		)
		if ok {
			return row.id, slug, true
		}
		continue
	}
	log.errorf("Failed to create story: slug collision after 10 attempts")
	return 0, "", false
}

db_create_default_step :: proc(story_id: i64) -> (string, bool) {
	for _ in 0 ..< 10 {
		slug := generate_slug()
		_, ok := sqlite.sql_one(
			db,
			`
				INSERT INTO steps (story_id, slug, is_default)
				VALUES (?, ?, 1)
				RETURNING id
			`,
			struct {
				id: i64,
			},
			story_id,
			slug,
		)
		if ok {
			return slug, true
		}
		continue
	}
	log.errorf("Failed to create default step: slug collision after 10 attempts")
	return "", false
}

db_get_step :: proc(step_id: i64) -> (Step, bool) {
	return sqlite.sql_one(
		db,
		`
			SELECT id, slug, story_id, content, internal_name,
					image_top, image_bottom, is_default,
					created_at, updated_at
			FROM steps
			WHERE id = ?
		`,
		Step,
		step_id,
	)
}

db_update_step :: proc(step_id: i64, internal_name: string, content: string) -> bool {
	status := sqlite.sql_exec(
		db,
		`
			UPDATE steps
			SET internal_name = ?, content = ?, updated_at = datetime('now')
			WHERE id = ?
		`,
		internal_name,
		content,
		step_id,
	)
	if status != nil {
		log.errorf("Failed to update step: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_create_choice :: proc(story_id, source_step_id, dest_step_id: i64, prompt: string) -> (i64, bool) {
	row, ok := sqlite.sql_one(
		db,
		`
			INSERT INTO choices (story_id, source_step_id, dest_step_id, prompt, ord)
			VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(ord) FROM choices WHERE source_step_id = ?), -1) + 1)
			RETURNING id
		`,
		struct {
			id: i64,
		},
		story_id,
		source_step_id,
		dest_step_id,
		prompt,
		source_step_id,
	)
	if !ok {
		log.errorf("Failed to create choice")
		return 0, false
	}
	return row.id, true
}

db_update_choice :: proc(choice_id: i64, step_id: i64, prompt: string) -> bool {
	status := sqlite.sql_exec(
		db,
		`
			UPDATE choices
			SET prompt = ?, updated_at = datetime('now')
			WHERE id = ? AND source_step_id = ?
		`,
		prompt,
		choice_id,
		step_id,
	)
	if status != nil {
		log.errorf("Failed to update choice: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_update_step_image :: proc(step_id: i64, position: string, filename: string) -> bool {
	sql :=
		position == "top" ? `
			UPDATE steps
			SET image_top = ?, updated_at = datetime('now')
			WHERE id = ?
		` : `
			UPDATE steps
			SET image_bottom = ?, updated_at = datetime('now')
			WHERE id = ?
		`
	status := sqlite.sql_exec(db, sql, filename, step_id)
	if status != nil {
		log.errorf("Failed to update step image: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_delete_step :: proc(step_id: i64) -> bool {
	// Clean up image files before deleting
	step, ok := db_get_step(step_id)
	if ok {
		delete_upload(step.image_top)
		delete_upload(step.image_bottom)
	}

	status := sqlite.sql_exec(db, `
		DELETE FROM steps
		WHERE id = ?
	`, step_id)
	if status != nil {
		log.errorf("Failed to delete step: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_delete_choice :: proc(choice_id: i64, step_id: i64) -> bool {
	status := sqlite.sql_exec(
		db,
		`
			DELETE FROM choices
			WHERE id = ? AND source_step_id = ?
		`,
		choice_id,
		step_id,
	)
	if status != nil {
		log.errorf("Failed to delete choice: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

// Set ord = index for each choice ID in the given order, scoped to source_step_id.
db_set_default_step :: proc(story_id: i64, step_id: i64) -> bool {
	if status := sqlite.sql_exec(db, `BEGIN`); status != nil {
		log.errorf("Failed to begin tx: %s", sqlite.status_explain(status))
		return false
	}
	if status := sqlite.sql_exec(
		db,
		`
			UPDATE steps SET is_default = 0, updated_at = datetime('now')
			WHERE story_id = ? AND is_default = 1
		`,
		story_id,
	); status != nil {
		log.errorf("Failed to clear default: %s", sqlite.status_explain(status))
		sqlite.sql_exec(db, `ROLLBACK`)
		return false
	}
	if status := sqlite.sql_exec(
		db,
		`
			UPDATE steps SET is_default = 1, updated_at = datetime('now')
			WHERE id = ? AND story_id = ?
		`,
		step_id,
		story_id,
	); status != nil {
		log.errorf("Failed to set default: %s", sqlite.status_explain(status))
		sqlite.sql_exec(db, `ROLLBACK`)
		return false
	}
	if status := sqlite.sql_exec(db, `COMMIT`); status != nil {
		log.errorf("Failed to commit tx: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

db_reorder_choices :: proc(step_id: i64, choice_ids: []i64) -> bool {
	for id, idx in choice_ids {
		status := sqlite.sql_exec(
			db,
			`
				UPDATE choices
				SET ord = ?
				WHERE id = ? AND source_step_id = ?
			`,
			i64(idx),
			id,
			step_id,
		)
		if status != nil {
			log.errorf("Failed to reorder choice %d: %s", id, sqlite.status_explain(status))
			return false
		}
	}
	return true
}

Choice_View :: struct {
	id:                i64,
	prompt:            string,
	step_name:         string,
	step_slug:         string,
	story_slug:        string,
	current_step_slug: string,
	ord:               i64,
}

db_get_choices_for_step :: proc(
	step_id: i64,
	story_slug: string,
	current_step_slug: string,
) -> (
	incoming: [dynamic]Choice_View,
	outgoing: [dynamic]Choice_View,
) {
	incoming = make([dynamic]Choice_View)
	outgoing = make([dynamic]Choice_View)

	// Outgoing: choices where this step is the source
	out_query, out_status := sqlite.sql_bind(
		db,
		`
			SELECT c.id, c.prompt, s.slug,
					COALESCE(NULLIF(s.internal_name, ''), ?), c.ord
			FROM choices c
			JOIN steps s ON s.id = c.dest_step_id
			WHERE c.source_step_id = ?
			ORDER BY c.ord, c.id
		`,
		DEFAULT_STEP_NAME,
		step_id,
	)
	if out_status == nil {
		for row in sqlite.sql_row(db, out_query, struct {
				id:        i64,
				prompt:    string,
				step_slug: string,
				step_name: string,
				ord:       i64,
			}) {
			append(
				&outgoing,
				Choice_View {
					id = row.id,
					prompt = row.prompt,
					story_slug = story_slug,
					step_slug = row.step_slug,
					step_name = row.step_name,
					current_step_slug = current_step_slug,
					ord = row.ord,
				},
			)
		}
	}

	// Incoming: choices where this step is the destination
	in_query, in_status := sqlite.sql_bind(
		db,
		`
			SELECT c.id, c.prompt, s.slug,
					COALESCE(NULLIF(s.internal_name, ''), ?)
			FROM choices c
			JOIN steps s ON s.id = c.source_step_id
			WHERE c.dest_step_id = ?
			ORDER BY c.id
		`,
		DEFAULT_STEP_NAME,
		step_id,
	)
	if in_status == nil {
		for row in sqlite.sql_row(db, in_query, struct {
				id:        i64,
				prompt:    string,
				step_slug: string,
				step_name: string,
			}) {
			append(
				&incoming,
				Choice_View {
					id = row.id,
					prompt = row.prompt,
					story_slug = story_slug,
					step_slug = row.step_slug,
					step_name = row.step_name,
					current_step_slug = current_step_slug,
				},
			)
		}
	}

	return
}

db_update_story_slug :: proc(id: i64, slug: string) -> bool {
	status := sqlite.sql_exec(
		db,
		`
			UPDATE stories
			SET slug = ?, updated_at = datetime('now')
			WHERE id = ?
		`,
		slug,
		id,
	)
	if status != nil {
		log.errorf("Failed to update story slug: %s", sqlite.status_explain(status))
		return false
	}
	return true
}

SCHEMA :: [?]string {
	`PRAGMA journal_mode = WAL`,
	`PRAGMA foreign_keys = ON`,
	`CREATE TABLE IF NOT EXISTS stories (
		id            INTEGER PRIMARY KEY,
		slug          TEXT NOT NULL DEFAULT '',
		title         TEXT NOT NULL DEFAULT '',
		description   TEXT NOT NULL DEFAULT '',
		published     INTEGER NOT NULL DEFAULT 0,
		cover         TEXT NOT NULL DEFAULT '',
		password_hash TEXT NOT NULL DEFAULT '',
		chapter_view  TEXT NOT NULL,
		created_at    TEXT NOT NULL DEFAULT (datetime('now')),
		updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
	)`,
	`CREATE TABLE IF NOT EXISTS steps (
		id            INTEGER PRIMARY KEY,
		slug          TEXT NOT NULL DEFAULT '',
		story_id      INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
		content       TEXT NOT NULL DEFAULT '',
		internal_name TEXT NOT NULL DEFAULT '',
		image_top     TEXT NOT NULL DEFAULT '',
		image_bottom  TEXT NOT NULL DEFAULT '',
		is_default    INTEGER NOT NULL DEFAULT 0,
		created_at    TEXT NOT NULL DEFAULT (datetime('now')),
		updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
	)`,
	`CREATE TABLE IF NOT EXISTS choices (
		id             INTEGER PRIMARY KEY,
		story_id       INTEGER NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
		source_step_id INTEGER NOT NULL REFERENCES steps(id) ON DELETE CASCADE,
		dest_step_id   INTEGER NOT NULL REFERENCES steps(id) ON DELETE CASCADE,
		prompt         TEXT NOT NULL DEFAULT '',
		ord            INTEGER NOT NULL DEFAULT 0,
		created_at     TEXT NOT NULL DEFAULT (datetime('now')),
		updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
	)`,
	`CREATE INDEX IF NOT EXISTS idx_steps_story_id ON steps(story_id)`,
	`CREATE INDEX IF NOT EXISTS idx_choices_story_id ON choices(story_id)`,
}
