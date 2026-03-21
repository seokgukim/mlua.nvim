-- LSP client setup and management for mLua
-- Handles client lifecycle; installation is delegated to installer.lua,
-- and workspace indexing is delegated to the JS wrapper (javascript/mlua-server.js).

local utils = require("mlua.utils")
local installer = require("mlua.installer")
local execspace = require("mlua.execspace")
local workspace = require("mlua.workspace")

local M = {}

---@type table<number, table<number, boolean>> Attached buffers per client
local attached_buffers = {}

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
---@field install_dir string Installation directory (javascript/)
---@field publisher string Extension publisher
---@field extension string Extension name

-- Delegate config and install operations to installer.lua
M.config = installer.config
M.get_latest_version = installer.get_latest_version
M.get_installed_version = installer.get_installed_version
M.download = installer.download
M.update = installer.update
M.check_version = installer.check_version
M.uninstall = installer.uninstall

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
		vim.notify("mLua language server not found. Run :Mlua install to install.", vim.log.levels.WARN)
		return
	end

	-- javascript/ directory is the parent of the installed extension dir
	local javascript_dir = vim.fn.fnamemodify(installed_dir, ":h")
	local wrapper_path = javascript_dir .. "/mlua-server.js"

	if vim.fn.filereadable(wrapper_path) == 0 then
		vim.notify("mlua-server.js wrapper not found at: " .. wrapper_path, vim.log.levels.ERROR)
		return
	end

	-- Build handlers: mlua required handlers first, then user-supplied handlers
	-- so the user can override everything except the required ones.
	-- Required handlers (workspace/diagnostic/refresh, mlua/execSpaceDecorationChanged)
	-- are always set and cannot be overridden.
	local required_handlers = {
		-- workspace/diagnostic/refresh arrives as a NOTIFICATION from the proxy
		-- (proxy intercepts the server's request, acks it, and re-sends without id).
		-- Neovim receives it here and manually re-requests diagnostics for all
		-- attached buffers.
		["workspace/diagnostic/refresh"] = function(_, _, ctx)
			local client = vim.lsp.get_client_by_id(ctx.client_id)
			if not client then return end
			for bufnr, _ in pairs(attached_buffers[client.id] or {}) do
				if vim.api.nvim_buf_is_valid(bufnr) then
					client:request("textDocument/diagnostic", {
						textDocument = { uri = vim.uri_from_bufnr(bufnr) },
					}, nil, bufnr)
				end
			end
		end,

		["mlua/execSpaceDecorationChanged"] = function(_, params, ctx)
			local client = vim.lsp.get_client_by_id(ctx.client_id)
			if client and params and params.uri then
				local bufnr = vim.uri_to_bufnr(params.uri)
				if vim.api.nvim_buf_is_valid(bufnr) then
					execspace.request_decorations(client, bufnr)
				end
			end
		end,
	}
	local handlers = vim.tbl_extend("force", required_handlers, opts.handlers or {})

	-- Register the server config via the 0.11+ vim.lsp.config() API.
	-- This decouples server definition from client lifecycle management.
	vim.lsp.config("mlua", {
		cmd = { "node", wrapper_path, "--stdio" },
		filetypes = { "mlua" },
		root_dir = function(bufnr, on_dir)
			local fname = vim.api.nvim_buf_get_name(bufnr)
			local root = utils.find_root(fname)
			if root then
				on_dir(vim.fn.fnamemodify(root, ":p"))
			else
				on_dir(vim.fn.fnamemodify(fname, ":p:h"))
			end
		end,
		settings = opts.settings or {},
		handlers = handlers,
		flags = {
			debounce_text_changes = 150,
			allow_incremental_sync = true,
		},
		cmd_env = { MLUA_INSTALL_DIR = installed_dir },
		capabilities = opts.capabilities,
		on_init = function(client, _)
			if client.server_capabilities.semanticTokensProvider then
				client.server_capabilities.semanticTokensProvider.full = true
			end
		end,
		on_attach = function(client, bufnr)
			-- Show version message only once when first mlua file is attached
			vim.notify_once("mLua LSP v" .. installed_version .. " configured", vim.log.levels.INFO)

			attached_buffers[client.id] = attached_buffers[client.id] or {}
			attached_buffers[client.id][bufnr] = true

			vim.api.nvim_create_autocmd("BufUnload", {
				buffer = bufnr,
				once = true,
				callback = function()
					if attached_buffers[client.id] then
						attached_buffers[client.id][bufnr] = nil
					end
				end,
			})

			if opts.execspace_decorations ~= false then
				execspace.setup_for_buffer(client, bufnr)
			end

			if opts.on_attach then
				pcall(opts.on_attach, client, bufnr)
			end
		end,
		on_exit = function(code, signal, client_id)
			attached_buffers[client_id] = nil
		end,
	})

	-- Enable the server for the mlua filetype using the 0.11+ API.
	vim.lsp.enable("mlua")
end

-- Subcommand handlers
local subcommands = {
	install = { fn = function() M.download() end, desc = "Install mLua language server" },
	update = { fn = function() M.update() end, desc = "Update mLua language server" },
	version = { fn = function() M.check_version() end, desc = "Check mLua version" },
	uninstall = { fn = function() M.uninstall() end, desc = "Uninstall mLua language server" },
	restart = {
		fn = function()
			vim.lsp.stop_client(vim.lsp.get_clients({ name = "mlua" }))
			vim.defer_fn(function()
				vim.cmd("edit")
			end, 500)
		end,
		desc = "Restart mLua language server",
	},
	reload = {
		fn = function()
			local clients = vim.lsp.get_clients({ name = "mlua" })
			for _, client in ipairs(clients) do
				local tracked = attached_buffers[client.id]
				if tracked then
					for bufnr in pairs(tracked) do
						local fname = vim.api.nvim_buf_get_name(bufnr)
						local root_dir = utils.find_root(fname)
						if root_dir then
							local _, installed_dir = M.get_installed_version()
							workspace.reload_workspace(client, bufnr, root_dir, installed_dir)
						end
					end
				end
			end
		end,
		desc = "Reload mLua workspace index",
	},
	execspace = {
		fn = function() execspace.toggle() end,
		desc = "Toggle ExecSpace decorations",
	},
}

-- Main :Mlua command
vim.api.nvim_create_user_command("Mlua", function(opts)
	local args = vim.split(opts.args, "%s+", { trimempty = true })
	local subcmd = args[1]

	if not subcmd or subcmd == "" then
		vim.notify("Usage: :Mlua <subcommand>", vim.log.levels.INFO)
		return
	end

	local cmd = subcommands[subcmd]
	if cmd then
		cmd.fn()
	else
		vim.notify(string.format("Unknown subcommand: %s", subcmd), vim.log.levels.ERROR)
	end
end, {
	nargs = "?",
	complete = function(arglead)
		local names = vim.tbl_keys(subcommands)
		table.sort(names)
		return vim.tbl_filter(function(name) return name:find("^" .. arglead) ~= nil end, names)
	end,
	desc = "Mlua commands",
})

M.execspace = execspace
return M
