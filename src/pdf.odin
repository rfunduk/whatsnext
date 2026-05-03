package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import haru "lib:libharu"

// --- Constants (matching old Go code) ---

// A5 in points
A5_WIDTH: f32 : 419.53
A5_HEIGHT: f32 : 595.28

// Margins in points (converted from mm: 1mm = 2.8346pt)
BINDING_MARGIN: f32 : 51.02 // 18mm
OUTER_MARGIN: f32 : 39.68 // 14mm
TOP_MARGIN: f32 : 34.02 // 12mm
BOTTOM_MARGIN: f32 : 34.02

// Typography
TITLE_SIZE: f32 : 28.0
CONTENT_SIZE: f32 : 16.0
CHOICE_SIZE: f32 : 12.0
DESC_SIZE: f32 : 10.0
PAGE_NUM_SIZE: f32 : 10.0
THE_END_SIZE: f32 : 14.0

CONTENT_LINE_HEIGHT_FACTOR: f32 : 1.5
CHOICE_LINE_HEIGHT_FACTOR: f32 : 1.75
DESC_LINE_HEIGHT_FACTOR: f32 : 1.25

CHOICE_INDENT: f32 : 62.36 // 22mm in points

OFFSET_BETWEEN: f32 : 28.35 // 10mm in points

// Colors (0-1 range)
TEXT_COLOR :: [3]f32{50.0 / 255, 50.0 / 255, 50.0 / 255}
CHOICE_COLOR :: [3]f32{100.0 / 255, 100.0 / 255, 100.0 / 255}
DESC_COLOR :: [3]f32{10.0 / 255, 10.0 / 255, 10.0 / 255}
PAGE_NUM_COLOR :: [3]f32{100.0 / 255, 100.0 / 255, 100.0 / 255}
THE_END_COLOR :: [3]f32{110.0 / 255, 110.0 / 255, 110.0 / 255}

// --- PDF format enum ---

Pdf_Format :: enum {
	Fullsize,
	Booklet,
}

// --- Layout data structures ---

Font_Style :: enum {
	Title,
	Content,
	Choice,
	Desc,
	Page_Num,
	The_End,
}

Pdf_Line :: struct {
	text:         string,
	font:         Font_Style,
	x, y:         f32,
	alignment:    enum {
		Left,
		Center,
		Right,
	},
	image_path:   string,
	image_width:  f32,
	image_height: f32,
}

Pdf_Page :: struct {
	lines:        [dynamic]Pdf_Line,
	display_num:  int, // 0 = no page number
	margin_left:  f32,
	margin_right: f32,
}

Step_Location :: struct {
	first_page: int,
	last_page:  int,
	choice_y:   f32,
}

// --- Error handler ---

haru_error_handler :: proc "c" (error_no: haru.Status, detail_no: haru.Status, user_data: rawptr) {
	context = global_context
	log.errorf("libharu error: 0x%04X (detail: %d)", error_no, detail_no)
}

// Convert UTF-8 string to Windows-1252 (WinAnsiEncoding) for libharu.
// Unmappable codepoints become '?'.
pdf_to_win1252 :: proc(s: string) -> string {
	buf := make([dynamic]u8)
	for r in s {
		if r < 0x80 {
			append(&buf, u8(r))
		} else if b, ok := utf8_to_win1252(r); ok {
			append(&buf, b)
		} else {
			append(&buf, '?')
		}
	}
	return string(buf[:])
}

