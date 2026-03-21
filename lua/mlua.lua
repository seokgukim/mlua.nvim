-- mLua.nvim - Neovim plugin for mLua language support
-- Provides LSP integration and Tree-sitter support for MapleStory Worlds scripting language

local M = {}

---@class MluaLspConfig
---@field enabled boolean Enable LSP
---@field cmd string[]|nil LSP command (auto-detected if nil)
---@field capabilities table|nil LSP capabilities
---@field on_attach function|nil User callback on attach
---@field execspace_decorations boolean Enable ExecSpace virtual text decorations

---@class MluaTreesitterConfig
---@field enabled boolean Enable Tree-sitter integration
---@field parser_path string Path to tree-sitter-mlua

---@class MluaKeymapsConfig
---@field hover string|false Keymap for hover (default: "K")
---@field definition string|false Keymap for go to definition (default: "gd")
---@field references string|false Keymap for find references (default: "gr")
---@field declaration string|false Keymap for go to declaration (default: "gD")
---@field implementation string|false Keymap for go to implementation (default: "gi")
---@field rename string|false Keymap for rename (default: "<leader>rn")
---@field code_action string|false Keymap for code action (default: "<leader>ca")
---@field format string|false Keymap for format (default: "<leader>f")
---@field toggle_inlay_hints string|false Keymap for toggle inlay hints (default: "<leader>h")

---@class MluaConfig
---@field lsp MluaLspConfig LSP configuration options
---@field treesitter MluaTreesitterConfig Tree-sitter configuration options
---@field keymaps MluaKeymapsConfig|false Keymap configuration (false to disable all keymaps)
local default_config = {
	lsp = {
		enabled = true,
		cmd = nil, -- Auto-detected from LSP module
		capabilities = nil, -- Will be set from nvim-cmp if available
		on_attach = nil, -- User callback
		execspace_decorations = true, -- Enable ExecSpace virtual text decorations
	},
	treesitter = {
		enabled = true,
		parser_path = vim.fn.expand("~/tree-sitter-mlua"),
	},
	keymaps = {
		hover = "K",
		definition = "gd",
		references = "gr",
		declaration = "gD",
		implementation = "gi",
		rename = "<leader>rn",
		code_action = "<leader>ca",
		format = "<leader>f",
		toggle_inlay_hints = "<leader>h",
	},
}

---@type MluaConfig
M.config = default_config

-- Setup Tree-sitter parser for mLua
local function setup_treesitter()
	if not M.config.treesitter.enabled then
		return false
	end

	-- Add plugin runtimepath so Tree-sitter can find queries/mlua/highlights.scm
	vim.opt.runtimepath:append(M.config.treesitter.parser_path)

	-- Verify parser is available
	local parser_path = vim.fn.stdpath("data") .. "/site/parser/mlua.so"
	if vim.fn.filereadable(parser_path) == 1 then
		-- Enable Tree-sitter highlighting for mLua files
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "mlua",
			callback = function(args)
				local bufnr = args.buf
				-- Start Tree-sitter highlighting
				pcall(vim.treesitter.start, bufnr, "mlua")
				-- Disable Vim syntax to avoid conflicts
				vim.bo[bufnr].syntax = ""
			end,
		})

		-- Also enable for any existing mLua buffers
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "mlua" then
				pcall(vim.treesitter.start, bufnr, "mlua")
				vim.bo[bufnr].syntax = ""
			end
		end

		return true
	else
		return false
	end
end

