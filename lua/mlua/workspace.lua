-- Workspace management - simplified after Node.js wrapper migration
-- Now only handles workspace reload functionality by sending a custom notification
-- to the mlua-server.js proxy.

local M = {}

---Reload workspace - notify proxy to re-collect all documents and entries
---@param client table LSP client
---@param bufnr number Buffer number
---@param root_dir string|nil Root directory
---@param installed_dir string|nil LSP server installation directory
function M.reload_workspace(client, bufnr, root_dir, installed_dir)
	if not root_dir or not client then
		return
	end

	vim.notify("Reloading mLua workspace...", vim.log.levels.INFO)

	-- Send custom notification intercepted by the JS proxy
	client:notify("mlua/reloadWorkspace", {
		rootDir = root_dir,
	})
	
	vim.notify("✓ Workspace reload requested", vim.log.levels.INFO)
end

return M