utf8_to_win1252 :: proc(r: rune) -> (u8, bool) {
	// Latin-1 supplement (U+00A0..U+00FF) maps directly
	if r >= 0xA0 && r <= 0xFF { return u8(r), true }

	// Windows-1252 specials in the 0x80..0x9F range
	switch r {
	case 0x20AC: return 0x80, true // euro sign
	case 0x201A: return 0x82, true // single low-9 quote
	case 0x0192: return 0x83, true // f with hook
	case 0x201E: return 0x84, true // double low-9 quote
	case 0x2026: return 0x85, true // ellipsis
	case 0x2020: return 0x86, true // dagger
	case 0x2021: return 0x87, true // double dagger
	case 0x02C6: return 0x88, true // circumflex
	case 0x2030: return 0x89, true // per mille
	case 0x0160: return 0x8A, true // S caron
	case 0x2039: return 0x8B, true // single left angle quote
	case 0x0152: return 0x8C, true // OE ligature
	case 0x017D: return 0x8E, true // Z caron
	case 0x2018: return 0x91, true // left single quote
	case 0x2019: return 0x92, true // right single quote
	case 0x201C: return 0x93, true // left double quote
	case 0x201D: return 0x94, true // right double quote
	case 0x2022: return 0x95, true // bullet
	case 0x2013: return 0x96, true // en dash
	case 0x2014: return 0x97, true // em dash
	case 0x02DC: return 0x98, true // tilde
	case 0x2122: return 0x99, true // trademark
	case 0x0161: return 0x9A, true // s caron
	case 0x203A: return 0x9B, true // single right angle quote
	case 0x0153: return 0x9C, true // oe ligature
	case 0x017E: return 0x9E, true // z caron
	case 0x0178: return 0x9F, true // Y diaeresis
	}
	return 0, false
}

// --- Public entry point ---

pdf_generate :: proc(story: Story, steps: []Step, choices: []Choice, format: Pdf_Format) -> []u8 {
	ordered_steps := pdf_order_steps(story, steps, choices)
	if len(ordered_steps) == 0 {
		log.errorf("No steps to render for story %d", story.id)
		return nil
	}

	pages := pdf_compute_layout(story, ordered_steps, choices)
	defer {
		for &page in pages { delete(page.lines) }
		delete(pages)
	}

	switch format {
	case .Fullsize:
		return pdf_render_fullsize(pages[:])
	case .Booklet:
		return pdf_render_booklet(pages[:])
	}
	return nil
}

// --- Step ordering (seeded random, matching old code) ---

pdf_order_steps :: proc(story: Story, steps: []Step, choices: []Choice) -> []Step {
	// Track which steps have incoming choices (for orphan detection)
	has_incoming := make(map[i64]bool)
	for choice in choices { has_incoming[choice.dest_step_id] = true }

	// Find default step
	default_step: Step
	default_found := false
	other_steps := make([dynamic]Step)

	for step in steps {
		if step.is_default {
			default_step = step
			default_found = true
		} else {
			// Skip orphans (no inbound choices and not default)
			if step.id not_in has_incoming { continue }
			append(&other_steps, step)
		}
	}

	if !default_found {
		delete(other_steps)
		return nil
	}

	// Deterministic shuffle using created_at as seed
	seed := pdf_hash_string(story.created_at)
	pdf_shuffle(other_steps[:], seed)

	// Build ordered list: default first, then shuffled others
	result := make([dynamic]Step)
	append(&result, default_step)
	for step in other_steps { append(&result, step) }
	delete(other_steps)

	return result[:]
}

// Simple string hash for deterministic seeding
pdf_hash_string :: proc(s: string) -> u64 {
	h: u64 = 5381
	for b in transmute([]u8)s { h = ((h << 5) + h) + u64(b) }
	return h
}

// Fisher-Yates shuffle with simple LCG
pdf_shuffle :: proc(items: []Step, seed: u64) {
	state := seed
	for i := len(items) - 1; i > 0; i -= 1 {
		state = state * 6364136223846793005 + 1442695040888963407
		j := int(state >> 33) % (i + 1)
		items[i], items[j] = items[j], items[i]
	}
}

// --- Font setup helpers ---

Haru_Fonts :: struct {
	title:    ^haru.Font,
	content:  ^haru.Font,
	choice:   ^haru.Font,
	desc:     ^haru.Font,
	page_num: ^haru.Font,
	the_end:  ^haru.Font,
}

