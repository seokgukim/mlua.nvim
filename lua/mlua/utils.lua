-- Utility functions for mLua plugin
-- Path handling, JSON, file operations, and fuzzy matching

local uv = vim.loop or vim.uv

local M = {}

---@type string|nil
local node_platform_cache

---Find the root directory of an mLua project
---@param fname string File name to start searching from
---@return string|nil root_dir The project root directory or nil if not found
function M.find_root(fname)
	local markers = { "Environment", "Global", "map", "RootDesk", "ui" }
	local path = vim.fn.fnamemodify(fname, ":p:h")
	local home = vim.loop.os_homedir()

	while path ~= home and path ~= "/" do
		local found_all = true
		for _, marker in ipairs(markers) do
			local marker_path = path .. "/" .. marker
			if vim.fn.isdirectory(marker_path) ~= 1 then
				found_all = false
				break
			end
		end
		if found_all then
			return path
		end
		path = vim.fn.fnamemodify(path, ":h")
	end

	return nil
end

---Trim whitespace from a string
---@param value any Value to trim (returns unchanged if not a string)
---@return any trimmed The trimmed value
function M.trim(value)
	if type(value) ~= "string" then
		return value
	end

	if vim.trim then
		return vim.trim(value)
	end

	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Detect the Node.js platform (win32, linux, darwin, etc.)
---@return string platform The detected platform or "unknown"
function M.detect_node_platform()
	if node_platform_cache then
		return node_platform_cache
	end

	local output = vim.fn.system({ "node", "-p", "process.platform" })
	if vim.v.shell_error ~= 0 then
		node_platform_cache = "unknown"
	else
		node_platform_cache = M.trim(output)
	end

	return node_platform_cache
end

