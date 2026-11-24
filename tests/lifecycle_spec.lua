describe("persistent breakpoint lifecycle", function()
	local dap = require("dap")
	local Store = require("persistent-breakpoints.store")
	local api, root, cwd, buffers, notices, notify, input
	local function buffer(name)
		local buf = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = buf
		vim.api.nvim_buf_set_name(buf, root .. "/" .. name)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d", "e" })
		vim.api.nvim_set_current_buf(buf)
		return buf
	end
	local function reset()
		pcall(vim.api.nvim_del_augroup_by_name, "persistent_breakpoints")
		package.loaded["persistent-breakpoints.core"] = nil
		api = require("persistent-breakpoints.core")
		package.loaded["persistent-breakpoints.api"] = nil
	end
	before_each(function()
		pcall(vim.api.nvim_del_augroup_by_name, "persistent_breakpoints")
		cwd, root = vim.fn.getcwd(), vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		vim.api.nvim_set_current_dir(root)
		buffers, notices = {}, {}
		notify = vim.notify
		input = vim.fn.input
		vim.notify = function(msg)
			notices[#notices + 1] = msg
		end
		dap.clear_breakpoints()
		reset()
		api.setup({ directory = root .. "/store" })
	end)
	after_each(function()
		pcall(vim.api.nvim_del_augroup_by_name, "persistent_breakpoints")
		dap.sessions()[98765] = nil
		for _, event in ipairs({ "event_terminated", "event_exited", "disconnect" }) do
			dap.listeners.after[event].persistent_breakpoints = nil
		end
		dap.clear_breakpoints()
		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		vim.api.nvim_set_current_dir(cwd)
		vim.notify = notify
		vim.fn.input = input
		vim.fn.delete(root, "rf")
	end)
	local function points(buf)
		return require("dap.breakpoints").get()[buf] or {}
	end
	local function restart()
		dap.clear_breakpoints()
		reset()
		api.setup({ directory = root .. "/store" })
	end
	it("round-trips ordinary, conditional, hit-count and log breakpoints across initialization", function()
		local buf = buffer("雪 #%.cpp")
		for line, fields in ipairs({ {}, { "x>0" }, { nil, "5" }, { nil, nil, "x={x}" } }) do
			vim.api.nvim_win_set_cursor(0, { line, 0 })
			dap.set_breakpoint(fields[1], fields[2], fields[3])
			assert.is_true(api.changed())
		end
		restart()
		assert.equals(4, #points(buf))
		assert.equals("x>0", points(buf)[2].condition)
		assert.equals("5", points(buf)[3].hitCondition)
		assert.equals("x={x}", points(buf)[4].logMessage)
		vim.api.nvim_exec_autocmds("SessionLoadPost", {})
		assert.equals(4, #points(buf))
	end)
	it("keeps other files and tracks moved lines and renamed buffers", function()
		local first = buffer("a.py")
		api.toggle()
		local second = buffer("b.rs")
		api.toggle()
		vim.api.nvim_set_current_buf(first)
		vim.api.nvim_buf_set_lines(first, 0, 0, false, { "inserted" })
		vim.api.nvim_buf_set_name(first, root .. "/renamed.py")
		assert.is_true(api.save())
		local state = api.snapshot()
		assert.is_nil(state[root .. "/a.py"])
		assert.equals(2, state[root .. "/renamed.py"][1].line)
		assert.equals(1, #points(second))
		restart()
		assert.equals(2, points(first)[1].line)
	end)
	it("clears persisted state so reload and restart cannot resurrect it", function()
		local buf = buffer("a.sh")
		api.toggle()
		assert.is_true(api.clear())
		api.refresh()
		restart()
		assert.equals(0, #points(buf))
		assert.same({}, Store.new(root .. "/store", root).load())
	end)
	it("retains live breakpoints when another editor prevents a clear", function()
		local buf = buffer("keep.cpp")
		dap.set_breakpoint("x > 0", "5", "x={x}")
		assert.is_true(api.changed())
		local other = Store.new(root .. "/store", root)
		local concurrent = other.load()
		concurrent[root .. "/other.cpp"] = { { line = 1 } }
		assert.is_true(other.save(concurrent))
		assert.is_false(api.clear())
		local bp = points(buf)[1]
		assert.equals("x > 0", bp.condition)
		assert.equals("5", bp.hitCondition)
		assert.equals("x={x}", bp.logMessage)
		assert.same(concurrent, other.load())
	end)

	it("restores files loaded after setup without duplicating session restoration", function()
		local path = root .. "/late.cpp"
		local disk = Store.new(root .. "/store", root)
		disk.load()
		assert.is_true(disk.save({ [path] = { { line = 2, hitCondition = "3" } } }))
		restart()
		vim.fn.writefile({ "a", "b" }, path)
		vim.cmd.edit({ args = { path }, magic = { file = false } })
		local buf = vim.api.nvim_get_current_buf()
		buffers[#buffers + 1] = buf
		assert.equals(2, points(buf)[1].line)
		vim.api.nvim_exec_autocmds("SessionLoadPost", {})
		assert.equals(1, #points(buf))
	end)
	it("switches project stores and restores the old project's breakpoints", function()
		local buf = buffer("a.cpp")
		api.toggle()
		vim.fn.mkdir(root .. "/other", "p")
		vim.api.nvim_set_current_dir(root .. "/other")
		assert.equals(0, #points(buf))
		vim.api.nvim_set_current_dir(root)
		assert.equals(1, #points(buf))
	end)
	it("defers project switching during debugging and uses public DAP restore notifications", function()
		local buf = buffer("a.cpp")
		api.toggle()
		local requests = {}
		dap.sessions()[98765] = {
			children = {},
			set_breakpoints = function(_, bps)
				requests[#requests + 1] = bps
			end,
		}
		dap.clear_breakpoints()
		reset()
		api.setup({ directory = root .. "/store" })
		assert.is_true(#requests >= 2)
		assert.equals(1, #points(buf))
		vim.fn.mkdir(root .. "/other", "p")
		vim.api.nvim_set_current_dir(root .. "/other")
		assert.equals(1, #points(buf))
		dap.sessions()[98765] = nil
		api.refresh()
		assert.equals(0, #points(buf))
	end)
	it("keeps unsaved edits in memory and refuses project switching after a conflict", function()
		local buf = buffer("a.cpp")
		api.toggle()
		local other = Store.new(root .. "/store", root)
		other.load()
		assert.is_true(other.save({}))
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		assert.is_false(api.toggle())
		assert.equals(2, #points(buf))
		vim.fn.mkdir(root .. "/other", "p")
		vim.api.nvim_set_current_dir(root .. "/other")
		assert.equals(2, #points(buf))
		assert.is_true(#notices > 0)
	end)
end)