pdf_load_fonts :: proc(doc: ^haru.Doc) -> Haru_Fonts {
	sans := haru.LoadTTFontFromFile(doc, "vendor/fonts/NotoSans-Regular.ttf", 1)
	sans_bold := haru.LoadTTFontFromFile(doc, "vendor/fonts/NotoSans-Bold.ttf", 1)
	sans_italic := haru.LoadTTFontFromFile(doc, "vendor/fonts/NotoSans-Italic.ttf", 1)
	serif := haru.LoadTTFontFromFile(doc, "vendor/fonts/NotoSerif-Regular.ttf", 1)

	return Haru_Fonts {
		title = haru.GetFont(doc, sans_bold, "WinAnsiEncoding"),
		content = haru.GetFont(doc, serif, "WinAnsiEncoding"),
		choice = haru.GetFont(doc, sans_italic, "WinAnsiEncoding"),
		desc = haru.GetFont(doc, serif, "WinAnsiEncoding"),
		page_num = haru.GetFont(doc, sans, "WinAnsiEncoding"),
		the_end = haru.GetFont(doc, sans, "WinAnsiEncoding"),
	}
}

pdf_font_for_style :: proc(fonts: Haru_Fonts, style: Font_Style) -> (^haru.Font, f32) {
	switch style {
	case .Title:
		return fonts.title, TITLE_SIZE
	case .Content:
		return fonts.content, CONTENT_SIZE
	case .Choice:
		return fonts.choice, CHOICE_SIZE
	case .Desc:
		return fonts.desc, DESC_SIZE
	case .Page_Num:
		return fonts.page_num, PAGE_NUM_SIZE
	case .The_End:
		return fonts.the_end, THE_END_SIZE
	}
	return fonts.content, CONTENT_SIZE
}

// --- Text measurement ---

// Wraps text to fit within max_width, returns lines.
// Uses HPDF_Font_MeasureText for accurate measurement.
pdf_wrap_text :: proc(font: ^haru.Font, font_size: f32, text: string, max_width: f32) -> []string {
	lines := make([dynamic]string)
	if len(text) == 0 { return lines[:] }

	remaining := text
	for len(remaining) > 0 {
		text_bytes := transmute([]u8)remaining
		real_width: haru.Real
		fit := haru.Font_MeasureText(
			font,
			raw_data(text_bytes),
			haru.Uint(len(text_bytes)),
			haru.Real(max_width),
			haru.Real(font_size),
			0, // char_space
			0, // word_space
			true, // wordwrap
			&real_width,
		)

		if fit == 0 || int(fit) >= len(remaining) {
			// Everything fits or nothing fits (force all)
			append(&lines, remaining)
			break
		}

		// Find last space at or before fit position for clean break
		break_pos := int(fit)
		for break_pos > 0 && remaining[break_pos - 1] != ' ' { break_pos -= 1 }

		// Force break if no space found
		if break_pos == 0 { break_pos = int(fit) }

		append(&lines, remaining[:break_pos])
		remaining = strings.trim_left_space(remaining[break_pos:])
	}

	return lines[:]
}

// --- Layout computation ---

