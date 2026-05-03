package libharu

import "core:c"

HARU_LIB :: #config(HARU_LIB, "libhpdf.a")

foreign import lib {HARU_LIB, "system:png", "system:z", "system:m"}

// --- Opaque handles ---

Doc :: rawptr
Page :: rawptr
Font :: rawptr
Image :: rawptr

// --- Types ---

Status :: c.ulong
Real :: c.float
Uint :: c.uint

Point :: struct {
	x: Real,
	y: Real,
}

Text_Width :: struct {
	numchars: Uint,
	numwords: Uint,
	width:    Uint,
	numspace: Uint,
}

// --- Enums ---

Page_Sizes :: enum c.int {
	LETTER,
	LEGAL,
	A3,
	A4,
	A5,
	B4,
	B5,
	EXECUTIVE,
	US4x6,
	US4x8,
	US5x7,
	COMM10,
	EOF,
}

Page_Direction :: enum c.int {
	PORTRAIT,
	LANDSCAPE,
}

// --- Callback types ---

Error_Handler :: #type proc "c" (error_no: Status, detail_no: Status, user_data: rawptr)

// --- Functions ---

@(default_calling_convention = "c")
@(link_prefix = "HPDF_")
foreign lib {
	// Document
	New :: proc(user_error_fn: Error_Handler, user_data: rawptr) -> ^Doc ---
	Free :: proc(pdf: ^Doc) ---
	SetErrorHandler :: proc(pdf: ^Doc, user_error_fn: Error_Handler) -> Status ---

	// Stream output
	SaveToStream :: proc(pdf: ^Doc) -> Status ---
	GetStreamSize :: proc(pdf: ^Doc) -> c.uint ---
	ReadFromStream :: proc(pdf: ^Doc, buf: [^]u8, size: ^c.uint) -> Status ---
	ResetStream :: proc(pdf: ^Doc) -> Status ---

	// Pages
	AddPage :: proc(pdf: ^Doc) -> ^Page ---

	// Fonts
	GetFont :: proc(pdf: ^Doc, font_name: cstring, encoding_name: cstring) -> ^Font ---
	LoadTTFontFromFile :: proc(pdf: ^Doc, file_name: cstring, embedding: c.int) -> cstring ---

	// Page properties
	Page_SetSize :: proc(page: ^Page, size: Page_Sizes, direction: Page_Direction) -> Status ---
	Page_SetWidth :: proc(page: ^Page, value: Real) -> Status ---
	Page_SetHeight :: proc(page: ^Page, value: Real) -> Status ---
	Page_GetWidth :: proc(page: ^Page) -> Real ---
	Page_GetHeight :: proc(page: ^Page) -> Real ---

	// Page font
	Page_SetFontAndSize :: proc(page: ^Page, font: ^Font, size: Real) -> Status ---

	// Text
	Page_BeginText :: proc(page: ^Page) -> Status ---
	Page_EndText :: proc(page: ^Page) -> Status ---
	Page_TextOut :: proc(page: ^Page, xpos: Real, ypos: Real, text: cstring) -> Status ---
	Page_ShowText :: proc(page: ^Page, text: cstring) -> Status ---
	Page_MoveTextPos :: proc(page: ^Page, x: Real, y: Real) -> Status ---
	Page_GetCurrentTextPos :: proc(page: ^Page) -> Point ---
	Page_TextWidth :: proc(page: ^Page, text: cstring) -> Real ---

	// Color
	Page_SetRGBFill :: proc(page: ^Page, r: Real, g: Real, b: Real) -> Status ---

	// Font metrics
	Font_MeasureText :: proc(font: ^Font, text: [^]u8, len: Uint, width: Real, font_size: Real, char_space: Real, word_space: Real, wordwrap: bool, real_width: ^Real) -> Uint ---

	// Images
	LoadPngImageFromMem :: proc(pdf: ^Doc, buf: [^]u8, size: Uint) -> Image ---
	LoadJpegImageFromMem :: proc(pdf: ^Doc, buf: [^]u8, size: Uint) -> Image ---
	Image_GetWidth :: proc(image: Image) -> Uint ---
	Image_GetHeight :: proc(image: Image) -> Uint ---
	Page_DrawImage :: proc(page: ^Page, image: Image, x: Real, y: Real, width: Real, height: Real) -> Status ---
}
