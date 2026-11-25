describe("stale editor recovery", function()
	it("retains the losing snapshot across rejection and preserves the winner on exit", function()
		local root = vim.fn.tempname() .. " project"
		vim.fn.mkdir(root, "p")
		local live, unloaded = root .. "/live.lua", root .. "/unloaded.lua"
		local repo = vim.fn.getcwd()
		local editors = {}
		local function run(editor, code, ...)
			return vim.rpcrequest(editor, "nvim_exec_lua", code, { ... })
		end
		local function start()
			local editor = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" },
				{ rpc = true, cwd = root })
			table.insert(editors, editor)
			run(editor, [[
				local repo, dir = ...
				vim.opt.rtp:prepend(repo)
				vim.opt.rtp:append(vim.env.DAP_PATH)
				vim.cmd.runtime("plugin/persistent-breakpoints.vim")
				require("persistent-breakpoints").setup({ save_dir = dir })
				api = require("persistent-breakpoints.api")
				dap = require("dap")
			]], repo, root .. "/store")
			return editor
		end
		local ok, err = xpcall(function()
			vim.fn.writefile({ "a", "b", "c", "d", "e" }, live)
			vim.fn.writefile({ "a" }, unloaded)
			local winner = start()
			run(winner, [[
				local hidden, live = ...
				vim.cmd.edit(hidden)
				assert(api.toggle_breakpoint())
				vim.cmd.edit(live)
				assert(api.toggle_breakpoint())
			]], vim.fn.fnameescape(unloaded), vim.fn.fnameescape(live))
			local loser = start()
			run(loser, "vim.cmd.edit(...)", vim.fn.fnameescape(live))
			run(winner, [[
				vim.api.nvim_win_set_cursor(0, { 5, 0 })
				assert(api.toggle_breakpoint())
			]])
			local winning, store = unpack(run(winner, "return { api.snapshot() }"))
			local bytes = vim.fn.readblob(store)
			run(loser, [[
				for line, fields in ipairs({ { "x > 0" }, { nil, "5" }, { nil, nil, "x={x}" } }) do
					vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
					dap.set_breakpoint(fields[1], fields[2], fields[3])
				end
				assert(api.breakpoints_changed_in_current_buffer() == false)
				vim.api.nvim_buf_set_lines(0, 0, 0, false, { "-- inserted" })
			]])
			assert.equals(0, run(loser, "return vim.fn.bufloaded(...)", unloaded))
			local recovered, target = unpack(run(loser, "return { api.snapshot() }"))
			assert.equals(store, target)
			assert.same({
				[live] = { { line = 2 }, { line = 3, condition = "x > 0" },
					{ line = 4, hitCondition = "5" }, { line = 5, logMessage = "x={x}" } },
				[unloaded] = { { line = 1 } },
			}, recovered)
			assert.matches(":PBExport", run(loser, "return vim.fn.execute('messages')"))
			local export = root .. "/losing editor.json"
			local function export_to(path)
				return run(loser, "return (pcall(vim.cmd, ...))", "PBExport " .. vim.fn.fnameescape(path))
			end
			assert.is_false(export_to(root .. "/missing/recovery.json"))
			assert.is_false(export_to(store))
			assert.is_true(export_to(export))
			assert.same(recovered, vim.json.decode(vim.fn.readfile(export)[1]))
			assert.is_false(export_to(export))
			assert.same(recovered, run(loser, "return (api.snapshot())"))
			vim.rpcnotify(loser, "nvim_command", "qa!")
			assert.equals(0, vim.fn.jobwait({ loser }, 5000)[1])
			assert.same(recovered, vim.json.decode(vim.fn.readfile(export)[1]))
			assert.same(bytes, vim.fn.readblob(store))
			assert.same(winning, run(start(), "return (api.snapshot())"))
		end, debug.traceback)
		for _, editor in ipairs(editors) do
			if vim.fn.jobwait({ editor }, 0)[1] == -1 then
				vim.rpcnotify(editor, "nvim_command", "qa!")
				vim.fn.jobwait({ editor }, 5000)
			end
		end
		vim.fn.delete(root, "rf")
		assert(ok, err)
	end)
end)