pdf_compute_layout :: proc(story: Story, steps: []Step, choices: []Choice) -> [dynamic]Pdf_Page {
	// Create a temporary doc just for font metrics
	doc := haru.New(haru_error_handler, nil)
	if doc == nil {
		log.errorf("Failed to create temporary PDF doc for metrics")
		return {}
	}
	defer haru.Free(doc)

	fonts := pdf_load_fonts(doc)

	pages := make([dynamic]Pdf_Page)
	step_locations := make(map[i64]Step_Location)

	// Build step->choices map
	step_choices := make(map[i64][dynamic]Choice)
	for choice in choices {
		if choice.source_step_id not_in step_choices {
			step_choices[choice.source_step_id] = make([dynamic]Choice)
		}
		append(&step_choices[choice.source_step_id], choice)
	}

	// --- Title page ---
	{
		title_page := Pdf_Page {
			lines        = make([dynamic]Pdf_Line),
			display_num  = 0,
			margin_left  = 56.69, // 20mm
			margin_right = 56.69,
		}

		title := pdf_to_win1252(story.title)
		if len(title) == 0 { title = DEFAULT_STORY_TITLE }

		content_width := A5_WIDTH - title_page.margin_left - title_page.margin_right

		// Calculate total height for vertical centering
		title_lines := pdf_wrap_text(fonts.title, TITLE_SIZE, title, content_width)
		title_height := f32(len(title_lines)) * TITLE_SIZE

		desc := pdf_to_win1252(strings.trim_right_space(story.description))
		desc_lines_all := make([dynamic]string)
		if len(desc) > 0 {
			paragraphs := strings.split(desc, "\n")
			for p in paragraphs {
				if len(p) == 0 {
					append(&desc_lines_all, "")
				} else {
					wrapped := pdf_wrap_text(fonts.desc, DESC_SIZE, p, content_width)
					for line in wrapped {
						append(&desc_lines_all, line)
					}
				}
			}
		}
		desc_height: f32 = 0
		if len(desc_lines_all) > 0 {
			desc_height = OFFSET_BETWEEN + f32(len(desc_lines_all)) * DESC_SIZE * DESC_LINE_HEIGHT_FACTOR
		}

		total_height := title_height + desc_height
		start_y := (A5_HEIGHT - total_height) / 2

		// Title lines
		y := start_y
		for line in title_lines {
			append(
				&title_page.lines,
				Pdf_Line{text = line, font = .Title, x = title_page.margin_left, y = y},
			)
			y += TITLE_SIZE
		}

		// Description lines
		if len(desc_lines_all) > 0 {
			y += OFFSET_BETWEEN
			desc_line_height := DESC_SIZE * DESC_LINE_HEIGHT_FACTOR
			for line in desc_lines_all {
				if len(line) > 0 {
					append(
						&title_page.lines,
						Pdf_Line{text = line, font = .Desc, x = title_page.margin_left, y = y},
					)
				}
				y += desc_line_height
			}
		}

		append(&pages, title_page)
	}

	// --- Blank page after title ---
	append(
		&pages,
		Pdf_Page {
			lines = make([dynamic]Pdf_Line),
			display_num = 0,
			margin_left = OUTER_MARGIN,
			margin_right = BINDING_MARGIN,
		},
	)

	// --- Step pages ---
	display_page_num := 1

	for step in steps {
		page_idx := len(pages) // first page for this step
		is_left := (len(pages) % 2 == 0) // even index = left side in booklet
		m_left := BINDING_MARGIN if is_left else OUTER_MARGIN
		m_right := OUTER_MARGIN if is_left else BINDING_MARGIN

		page := Pdf_Page {
			lines        = make([dynamic]Pdf_Line),
			display_num  = display_page_num,
			margin_left  = m_left,
			margin_right = m_right,
		}

		content_width := A5_WIDTH - m_left - m_right

		// Page number space at top
		y: f32 = TOP_MARGIN + PAGE_NUM_SIZE * 3 // skip past page number area

		// Image top
		if len(step.image_top) > 0 {
			img_path := fmt.aprintf("uploads/%s", step.image_top)
			img_w, img_h := pdf_measure_image(doc, img_path)
			if img_w > 0 && img_h > 0 {
				scale := content_width / img_w
				draw_h := img_h * scale

				// Check page overflow
				if y + draw_h + OFFSET_BETWEEN > A5_HEIGHT - BOTTOM_MARGIN {
					append(&pages, page)
					display_page_num += 1

					is_left = (len(pages) % 2 == 0)
					m_left = BINDING_MARGIN if is_left else OUTER_MARGIN
					m_right = OUTER_MARGIN if is_left else BINDING_MARGIN
					content_width = A5_WIDTH - m_left - m_right
					scale = content_width / img_w
					draw_h = img_h * scale

					page = Pdf_Page {
						lines        = make([dynamic]Pdf_Line),
						display_num  = display_page_num,
						margin_left  = m_left,
						margin_right = m_right,
					}
					y = TOP_MARGIN + PAGE_NUM_SIZE * 3
				}

				append(&page.lines, Pdf_Line {
					x            = m_left,
					y            = y,
					image_path   = img_path,
					image_width  = content_width,
					image_height = draw_h,
				})
				y += draw_h + OFFSET_BETWEEN
			}
		}

		// Content text
		content_raw, _ := strings.replace_all(step.content, "\r", "")
		content := pdf_to_win1252(content_raw)
		content_line_height := CONTENT_SIZE * CONTENT_LINE_HEIGHT_FACTOR

		if len(strings.trim_space(content)) > 0 {
			paragraphs := strings.split(content, "\n")
			for p in paragraphs {
				if len(p) == 0 {
					y += content_line_height
					continue
				}
				wrapped := pdf_wrap_text(fonts.content, CONTENT_SIZE, p, content_width)
				for line in wrapped {
					// Check page overflow
					if y + content_line_height > A5_HEIGHT - BOTTOM_MARGIN {
						append(&pages, page)
						display_page_num += 1

						is_left = (len(pages) % 2 == 0)
						m_left = BINDING_MARGIN if is_left else OUTER_MARGIN
						m_right = OUTER_MARGIN if is_left else BINDING_MARGIN
						content_width = A5_WIDTH - m_left - m_right

						page = Pdf_Page {
							lines        = make([dynamic]Pdf_Line),
							display_num  = display_page_num,
							margin_left  = m_left,
							margin_right = m_right,
						}
						y = TOP_MARGIN + PAGE_NUM_SIZE * 3
					}

					append(&page.lines, Pdf_Line{text = line, font = .Content, x = m_left, y = y})
					y += content_line_height
				}
			}
		}

		// Image bottom
		if len(step.image_bottom) > 0 {
			img_path := fmt.aprintf("uploads/%s", step.image_bottom)
			img_w, img_h := pdf_measure_image(doc, img_path)
			if img_w > 0 && img_h > 0 {
				scale := content_width / img_w
				draw_h := img_h * scale

				if y + draw_h + OFFSET_BETWEEN > A5_HEIGHT - BOTTOM_MARGIN {
					append(&pages, page)
					display_page_num += 1

					is_left = (len(pages) % 2 == 0)
					m_left = BINDING_MARGIN if is_left else OUTER_MARGIN
					m_right = OUTER_MARGIN if is_left else BINDING_MARGIN
					content_width = A5_WIDTH - m_left - m_right
					scale = content_width / img_w
					draw_h = img_h * scale

					page = Pdf_Page {
						lines        = make([dynamic]Pdf_Line),
						display_num  = display_page_num,
						margin_left  = m_left,
						margin_right = m_right,
					}
					y = TOP_MARGIN + PAGE_NUM_SIZE * 3
				}

				append(&page.lines, Pdf_Line {
					x            = m_left,
					y            = y,
					image_path   = img_path,
					image_width  = content_width,
					image_height = draw_h,
				})
				y += draw_h + OFFSET_BETWEEN
			}
		}

		// Space before choices
		y += content_line_height

		// Check if choices fit on this page
		step_choice_list := step_choices[step.id] if step.id in step_choices else {}
		choice_line_height := CHOICE_SIZE * CHOICE_LINE_HEIGHT_FACTOR
		choice_avail_width := A5_WIDTH - CHOICE_INDENT - m_right

		choice_total_lines := 0
		if len(step_choice_list) == 0 {
			choice_total_lines = 1 // "THE END"
		} else {
			for ch in step_choice_list {
				// Measure with placeholder page number for wrapping estimate
				probe := pdf_to_win1252(fmt.aprintf("%s, go to page 99", ch.prompt))
				wrapped := pdf_wrap_text(fonts.choice, CHOICE_SIZE, probe, choice_avail_width)
				choice_total_lines += max(len(wrapped), 1)
			}
		}
		choices_height := f32(choice_total_lines) * choice_line_height

		if y + choices_height > A5_HEIGHT - BOTTOM_MARGIN {
			append(&pages, page)
			display_page_num += 1

			is_left = (len(pages) % 2 == 0)
			m_left = BINDING_MARGIN if is_left else OUTER_MARGIN
			m_right = OUTER_MARGIN if is_left else BINDING_MARGIN

			page = Pdf_Page {
				lines        = make([dynamic]Pdf_Line),
				display_num  = display_page_num,
				margin_left  = m_left,
				margin_right = m_right,
			}
			y = TOP_MARGIN + PAGE_NUM_SIZE * 3
		}

		// Record step location (choice_y will be used in second pass)
		step_locations[step.id] = Step_Location {
			first_page = page_idx,
			last_page  = len(pages), // current page index
			choice_y   = y,
		}

		// Reserve space for choices (they'll be filled in second pass)
		y += choices_height

		append(&pages, page)
		display_page_num += 1
	}

	// --- Second pass: fill in choices ---
	for step in steps {
		loc := step_locations[step.id]
		last_page := &pages[loc.last_page]
		y := loc.choice_y
		choice_line_height := CHOICE_SIZE * CHOICE_LINE_HEIGHT_FACTOR

		step_choice_list := step_choices[step.id] if step.id in step_choices else {}

		if len(step_choice_list) == 0 {
			// THE END
			append(
				&last_page.lines,
				Pdf_Line{text = "THE END", font = .The_End, x = 0, y = y, alignment = .Center},
			)
		} else {
			choice_avail_width := A5_WIDTH - CHOICE_INDENT - last_page.margin_right
			for choice in step_choice_list {
				dest_loc, dest_ok := step_locations[choice.dest_step_id]
				if !dest_ok { continue }

				dest_display := pages[dest_loc.first_page].display_num
				full_text := pdf_to_win1252(fmt.aprintf("%s, go to page %d", choice.prompt, dest_display))
				wrapped := pdf_wrap_text(fonts.choice, CHOICE_SIZE, full_text, choice_avail_width)
				for line, li in wrapped {
				x := CHOICE_INDENT + (CHOICE_SIZE if li > 0 else 0)
					append(
						&last_page.lines,
						Pdf_Line {
							text = line,
							font = .Choice,
							x    = x,
							y    = y,
						},
					)
					y += choice_line_height
				}
			}
		}
	}

	// Clean up step_choices
	for _, &list in step_choices { delete(list) }
	delete(step_choices)
	delete(step_locations)

	// If total page count is even and the last page has content,
	// add 2 blank pages so the booklet back cover is blank.
	if len(pages) % 2 == 0 && len(pages) > 0 && len(pages[len(pages) - 1].lines) > 0 {
		for _ in 0 ..< 2 {
			append(&pages, Pdf_Page {
				lines        = make([dynamic]Pdf_Line),
				display_num  = 0,
				margin_left  = OUTER_MARGIN,
				margin_right = BINDING_MARGIN,
			})
		}
	}

	return pages
}

