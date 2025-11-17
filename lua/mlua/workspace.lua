-- Simple workspace management - VS Code style
local utils = require("mlua.utils")

local M = {}

-- Basic Lua keywords for reference
-- Do not load these via workspace
local basic_keywords = {
	"and",
	"break",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
	"type",
	"table",
	"string",
	"number",
	"boolean",
	"math",
	"io",
	"os",
	"coroutine",
	"debug",
	"package",
	"require",
	"print",
	"pairs",
	"ipairs",
	"next",
	"pcall",
	"xpcall",
	"select",
	"unpack",
	"rawget",
	"rawset",
	"setmetatable",
	"getmetatable",
	"rawequal",
	"tonumber",
	"tostring",
	"error",
	"assert",
	"load",
	"loadfile",
	"dofile",
	"collectgarbage",
}

local basic_keyword_set = {}
for _, kw in ipairs(basic_keywords) do
	basic_keyword_set[kw] = true
end

-- Track which files are loaded in LSP (per client)
local loaded_files = {}

-- Workspace file index: root_dir -> { basename (lowercase) -> { full paths } }
local path_state = {}
local path_fuzzy = {}

-- Build workspace file index (async, non-blocking)
function M.build_workspace_index_async(root_dir, callback)
	if not root_dir then
		if callback then
			callback(0)
		end
		return
	end

	-- Normalize root directory
	root_dir = utils.normalize_path(root_dir)
	if path_state[root_dir] then
		-- Already indexed
		if callback then
			callback(0)
		end
		return
	end
	path_state[root_dir] = {}

	-- Use different command for Windows
	local cmd
	if vim.fn.has("win32") == 1 then
		-- PowerShell command for Windows - convert forward slashes back to backslashes for PowerShell
		local ps_path = root_dir:gsub("/", "\\")
		cmd = {
			"powershell.exe",
			"-NoProfile",
			"-Command",
			string.format(
				'Get-ChildItem -Path "%s" -Include *.mlua, *.d -Recurse -File | ForEach-Object { $_.FullName }',
				ps_path
			),
		}
	else
		-- find command for Unix/Linux/macOS
		cmd = { "find", root_dir, "-type", "f", "(", "-name", "*.mlua", "-o", "-name", "*.d", ")" }
	end

	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end

			local paths = {}
			for _, line in ipairs(data) do
				-- Clean the line - remove any whitespace including \r\n
				line = line:gsub("^%s+", ""):gsub("%s+$", "")
				if line ~= "" then
					-- Normalize path for consistency
					local normalized = utils.normalize_path(line)
					table.insert(paths, normalized)
				end
			end
			utils.shuffle_table(paths)
			path_fuzzy[root_dir] = paths

			-- Split paths into chunks for on-demand loading
			for _, path in ipairs(paths) do
				path_state[root_dir][path] = false -- Mark as not loaded
			end

			if callback then
				vim.schedule(function()
					callback(#paths)
				end)
			end
		end,
		on_stderr = function(_, data)
			if data and #data > 0 then
				local err = table.concat(data, "\n")
				if err ~= "" then
					vim.schedule(function()
						vim.notify("Workspace index error: " .. err, vim.log.levels.ERROR)
					end)
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				vim.schedule(function()
					vim.notify("Workspace indexing failed with code: " .. exit_code, vim.log.levels.WARN)
				end)
			end
		end,
	})
end

-- Load a file into LSP via didOpen
function M.load_file(client_id, file_path)
	if not file_path or file_path == "" then
		return false
	end

	local normalized_path = utils.normalize_path(file_path)

	-- Clean the path - remove any potential control characters
	normalized_path = normalized_path:gsub("[\r\n\t]", "")

	-- Check if already loaded
	local client_loaded = loaded_files[client_id] or {}
	if client_loaded[normalized_path] then
		return false
	end

	-- For file operations on Windows, we need the original path format
	-- vim.fn.filereadable and file reading work better with native paths
	local read_path = normalized_path -- Use normalized path (already absolute)
	if vim.fn.has("win32") == 1 then
		-- Convert forward slashes to backslashes for Windows file operations
		read_path = normalized_path:gsub("/", "\\")
	end

	-- Read file content
	-- Try multiple path formats for Windows compatibility
	local test_paths = { read_path, normalized_path }
	local content = nil
	local working_path = nil
	local last_error = nil

	for _, test_path in ipairs(test_paths) do
		local file, err = io.open(test_path, "r")
		if file then
			content = file:read("*all")
			file:close()
			working_path = test_path
			break
		else
			last_error = err
		end
	end

	if not content then
		return false
	end

	-- Create proper file:// URI (always uses forward slashes)
	local uri = vim.uri_from_fname(normalized_path)
	local client = vim.lsp.get_client_by_id(client_id)
	if not client then
		return false
	end

	-- Send didOpen to LSP
	client:notify("textDocument/didOpen", {
		textDocument = {
			uri = uri,
			languageId = "mlua",
			version = 0,
			text = content,
		},
	})

	-- Track as loaded
	if not loaded_files[client_id] then
		loaded_files[client_id] = {}
	end
	loaded_files[client_id][normalized_path] = true

	return true
end

-- Extract tokens from line(s)
local function extract_tokens_from_lines(lines)
	local tokens = {}

	for _, line in ipairs(lines) do
		-- Just seperate by delimiters and extract words
		-- Consider alphanumeric and underscore as part of tokens
		for token in line:gmatch("[%w%d_]+") do
			-- Trim leading _ to get Logic script names
			if token:sub(1, 1) == "_" then
				token = token:sub(2)
			end
			token_normalized = token:lower()

			if token_normalized == "" or basic_keyword_set[token_normalized] then
			-- Skip empty tokens and basic keywords
			else
				tokens[token_normalized] = true
			end
		end
	end

	return tokens
