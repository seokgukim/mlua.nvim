-- Document service - handles workspace document management like VS Code's DocumentService
-- Provides file watching and LSP notifications for create/delete/rename

local utils = require("mlua.utils")

local M = {}

---@type table<number, table<string, boolean>> Track loaded documents per client
local loaded_documents = {}

---@type table<number, number> File watcher handles (client_id -> augroup_id)
local watchers = {}

---@type table<number, table> Event handlers (client_id -> handlers)
local event_handlers = {}

---@class DocumentItem
---@field uri string Document URI
---@field languageId string Language ID (always "mlua")
---@field version number Document version
---@field text string Document content

---Collect all .mlua documents in a workspace (synchronously with progress)
---@param root_dir string|nil Root directory to search
---@param progress_callback function|nil Called with (current, total, filename)
---@return DocumentItem[] documents List of document items
function M.collect_all_documents(root_dir, progress_callback)
	if not root_dir or root_dir == "" then
		return {}
	end

	root_dir = vim.fn.fnamemodify(root_dir, ":p")

	local documents = {}
	local files

	-- Use different command for Windows
	if vim.fn.has("win32") == 1 then
		local ps_path = root_dir:gsub("/", "\\")
		local cmd = string.format(
			'powershell.exe -NoProfile -Command "Get-ChildItem -Path \'%s\' -Include *.mlua -Recurse -File | ForEach-Object { $_.FullName }"',
			ps_path
		)
		local output = vim.fn.system(cmd)
		files = vim.split(output, "\n", { trimempty = true })
	else
		files = vim.fn.globpath(root_dir, "**/*.mlua", false, true)
	end

	local total = #files
	for i, path in ipairs(files) do
		-- Clean and normalize path
		path = path:gsub("[\r\n\t]", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if path ~= "" then
			local normalized = utils.normalize_path(path)

			-- Read file content
			local content = nil
			local file = io.open(normalized, "r")
			if file then
				content = file:read("*all")
				file:close()
			end

			if content then
				table.insert(documents, {
					uri = vim.uri_from_fname(normalized),
					languageId = "mlua",
					version = 0,
					text = content,
				})
			end

			-- Report progress
			if progress_callback then
				progress_callback(i, total, vim.fn.fnamemodify(normalized, ":t"))
			end
		end
	end

	return documents
end

---Collect documents asynchronously (non-blocking)
---@param root_dir string|nil Root directory to search
---@param callback function Called with documents list when complete
---@param progress_callback function|nil Called with (current, total, filename)
function M.collect_all_documents_async(root_dir, callback, progress_callback)
	if not root_dir or root_dir == "" then
		if callback then
			callback({})
		end
		return
	end

	root_dir = vim.fn.fnamemodify(root_dir, ":p")

	local cmd
	if vim.fn.has("win32") == 1 then
		local ps_path = root_dir:gsub("/", "\\")
		cmd = {
			"powershell.exe",
			"-NoProfile",
			"-Command",
			string.format(
				'Get-ChildItem -Path "%s" -Include *.mlua -Recurse -File | ForEach-Object { $_.FullName }',
				ps_path
			),
		}
	else
		cmd = { "find", root_dir, "-type", "f", "-name", "*.mlua" }
	end

	local documents = {}
	local files = {}

	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end

			for _, line in ipairs(data) do
				line = line:gsub("[\r\n\t]", ""):gsub("^%s+", ""):gsub("%s+$", "")
				if line ~= "" then
					table.insert(files, line)
				end
			end
		end,
		on_exit = function(_, exit_code)
			if exit_code ~= 0 then
				vim.schedule(function()
					if callback then
						callback({})
					end
				end)
				return
			end

			-- Process files in batches
			local total = #files
			local processed = 0
			local batch_size = 50

			local function process_batch(start_idx)
				local batch_end = math.min(start_idx + batch_size - 1, total)

				for i = start_idx, batch_end do
					local path = files[i]
					local normalized = utils.normalize_path(path)

					local content = nil
					local file = io.open(normalized, "r")
					if file then
						content = file:read("*all")
						file:close()
					end

					if content then
						table.insert(documents, {
							uri = vim.uri_from_fname(normalized),
							languageId = "mlua",
							version = 0,
							text = content,
						})
					end

					processed = processed + 1
					if progress_callback then
						progress_callback(processed, total, vim.fn.fnamemodify(normalized, ":t"))
					end
				end

				if batch_end < total then
					vim.schedule(function()
						process_batch(batch_end + 1)
					end)
				else
					vim.schedule(function()
						if callback then
							callback(documents)
						end
					end)
				end
			end

			vim.schedule(function()
				if total > 0 then
					process_batch(1)
				else
					if callback then
						callback({})
					end
				end
			end)
		end,
	})