// --- Full-size A5 rendering ---

pdf_render_fullsize :: proc(pages: []Pdf_Page) -> []u8 {
	doc := haru.New(haru_error_handler, nil)
	if doc == nil { return nil }

	fonts := pdf_load_fonts(doc)

	for &lpage in pages {
		page := haru.AddPage(doc)
		haru.Page_SetWidth(page, haru.Real(A5_WIDTH))
		haru.Page_SetHeight(page, haru.Real(A5_HEIGHT))

		// Render page number
		if lpage.display_num > 0 { pdf_render_page_number(page, fonts, lpage.display_num, 0) }

		// Render lines
		for &line in lpage.lines { pdf_render_line(page, fonts, line, lpage, 0, doc) }
	}

	return pdf_doc_to_bytes(doc)
}

// --- Booklet A4 rendering ---

pdf_render_booklet :: proc(pages: []Pdf_Page) -> []u8 {
	// Pad to multiple of 4
	padded := make([dynamic]Pdf_Page)
	for &p in pages { append(&padded, p) }
	for len(padded) % 4 != 0 {
		append(
			&padded,
			Pdf_Page {
				lines = make([dynamic]Pdf_Line),
				display_num = 0,
				margin_left = OUTER_MARGIN,
				margin_right = BINDING_MARGIN,
			},
		)
	}
	defer {
		// Only delete the blank padding pages we created
		for i := len(pages); i < len(padded); i += 1 { delete(padded[i].lines) }
		delete(padded)
	}

	n := len(padded)
	doc := haru.New(haru_error_handler, nil)
	if doc == nil { return nil }

	fonts := pdf_load_fonts(doc)

	sheets := n / 4
	for i in 0 ..< sheets {
		// Front side: left = pages[N-1-2*i], right = pages[2*i]
		{
			page := haru.AddPage(doc)
			haru.Page_SetWidth(page, haru.Real(A5_WIDTH * 2))
			haru.Page_SetHeight(page, haru.Real(A5_HEIGHT))

			left_idx := n - 1 - 2 * i
			right_idx := 2 * i

			pdf_render_booklet_slot(page, fonts, padded[left_idx], 0, doc)
			pdf_render_booklet_slot(page, fonts, padded[right_idx], A5_WIDTH, doc)
		}

		// Back side: left = pages[2*i+1], right = pages[N-2-2*i]
		{
			page := haru.AddPage(doc)
			haru.Page_SetWidth(page, haru.Real(A5_WIDTH * 2))
			haru.Page_SetHeight(page, haru.Real(A5_HEIGHT))

			left_idx := 2 * i + 1
			right_idx := n - 2 - 2 * i

			pdf_render_booklet_slot(page, fonts, padded[left_idx], 0, doc)
			pdf_render_booklet_slot(page, fonts, padded[right_idx], A5_WIDTH, doc)
		}
	}

	return pdf_doc_to_bytes(doc)
}