---Setup function to be called from init.lua
---@param opts MluaConfig?
function M.setup(opts)
	-- Merge user config with defaults
	M.config = vim.tbl_deep_extend("force", default_config, opts or {})

	-- Initialize Tree-sitter if available
	local has_treesitter = setup_treesitter()

	-- Setup LSP if enabled
	if M.config.lsp.enabled then
		local lsp = require("mlua.lsp")

		-- Get capabilities from nvim-cmp if available and not provided
		local capabilities = M.config.lsp.capabilities
		if not capabilities then
			local ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
			if ok then
				capabilities = cmp_nvim_lsp.default_capabilities()
			end
		end

		-- Build LSP config
		local lsp_config = vim.tbl_deep_extend("force", {
			capabilities = capabilities,
			execspace_decorations = M.config.lsp.execspace_decorations,
			on_attach = function(client, bufnr)
				-- Enable completion triggered by <c-x><c-o>
				vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"

				-- Enable inlay hints if supported
				if client.server_capabilities.inlayHintProvider then
					vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
				end

				-- Only enable document highlight if Tree-sitter is not available
				if not has_treesitter and client.server_capabilities.documentHighlightProvider then
					vim.api.nvim_create_augroup("lsp_document_highlight", { clear = false })
					vim.api.nvim_clear_autocmds({
						buffer = bufnr,
						group = "lsp_document_highlight",
					})
					vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
						group = "lsp_document_highlight",
						buffer = bufnr,
						callback = vim.lsp.buf.document_highlight,
					})
					vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
						group = "lsp_document_highlight",
						buffer = bufnr,
						callback = vim.lsp.buf.clear_references,
					})
				end

				-- Call user's on_attach if provided
				if M.config.lsp.on_attach then
					M.config.lsp.on_attach(client, bufnr)
				end
			end,
		}, M.config.lsp or {})

		-- Setup LSP
		lsp.setup(lsp_config)

		-- Create buffer-local commands and keymaps for LSP actions
		vim.api.nvim_create_autocmd("LspAttach", {
			pattern = "*",
			callback = function(args)
				local client = vim.lsp.get_client_by_id(args.data.client_id)
				if client and client.name == "mlua" then
			local bufnr = args.buf
				local opts = { buffer = bufnr, silent = true }

				-- Configurable LSP keymaps (buffer-local, only for mlua LSP)
					local keymaps = M.config.keymaps
					if keymaps ~= false then
						local function set_keymap(key, action, desc)
							if key and key ~= false then
								vim.keymap.set("n", key, action, vim.tbl_extend("force", opts, { desc = desc }))
							end
						end

						set_keymap(keymaps.hover, vim.lsp.buf.hover, "Hover")
						set_keymap(keymaps.definition, vim.lsp.buf.definition, "Go to definition")
						set_keymap(keymaps.references, vim.lsp.buf.references, "Find references")
						set_keymap(keymaps.declaration, vim.lsp.buf.declaration, "Go to declaration")
						set_keymap(keymaps.implementation, vim.lsp.buf.implementation, "Go to implementation")
						set_keymap(keymaps.rename, vim.lsp.buf.rename, "Rename symbol")
						set_keymap(keymaps.code_action, vim.lsp.buf.code_action, "Code action")
						set_keymap(keymaps.format, function() vim.lsp.buf.format({ async = true }) end, "Format")
						set_keymap(keymaps.toggle_inlay_hints, function()
							local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
							vim.lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
						end, "Toggle inlay hints")
					end
				end
			end,
		})
	end

	-- Setup DAP if enabled
	-- NOTE: DAP support has been moved to a separate plugin.
	-- The MSW debugger uses a binary protocol instead of JSON-RPC,
	-- which is incompatible with nvim-dap. A custom debug solution is needed.
end

-- Export debug utilities
M.debug = require("mlua.debug")

-- Debug function to check Tree-sitter status
function M.check_treesitter()
	local bufnr = vim.api.nvim_get_current_buf()
	local info = {
		filetype = vim.bo[bufnr].filetype,
		parser_installed = vim.fn.filereadable(vim.fn.stdpath("data") .. "/site/parser/mlua.so") == 1,
		highlighter_active = pcall(vim.treesitter.get_parser, bufnr, "mlua"),
		parser_path = M.config.treesitter.parser_path,
		queries_path = M.config.treesitter.parser_path .. "/queries",
	}

	-- Try to get parser
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "mlua")
	info.parser_available = ok

	-- Try to get query
	local query_ok, query = pcall(vim.treesitter.query.get, "mlua", "highlights")
	info.query_available = query_ok
	if query_ok and query then
		info.query_captures = #query.captures
	end

	-- Print info:MluaTSInstall
	print("=== mLua Tree-sitter Status ===")
	for k, v in pairs(info) do
		print(string.format("%s: %s", k, vim.inspect(v)))
	end

	-- Try to start Tree-sitter
	if info.filetype == "mlua" and info.parser_installed then
		print("\nAttempting to start Tree-sitter...")
		local start_ok, err = pcall(vim.treesitter.start, bufnr, "mlua")
		print("Start result:", start_ok, err)
	end
end

return M