end

-- Find related files based on buffer content
function M.load_related_files(client_id, bufnr, root_dir, line_numbers, max_matches)
	-- Normalize root_dir for consistent lookup (especially important on Windows)
	root_dir = utils.normalize_path(root_dir)
	if not path_state[root_dir] then
		-- Workspace not indexed yet
		return
	end

	-- Get lines to inspect (either provided line numbers or current cursor line)
	local lines = {}
	if line_numbers and type(line_numbers) == "table" and #line_numbers > 0 then
		for _, line_num in ipairs(line_numbers) do
			local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
			if line then
				table.insert(lines, line)
			end
		end
	elseif line_numbers == -1 then
		-- Load all lines in the buffer
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		-- Default: current cursor line
		local cursor = vim.api.nvim_win_get_cursor(0)
		local row = cursor and cursor[1] or 1
		local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
		table.insert(lines, line)
	end

	-- Extract tokens from the specified lines
	local tokens = extract_tokens_from_lines(lines)

	if next(tokens) == nil then
		-- No tokens found, nothing to do
		return
	end

	-- Load matching files using fuzzy matching
	local loaded_count = 0
	local matches = {} -- Store all matches with scores

	-- For each token, find matching files using fuzzy matching
	for token in pairs(tokens) do
		-- First try exact match in index
		local exact_paths = path_state[root_dir] and path_state[root_dir][token]
		if exact_paths then
			for _, path in ipairs(exact_paths) do
				table.insert(matches, { path = path, score = 100 })
			end
		else
			-- Fuzzy match against all files in index
			local max_matches = max_matches or 3 -- Default max matches per token
			local match_count = 0
			local random_start = math.random(#path_fuzzy[root_dir])
			for i = 1, #path_fuzzy[root_dir] do
				if match_count >= max_matches then
					break
				end

				-- Randomize start index for fuzzy matching
				local index = ((random_start + i - 2) % #path_fuzzy[root_dir]) + 1
				local path = path_fuzzy[root_dir][index]

				if path_state[root_dir][path] == false then
					local basename = vim.fn.fnamemodify(path, ":t"):lower()
					local score = utils.fuzzy_match(token, basename)
					if score >= 70 then -- Minimum score threshold
						table.insert(matches, { path = path, score = score })
						match_count = match_count + 1
						path_state[root_dir][path] = true -- Mark as loaded
					end
				end
			end
		end
	end

	-- Load top matches
	for _, match in ipairs(matches) do
		if M.load_file(client_id, match.path) then
			loaded_count = loaded_count + 1
		end
	end

	if loaded_count > 0 then
		local msg = string.format("Loaded %d related file(s)", loaded_count)
		vim.notify(msg, vim.log.levels.INFO)
	end
end

-- Setup for a buffer (called from on_attach)
function M.setup_for_buffer(client, bufnr, root_dir, max_matches, max_modified_lines, trigger_count)
	if not root_dir then
		return
	end

	-- First, send the current buffer via didOpen
	local current_path = vim.api.nvim_buf_get_name(bufnr)
	if current_path and current_path ~= "" then
		vim.defer_fn(function()
			M.load_file(client.id, current_path)
		end, 100)
	end

	-- Track recently modified lines (keep last 3)
	local modified_lines = {}

	-- Track changes to capture recently modified lines
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, _, _, first_line, old_last_line, new_last_line)
			-- on_lines params are 0-indexed, convert to 1-indexed for nvim_buf_get_lines
			-- Track the range of lines that were modified
			for i = first_line + 1, new_last_line do
				-- Avoid duplicates and keep most recent at front
				local already_tracked = false
				for _, line_num in ipairs(modified_lines) do
					if line_num == i then
						already_tracked = true
						break
					end
				end
				if not already_tracked then
					table.insert(modified_lines, 1, i) -- Insert at front
				end
			end
			-- Keep only last n lines
			while #modified_lines > max_modified_lines do
				table.remove(modified_lines)
			end
		end,
	})

	-- For every N characters typed: load related files for current line
	local inserted_chars = 0

	-- InsertLeave: load related files from the last N modified lines
	vim.api.nvim_create_autocmd("InsertLeave", {
		buffer = bufnr,
		callback = function()
			-- Reset the character counter
			inserted_chars = 0

			if #modified_lines > 0 then
				M.load_related_files(client.id, bufnr, root_dir, modified_lines, max_matches)
			else
				-- Fallback: use current cursor line if no modified lines tracked
				M.load_related_files(client.id, bufnr, root_dir, nil, max_matches)
			end
		end,
	})

	vim.api.nvim_create_autocmd("InsertCharPre", {
		buffer = bufnr,
		callback = function()
			inserted_chars = inserted_chars + 1
			if inserted_chars >= trigger_count then
				inserted_chars = 0
				-- Load related files for current line
				M.load_related_files(client.id, bufnr, root_dir, nil, max_matches)
			end
		end,
	})
end

function M.reload_workspace(client, bufnr, root_dir, max_matches)
	if not root_dir then
		return
	end
	-- Clear loaded state for this root_dir
	path_state[root_dir] = nil
	path_fuzzy[root_dir] = nil
	-- Clear loaded files for this client
	if loaded_files[client.id] then
		loaded_files[client.id] = {}
	end

	-- Rebuild index
	M.build_workspace_index_async(root_dir, function(total_files)
		vim.notify(string.format("Workspace reloaded: %d files indexed", total_files), vim.log.levels.INFO)
		M.load_related_files(client.id, bufnr, root_dir, -1, max_matches)
	end)

	vim.notify("Workspace reloaded. Files will be re-indexed on demand.", vim.log.levels.INFO)
end

return M