pdf_render_booklet_slot :: proc(page: ^haru.Page, fonts: Haru_Fonts, lpage: Pdf_Page, x_offset: f32, doc: ^haru.Doc) {
	if lpage.display_num > 0 {
		pdf_render_page_number(page, fonts, lpage.display_num, x_offset)
	}
	for line in lpage.lines {
		pdf_render_line(page, fonts, line, lpage, x_offset, doc)
	}
}

// --- Rendering helpers ---

pdf_render_page_number :: proc(page: ^haru.Page, fonts: Haru_Fonts, display_num: int, x_offset: f32) {
	font := fonts.page_num
	haru.Page_SetFontAndSize(page, font, haru.Real(PAGE_NUM_SIZE))
	haru.Page_SetRGBFill(
		page,
		haru.Real(PAGE_NUM_COLOR.r),
		haru.Real(PAGE_NUM_COLOR.g),
		haru.Real(PAGE_NUM_COLOR.b),
	)

	text := fmt.ctprintf("Page %d", display_num)
	text_width := haru.Page_TextWidth(page, text)

	// Alternating alignment: odd pages right, even pages left
	x: f32
	if display_num % 2 == 1 {
		// Right-aligned (odd = right side page)
		x = x_offset + A5_WIDTH - OUTER_MARGIN - f32(text_width)
	} else {
		// Left-aligned (even = left side page)
		x = x_offset + OUTER_MARGIN
	}

	y := A5_HEIGHT - TOP_MARGIN - PAGE_NUM_SIZE // top of page, libharu bottom-left origin

	haru.Page_BeginText(page)
	haru.Page_TextOut(page, haru.Real(x), haru.Real(y), text)
	haru.Page_EndText(page)
}

