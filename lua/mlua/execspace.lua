-- ExecSpace decoration service - displays virtual text for method execution context
-- Mirrors VS Code's ExecSpaceDecorationService

local M = {}

-- ExecSpace decoration kinds (matching VS Code's enum)
M.ExecSpaceKind = {
	InvalidExecSpace = 0,
	ClientOnly = 1,
	ServerOnly = 2,
	Client = 3,
	Server = 4,
	Multicast = 5,
	Overlap = 6,
}

-- Virtual text labels for each kind
local labels = {
	[0] = { text = "⚠ Invalid", hl = "DiagnosticError" },
	[1] = { text = "ClientOnly", hl = "MluaExecSpaceClientOnly" },
	[2] = { text = "ServerOnly", hl = "MluaExecSpaceServerOnly" },
	[3] = { text = "Client", hl = "MluaExecSpaceClient" },
	[4] = { text = "Server", hl = "MluaExecSpaceServer" },
	[5] = { text = "Multicast", hl = "MluaExecSpaceMulticast" },
	[6] = { text = "Overlap", hl = "MluaExecSpaceOverlap" },
}

-- Namespace for virtual text
local ns_id = vim.api.nvim_create_namespace("mlua_execspace")

-- Track decorations per buffer
local buffer_decorations = {}

-- Setup highlight groups
local function setup_highlights()
	-- Define highlight groups if they don't exist
	local highlights = {
		MluaExecSpaceClientOnly = { fg = "#61AFEF", italic = true }, -- Blue
		MluaExecSpaceServerOnly = { fg = "#E06C75", italic = true }, -- Red
		MluaExecSpaceClient = { fg = "#98C379", italic = true }, -- Green
		MluaExecSpaceServer = { fg = "#E5C07B", italic = true }, -- Yellow
		MluaExecSpaceMulticast = { fg = "#C678DD", italic = true }, -- Purple
		MluaExecSpaceOverlap = { fg = "#D19A66", italic = true }, -- Orange
	}

	for name, attrs in pairs(highlights) do
		-- Only set if not already defined by user
		local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = name })
		if not ok or vim.tbl_isempty(existing) then
			vim.api.nvim_set_hl(0, name, attrs)
		end
	end
end

-- Clear decorations for a buffer
function M.clear_decorations(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	buffer_decorations[bufnr] = nil
end

-- Set decorations for a buffer from LSP response
-- response format: [[kind, [line1, line2, ...]], ...]
function M.set_decorations(bufnr, response)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Clear existing decorations
	M.clear_decorations(bufnr)

	if not response or type(response) ~= "table" then
		return
	end

	local decorations = {}

	for _, entry in ipairs(response) do
		local kind = entry[1]
		local lines = entry[2]

		if kind and lines and type(lines) == "table" then
			local label_info = labels[kind]
			if label_info then
				for _, line in ipairs(lines) do
					-- line is 0-indexed from server
					if type(line) == "number" and line >= 0 then
						table.insert(decorations, {
							line = line,
							kind = kind,
							text = label_info.text,
							hl = label_info.hl,
						})
					end
				end
			end
		end
	end

	-- Sort by line number
	table.sort(decorations, function(a, b)
		return a.line < b.line
	end)

	-- Apply virtual text
	for _, dec in ipairs(decorations) do
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if dec.line < line_count then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, dec.line, 0, {
				virt_text = { { " " .. dec.text, dec.hl } },
				virt_text_pos = "eol",
				priority = 100,
			})
		end
	end

	buffer_decorations[bufnr] = decorations
end

-- Request decorations from LSP server
function M.request_decorations(client, bufnr)
	if not client or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local uri = vim.uri_from_bufnr(bufnr)

	-- Use the custom request that VS Code uses
	client:request("msw.protocol.execSpaceDecorationRequest", { uri = uri }, function(err, result)
		if err then
			-- Silently ignore errors (server may not support this)
			return
		end

		if result then
			vim.schedule(function()
				M.set_decorations(bufnr, result)
			end)
		end
	end, bufnr)
end

-- Setup for a buffer (called from on_attach)
function M.setup_for_buffer(client, bufnr)
	setup_highlights()

	-- Request decorations initially
	M.request_decorations(client, bufnr)

	-- Request decorations after text changes (debounced)
	local timer = nil
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function()
			if timer then
				timer:stop()
			end
			timer = vim.defer_fn(function()
				M.request_decorations(client, bufnr)
			end, 500) -- Debounce 500ms
		end,
		on_detach = function()
			if timer then
				timer:stop()
			end
			M.clear_decorations(bufnr)
		end,
	})

	-- Clean up on buffer unload
	vim.api.nvim_create_autocmd("BufUnload", {
		buffer = bufnr,
		once = true,
		callback = function()
			buffer_decorations[bufnr] = nil
		end,
	})
end

-- Toggle decorations for current buffer
function M.toggle(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if buffer_decorations[bufnr] then
		M.clear_decorations(bufnr)
	else
		local clients = vim.lsp.get_clients({ name = "mlua", bufnr = bufnr })
		if #clients > 0 then
			M.request_decorations(clients[1], bufnr)
		end
	end
end

-- Refresh decorations for all visible buffers
function M.refresh_all()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local bufnr = vim.api.nvim_win_get_buf(win)
		if vim.bo[bufnr].filetype == "mlua" then
			local clients = vim.lsp.get_clients({ name = "mlua", bufnr = bufnr })
			if #clients > 0 then
				M.request_decorations(clients[1], bufnr)
			end
		end
	end
end

return M