---Normalize path for cross-platform compatibility
---@param path string|nil Path to normalize
---@return string|nil normalized The normalized path
function M.normalize_path(path)
	if not path or path == "" then
		return path
	end

	-- Check if already absolute (Windows: C:/ or C:\ or UNC; Unix: starts with /)
	local is_absolute = path:match("^[A-Za-z]:[/\\]") or path:match("^/") or path:match("^\\\\")

	local absolute
	if is_absolute then
		-- Already absolute, use it directly (don't expand, it can add extensions)
		absolute = path
	else
		-- Expand and make it absolute
		local expanded = vim.fn.expand(path)
		absolute = vim.fn.fnamemodify(expanded, ":p")
	end

	-- On Windows, ensure forward slashes for URIs
	if vim.fn.has("win32") == 1 then
		absolute = absolute:gsub("\\", "/")
	end

	return absolute
end

---Normalize path for Node.js require() - handles Windows path separators
---@param path string|nil Path to normalize
---@return string|nil normalized The normalized path for Node.js
function M.normalize_for_node(path)
	if not path or path == "" then
		return path
	end

	local platform = M.detect_node_platform()

	-- On Windows (native Node.js), convert backslashes to forward slashes
	-- for JavaScript require() statements
	if platform == "win32" then
		-- Check if path is already normalized (contains forward slashes)
		if path:match("^%a:[/\\]") or path:match("^/") then
			-- Convert backslashes to forward slashes for require()
			local normalized = path:gsub("\\", "/")
			return normalized
		end
		return path
	end

	-- On Linux/macOS (including WSL with Linux Node.js), paths work as-is
	-- No conversion needed - Linux Node.js understands Linux paths natively
	return path
end

---Decode JSON string to Lua table
---@param payload string|nil JSON string to decode
---@return table|nil decoded The decoded table or nil on error
function M.json_decode(payload)
	if payload == nil or payload == "" then
		return nil
	end

	local ok, decoded = pcall(vim.fn.json_decode, payload)
	if not ok then
		return nil
	end

	return decoded
end

---Encode Lua table to JSON string
---@param value any Value to encode
---@return string|nil encoded The encoded JSON string or nil on error
function M.json_encode(value)
	if value == nil then
		return nil
	end

	if vim.json and vim.json.encode then
		local ok, encoded = pcall(vim.json.encode, value)
		if ok then
			return encoded
		end
	end

	local ok, encoded = pcall(vim.fn.json_encode, value)
	if ok then
		return encoded
	end

	return nil
end

---Ensure cache directory exists
---@param root string|nil Root directory
---@return string|nil dir The cache directory path or nil
local function ensure_cache_dir(root)
	if not root or root == "" then
		return nil
	end

	local dir
	if vim.fs and vim.fs.joinpath then
		dir = vim.fs.joinpath(root, "cache")
	else
		dir = root .. "/cache"
	end

	dir = vim.fn.fnamemodify(dir, ":p")
	vim.fn.mkdir(dir, "p")
	return dir
end

---Build cache file path with consistent separators
---@param root string|nil Root directory
---@param filename string File name
---@return string|nil path The full cache file path or nil
function M.build_cache_path(root, filename)
	local dir = ensure_cache_dir(root)
	if not dir or dir == "" then
		return nil
	end

	if vim.fs and vim.fs.joinpath then
		return vim.fs.joinpath(dir, filename)
	end

	-- Ensure consistent forward slashes for path construction
	-- This is especially important on Windows where fnamemodify may use backslashes
	dir = dir:gsub("\\", "/")
	return dir .. "/" .. filename
end

---Build project-specific cache file path
---@param root string|nil Root directory
---@param project string|nil Project path (used for hashing)
---@param suffix string File name suffix
---@return string|nil path The full cache file path or nil
function M.build_project_cache_path(root, project, suffix)
	if not root or root == "" or not project or project == "" then
		return nil
	end

	-- Normalize project path to ensure consistent hashing
	project = vim.fn.fnamemodify(project, ":p")

	local hash
	if vim.fn.sha256 then
		hash = vim.fn.sha256(project)
	else
		-- Fallback: create a simpler hash
		hash = project:gsub("[^%w]", "_")
	end

	local filename = string.format("%s-%s", hash, suffix)
	return M.build_cache_path(root, filename)
end

---Read text file contents
---@param path string|nil File path
---@return string|nil content The file content or nil
function M.read_text_file(path)
	if not path or path == "" then
		return nil
	end

	if vim.fn.filereadable(path) == 0 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end

	return table.concat(lines, "\n")
end

---Write text content to file
---@param path string|nil File path
---@param content string|nil Content to write
---@return boolean success Whether the write succeeded
function M.write_text_file(path, content)
	if not path or path == "" or not content then
		return false
	end

	local ok = pcall(vim.fn.writefile, { content }, path)
	return ok
end

---Read file state (from buffer if loaded, otherwise from disk)
---@param path string File path
---@return string|nil content The file content
---@return boolean from_buffer Whether content came from a buffer
function M.read_file_state(path)
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return table.concat(lines, "\n"), true
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, false
	end

	local content = table.concat(lines, "\n")
	content = content:gsub("\\", "\\\\")
	return content, false
end

---Check if string ends with suffix
---@param str string|nil String to check
---@param suffix string|nil Suffix to look for
---@return boolean ends_with Whether the string ends with the suffix
function M.ends_with(str, suffix)
	if type(str) ~= "string" or type(suffix) ~= "string" then
		return false
	end

	if #suffix == 0 then
		return true
	end

	return str:sub(-#suffix) == suffix
end

---Check if value is a list (array-like table)
---@param value any Value to check
---@return boolean is_list Whether the value is a list
function M.is_list(value)
	if type(value) ~= "table" then
		return false
	end

	if vim.islist then
		return vim.islist(value)
	end

	if vim.tbl_islist then
		return vim.tbl_islist(value)
	end

	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
	end

	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end

	return true
end

---Merge two lists into a new list
---@param left table|nil First list
---@param right table|nil Second list
---@return table combined The merged list
function M.merge_lists(left, right)
	local combined = {}

	if type(left) == "table" then
		for _, item in ipairs(left) do
			table.insert(combined, item)
		end
	end

	if type(right) == "table" then
		for _, item in ipairs(right) do
			table.insert(combined, item)
		end
	end

	return combined
end

---Fuzzy matching: returns score (0-100) for how well pattern matches text
---Higher score = better match
---@param pattern string|nil Pattern to match
---@param text string|nil Text to match against
---@return number score Match score (0-100)
function M.fuzzy_match(pattern, text)
	if not pattern or not text then
		return 0
	end

	pattern = pattern:lower()
	text = text:lower()

	-- Exact match
	if pattern == text then
		return 100
	end

	-- Starts with
	if text:sub(1, #pattern) == pattern then
		return 90
	end

	-- Contains
	if text:find(pattern, 1, true) then
		return 80
	end

	-- Fuzzy: all characters of pattern appear in order in text
	local pattern_idx = 1
	local text_idx = 1
	local matches = 0

	while pattern_idx <= #pattern and text_idx <= #text do
		if pattern:sub(pattern_idx, pattern_idx) == text:sub(text_idx, text_idx) then
			matches = matches + 1
			pattern_idx = pattern_idx + 1
		end
		text_idx = text_idx + 1
	end

	-- All characters matched in order
	if matches == #pattern then
		-- Score based on how compact the match is
		local ratio = matches / #text
		return math.floor(70 * ratio)
	end

	return 0
end

---Binary search for lower bound in sorted table
---@param tbl table Sorted table to search
---@param target any Target value to find
---@return number index The lower bound index
function M.lower_bound(tbl, target)
	local low = 1
	local high = #tbl + 1

	while low < high do
		local mid = math.floor((low + high) / 2)
		if tbl[mid] < target then
			low = mid + 1
		else
			high = mid
		end
	end

	return low
end

---Shuffle table in-place using Fisher-Yates algorithm
---@param t table Table to shuffle
function M.shuffle_table(t)
	local n = #t
	for i = n, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

return M
