-- LSP client setup and management for mLua
-- Handles installation, configuration, and client lifecycle

local utils = require("mlua.utils")
local entries = require("mlua.entries")
local workspace = require("mlua.workspace")
local predefines = require("mlua.predefines")
local document = require("mlua.document")
local execspace = require("mlua.execspace")

local M = {}

---@type table<number, table<number, boolean>> Attached buffers per client
local attached_buffers = {}

---@type table<string, boolean> Track if LSP is starting for a root_dir
local lsp_starting = {}

---Register buffer cleanup handler
---@param client_id number LSP client ID
---@param bufnr number Buffer number
local function register_buffer_cleanup(client_id, bufnr)
	vim.api.nvim_create_autocmd("BufUnload", {
		buffer = bufnr,
		once = true,
		callback = function()
			local buckets = attached_buffers[client_id]
			if buckets then
				buckets[bufnr] = nil
			end
		end,
	})
end

---Check if Node.js is available
---@return boolean available Whether Node.js is available
local function check_node_available()
	local handle = io.popen("node --version 2>&1")
	if not handle then
		return false
	end

	local result = handle:read("*a")
	handle:close()

	return result:match("v%d+%.%d+%.%d+") ~= nil
end

---@class LspConfig
---@field install_dir string Installation directory
---@field publisher string Extension publisher
---@field extension string Extension name

---@type LspConfig
M.config = {
	install_dir = vim.fn.has("win32") == 1 and vim.fn.expand("~/AppData/Local/nvim-data/mlua-lsp")
		or vim.fn.expand("~/.local/share/nvim/mlua-lsp"),
	publisher = "msw",
	extension = "mlua",
}

---Get the latest version from VS Code marketplace
---@return string|nil version The latest version or nil
function M.get_latest_version()
	local data = string.format(
		'{"filters":[{"criteria":[{"filterType":7,"value":"%s.%s"}]}],"flags":914}',
		M.config.publisher,
		M.config.extension
	)
	local curl_cmd

	if vim.fn.has("win32") == 1 then
		-- Windows: Escape double quotes and use double quotes for the argument
		data = data:gsub('"', '\\"')
		curl_cmd = string.format(
			'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json;api-version=3.0-preview.1" -d "%s" "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"',
			data
		)
	else
		-- Unix: Use single quotes for the argument
		curl_cmd = string.format(
			'curl -s -X POST -H "Content-Type: application/json" -H "Accept: application/json;api-version=3.0-preview.1" -d \'%s\' "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"',
			data
		)
	end

	local handle = io.popen(curl_cmd)
	if not handle then
		return nil
	end

	local result = handle:read("*a")
	handle:close()

	local version = result:match('"version":"([^"]+)"')
	return version
end

