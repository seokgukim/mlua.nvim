-- mLua DAP (Debug Adapter Protocol) integration for nvim-dap
-- Implements a debug adapter for the MSW debugger protocol
-- Note: This is a custom adapter that doesn't use standard DAP over JSON-RPC,
-- instead it communicates directly with the MSW debug server using its binary protocol.

local M = {}

---@class MluaDapLocalConfig
---@field port number Default port to connect to (default: 51300)
---@field host string Host to connect to (default: "localhost")
---@field timeout number Connection timeout in ms (default: 30000)
local default_config = {
	port = 51300,
	host = "localhost",
	timeout = 30000,
}

---@type MluaDapConfig
M.config = vim.deepcopy(default_config)

local adapter = require("mlua.dap.adapter")

-- Breakpoints tracked per file
local tracked_breakpoints = {}

---Setup nvim-dap integration for mLua
---@param opts MluaDapConfig?
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", default_config, opts or {})

	local ok, dap = pcall(require, "dap")
	if not ok then
		vim.notify("nvim-dap is required for mLua debugging", vim.log.levels.WARN)
		return
	end

	-- Since MSW uses a custom binary protocol (not standard DAP JSON-RPC),
	-- we implement a custom adapter that handles the communication directly.
	-- The nvim-dap UI (dap-ui) still works because we emit standard DAP events.

	-- Register the mLua debug adapter
	dap.adapters.mlua = function(callback, config)
		local host = config.host or M.config.host
		local port = config.port or M.config.port

		adapter.connect(host, port, function(err)
			if err then
				vim.notify("mLua debugger: " .. err, vim.log.levels.ERROR)
				return
			end

			-- Set up event handler to forward events to nvim-dap
			adapter.setEventHandler(function(event, body)
				-- nvim-dap needs to know about stopped events
				if event == "stopped" then
					-- Update DAP UI
					local dap_session = dap.session()
					if dap_session then
						dap_session:event("stopped", body)
					end
				elseif event == "terminated" then
					local dap_session = dap.session()
					if dap_session then
						dap_session:event("terminated", body)
					end
				end
			end)

			-- Send any tracked breakpoints
			for filePath, lines in pairs(tracked_breakpoints) do
				adapter.setBreakpoints(filePath, lines)
			end

			-- Create a pseudo-session that nvim-dap can work with
			-- We return a "pipe" adapter that we won't actually use for communication
			callback({
				type = "pipe",
				pipe = nil, -- Not used, we handle communication ourselves
			})
		end)
	end

	-- Register default configuration
	dap.configurations.mlua = {
		{
			type = "mlua",
			request = "attach",
			name = "Attach to MSW",
			port = M.config.port,
			host = M.config.host,
		},
	}

	-- Set up sign column for breakpoints
	vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint", linehl = "", numhl = "" })
	vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DapBreakpoint", linehl = "", numhl = "" })
	vim.fn.sign_define("DapStopped", { text = "→", texthl = "DapStopped", linehl = "DapStopped", numhl = "" })

	-- Create user commands
	vim.api.nvim_create_user_command("MluaDebugAttach", function(args)
		local port = M.config.port
		if args.args and #args.args > 0 then
			port = tonumber(args.args) or port
		end
		dap.run({
			type = "mlua",
			request = "attach",
			name = "Attach to MSW",
			port = port,
			host = M.config.host,
		})
	end, { nargs = "?", desc = "Attach mLua debugger to MSW" })

	vim.api.nvim_create_user_command("MluaDebugDisconnect", function()
		adapter.disconnect()
	end, { desc = "Disconnect mLua debugger" })

	vim.api.nvim_create_user_command("MluaDebugContinue", function()
		adapter.continue()
	end, { desc = "Continue execution" })

	vim.api.nvim_create_user_command("MluaDebugStepOver", function()
		adapter.next()
	end, { desc = "Step over" })

	vim.api.nvim_create_user_command("MluaDebugStepInto", function()
		adapter.stepIn()
	end, { desc = "Step into" })

	vim.api.nvim_create_user_command("MluaDebugStepOut", function()
		adapter.stepOut()
	end, { desc = "Step out" })

	vim.api.nvim_create_user_command("MluaDebugToggleBreakpoint", function()
		M.toggleBreakpoint()
	end, { desc = "Toggle breakpoint" })

	vim.api.nvim_create_user_command("MluaDebugClearBreakpoints", function()
		M.clearBreakpoints()
	end, { desc = "Clear all breakpoints" })

	-- Stack trace command
	vim.api.nvim_create_user_command("MluaDebugStackTrace", function()
		local trace = adapter.getStackTrace()
		if trace.totalFrames == 0 then
			vim.notify("No stack trace available", vim.log.levels.INFO)
			return
		end
		local lines = { "Stack Trace:" }
		for i, frame in ipairs(trace.stackFrames) do
			table.insert(lines, string.format("  %d: %s at %s:%d", i, frame.name, frame.source.name, frame.line))
		end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
	end, { desc = "Show stack trace" })

	-- Evaluate expression command
	vim.api.nvim_create_user_command("MluaDebugEval", function(args)
		if not args.args or #args.args == 0 then
			vim.notify("Usage: MluaDebugEval <expression>", vim.log.levels.WARN)
			return
		end
		adapter.evaluate(args.args, nil, "repl", function(result)
			vim.notify(string.format("%s = %s (%s)", args.args, result.result, result.type or "unknown"))
		end)
	end, { nargs = "+", desc = "Evaluate expression" })

	-- Set up buffer-local keymaps for mlua files
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "mlua",
		callback = function(args)
			local bufnr = args.buf
			local opts = { buffer = bufnr, silent = true }

			-- Debugging keymaps (only for mlua buffers)
			vim.keymap.set("n", "<F5>", "<cmd>MluaDebugContinue<cr>", vim.tbl_extend("force", opts, { desc = "Continue" }))
			vim.keymap.set("n", "<F9>", "<cmd>MluaDebugToggleBreakpoint<cr>", vim.tbl_extend("force", opts, { desc = "Toggle breakpoint" }))
			vim.keymap.set("n", "<F10>", "<cmd>MluaDebugStepOver<cr>", vim.tbl_extend("force", opts, { desc = "Step over" }))
			vim.keymap.set("n", "<F11>", "<cmd>MluaDebugStepInto<cr>", vim.tbl_extend("force", opts, { desc = "Step into" }))
			vim.keymap.set("n", "<S-F11>", "<cmd>MluaDebugStepOut<cr>", vim.tbl_extend("force", opts, { desc = "Step out" }))
			vim.keymap.set("n", "<leader>dc", "<cmd>MluaDebugContinue<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Continue" }))
			vim.keymap.set("n", "<leader>db", "<cmd>MluaDebugToggleBreakpoint<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Toggle breakpoint" }))
			vim.keymap.set("n", "<leader>dB", "<cmd>MluaDebugClearBreakpoints<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Clear breakpoints" }))
			vim.keymap.set("n", "<leader>ds", "<cmd>MluaDebugStepOver<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Step over" }))
			vim.keymap.set("n", "<leader>di", "<cmd>MluaDebugStepInto<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Step into" }))
			vim.keymap.set("n", "<leader>do", "<cmd>MluaDebugStepOut<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Step out" }))
			vim.keymap.set("n", "<leader>dt", "<cmd>MluaDebugStackTrace<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Stack trace" }))
			vim.keymap.set("n", "<leader>da", "<cmd>MluaDebugAttach<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Attach" }))
			vim.keymap.set("n", "<leader>dd", "<cmd>MluaDebugDisconnect<cr>", vim.tbl_extend("force", opts, { desc = "Debug: Disconnect" }))
		end,
	})