pdf_render_line :: proc(
	page: ^haru.Page,
	fonts: Haru_Fonts,
	line: Pdf_Line,
	lpage: Pdf_Page,
	x_offset: f32,
	doc: ^haru.Doc = nil,
) {
	// Image rendering
	if len(line.image_path) > 0 && doc != nil {
		data, read_err := os.read_entire_file_from_path(line.image_path, context.allocator)
		if read_err == nil {
			defer delete(data)
			image := pdf_load_image(doc, line.image_path, data)
			if image != nil {
				x := x_offset + line.x
				// Convert top-down y to libharu bottom-left origin
				y := A5_HEIGHT - line.y - line.image_height
				haru.Page_DrawImage(
					page, image,
					haru.Real(x), haru.Real(y),
					haru.Real(line.image_width), haru.Real(line.image_height),
				)
			}
		}
		return
	}

	font, size := pdf_font_for_style(fonts, line.font)
	haru.Page_SetFontAndSize(page, font, haru.Real(size))

	color := pdf_color_for_style(line.font)
	haru.Page_SetRGBFill(page, haru.Real(color.r), haru.Real(color.g), haru.Real(color.b))

	ctext := strings.clone_to_cstring(line.text)
	defer delete(ctext)

	// Convert y from top-down to libharu bottom-left origin
	y := A5_HEIGHT - line.y - size

	x: f32
	switch line.alignment {
	case .Left:
		x = x_offset + line.x
	case .Center:
		text_width := f32(haru.Page_TextWidth(page, ctext))
		content_width := A5_WIDTH - lpage.margin_left - lpage.margin_right
		x = x_offset + lpage.margin_left + (content_width - text_width) / 2
	case .Right:
		text_width := f32(haru.Page_TextWidth(page, ctext))
		x = x_offset + A5_WIDTH - lpage.margin_right - text_width
	}

	haru.Page_BeginText(page)
	haru.Page_TextOut(page, haru.Real(x), haru.Real(y), ctext)
	haru.Page_EndText(page)
}

