-- mLua.nvim - Neovim plugin for mLua language support
-- Provides LSP integration and Tree-sitter support for MapleStory Worlds scripting language

local M = {}

---@class MluaConfig
---@field lsp MluaLspConfig LSP configuration options
---@field treesitter boolean Enable Tree-sitter integration
local default_config = {
	lsp = {
		enabled = true,
		cmd = nil, -- Auto-detected from LSP module
		capabilities = nil, -- Will be set from nvim-cmp if available
		on_attach = nil, -- User callback
		max_matches = 3, -- Max fuzzy matches per token
		max_modified_lines = 5, -- Max modified lines to consider for re-indexing
		trigger_count = 4, -- Triggers load file after N characters typed
	},
	treesitter = {
		enabled = true,
		parser_path = vim.fn.expand("~/tree-sitter-mlua"),
	},
}

---@type MluaConfig
M.config = default_config

-- Setup Tree-sitter parser for mLua
local function setup_treesitter()
	if not M.config.treesitter.enabled then
		return false
	end

	local ok, parsers = pcall(require, "nvim-treesitter.parsers")
	if not ok then
		return false
	end

	-- Register the mLua parser
	local parser_config = parsers.get_parser_configs()
	parser_config.mlua = {
		install_info = {
			url = M.config.treesitter.parser_path,
			files = { "src/parser.c" },
			generate_requires_npm = false,
			requires_generate_from_grammar = false,
		},
		filetype = "mlua",
	}

	-- Add queries path for Tree-sitter to find highlights.scm
	local queries_path = M.config.treesitter.parser_path .. "/queries"
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
			max_matches = M.config.lsp.max_matches,
			max_modified_lines = M.config.lsp.max_modified_lines,
			trigger_count = M.config.lsp.trigger_count,
			on_attach = function(client, bufnr)
				-- Enable completion triggered by <c-x><c-o>
				vim.api.nvim_buf_set_option(bufnr, "omnifunc", "v:lua.vim.lsp.omnifunc")

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

		-- Create buffer-local commands for LSP actions
		-- Users can map these commands to their preferred keys
		vim.api.nvim_create_autocmd("LspAttach", {
			pattern = "*",
			callback = function(args)
				local client = vim.lsp.get_client_by_id(args.data.client_id)
				if client and client.name == "mlua" then
					local bufnr = args.buf

					-- LSP navigation and info commands
					vim.api.nvim_buf_create_user_command(bufnr, "MluaHover", function()
						vim.lsp.buf.hover()
					end, { desc = "Show hover information" })

					vim.api.nvim_buf_create_user_command(bufnr, "MluaDefinition", function()
						vim.lsp.buf.definition()
					end, { desc = "Go to definition" })

					vim.api.nvim_buf_create_user_command(bufnr, "MluaReferences", function()
						vim.lsp.buf.references()
					end, { desc = "Find references" })

					vim.api.nvim_buf_create_user_command(bufnr, "MluaRename", function()
						vim.lsp.buf.rename()
					end, { desc = "Rename symbol" })

					vim.api.nvim_buf_create_user_command(bufnr, "MluaFormat", function()
						vim.lsp.buf.format({ async = true })
					end, { desc = "Format document" })

					vim.api.nvim_buf_create_user_command(bufnr, "MluaToggleInlayHints", function()
						local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
						vim.lsp.inlay_hint.enable(not enabled, { bufnr = bufnr })
					end, { desc = "Toggle inlay hints" })
				end
			end,
		})
	end
end

-- Export debug utilities
M.debug = require("mlua.debug")

-- Debug function to check Tree-sitter status
function M.check_treesitter()
	local bufnr = vim.api.nvim_get_current_buf()
	local info = {
		filetype = vim.bo[bufnr].filetype,
		parser_installed = vim.fn.filereadable(vim.fn.stdpath("data") .. "/site/parser/mlua.so") == 1,
		highlighter_active = vim.treesitter.highlighter.active[bufnr] ~= nil,
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
