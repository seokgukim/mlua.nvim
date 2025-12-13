-- mLua DAP Adapter
-- Implements a custom Debug Adapter for nvim-dap using direct TCP communication
-- This adapter communicates directly with the MSW debug server using its binary protocol

local M = {}

local protocol = require("mlua.dap.protocol")
local uv = vim.uv or vim.loop

---@class MluaDebugSession
---@field socket userdata|nil TCP socket (uv_tcp_t)
---@field receiveBuffer string Buffer for incoming data
---@field running boolean Whether the session is running
---@field requestId number Current request ID counter
---@field pendingRequests table<number, function> Pending request callbacks
---@field currentStack table|nil Current stack trace
---@field currentStackFrameId number Currently selected stack frame ID
---@field variableContainers table<number, table> Variable containers by reference
---@field heartbeatTimer userdata|nil Heartbeat timer (uv_timer_t)
---@field timeoutTimer userdata|nil Receive timeout timer (uv_timer_t)
---@field onEvent function|nil Callback for DAP events
---@field pendingBreakpoints table<string, table> Pending breakpoints by file path

---@type MluaDebugSession|nil
local session = nil

---Generate next request ID
---@return number
local function nextRequestId()
	if not session then
		return 1
	end
	session.requestId = (session.requestId or 0) + 1
	return session.requestId
end

---Send a message through the socket
---@param data string
local function send(data)
	if session and session.socket then
		session.socket:write(data)
	end
end

---Reset receive timeout
local function resetReceiveTimeout()
	if session and session.timeoutTimer then
		session.timeoutTimer:stop()
		session.timeoutTimer:start(30000, 0, function()
			vim.schedule(function()
				vim.notify("mLua debugger: receive timeout", vim.log.levels.ERROR)
				M.disconnect()
			end)
		end)
	end
end

---Start heartbeat timer
local function startHeartbeat()
	if session and session.heartbeatTimer then
		session.heartbeatTimer:start(1000, 1000, function()
			send(protocol.createHeartbeat())
		end)
	end
end

---Stop timers
local function stopTimers()
	if session then
		if session.heartbeatTimer then
			session.heartbeatTimer:stop()
			session.heartbeatTimer:close()
		end
		if session.timeoutTimer then
			session.timeoutTimer:stop()
			session.timeoutTimer:close()
		end
	end
end

---Send DAP event
---@param event string
---@param body table|nil
local function sendDapEvent(event, body)
	if session and session.onEvent then
		session.onEvent(event, body)
	end
end

---Handle incoming message
---@param header table
---@param payload string
local function handleMessage(header, payload)
	resetReceiveTimeout()

	local messageType = header.messageType

	if messageType == protocol.MessageType.Heartbeat then
		-- Heartbeat received, nothing to do
	elseif messageType == protocol.MessageType.AcceptConnection then
		-- Connection accepted
		vim.schedule(function()
			vim.notify("mLua debugger: connected", vim.log.levels.INFO)
			-- Send any pending breakpoints
			if session and session.pendingBreakpoints then
				for filePath, breakpoints in pairs(session.pendingBreakpoints) do
					send(protocol.createSetBreakpoints(filePath, breakpoints))
				end
				session.pendingBreakpoints = {}
			end
		end)
	elseif messageType == protocol.MessageType.DenyConnection then
		-- Connection denied
		vim.schedule(function()
			vim.notify("mLua debugger: connection denied", vim.log.levels.ERROR)
			M.disconnect()
		end)
	elseif messageType == protocol.MessageType.UpdateCallStack then
		-- Call stack updated (breakpoint hit)
		local data = protocol.deserializeUpdateCallStack(payload)
		session.currentStack = {
			execSpace = data.execSpace,
			frames = data.stackFrames,
		}
		if #data.stackFrames > 0 then
			session.currentStackFrameId = data.stackFrames[1].id
		end
		-- Clear variable containers on new stack
		session.variableContainers = {}

		vim.schedule(function()
			sendDapEvent("stopped", {
				reason = "breakpoint",
				threadId = 1,
				allThreadsStopped = true,
			})
		end)
	elseif protocol.isAckType(messageType) then
		-- Response message
		local requestId
		local response

		if messageType == protocol.MessageType.FailureResponse then
			response = protocol.deserializeFailureResponse(payload)
			requestId = response.requestId
		elseif messageType == protocol.MessageType.ScopesResponse then
			response = protocol.deserializeScopesResponse(payload)
			requestId = response.requestId
		elseif messageType == protocol.MessageType.VariablesResponse then
			response = protocol.deserializeVariablesResponse(payload)
			requestId = response.requestId
		elseif messageType == protocol.MessageType.EvaluateResponse then
			response = protocol.deserializeEvaluateResponse(payload)
			requestId = response.requestId
		end

		if requestId and session.pendingRequests[requestId] then
			local callback = session.pendingRequests[requestId]
			session.pendingRequests[requestId] = nil
			vim.schedule(function()
				callback(response, messageType)
			end)
		end
	end
