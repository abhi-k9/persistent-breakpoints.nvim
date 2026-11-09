-- Public compatibility surface. Persistence and DAP lifetime live in core.
local core = require("persistent-breakpoints.core")
local M = {
	toggle_breakpoint = core.toggle,
	breakpoints_changed_in_current_buffer = core.changed,
	clear_all_breakpoints = core.clear,
	load_breakpoints = core.refresh,
	reload_breakpoints = core.reload,
	snapshot = core.snapshot,
	store_breakpoints = core.store_all,
}
function M.set_conditional_breakpoint()
	local condition = vim.fn.input("[Condition] > ")
	if condition == "" then
		return
	end
	require("dap").set_breakpoint(condition)
	return core.changed()
end
function M.set_log_point()
	local message = vim.fn.input("[Message] > ")
	if message == "" then
		return
	end
	require("dap").set_breakpoint(nil, nil, message)
	return core.changed()
end
return M
