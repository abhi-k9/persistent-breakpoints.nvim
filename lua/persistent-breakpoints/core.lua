-- Own persistence, not debugger behavior. Public set/clear APIs notify adapters.
local Store = require("persistent-breakpoints.store")
local M = {}
local store, data, tracked, dirty, directory
local notices = {}
local applying = false
local settings = {}

local function warn(message)
	if notices[message] then
		return
	end
	notices[message] = true
	vim.notify("Breakpoint persistence: " .. message, vim.log.levels.WARN)
end

local function snapshot()
	-- Only undocumented DAP module dependency: quickfix omits structured fields.
	return require("dap.breakpoints").get()
end

local function active()
	local dap = require("dap")
	-- Fail closed if an incompatible/missing API cannot confirm session safety.
	return type(dap.sessions) ~= "function" or type(dap.clear_breakpoints) ~= "function" or next(dap.sessions()) ~= nil
end

local function filename(buf)
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= "" and name or nil
end

local function capture()
	local all = snapshot()
	for buf, old in pairs(tracked) do
		local name = filename(buf)
		if name and vim.api.nvim_buf_is_loaded(buf) then
			local points = Store.validate({ [name] = all[buf] or {} })[name]
			if name ~= old then
				data[old], tracked[buf], dirty = nil, name, true
			end
			if not vim.deep_equal(points, data[name]) then
				data[name], dirty = points, true
			end
		end
	end
end

function M.save()
	if not store then
		return true
	end
	capture()
	if not dirty then
		return true
	end
	local ok, err = store.save(data)
	if ok then
		dirty, notices = false, {}
	else
		warn(err .. "; changes remain in memory")
	end
	return ok
end

local function apply()
	if applying then
		return
	end
	applying = true
	local ok, err = pcall(function()
		local existing = snapshot()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			local name = filename(buf)
			if name and vim.api.nvim_buf_is_loaded(buf) and not tracked[buf] and data[name] then
				local valid = true
				for _, bp in ipairs(data[name]) do
					if bp.line > vim.api.nvim_buf_line_count(buf) then
						valid = false
					end
				end
				if not valid then
					warn("saved line exceeds file length: " .. name .. "; original store retained")
				elseif not existing[buf] then
					vim.api.nvim_buf_call(buf, function()
						local cursor = vim.api.nvim_win_get_cursor(0)
						for _, bp in ipairs(data[name]) do
							vim.api.nvim_win_set_cursor(0, { bp.line, 0 })
							require("dap").set_breakpoint(bp.condition, bp.hitCondition, bp.logMessage)
							if settings.on_load_breakpoint then
								settings.on_load_breakpoint(
									{ condition = bp.condition, hit_condition = bp.hitCondition, log_message = bp.logMessage },
									buf,
									bp.line
								)
							end
						end
						vim.api.nvim_win_set_cursor(0, cursor)
					end)
					tracked[buf] = name
				else
					tracked[buf] = name
				end
			end
		end
	end)
	applying = false
	if not ok then
		warn("restore failed: " .. tostring(err))
	end
end

function M.refresh()
	if applying then
		return true
	end
	local cwd = vim.fn.getcwd()
	if store and store.root == Store.identity(cwd) then
		apply()
		return true
	end
	if store and active() then
		warn("project switch deferred while debugging; breakpoints still belong to " .. store.root)
		return false
	end
	if store and not M.save() then
		return false
	end
	local candidate = Store.new(directory, cwd)
	local loaded, err = candidate.load()
	if not loaded then
		warn(err .. "; store left untouched")
		if store then
			return false
		end
		loaded = {}
	end
	if store then
		require("dap").clear_breakpoints()
	end
	store, data, tracked, dirty = candidate, loaded, {}, false
	apply()
	return true
end

function M.changed()
	if not store then
		M.setup()
	end
	local buf = vim.api.nvim_get_current_buf()
	local name = filename(buf)
	if not name then
		return false
	end
	tracked[buf], dirty = tracked[buf] or name, true
	return M.save()
end

function M.toggle()
	if not store then
		M.setup()
	end
	require("dap").toggle_breakpoint()
	return M.changed()
end

function M.clear()
	if not store then
		M.setup()
	end
	require("dap").clear_breakpoints()
	data, tracked, dirty = {}, {}, true
	return M.save()
end

-- Explicit reload preserves pending changes; it never silently discards a conflict.
function M.reload()
	if not store then
		return M.setup()
	end
	if active() or not M.save() then
		return false
	end
	local loaded, err = store.load()
	if not loaded then
		warn(err)
		return false
	end
	require("dap").clear_breakpoints()
	data, tracked, dirty = loaded, {}, false
	apply()
	return true
end

function M.store_all(clear)
	if clear == true then
		return M.clear()
	end
	if not store then
		M.setup()
	end
	for buf in pairs(snapshot()) do
		local name = filename(buf)
		if name then
			tracked[buf] = tracked[buf] or name
		end
	end
	return M.save()
end

function M.snapshot()
	if not store then
		M.setup()
	end
	capture()
	return vim.deepcopy(data), store.path
end

function M.setup(opts)
	if store then
		return
	end
	settings = opts or {}
	directory = settings.save_dir or settings.directory or vim.fn.stdpath("data") .. "/nvim_checkpoints"
	M.refresh()
	local group = vim.api.nvim_create_augroup("persistent_breakpoints", { clear = true })
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "SessionLoadPost", "DirChanged" }, {
		group = group,
		callback = function()
			M.refresh()
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWritePost", "BufUnload", "VimLeavePre" }, {
		group = group,
		callback = function(ev)
			M.save()
			if ev.event == "BufUnload" then
				tracked[ev.buf] = nil
			end
		end,
	})
	for _, event in ipairs({ "event_terminated", "event_exited", "disconnect" }) do
		require("dap").listeners.after[event].persistent_breakpoints = function()
			vim.schedule(M.refresh)
		end
	end
end

return M