---Get the installed version and directory
---@return string|nil version The installed version or nil
---@return string|nil install_dir The installation directory or nil
function M.get_installed_version()
	local pattern = M.config.install_dir .. "/" .. M.config.publisher .. "." .. M.config.extension .. "-*"
	local dirs = vim.fn.glob(pattern, false, true)

	if #dirs == 0 then
		return nil
	end

	table.sort(dirs)
	local latest_dir = dirs[#dirs]
	local version = latest_dir:match("%-([%d%.]+)$")
	return version, latest_dir
end

---Download and install the mLua language server
---@param version string|nil Version to download (defaults to latest)
---@return boolean success Whether the download succeeded
function M.download(version)
	version = M.get_latest_version() or "1.1.4"

	if not version then
		vim.notify("Error: Could not fetch version", vim.log.levels.ERROR)
		return false
	end

	vim.notify("Downloading mLua v" .. version .. "...", vim.log.levels.INFO)

	local download_dir = M.config.install_dir
	local extension_name = M.config.publisher .. "." .. M.config.extension .. "-" .. version
	local vsix_file = download_dir .. "/" .. extension_name .. ".vsix"
	local zip_file = download_dir .. "/" .. extension_name .. ".zip"
	local extract_dir = download_dir .. "/" .. extension_name

	vim.fn.mkdir(download_dir, "p")

	local download_url = string.format(
		"https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/%s/extension/%s/%s/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage",
		M.config.publisher,
		M.config.publisher,
		M.config.extension,
		version
	)

	local download_cmd = string.format('curl -L -o "%s" "%s"', vsix_file, download_url)
	local result = os.execute(download_cmd)

	if result ~= 0 then
		vim.notify("Error: Download failed", vim.log.levels.ERROR)
		return false
	end

	os.rename(vsix_file, zip_file)
	vim.fn.mkdir(extract_dir, "p")

	local extract_cmd
	if vim.fn.has("win32") == 1 then
		extract_cmd = string.format(
			"powershell -Command \"Expand-Archive -Path '%s' -DestinationPath '%s' -Force\"",
			zip_file:gsub("/", "\\"),
			extract_dir:gsub("/", "\\")
		)
	else
		extract_cmd = string.format('unzip -q -o "%s" -d "%s"', zip_file, extract_dir)
	end

	os.execute(extract_cmd)
	os.remove(zip_file)

	vim.notify("mLua v" .. version .. " installed successfully!", vim.log.levels.INFO)
	return true, extract_dir
end

function M.update()
	local latest_version = M.get_latest_version()
	local installed_version, installed_dir = M.get_installed_version()

	if not latest_version then
		vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
		return
	end

	if not installed_version then
		vim.notify("mLua not installed. Installing v" .. latest_version .. "...", vim.log.levels.INFO)
		M.download(latest_version)
		return
	end

	vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
	vim.notify("Latest: v" .. latest_version, vim.log.levels.INFO)

	if installed_version == latest_version then
		vim.notify("Already up to date!", vim.log.levels.INFO)
		return
	end

	local confirm =
		vim.fn.confirm(string.format("Update mLua from v%s to v%s?", installed_version, latest_version), "&Yes\n&No", 2)

	if confirm ~= 1 then
		vim.notify("Update cancelled", vim.log.levels.INFO)
		return
	end

	local success = M.download(latest_version)

	if success then
		vim.notify("Removing old version...", vim.log.levels.INFO)
		local rm_cmd
		if vim.fn.has("win32") == 1 then
			rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
		else
			rm_cmd = string.format('rm -rf "%s"', installed_dir)
		end
		os.execute(rm_cmd)

		vim.notify("Update complete! Restart Neovim to use the new version.", vim.log.levels.WARN)
	end
end

---Check installed vs latest version
function M.check_version()
	local latest_version = M.get_latest_version()
	local installed_version = M.get_installed_version()

	if not latest_version then
		vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
		return
	end

	if not installed_version then
		vim.notify("mLua is not installed", vim.log.levels.WARN)
		vim.notify("Latest available: v" .. latest_version, vim.log.levels.INFO)
		vim.notify("Run :MluaInstall to install", vim.log.levels.INFO)
		return
	end

	vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
	vim.notify("Latest: v" .. latest_version, vim.log.levels.INFO)

	if installed_version ~= latest_version then
		vim.notify("Update available! Run :MluaUpdate to upgrade", vim.log.levels.WARN)
	else
		vim.notify("You have the latest version!", vim.log.levels.INFO)
	end
end

---Uninstall the mLua language server
function M.uninstall()
	local installed_version, installed_dir = M.get_installed_version()

	if not installed_version then
		vim.notify("mLua is not installed", vim.log.levels.WARN)
		return
	end

	local confirm = vim.fn.confirm(string.format("Uninstall mLua v%s?", installed_version), "&Yes\n&No", 2)

	if confirm ~= 1 then
		vim.notify("Uninstall cancelled", vim.log.levels.INFO)
		return
	end

	local rm_cmd
	if vim.fn.has("win32") == 1 then
		rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
	else
		rm_cmd = string.format('rm -rf "%s"', installed_dir)
	end

	os.execute(rm_cmd)
	vim.notify("mLua v" .. installed_version .. " uninstalled", vim.log.levels.INFO)
end

---Setup the LSP client
---@param opts table|nil Configuration options
function M.setup(opts)
	opts = opts or {}

	-- Set global folding option (default: false)
	vim.g.mlua_enable_folding = opts.enable_folding or false

	if not check_node_available() then
		vim.notify(
			"Node.js is not installed or not in PATH. Please install Node.js to use mLua LSP.",
			vim.log.levels.ERROR
		)
		return
	end

	local installed_version, installed_dir = M.get_installed_version()

	if not installed_version then
		vim.notify("mLua language server not found. Run :MluaInstall to install.", vim.log.levels.WARN)
		return
	end

	local server_path = installed_dir .. "/extension/scripts/server/out/languageServer.js"

	if vim.fn.filereadable(server_path) == 0 then
		vim.notify("Server file not found at: " .. server_path, vim.log.levels.ERROR)
		return
	end

	-- Create autocommand group to prevent duplicates
	local group = vim.api.nvim_create_augroup("MluaLsp", { clear = true })

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = group,
		pattern = "*.mlua",
		callback = function(args)
			-- Show version message only once when first mlua file is opened
			vim.notify_once("mLua LSP v" .. installed_version .. " configured", vim.log.levels.INFO)

			if not vim.api.nvim_buf_is_loaded(args.buf) then
				return
			end

			-- Check if LSP is already running for this buffer
			local clients = vim.lsp.get_clients({ name = "mlua", bufnr = args.buf })
			if #clients > 0 then
				-- LSP already attached, just setup triggers for this buffer
				local client = clients[1]
				local fname = vim.api.nvim_buf_get_name(args.buf)
				local root_dir = utils.find_root(fname)
				if root_dir then
					workspace.setup_for_buffer(
						client,
						args.buf,
						root_dir,
						opts.max_matches,
						opts.max_modified_lines,
						opts.trigger_count
					)
				end
				return
			end
			local fname = vim.api.nvim_buf_get_name(args.buf)
			local root_dir = utils.find_root(fname)
			local is_project = root_dir ~= nil

			-- Check if LSP is already starting for this root_dir
			if is_project and lsp_starting[root_dir] then
				return
			end

			local bufname = vim.api.nvim_buf_get_name(args.buf)

			if is_project then
				root_dir = vim.fn.fnamemodify(root_dir, ":p")
			else
				-- If no project root found, use the directory of the current file
				root_dir = vim.fn.fnamemodify(bufname, ":p:h")
			end

			-- Check if a client is already running for this root_dir
			local existing_clients = vim.lsp.get_clients({ name = "mlua" })
			for _, client in ipairs(existing_clients) do
				if client.config.root_dir == root_dir then
					vim.lsp.buf_attach_client(args.buf, client.id)
					return
				end
			end

			local client_capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
			client_capabilities.workspace = client_capabilities.workspace or {}
			client_capabilities.workspace.diagnostic = client_capabilities.workspace.diagnostic
				or {
					refreshSupport = true,
				}
			client_capabilities.textDocument = client_capabilities.textDocument or {}
			client_capabilities.textDocument.diagnostic = client_capabilities.textDocument.diagnostic
				or {
					dynamicRegistration = false,
					relatedDocumentSupport = false,
				}

			local function refresh_attached_diagnostics(client)
				-- Diagnostics are handled automatically by the LSP server
				-- No manual refresh needed
			end

			local handlers = vim.tbl_extend("force", {
				["workspace/diagnostic/refresh"] = function(_, _, ctx)
					-- Let Neovim handle diagnostic refresh automatically
					return vim.NIL
				end,
				-- Handle server's request to rename file when script name changes
				["msw.protocol.renameFile"] = function(_, params)
					if not params or not params.uri or not params.newName then
						return
					end

					local uri = params.uri
					local new_name = params.newName
					local old_path = vim.uri_to_fname(uri)
					local old_filename = vim.fn.fnamemodify(old_path, ":t:r")

					-- Check if filename already matches
					if old_filename == new_name or old_filename == new_name .. ".d" then
						return
					end

					-- Prompt user
					vim.schedule(function()
						local choice = vim.fn.confirm(
							string.format("Update file name to match script '%s'?", new_name),
							"&Yes\n&No",
							2
						)

						if choice == 1 then
							-- Determine new filename (preserve .d suffix if present)
							local ext = old_path:match("%.d%.mlua$") and ".d.mlua" or ".mlua"
							local dir = vim.fn.fnamemodify(old_path, ":h")
							local new_path = dir .. "/" .. new_name .. ext

							-- Check if buffer is modified
							local bufnr = vim.fn.bufnr(old_path)
							if bufnr ~= -1 and vim.bo[bufnr].modified then
								local save_choice = vim.fn.confirm(
									string.format("Save changes to '%s' before renaming?", vim.fn.fnamemodify(old_path, ":t")),
									"&Yes\n&No",
									1
								)
								if save_choice == 1 then
									vim.api.nvim_buf_call(bufnr, function()
										vim.cmd("write")
									end)
								end
							end

							-- Rename the file
							local ok, err = pcall(vim.fn.rename, old_path, new_path)
							if ok then
								-- Update buffer name if it's open
								if bufnr ~= -1 then
									vim.api.nvim_buf_set_name(bufnr, new_path)
									vim.cmd("edit") -- Reload buffer
								end
								vim.notify(string.format("Renamed to %s", vim.fn.fnamemodify(new_path, ":t")), vim.log.levels.INFO)
							else
								vim.notify(string.format("Failed to rename file: %s", tostring(err)), vim.log.levels.ERROR)
							end
						end
					end)
				end,
			}, opts.handlers or {})

			local user_on_attach = opts.on_attach

			local function track_buffer(client, bufnr)
				attached_buffers[client.id] = attached_buffers[client.id] or {}
				attached_buffers[client.id][bufnr] = true
				register_buffer_cleanup(client.id, bufnr)
			end

			-- local function default_on_attach(_, bufnr)
			--   vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr, desc = 'Go to definition' })
			--   vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = bufnr, desc = 'Hover' })
			--   vim.keymap.set('n', 'gr', vim.lsp.buf.references, { buffer = bufnr, desc = 'References' })
			--   vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { buffer = bufnr, desc = 'Rename' })
			--   vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { buffer = bufnr, desc = 'Code action' })
			-- end

			local function combined_on_attach(client, bufnr)
				track_buffer(client, bufnr)
				-- Don't manually request diagnostics - the server will push them automatically
				-- This prevents duplicate diagnostics from appearing

				-- Setup workspace loading for project buffers
				if is_project then
					workspace.setup_for_buffer(
						client,
						bufnr,
						root_dir,
						opts.max_matches,
						opts.max_modified_lines,
						opts.trigger_count
					)
				end

				-- Setup ExecSpace decorations (virtual text for Client/Server/etc)
				if opts.execspace_decorations ~= false then
					execspace.setup_for_buffer(client, bufnr)
				end

				if user_on_attach then
					local ok, err = pcall(user_on_attach, client, bufnr)
					if not ok then
						vim.notify("mLua on_attach callback failed: " .. tostring(err), vim.log.levels.ERROR)
					end
				else
					-- default_on_attach(client, bufnr)
				end
			end

			-- Load predefines synchronously (small, fast)
			local predefs = predefines.load_predefines(installed_dir) or {}

			-- Current buffer document
			local current_uri = vim.uri_from_bufnr(args.buf)
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local text = table.concat(lines, "\n")

			-- Function to start LSP with given workspace data
			local function start_lsp_with_data(document_items, entry_items)
				-- Ensure current buffer is included
				local has_current = false
				for _, item in ipairs(document_items) do
					if item.uri == current_uri then
						has_current = true
						break
					end
				end

				if not has_current then
					table.insert(document_items, 1, {
						uri = current_uri,
						languageId = "mlua",
						version = 0,
						text = text,
					})
				end

				local init_options_table = {
					documentItems = document_items,
					entryItems = entry_items,
					modules = predefs.modules or {},
					globalVariables = predefs.globalVariables or {},
					globalFunctions = predefs.globalFunctions or {},
					stopwatch = false,
					profileMode = 0,
					capabilities = {
						completionCapability = {
							codeBlockScriptSnippetCompletion = true,
							codeBlockBTNodeSnippetCompletion = true,
							codeBlockComponentSnippetCompletion = true,
							codeBlockEventSnippetCompletion = true,
							codeBlockMethodSnippetCompletion = true,
							codeBlockHandlerSnippetCompletion = true,
							codeBlockItemSnippetCompletion = true,
							codeBlockLogicSnippetCompletion = true,
							codeBlockPropertySnippetCompletion = true,
							codeBlockStateSnippetCompletion = true,
							codeBlockStructSnippetCompletion = true,
							attributeCompletion = true,
							eventMethodCompletion = true,
							overrideMethodCompletion = true,
							overridePropertyCompletion = true,
							annotationCompletion = true,
							keywordCompletion = true,
							luaCodeCompletion = true,
							commitCharacterSupport = true,
						},
						definitionCapability = {},
						diagnosticCapability = {
							needExtendsDiagnostic = true,
							notEqualsNameDiagnostic = true,
							duplicateLocalDiagnostic = true,
							introduceGlobalVariableDiagnostic = true,
							parseErrorDiagnostic = true,
							annotationParseErrorDiagnostic = true,
							unavailableAttributeDiagnostic = true,
							unavailableTypeDiagnostic = true,
							unresolvedMemberDiagnostic = true,
							unresolvedSymbolDiagnostic = true,
							assignTypeMismatchDiagnostic = true,
							parameterTypeMismatchDiagnostic = true,
							deprecatedDiagnostic = true,
							overrideMemberMismatchDiagnostic = true,
							unavailableOptionalParameterDiagnostic = true,
							unavailableParameterNameDiagnostic = true,
							invalidAttributeArgumentDiagnostic = true,
							notAllowPropertyDefaultValueDiagnostic = true,
							assignToReadonlyDiagnostic = true,
							needPropertyDefaultValueDiagnostic = true,
							notEnoughArgumentDiagnostic = true,
							tooManyArgumentDiagnostic = true,
							duplicateMemberDiagnostic = true,
							cannotOverrideMemberDiagnostic = true,
							tableKeyTypeMismatchDiagnostic = true,
							duplicateAttributeDiagnostic = true,
							invalidEventHandlerParameterDiagnostic = true,
							unavailablePropertyNameDiagnostic = true,
							annotationTypeNotFoundDiagnostic = true,
							annotationParamNotFoundDiagnostic = true,
							unbalancedAssignmentDiagnostic = true,
							unexpectedReturnDiagnostic = true,
							needReturnDiagnostic = true,
							duplicateParamDiagnostic = true,
							returnTypeMismatchDiagnostic = true,
							expectedReturnValueDiagnostic = true,
						},
						documentSymbolCapability = {},
						hoverCapability = {},
						referenceCapability = {},
						semanticTokensCapability = {},
						signatureHelpCapability = {},
						typeDefinitionCapability = {},
						renameCapability = {},
						inlayHintCapability = {},
						documentFormattingCapability = {},
						documentRangeFormattingCapability = {},
					},
				}

				local init_options_json = vim.fn.json_encode(init_options_table)

				-- Use Node.js (Bun has compatibility issues with worker threads)
				local runtime = "node"

				vim.lsp.start({
					name = "mlua",
					cmd = { runtime, server_path, "--stdio" },
					root_dir = root_dir,
					init_options = init_options_json,
					settings = opts.settings or {},
					handlers = handlers,
					flags = {
						debounce_text_changes = 150,
						allow_incremental_sync = true,
					},
					on_init = function(client, initialize_result)
						-- Silent on_init, only log errors
					end,
					on_attach = combined_on_attach,
					on_error = function(code, err)
						vim.notify("mLua LSP error [" .. tostring(code) .. "]: " .. tostring(err), vim.log.levels.ERROR)
					end,
					on_exit = function(code, signal, client_id)
						-- Cleanup document watchers
						document.cleanup(client_id)
					end,
					capabilities = client_capabilities,
				}, {
					bufnr = args.buf,
				})
			end

			-- Start LSP with VS Code-like full workspace loading
			if is_project then
				lsp_starting[root_dir] = true

				-- Show progress notification
				vim.notify("Loading mLua workspace...", vim.log.levels.INFO)

				-- Collect all documents and entries in parallel (like VS Code)
				local docs_ready = false
				local entries_ready = false
				local all_documents = {}
				local all_entries = {}

				local function try_start_lsp()
					if not docs_ready or not entries_ready then
						return
					end

					vim.schedule(function()
						-- Start LSP with full workspace context (VS Code style)
						start_lsp_with_data(all_documents, all_entries)

						lsp_starting[root_dir] = false

						vim.notify(
							string.format(
								"✓ mLua workspace loaded: %d files, %d entries",
								#all_documents,
								#all_entries
							),
							vim.log.levels.INFO
						)

						-- Setup file watchers (like VS Code's DocumentService)
						local client = vim.lsp.get_clients({ name = "mlua", bufnr = args.buf })[1]
						if client then
							document.setup_file_watcher(client, root_dir)
							document.setup_entry_watcher(client, root_dir, entries)
						end
					end)
				end

				-- Load all documents async (VS Code loads sync with progress, we do async for better UX)
				document.collect_all_documents_async(root_dir, function(documents)
					all_documents = documents
					docs_ready = true
					try_start_lsp()
				end, function(current, total, filename)
					-- Optional: could show progress here
				end)

				-- Load entry items
				entries.collect_entry_items_async(installed_dir, root_dir, function(entry_items)
					all_entries = entry_items
					entries_ready = true
					try_start_lsp()
				end)
			else
				-- No project, just start with current buffer
				start_lsp_with_data({}, {})
			end
		end,
	})
