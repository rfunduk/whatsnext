package microhttpd

import "core:c"

MHD_LIB :: #config(MHD_LIB, "libmicrohttpd.a")

when ODIN_OS == .Linux {
	foreign import lib {MHD_LIB, "system:pthread"}
} else {
	foreign import lib {MHD_LIB}
}

// --- Opaque handles ---

Daemon :: rawptr
Connection :: rawptr
Response :: rawptr
Post_Processor :: rawptr

// --- Enums ---

Result :: enum c.int {
	NO,
	YES,
}

Flags :: bit_set[enum c.uint {
	USE_ERROR_LOG,
	USE_TLS,
	USE_THREAD_PER_CONNECTION,
	USE_INTERNAL_POLLING_THREAD,
	USE_IPv6,
	USE_PEDANTIC_CHECKS,
	USE_POLL,
	USE_SUPPRESS_DATE_NO_CLOCK,
	USE_NO_LISTEN_SOCKET,
	USE_EPOLL,
	USE_ITC,
	BIT_11,
	USE_TURBO,
	BIT_13,
	USE_TCP_FASTOPEN,
	ALLOW_UPGRADE,
	USE_AUTO,
	BIT_17,
	BIT_18,
	USE_NO_THREAD_SAFETY,
};c.uint]

// Compound convenience constants
USE_DUAL_STACK: Flags : {.USE_ITC, .BIT_11}
ALLOW_SUSPEND_RESUME: Flags : {.USE_ITC, .BIT_13}
USE_AUTO_INTERNAL_THREAD: Flags : {.USE_AUTO, .USE_INTERNAL_POLLING_THREAD}

Response_Memory_Mode :: enum c.int {
	PERSISTENT, // Buffer is persistent (caller must keep alive)
	MUST_FREE, // MHD will free() the buffer
	MUST_COPY, // MHD will copy the buffer
}

Value_Kind :: bit_set[enum c.int {
	HEADER_KIND,
	COOKIE_KIND,
	POSTDATA_KIND,
	GET_ARGUMENT_KIND,
	FOOTER_KIND,
};c.uint]

Option :: enum c.int {
	END,
	CONNECTION_MEMORY_LIMIT,
	CONNECTION_LIMIT,
	CONNECTION_TIMEOUT,
	NOTIFY_COMPLETED,
	PER_IP_CONNECTION_LIMIT,
	SOCK_ADDR,
	URI_LOG_CALLBACK,
	LISTEN_SOCKET = 12,
	EXTERNAL_LOGGER = 13,
	THREAD_POOL_SIZE = 14,
	THREAD_STACK_SIZE = 19,
	LISTENING_ADDRESS_REUSE = 25,
	LISTEN_BACKLOG_SIZE = 28,
	SIGPIPE_HANDLED_BY_APP = 33,
}

Request_Termination_Code :: enum c.int {
	COMPLETED_OK,
	WITH_ERROR,
	TIMEOUT_REACHED,
	DAEMON_SHUTDOWN,
	READ_ERROR,
	CLIENT_ABORT,
}

// --- Callback types ---

Access_Handler_Callback :: #type proc "c" (
	cls: rawptr,
	connection: Connection,
	url: cstring,
	method: cstring,
	version: cstring,
	upload_data: [^]u8,
	upload_data_size: ^c.size_t,
	req_cls: ^rawptr,
) -> Result

Accept_Policy_Callback :: #type proc "c" (
	cls: rawptr,
	addr: rawptr, // struct sockaddr*
	addrlen: c.uint,
) -> Result

Request_Completed_Callback :: #type proc "c" (
	cls: rawptr,
	connection: Connection,
	req_cls: ^rawptr,
	toe: Request_Termination_Code,
)

Key_Value_Iterator :: #type proc "c" (cls: rawptr, kind: Value_Kind, key: cstring, value: cstring) -> Result

// --- Functions ---

@(default_calling_convention = "c")
@(link_prefix = "MHD_")
foreign lib {
	start_daemon :: proc(flags: Flags, port: c.uint16_t, apc: Accept_Policy_Callback, apc_cls: rawptr, dh: Access_Handler_Callback, dh_cls: rawptr, #c_vararg args: ..any) -> Daemon ---
	stop_daemon :: proc(daemon: Daemon) ---

	// --- Response ---
	create_response_from_buffer :: proc(size: c.size_t, buffer: rawptr, mode: Response_Memory_Mode) -> Response ---
	create_response_from_fd :: proc(size: c.uint64_t, fd: c.int) -> Response ---
	queue_response :: proc(connection: Connection, status_code: Status, response: Response) -> Result ---
	destroy_response :: proc(response: Response) ---
	add_response_header :: proc(response: Response, header: cstring, content: cstring) -> Result ---

	// --- Connection introspection ---
	get_connection_values :: proc(connection: Connection, kind: Value_Kind, iterator: Key_Value_Iterator, iterator_cls: rawptr) -> c.int ---
	lookup_connection_value :: proc(connection: Connection, kind: Value_Kind, key: cstring) -> cstring ---

	// --- Post processing ---
	create_post_processor :: proc(connection: Connection, buffer_size: c.size_t, iter: Post_Data_Iterator, iter_cls: rawptr) -> Post_Processor ---
	post_process :: proc(pp: Post_Processor, post_data: [^]u8, post_data_len: c.size_t) -> Result ---
	destroy_post_processor :: proc(pp: Post_Processor) -> Result ---
}

// --- Post processing types ---

Post_Data_Iterator :: #type proc "c" (
	cls: rawptr,
	kind: Value_Kind,
	key: cstring,
	filename: cstring,
	content_type: cstring,
	transfer_encoding: cstring,
	data: [^]u8,
	off: u64,
	size: c.size_t,
) -> Result

// --- HTTP status codes ---

Status :: enum c.uint {
	OK                    = 200,
	CREATED               = 201,
	NO_CONTENT            = 204,
	MOVED_PERMANENTLY     = 301,
	FOUND                 = 302,
	NOT_MODIFIED          = 304,
	BAD_REQUEST           = 400,
	UNAUTHORIZED          = 401,
	FORBIDDEN             = 403,
	NOT_FOUND             = 404,
	METHOD_NOT_ALLOWED    = 405,
	TOO_MANY_REQUESTS     = 429,
	INTERNAL_SERVER_ERROR = 500,
	SERVICE_UNAVAILABLE   = 503,
}
