package main

Story :: struct {
	id:            i64,
	slug:          string,
	title:         string,
	description:   string,
	cover:         string,
	password_hash: string,
	chapter_view:  string,
	created_at:    string,
	updated_at:    string,
}

Step :: struct {
	id:            i64,
	slug:          string,
	story_id:      i64,
	content:       string,
	internal_name: string,
	image_top:     string,
	image_bottom:  string,
	is_default:    bool,
	created_at:    string,
	updated_at:    string,
}

Choice :: struct {
	id:             i64,
	story_id:       i64,
	source_step_id: i64,
	dest_step_id:   i64,
	prompt:         string,
	created_at:     string,
	updated_at:     string,
}