end

---Toggle a breakpoint at the current cursor position
function M.toggleBreakpoint()
	local bufnr = vim.api.nvim_get_current_buf()
	local filePath = vim.api.nvim_buf_get_name(bufnr)
	local line = vim.api.nvim_win_get_cursor(0)[1]

	-- Initialize breakpoints for this file if needed
	if not tracked_breakpoints[filePath] then
		tracked_breakpoints[filePath] = {}
	end

	-- Check if breakpoint exists at this line
	local found_idx = nil
	for i, bp_line in ipairs(tracked_breakpoints[filePath]) do
		if bp_line == line then
			found_idx = i
			break
		end
	end

	if found_idx then
		-- Remove breakpoint
		table.remove(tracked_breakpoints[filePath], found_idx)
		vim.fn.sign_unplace("mlua_breakpoints", { buffer = bufnr, id = line })
	else
		-- Add breakpoint
		table.insert(tracked_breakpoints[filePath], line)
		vim.fn.sign_place(line, "mlua_breakpoints", "DapBreakpoint", bufnr, { lnum = line, priority = 10 })
	end

	-- Send updated breakpoints to server if connected
	if adapter.isConnected() then
		adapter.setBreakpoints(filePath, tracked_breakpoints[filePath])
	end
end

---Clear all breakpoints
function M.clearBreakpoints()
	for filePath, _ in pairs(tracked_breakpoints) do
		-- Find buffer for this file
		local bufnr = vim.fn.bufnr(filePath)
		if bufnr ~= -1 then
			vim.fn.sign_unplace("mlua_breakpoints", { buffer = bufnr })
		end

		-- Send empty breakpoints to server if connected
		if adapter.isConnected() then
			adapter.setBreakpoints(filePath, {})
		end
	end
	tracked_breakpoints = {}
end

---Get breakpoints for a file
---@param filePath string
---@return number[]
function M.getBreakpoints(filePath)
	return tracked_breakpoints[filePath] or {}
end

-- Export adapter functions for direct use
M.connect = function(host, port, callback)
	adapter.connect(host or M.config.host, port or M.config.port, callback)
end
M.disconnect = adapter.disconnect
M.isConnected = adapter.isConnected
M.continue = adapter.continue
M.stepOver = adapter.next
M.stepInto = adapter.stepIn
M.stepOut = adapter.stepOut
M.setBreakpoints = adapter.setBreakpoints
M.getStackTrace = adapter.getStackTrace
M.getScopes = adapter.getScopes
M.getVariables = adapter.getVariables
M.evaluate = adapter.evaluate
M.getExecSpace = adapter.getExecSpace

return M