end

---Setup file watcher for a workspace
---@param client table LSP client
---@param root_dir string|nil Root directory to watch
function M.setup_file_watcher(client, root_dir)
	if not client or not root_dir then
		return
	end

	root_dir = vim.fn.fnamemodify(root_dir, ":p")

	-- Store handlers for this client
	event_handlers[client.id] = event_handlers[client.id] or {}

	-- Watch for .mlua file changes using autocommands
	local group = vim.api.nvim_create_augroup("MluaDocumentService_" .. client.id, { clear = true })

	-- Track new files
	vim.api.nvim_create_autocmd({ "BufNewFile" }, {
		group = group,
		pattern = "*.mlua",
		callback = function(args)
			local fname = vim.api.nvim_buf_get_name(args.buf)
			if not fname or fname == "" then
				return
			end

			-- Check if file is within root_dir
			local normalized = utils.normalize_path(fname)
			if not normalized:find(root_dir, 1, true) then
				return
			end

			-- Notify server about new file
			vim.defer_fn(function()
				if vim.fn.filereadable(fname) == 1 then
					local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
					local text = table.concat(lines, "\n")

					client:notify("msw.protocol.fileCreated", {
						documentItem = {
							uri = vim.uri_from_fname(normalized),
							languageId = "mlua",
							version = 0,
							text = text,
						},
					})
				end
			end, 100)
		end,
	})

	-- Track file deletions
	vim.api.nvim_create_autocmd({ "BufDelete" }, {
		group = group,
		pattern = "*.mlua",
		callback = function(args)
			local fname = vim.api.nvim_buf_get_name(args.buf)
			if not fname or fname == "" then
				return
			end

			local normalized = utils.normalize_path(fname)
			if not normalized:find(root_dir, 1, true) then
				return
			end

			-- Check if file was actually deleted (not just buffer closed)
			vim.defer_fn(function()
				if vim.fn.filereadable(fname) == 0 then
					client:notify("msw.protocol.fileDeleted", {
						uri = vim.uri_from_fname(normalized),
					})
				end
			end, 100)
		end,
	})

	-- Track file renames via BufFilePost (fires on :saveas or buffer rename)
	vim.api.nvim_create_autocmd({ "BufFilePost" }, {
		group = group,
		pattern = "*.mlua",
		callback = function(args)
			local new_name = vim.api.nvim_buf_get_name(args.buf)
			if not new_name or new_name == "" then
				return
			end

			local normalized = utils.normalize_path(new_name)
			if not normalized:find(root_dir, 1, true) then
				return
			end

			-- Get the new script name from filename (without .d suffix)
			local new_script_name = vim.fn.fnamemodify(new_name, ":t:r")
			if new_script_name:match("%.d$") then
				new_script_name = new_script_name:sub(1, -3) -- Remove .d suffix
			end

			-- Check if file content has a script declaration that doesn't match
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local text = table.concat(lines, "\n")

			-- Find script declaration: "script SomeName" or "script SomeName extends ..."
			local script_match = text:match("script%s+(%S+)")
			if script_match and script_match ~= new_script_name then
				-- Prompt user to update script content
				vim.schedule(function()
					local choice = vim.fn.confirm(
						string.format("Update script content? '%s' → '%s'\nReferenced code will be updated.", script_match, new_script_name),
						"&Yes\n&No",
						2
					)

					if choice == 1 then
						-- Use LSP rename to update the script name (this will update all references)
						-- Find the position of the script name in the file
						for i, line in ipairs(lines) do
							local start_col = line:find("script%s+" .. script_match)
							if start_col then
								local name_start = line:find(script_match, start_col)
								if name_start then
									-- Position cursor and trigger rename
									local pos = { line = i - 1, character = name_start - 1 }

									-- Send rename request
									client:request("textDocument/rename", {
										textDocument = { uri = vim.uri_from_fname(normalized) },
										position = pos,
										newName = new_script_name,
									}, function(err, result)
										if err then
											vim.notify("Rename failed: " .. tostring(err), vim.log.levels.ERROR)
											return
										end

										if result and result.changes then
											-- Apply the workspace edit
											vim.lsp.util.apply_workspace_edit(result, client.offset_encoding or "utf-16")
											vim.notify("Script name updated to '" .. new_script_name .. "'", vim.log.levels.INFO)
										end
									end, args.buf)
									break
								end
							end
						end
					end
				end)
			end

			-- Notify server about the file (as new file at new location)
			client:notify("msw.protocol.fileCreated", {
				documentItem = {
					uri = vim.uri_from_fname(normalized),
					languageId = "mlua",
					version = 0,
					text = text,
				},
			})
		end,
	})

	watchers[client.id] = group