end

-- Install Tree-sitter parser and queries
function M.install_treesitter()
	local parser_dir = vim.fn.expand("~/tree-sitter-mlua")
	local parser_ext = vim.fn.has("win32") == 1 and "dll" or "so"
	local parser_path = vim.fn.stdpath("data") .. "/site/parser/mlua." .. parser_ext
	local queries_dir = vim.fn.stdpath("data") .. "/site/queries/mlua"

	-- Check if parser repo exists, if not, clone it
	if vim.fn.isdirectory(parser_dir) == 0 then
		vim.notify("Cloning tree-sitter-mlua repository...", vim.log.levels.INFO)
		local clone_cmd = string.format('git clone https://github.com/seokgukim/tree-sitter-mlua.git "%s"', parser_dir)
		local result = vim.fn.system(clone_cmd)
		if vim.v.shell_error ~= 0 then
			vim.notify("Failed to clone repository:\n" .. result, vim.log.levels.ERROR)
			return false
		end
		vim.notify("✓ Repository cloned", vim.log.levels.INFO)
	else
		-- Repository exists, pull latest changes
		vim.notify("Updating tree-sitter-mlua repository...", vim.log.levels.INFO)
		local pull_cmd = string.format('cd "%s" && git pull', parser_dir)
		local result = vim.fn.system(pull_cmd)
		if vim.v.shell_error ~= 0 then
			vim.notify("Failed to pull updates:\n" .. result, vim.log.levels.WARN)
			vim.notify("Continuing with existing version...", vim.log.levels.INFO)
		else
			vim.notify("✓ Repository updated", vim.log.levels.INFO)
		end
	end

	vim.notify("Setting up Tree-sitter parser for mLua...", vim.log.levels.INFO)

	-- Ensure parser directory exists
	vim.fn.mkdir(vim.fn.stdpath("data") .. "/site/parser", "p")

	-- Compile parser directly (no need for npm install, parser.c already exists)
	vim.notify("Compiling parser...", vim.log.levels.INFO)
	local compile_cmd
	if vim.fn.has("win32") == 1 then
		-- Windows: use cl.exe (MSVC) or gcc if available
		if vim.fn.executable("cl") == 1 then
			compile_cmd = string.format(
				'cl /O2 /LD /MD /I"%s\\src" "%s\\src\\parser.c" /link /out:"%s"',
				parser_dir,
				parser_dir,
				parser_path
			)
		elseif vim.fn.executable("gcc") == 1 then
			compile_cmd = string.format(
				'gcc -o "%s" -I"%s/src" "%s/src/parser.c" -shared -Os -fPIC',
				parser_path,
				parser_dir,
				parser_dir
			)
		else
			vim.notify("No C compiler found. Install MSVC (cl) or MinGW (gcc).", vim.log.levels.ERROR)
			return false
		end
	else
		compile_cmd = string.format(
			'cc -o "%s" -I"%s/src" "%s/src/parser.c" -shared -Os -fPIC',
			parser_path,
			parser_dir,
			parser_dir
		)
	end

	local compile_result = vim.fn.system(compile_cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Compilation failed:\n" .. compile_result, vim.log.levels.ERROR)
		return false
	end

	-- Verify parser file was created
	if vim.fn.filereadable(parser_path) == 0 then
		vim.notify("Parser file not created at: " .. parser_path, vim.log.levels.ERROR)
		return false
	end

	-- Install queries
	vim.notify("Installing queries...", vim.log.levels.INFO)
	vim.fn.mkdir(queries_dir, "p")
	local highlights_src = parser_dir .. "/queries/highlights.scm"
	local highlights_dst = queries_dir .. "/highlights.scm"

	-- Copy query file
	local copy_cmd
	if vim.fn.has("win32") == 1 then
		copy_cmd = string.format('copy /Y "%s" "%s"', highlights_src:gsub("/", "\\"), highlights_dst:gsub("/", "\\"))
	else
		copy_cmd = string.format('cp "%s" "%s"', highlights_src, highlights_dst)
	end

	local copy_result = vim.fn.system(copy_cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to copy queries:\n" .. copy_result, vim.log.levels.ERROR)
		return false
	end

	vim.notify(
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
		vim.log.levels.INFO
	)
	vim.notify("✓ Tree-sitter setup complete!", vim.log.levels.INFO)
	vim.notify("  Parser: " .. parser_path, vim.log.levels.INFO)
	vim.notify("  Queries: " .. highlights_dst, vim.log.levels.INFO)
	vim.notify(
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
		vim.log.levels.INFO
	)
	vim.notify("Restart Neovim to activate highlighting.", vim.log.levels.WARN)

	return true
end

-- Commands
vim.api.nvim_create_user_command("MluaInstall", M.download, { desc = "Install mLua language server" })
vim.api.nvim_create_user_command("MluaUpdate", M.update, { desc = "Update mLua language server" })
vim.api.nvim_create_user_command("MluaCheckVersion", M.check_version, { desc = "Check mLua version" })
vim.api.nvim_create_user_command("MluaUninstall", M.uninstall, { desc = "Uninstall mLua language server" })
vim.api.nvim_create_user_command(
	"MluaTSInstall",
	M.install_treesitter,
	{ desc = "Install Tree-sitter parser for mLua" }
)
vim.api.nvim_create_user_command("MluaRestart", function()
	vim.lsp.stop_client(vim.lsp.get_clients({ name = "mlua" }))
	vim.defer_fn(function()
		vim.cmd("edit")
	end, 500)
end, { desc = "Restart mLua language server" })
vim.api.nvim_create_user_command("MluaReloadWorkspace", function()
	local clients = vim.lsp.get_clients({ name = "mlua" })
	for _, client in ipairs(clients) do
		local tracked = attached_buffers[client.id]
		if not tracked then
			return
		end

		for bufnr in pairs(tracked) do
			local fname = vim.api.nvim_buf_get_name(bufnr)
			local root_dir = utils.find_root(fname)
			if root_dir then
				workspace.reload_workspace(client, bufnr, root_dir, opt.max_matches)
			end
		end
	end
end, { desc = "Reload mLua workspace index" })

vim.api.nvim_create_user_command("MluaToggleExecSpace", function()
	execspace.toggle()
end, { desc = "Toggle ExecSpace decorations" })

vim.api.nvim_create_user_command("MluaRefreshExecSpace", function()
	execspace.refresh_all()
end, { desc = "Refresh ExecSpace decorations for all buffers" })

-- Export execspace module for external access
M.execspace = execspace

return M