end

---Process receive buffer
local function processReceiveBuffer()
	if not session then
		return
	end
	while #session.receiveBuffer >= protocol.HEADER_SIZE do
		local header = protocol.deserializeHeader(session.receiveBuffer)
		if not header then
			break
		end

		if #session.receiveBuffer < header.totalLength then
			break
		end

		local payload = session.receiveBuffer:sub(protocol.HEADER_SIZE + 1, header.totalLength)
		session.receiveBuffer = session.receiveBuffer:sub(header.totalLength + 1)

		handleMessage(header, payload)
	end
end

---Connect to debug server
---@param host string
---@param port number
---@param callback function Called with nil on success, or error message on failure
function M.connect(host, port, callback)
	-- Initialize session
	session = {
		socket = nil,
		receiveBuffer = "",
		running = true,
		requestId = 0,
		pendingRequests = {},
		currentStack = nil,
		currentStackFrameId = -1,
		variableContainers = {},
		heartbeatTimer = uv.new_timer(),
		timeoutTimer = uv.new_timer(),
		onEvent = nil,
		pendingBreakpoints = {},
	}

	local socket = uv.new_tcp()
	session.socket = socket

	socket:connect(host, port, function(err)
		if err then
			vim.schedule(function()
				session = nil
				callback("Failed to connect: " .. err)
			end)
			return
		end

		-- Start reading
		socket:read_start(function(read_err, data)
			if read_err then
				vim.schedule(function()
					vim.notify("mLua debugger: read error - " .. read_err, vim.log.levels.ERROR)
					M.disconnect()
				end)
				return
			end

			if data then
				if session then
					session.receiveBuffer = session.receiveBuffer .. data
					processReceiveBuffer()
				end
			else
				-- Connection closed
				vim.schedule(function()
					M.disconnect()
				end)
			end
		end)

		-- Start heartbeat and timeout timers
		startHeartbeat()
		resetReceiveTimeout()

		vim.schedule(function()
			callback(nil)
		end)
	end)
end

---Set event handler for DAP events
---@param handler function
function M.setEventHandler(handler)
	if session then
		session.onEvent = handler
	end
end

---Disconnect the debug session
function M.disconnect()
	if not session then
		return
	end

	local sess = session
	session = nil

	stopTimers()

	if sess.socket then
		sess.socket:read_stop()
		if not sess.socket:is_closing() then
			sess.socket:shutdown(function()
				if sess.socket and not sess.socket:is_closing() then
					sess.socket:close()
				end
			end)
		end
	end

	sess.running = false

	vim.schedule(function()
		if sess.onEvent then
			sess.onEvent("terminated")
		end
	end)
end

---Check if session is active
---@return boolean
function M.isConnected()
	return session ~= nil and session.socket ~= nil
end