pdf_color_for_style :: proc(style: Font_Style) -> [3]f32 {
	switch style {
	case .Title:
		return TEXT_COLOR
	case .Content:
		return TEXT_COLOR
	case .Choice:
		return CHOICE_COLOR
	case .Desc:
		return DESC_COLOR
	case .Page_Num:
		return PAGE_NUM_COLOR
	case .The_End:
		return THE_END_COLOR
	}
	return TEXT_COLOR
}

// --- Image helpers ---

pdf_measure_image :: proc(doc: ^haru.Doc, path: string) -> (width: f32, height: f32) {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil { return 0, 0 }
	defer delete(data)

	image := pdf_load_image(doc, path, data)
	if image == nil { return 0, 0 }

	return f32(haru.Image_GetWidth(image)), f32(haru.Image_GetHeight(image))
}

pdf_load_image :: proc(doc: ^haru.Doc, path: string, data: []u8) -> haru.Image {
	ext := filepath.ext(path)
	if ext == ".png" {
		return haru.LoadPngImageFromMem(doc, raw_data(data), haru.Uint(len(data)))
	}
	if ext == ".jpg" || ext == ".jpeg" {
		return haru.LoadJpegImageFromMem(doc, raw_data(data), haru.Uint(len(data)))
	}
	return nil
}

// --- Stream to bytes ---

pdf_doc_to_bytes :: proc(doc: ^haru.Doc) -> []u8 {
	status := haru.SaveToStream(doc)
	if status != 0 {
		log.errorf("Failed to save PDF to stream: 0x%04X", status)
		haru.Free(doc)
		return nil
	}

	size := haru.GetStreamSize(doc)
	if size == 0 {
		haru.Free(doc)
		return nil
	}

	buf := make([]u8, size)
	read_size := size
	haru.ResetStream(doc)
	status = haru.ReadFromStream(doc, raw_data(buf), &read_size)
	haru.Free(doc)

	if status != 0 && status != 0x1016 { 	// 0x1016 = HPDF_STREAM_EOF (normal)
		log.errorf("Failed to read PDF stream: 0x%04X", status)
		delete(buf)
		return nil
	}

	return buf[:read_size]
}
