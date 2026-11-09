dofile("tests/minimal_init.lua")
require("plenary.test_harness").test_directory(
	"tests",
	{ minimal_init = "tests/minimal_init.lua", sequential = true, timeout = 10000 }
)
