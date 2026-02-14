package tests

import src "../src"
import t "core:testing"

@(test)
test_sanity :: proc(test: ^t.T) {
	t.expect(test, true, "expected sanity")
}
