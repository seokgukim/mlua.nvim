-- Workspace management - simplified after VS Code-style full init
-- Now only handles workspace reload functionality

local document = require("mlua.document")
local entries = require("mlua.entries")

local M = {}

---Reload workspace - re-collect all documents and notify LSP
---@param client table LSP client
---@param bufnr number Buffer number
---@param root_dir string|nil Root directory
---@param installed_dir string|nil LSP server installation directory
function M.reload_workspace(client, bufnr, root_dir, installed_dir)
	if not root_dir or not client then
		return
	end

	vim.notify("Reloading mLua workspace...", vim.log.levels.INFO)

	-- Re-collect all documents
	document.collect_all_documents_async(root_dir, function(documents)
		-- Notify server about all documents
		for _, doc in ipairs(documents) do
			client:notify("textDocument/didOpen", {
				textDocument = doc,
			})
		end

		-- Re-collect entries if installed_dir provided
		if installed_dir then
			entries.collect_entry_items_async(installed_dir, root_dir, function(entry_items)
				-- Notify server about entries
				for _, entry in ipairs(entry_items) do
					client:notify("msw.protocol.entryChanged", {
						entryItem = entry,
					})
				end

				vim.notify(
					string.format("✓ Workspace reloaded: %d files, %d entries", #documents, #entry_items),
					vim.log.levels.INFO
				)
			end)
		else
			vim.notify(
				string.format("✓ Workspace reloaded: %d files", #documents),
				vim.log.levels.INFO
			)
		end

		-- Refresh diagnostics and semantic tokens
		client:notify("msw.protocol.refreshDiagnostic", {})
		client:notify("msw.protocol.refreshSemanticTokens", {})
	end)
end

return M