end

---Setup entry file watcher (for .map, .ui, .model, .collisiongroupset files)
---@param client table LSP client
---@param root_dir string|nil Root directory to watch
---@param entries_module table|nil Entries module for parsing
function M.setup_entry_watcher(client, root_dir, entries_module)
	if not client or not root_dir then
		return
	end

	root_dir = vim.fn.fnamemodify(root_dir, ":p")

	local group = vim.api.nvim_create_augroup("MluaEntryService_" .. client.id, { clear = true })

	-- Watch for entry file changes
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		group = group,
		pattern = { "*.map", "*.ui", "*.model", "*.collisiongroupset" },
		callback = function(args)
			local fname = vim.api.nvim_buf_get_name(args.buf)
			if not fname or fname == "" then
				return
			end

			local normalized = utils.normalize_path(fname)
			if not normalized:find(root_dir, 1, true) then
				return
			end

			-- Parse and notify about entry change
			vim.defer_fn(function()
				-- Use entries module if provided and has load_entry_file
				if entries_module and entries_module.load_entry_file then
					local entry = entries_module.load_entry_file(normalized)
					if entry then
						client:notify("msw.protocol.entryChanged", {
							entryItem = entry,
						})
						return
					end
				end

				-- Fallback: simple inline parser
				local content = nil
				local file = io.open(normalized, "r")
				if file then
					content = file:read("*all")
					file:close()
				end

				if content then
					local ok, payload = pcall(vim.fn.json_decode, content)
					if ok and payload then
						local entry_key = payload.EntryKey or payload.entryKey
						local content_type = payload.ContentType or payload.contentType

						if entry_key and content_type then
							-- Send notification to server
							client:notify("msw.protocol.entryChanged", {
								entryItem = {
									uri = vim.uri_from_fname(normalized),
									entryKey = entry_key,
									contentType = content_type,
									-- contentProto parsing is handled by server
								},
							})
						end
					end
				end
			end, 100)
		end,
	})
end

---Clean up watchers for a client
---@param client_id number LSP client ID
function M.cleanup(client_id)
	if watchers[client_id] then
		pcall(vim.api.nvim_del_augroup_by_id, watchers[client_id])
		watchers[client_id] = nil
	end

	local entry_group_name = "MluaEntryService_" .. client_id
	pcall(vim.api.nvim_del_augroup_by_name, entry_group_name)

	event_handlers[client_id] = nil
	loaded_documents[client_id] = nil
end

return M
