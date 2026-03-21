-- Utility functions for mLua
local M = {}

---Find project root for a given file
---@param filename string File path
---@return string|nil root_dir Root directory or nil
function M.find_root(filename)
	local root_patterns = { "package.json", ".git", "workspace.json" }
	local roots = vim.fs.find(root_patterns, { path = filename, upward = true })
	if #roots > 0 then
		return vim.fs.dirname(roots[1])
	end
	return nil
end

return M
