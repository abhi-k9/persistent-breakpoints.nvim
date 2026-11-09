describe("breakpoint storage", function()
	local Store = require("persistent-breakpoints.store")
	local root, dir, store, originals
	local points = {
		["/src/雪 space #%.cpp"] = {
			{ line = 2 },
			{ line = 3, condition = "x > 0", hitCondition = ">= 5", logMessage = "x={x}" },
		},
	}
	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		dir = root .. "/checkpoints"
		store = Store.new(dir, root)
		originals = {}
	end)
	after_each(function()
		for key, value in pairs(originals) do
			vim.uv[key] = value
		end
		vim.fn.delete(root, "rf")
	end)
	local function fault(key, callback)
		originals[key] = vim.uv[key]
		vim.uv[key] = callback
	end
	local function raw()
		return table.concat(vim.fn.readfile(store.path), "\n")
	end
	local function seed()
		assert.same({}, store.load())
		assert.is_true(store.save(points))
	end

	it("initializes lazily and round-trips all fields without transient adapter state", function()
		assert.same({}, store.load())
		assert.equals(0, vim.fn.isdirectory(dir))
		local input = vim.deepcopy(points)
		input["/src/雪 space #%.cpp"][1].state = { id = 99, verified = false }
		assert.is_true(store.save(input))
		assert.same(points, Store.new(dir, root).load())
		assert.equals(1, vim.json.decode(raw()).version)
	end)
	it("distinguishes an absent store from an explicitly cleared store", function()
		seed()
		assert.is_true(store.save({}))
		assert.same({}, Store.new(dir, root).load())
	end)
	it("separates colliding legacy names and preserves native path strings", function()
		assert.is_not.equals(Store.new(dir, "/a_b/c").path, Store.new(dir, "/a/b_c").path)
		assert.is_not.equals(Store.new(dir, "C:/a_b/c").path, Store.new(dir, "C:/a/b_c").path)
		local input = { ["C:\\雪 space\\a.cpp"] = { { line = 1 } }, ["\\\\host\\share\\x.py"] = {} }
		assert.same(input, Store.validate(input))
	end)
	it("imports legacy fields without changing the original, including after clear", function()
		vim.fn.mkdir(dir, "p")
		local legacy = dir .. "/" .. root:gsub(vim.fn.has("win32") == 1 and "[:/\\]" or "/", "_") .. ".json"
		local text = vim.json.encode(points)
		vim.fn.writefile({ text }, legacy)
		assert.same(points, store.load())
		assert.is_true(store.legacy)
		assert.is_true(store.save(points))
		assert.same(points, Store.new(dir, root).load())
		assert.is_true(store.save({}))
		assert.same({}, Store.new(dir, root).load())
		assert.equals(text, table.concat(vim.fn.readfile(legacy), "\n"))
	end)
	it("blocks corrupt, truncated and unknown-schema stores without replacing them", function()
		seed()
		for _, text in ipairs({ "{", "null", '{"version":2}', '{"version":1,"breakpoints":[]}' }) do
			vim.fn.writefile({ text }, store.path)
			local reader = Store.new(dir, root)
			local state, err = reader.load()
			assert.is_nil(state)
			assert.is_string(err)
			assert.is_false(reader.save({}))
			assert.equals(text, raw())
		end
	end)
	it("rejects malformed breakpoint fields and relative traversal filenames", function()
		seed()
		local original = raw()
		for _, invalid in ipairs({
			{ ["../escape"] = {} },
			{ ["/x"] = { { line = 0 } } },
			{ ["/x"] = { { line = 1, condition = {} } } },
			{ ["/x"] = { { line = 1 }, { line = 1 } } },
		}) do
			assert.is_false(store.save(invalid))
			assert.equals(original, raw())
		end
	end)
	it("preserves the previous bytes on failed rename and permits a safe retry", function()
		seed()
		local original = raw()
		fault("fs_rename", function()
			return nil, "injected rename failure"
		end)
		assert.is_false(store.save({}))
		assert.equals(original, raw())
		assert.is_nil(vim.uv.fs_stat(store.path .. ".lock"))
		vim.uv.fs_rename = originals.fs_rename
		assert.is_true(store.save({}))
	end)
	it("preserves previous bytes on write and fsync failures", function()
		seed()
		local original = raw()
		for _, key in ipairs({ "fs_write", "fs_fsync" }) do
			fault(key, function()
				return nil, "injected failure"
			end)
			assert.is_false(store.save({}))
			assert.equals(original, raw())
			vim.uv[key] = originals[key]
		end
	end)
	it("finishes partial writes before committing", function()
		assert.same({}, store.load())
		local write = vim.uv.fs_write
		fault("fs_write", function(fd, text, offset)
			return write(fd, text:sub(1, 7), offset)
		end)
		assert.is_true(store.save(points))
		assert.same(points, Store.new(dir, root).load())
	end)
	it("detects stale writers instead of losing another editor's changes", function()
		seed()
		local other = Store.new(dir, root)
		assert.same(points, other.load())
		assert.is_true(store.save({}))
		assert.is_false(other.save(points))
		assert.same({}, Store.new(dir, root).load())
	end)
	it("does not steal a lock left by an interrupted writer", function()
		seed()
		local fd = assert(vim.uv.fs_open(store.path .. ".lock", "wx", 384))
		vim.uv.fs_close(fd)
		assert.is_false(store.save({}))
		assert.is_truthy(vim.uv.fs_stat(store.path .. ".lock"))
		assert.same(points, Store.new(dir, root).load())
	end)
	it("rejects store symlinks without touching their targets", function()
		if vim.fn.has("win32") == 1 then
			pending("native symlink privileges vary")
			return
		end
		vim.fn.mkdir(dir, "p")
		local target = root .. "/target"
		vim.fn.writefile({ "keep" }, target)
		assert(vim.uv.fs_symlink(target, store.path))
		assert.is_nil(store.load())
		assert.is_false(store.save({}))
		assert.same({ "keep" }, vim.fn.readfile(target))
	end)
	it("treats denied reads as failures rather than empty stores", function()
		seed()
		local open = vim.uv.fs_open
		fault("fs_open", function(path, flags, mode)
			if path == store.path and flags == "r" then
				return nil, "EACCES: denied"
			end
			return open(path, flags, mode)
		end)
		assert.is_nil(store.load())
		assert.is_false(store.save({}))
	end)
end)