---Get current stack trace
---@param startFrame number|nil
---@param maxLevels number|nil
---@return table
function M.getStackTrace(startFrame, maxLevels)
	if not session or not session.currentStack then
		return { stackFrames = {}, totalFrames = 0 }
	end

	startFrame = startFrame or 0
	maxLevels = maxLevels or 1000
	local endFrame = startFrame + maxLevels

	local frames = {}
	local allFrames = session.currentStack.frames

	for i = startFrame + 1, math.min(#allFrames, endFrame) do
		local frame = allFrames[i]
		table.insert(frames, {
			id = frame.id,
			name = frame.name,
			source = {
				name = vim.fn.fnamemodify(frame.filePath, ":t"),
				path = frame.filePath,
			},
			line = frame.line,
			column = 0,
		})
	end

	return {
		stackFrames = frames,
		totalFrames = #allFrames,
	}
end

---Set breakpoints for a file
---@param filePath string
---@param lines number[]
---@return table
function M.setBreakpoints(filePath, lines)
	if not session then
		return { breakpoints = {} }
	end

	-- If not connected yet, store as pending
	if not session.socket then
		session.pendingBreakpoints[filePath] = lines
	else
		send(protocol.createSetBreakpoints(filePath, lines))
	end

	-- Return verified breakpoints
	local result = {}
	for _, line in ipairs(lines) do
		table.insert(result, {
			verified = true,
			line = line,
		})
	end

	return { breakpoints = result }
end

---Continue execution
function M.continue()
	if not session then
		return
	end
	send(protocol.createContinue())
end

---Step over
function M.next()
	if not session then
		return
	end
	send(protocol.createStepOver())
end

---Step into
function M.stepIn()
	if not session then
		return
	end
	send(protocol.createStepInto())
end

---Step out
function M.stepOut()
	if not session then
		return
	end
	send(protocol.createStepOut())
end

---Get scopes for a stack frame
---@param frameId number
---@param callback function
function M.getScopes(frameId, callback)
	if not session or not session.socket then
		callback({ scopes = {} })
		return
	end

	session.currentStackFrameId = frameId

	local requestId = nextRequestId()
	session.pendingRequests[requestId] = function(response, messageType)
		if messageType == protocol.MessageType.FailureResponse then
			vim.notify("mLua debugger: scopes request failed - " .. (response.reason or "unknown"), vim.log.levels.WARN)
			callback({ scopes = {} })
			return
		end

		local scopes = {}
		for _, scope in ipairs(response.scopes) do
			-- Store variables in container
			session.variableContainers[scope.variablesReference] = {
				variables = scope.variables,
			}
			for _, var in ipairs(scope.variables) do
				session.variableContainers[var.variablesReference] = var
			end

			table.insert(scopes, {
				name = scope.name,
				variablesReference = scope.variablesReference,
				expensive = false,
			})
		end

		callback({ scopes = scopes })
	end

	send(protocol.createScopesRequest(requestId, frameId))
end

---Get variables for a reference
---@param variablesReference number
---@param callback function
function M.getVariables(variablesReference, callback)
	if not session or not session.socket then
		callback({ variables = {} })
		return
	end

	-- Check if we already have the variables cached
	local container = session.variableContainers[variablesReference]
	if container and container.variables then
		local variables = {}
		for _, var in ipairs(container.variables) do
			table.insert(variables, {
				name = var.name,
				value = var.value,
				type = var.type,
				variablesReference = var.variablesReference,
			})
		end
		callback({ variables = variables })
		return
	end

	-- Need to request from server
	local parentVariable = session.variableContainers[variablesReference]
	if not parentVariable then
		callback({ variables = {} })
		return
	end

	local requestId = nextRequestId()
	session.pendingRequests[requestId] = function(response, messageType)
		if messageType == protocol.MessageType.FailureResponse then
			vim.notify(
				"mLua debugger: variables request failed - " .. (response.reason or "unknown"),
				vim.log.levels.WARN
			)
			callback({ variables = {} })
			return
		end

		-- Cache the variables
		parentVariable.variables = response.variables
		for _, var in ipairs(response.variables) do
			session.variableContainers[var.variablesReference] = var
		end

		local variables = {}
		for _, var in ipairs(response.variables) do
			table.insert(variables, {
				name = var.name,
				value = var.value,
				type = var.type,
				variablesReference = var.variablesReference,
			})
		end

		callback({ variables = variables })
	end

	send(protocol.createVariablesRequest(requestId, session.currentStackFrameId, {
		name = parentVariable.name or "",
		variablesReference = parentVariable.variablesReference or variablesReference,
		type = parentVariable.type or "",
		value = parentVariable.value or "",
	}))
end

---Evaluate an expression
---@param expression string
---@param frameId number|nil
---@param context string|nil
---@param callback function
function M.evaluate(expression, frameId, context, callback)
	if not session or not session.socket then
		callback({ result = "", variablesReference = 0 })
		return
	end

	frameId = frameId or session.currentStackFrameId
	context = context or ""

	local requestId = nextRequestId()
	session.pendingRequests[requestId] = function(response, messageType)
		if messageType == protocol.MessageType.FailureResponse then
			callback({ result = "Error: " .. (response.reason or "unknown"), variablesReference = 0 })
			return
		end

		local variable = response.variable
		if variable then
			session.variableContainers[variable.variablesReference] = variable
			callback({
				result = variable.value,
				type = variable.type,
				variablesReference = variable.variablesReference,
			})
		else
			callback({ result = "", variablesReference = 0 })
		end
	end

	send(protocol.createEvaluateRequest(requestId, frameId, expression, 0, 0, context))
end

---Get current exec space
---@return string|nil
function M.getExecSpace()
	if not session or not session.currentStack then
		return nil
	end
	return session.currentStack.execSpace
end

return M
