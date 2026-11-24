-- Bounded JSON storage with validation, optimistic concurrency and atomic replace.
local M, uv = {}, vim.uv
local LIMIT = 4 * 1024 * 1024

local function absolute(path)
	return type(path) == "string"
		and not path:find("%z")
		and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:sub(1, 2) == "\\\\")
end

function M.validate(data)
	assert(type(data) == "table" and (not vim.islist(data) or next(data) == nil), "expected file map")
	local result = {}
	for path, list in pairs(data) do
		assert(absolute(path), "breakpoint filename must be absolute")
		assert(type(list) == "table" and (vim.islist(list) or next(list) == nil), "expected breakpoint list")
		result[path] = {}
		local lines = {}
		for _, bp in ipairs(list) do
			assert(
				type(bp) == "table"
					and type(bp.line) == "number"
					and bp.line >= 1
					and bp.line <= 2147483647
					and bp.line % 1 == 0
					and not lines[bp.line],
				"invalid/duplicate breakpoint line"
			)
			lines[bp.line] = true
			local item = { line = bp.line }
			for _, key in ipairs({ "condition", "hitCondition", "logMessage" }) do
				assert(bp[key] == nil or type(bp[key]) == "string", "invalid " .. key)
				item[key] = bp[key]
			end
			result[path][#result[path] + 1] = item
		end
		table.sort(result[path], function(a, b)
			return a.line < b.line
		end)
	end
	return result
end

local function read(path)
	local stat, err, code = uv.fs_lstat(path)
	if not stat then
		if code == "ENOENT" then
			return nil
		end
		error(err)
	end
	assert(stat.type == "file" and stat.size <= LIMIT, "store is not a bounded regular file: " .. path)
	local fd = assert(uv.fs_open(path, "r", 0))
	local ok, value = pcall(function()
		local opened = assert(uv.fs_fstat(fd))
		assert(opened.type == "file" and opened.size <= LIMIT and opened.ino == stat.ino, "store changed during read")
		local raw = assert(uv.fs_read(fd, opened.size, 0))
		assert(#raw == opened.size, "short store read")
		return raw
	end)
	local closed, close_err = uv.fs_close(fd)
	assert(ok, value)
	assert(closed, close_err)
	return value
end

function M.identity(cwd)
	return vim.fs.normalize(uv.fs_realpath(cwd) or cwd, { expand_env = false })
end

function M.new(directory, cwd)
	local root = M.identity(cwd)
	assert(absolute(root), "project root must be absolute")
	local legacy = cwd:gsub(vim.fn.has("win32") == 1 and "[:/\\]" or "/", "_")
	local self = { root = root, path = directory .. "/v1-" .. vim.fn.sha256(root) .. ".json" }
	local baseline, legacy_baseline, loaded = nil, nil, false

	function self.load()
		loaded = false
		local ok, data = pcall(function()
			baseline = read(self.path)
			if baseline then
				local envelope = vim.json.decode(baseline)
				assert(
					type(envelope) == "table" and envelope.version == 1 and envelope.root == root,
					"unknown schema or project identity"
				)
				return M.validate(envelope.breakpoints)
			end
			-- Legacy names are inherently ambiguous. Never modify/delete that source.
			local raw = read(directory .. "/" .. legacy .. ".json")
			legacy_baseline = raw
			self.legacy = raw ~= nil
			return raw and M.validate(vim.json.decode(raw)) or {}
		end)
		loaded = ok
		if ok then
			return data
		end
		return nil, tostring(data)
	end

	function self.save(data)
		if not loaded then
			return false, "store could not be loaded; repair it before saving"
		end
		local lock, temporary, fd
		local ok, err = pcall(function()
			local encoded = vim.json.encode({ version = 1, root = root, breakpoints = M.validate(data) })
			assert(#encoded <= LIMIT, "breakpoint store exceeds 4 MiB")
			local stat = uv.fs_lstat(directory)
			if not stat then
				vim.fn.mkdir(directory, "p", 448)
			end
			assert((uv.fs_lstat(directory) or {}).type == "directory", "store directory must not be a symlink")
			lock = assert(uv.fs_open(self.path .. ".lock", "wx", 384))
			assert(read(self.path) == baseline, "store changed in another editor; refusing to overwrite")
			if baseline == nil then
				assert(
					read(directory .. "/" .. legacy .. ".json") == legacy_baseline,
					"legacy store changed during migration"
				)
			end
			local opened, path = uv.fs_mkstemp(self.path .. ".tmp-XXXXXX")
			assert(opened, path)
			fd, temporary = opened, path
			local offset = 0
			while offset < #encoded do
				local written = assert(uv.fs_write(fd, encoded:sub(offset + 1), offset))
				assert(written > 0, "short store write")
				offset = offset + written
			end
			assert(uv.fs_fsync(fd))
			local closed, close_err = uv.fs_close(fd)
			fd = nil
			assert(closed, close_err)
			assert(uv.fs_rename(temporary, self.path)) -- never unlink destination as a fallback
			temporary = nil
			assert(read(self.path) == encoded, "store verification failed")
			baseline = encoded
		end)
		if fd then
			uv.fs_close(fd)
		end
		if temporary then
			uv.fs_unlink(temporary)
		end
		if lock then
			uv.fs_close(lock)
			uv.fs_unlink(self.path .. ".lock")
		end
		return ok, not ok and tostring(err) or nil
	end
	return self
end

return M
