-- MSW Debug Protocol implementation
-- Binary protocol for communicating with the MSW debugger server

local M = {}

---@enum MessageType
M.MessageType = {
	None = 0,
	Heartbeat = 1,
	AcceptConnection = 2,
	DenyConnection = 3,
	UpdateCallStack = 4,
	SetBreakpoints = 5,
	Continue = 6,
	StepOver = 7,
	StepInto = 8,
	StepOut = 9,
	FailureResponse = 10,
	ScopesRequest = 11,
	ScopesResponse = 12,
	VariablesRequest = 13,
	VariablesResponse = 14,
	EvaluateRequest = 15,
	EvaluateResponse = 16,
}

-- Message header size: 1 byte (type) + 4 bytes (length)
M.HEADER_SIZE = 5

---@class MessageHeader
---@field messageType number
---@field totalLength number

---@class StackFrame
---@field id number
---@field filePath string
---@field name string
---@field line number

---@class Breakpoint
---@field line number

---@class Variable
---@field name string
---@field variablesReference number
---@field type string
---@field value string

---@class Scope
---@field name string
---@field variablesReference number
---@field variables Variable[]

-- Binary buffer utilities
local Buffer = {}

---Create a new buffer for writing
---@param size number
---@return table
function Buffer.new(size)
	return {
		data = string.rep("\0", size),
		offset = 0,
		size = size,
	}
end

---Create a buffer from existing data for reading
---@param data string
---@return table
function Buffer.fromData(data)
	return {
		data = data,
		offset = 0,
		size = #data,
	}
end

---Write int8 to buffer
---@param buf table
---@param value number
function Buffer.writeInt8(buf, value)
	local byte = string.char(value % 256)
	buf.data = buf.data:sub(1, buf.offset) .. byte .. buf.data:sub(buf.offset + 2)
	buf.offset = buf.offset + 1
end

---Write int32 little-endian to buffer
---@param buf table
---@param value number
function Buffer.writeInt32LE(buf, value)
	local b1 = value % 256
	local b2 = math.floor(value / 256) % 256
	local b3 = math.floor(value / 65536) % 256
	local b4 = math.floor(value / 16777216) % 256
	local bytes = string.char(b1, b2, b3, b4)
	buf.data = buf.data:sub(1, buf.offset) .. bytes .. buf.data:sub(buf.offset + 5)
	buf.offset = buf.offset + 4
end

---Write UTF-8 string to buffer
---@param buf table
---@param str string
function Buffer.writeString(buf, str)
	buf.data = buf.data:sub(1, buf.offset) .. str .. buf.data:sub(buf.offset + #str + 1)
	buf.offset = buf.offset + #str
end

---Read int8 from buffer
---@param buf table
---@return number
function Buffer.readInt8(buf)
	local value = buf.data:byte(buf.offset + 1)
	buf.offset = buf.offset + 1
	return value
end

---Read int32 little-endian from buffer
---@param buf table
---@return number
function Buffer.readInt32LE(buf)
	local b1 = buf.data:byte(buf.offset + 1)
	local b2 = buf.data:byte(buf.offset + 2)
	local b3 = buf.data:byte(buf.offset + 3)
	local b4 = buf.data:byte(buf.offset + 4)
	buf.offset = buf.offset + 4
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

---Read UTF-8 string from buffer
---@param buf table
---@param length number
---@return string
function Buffer.readString(buf, length)
	local str = buf.data:sub(buf.offset + 1, buf.offset + length)
	buf.offset = buf.offset + length
	return str
end

-- Message serialization

---Serialize message header
---@param messageType number
---@param totalLength number
---@return string
local function serializeHeader(messageType, totalLength)
	local buf = Buffer.new(M.HEADER_SIZE)
	Buffer.writeInt8(buf, messageType)
	Buffer.writeInt32LE(buf, totalLength)
	return buf.data
end

---Deserialize message header
---@param data string
---@return MessageHeader|nil
function M.deserializeHeader(data)
	if #data < M.HEADER_SIZE then
		return nil
	end
	local buf = Buffer.fromData(data)
	return {
		messageType = Buffer.readInt8(buf),
		totalLength = Buffer.readInt32LE(buf),
	}
end

---Create Heartbeat message
---@return string
function M.createHeartbeat()
	return serializeHeader(M.MessageType.Heartbeat, M.HEADER_SIZE)
end

---Create Continue message
---@return string
function M.createContinue()
	return serializeHeader(M.MessageType.Continue, M.HEADER_SIZE)
end

---Create StepOver message
---@return string
function M.createStepOver()
	return serializeHeader(M.MessageType.StepOver, M.HEADER_SIZE)
end

---Create StepInto message
---@return string
function M.createStepInto()
	return serializeHeader(M.MessageType.StepInto, M.HEADER_SIZE)
end

---Create StepOut message
---@return string
function M.createStepOut()
	return serializeHeader(M.MessageType.StepOut, M.HEADER_SIZE)
end

---Create SetBreakpoints message
---@param filePath string
---@param lines number[]
---@return string
function M.createSetBreakpoints(filePath, lines)
	local filePathBytes = filePath
	local filePathLength = #filePathBytes

	-- Calculate total length
	local totalLength = M.HEADER_SIZE -- header
		+ 4 -- filePathLength
		+ filePathLength -- filePath
		+ 4 -- breakpointCount
		+ (#lines * 4) -- breakpoints (each is 4 bytes for line number)

	local buf = Buffer.new(totalLength)
	Buffer.writeInt8(buf, M.MessageType.SetBreakpoints)
	Buffer.writeInt32LE(buf, totalLength)
	Buffer.writeInt32LE(buf, filePathLength)
	Buffer.writeString(buf, filePathBytes)
	Buffer.writeInt32LE(buf, #lines)
	for _, line in ipairs(lines) do
		Buffer.writeInt32LE(buf, line)
	end

	return buf.data
end

---Create ScopesRequest message
---@param requestId number
---@param stackFrameId number
---@return string
function M.createScopesRequest(requestId, stackFrameId)
	local totalLength = M.HEADER_SIZE + 4 + 4 -- header + requestId + stackFrameId

	local buf = Buffer.new(totalLength)
	Buffer.writeInt8(buf, M.MessageType.ScopesRequest)
	Buffer.writeInt32LE(buf, totalLength)
	Buffer.writeInt32LE(buf, requestId)
	Buffer.writeInt32LE(buf, stackFrameId)

	return buf.data
end

---Serialize a Variable for sending
---@param variable Variable
---@return string
local function serializeVariable(variable)
	local nameBytes = variable.name
	local typeBytes = variable.type
	local valueBytes = variable.value

	local size = 4 + #nameBytes + 4 + 4 + #typeBytes + 4 + #valueBytes
	local buf = Buffer.new(size)

	Buffer.writeInt32LE(buf, #nameBytes)
	Buffer.writeString(buf, nameBytes)
	Buffer.writeInt32LE(buf, variable.variablesReference)
	Buffer.writeInt32LE(buf, #typeBytes)
	Buffer.writeString(buf, typeBytes)
	Buffer.writeInt32LE(buf, #valueBytes)
	Buffer.writeString(buf, valueBytes)

	return buf.data
end

---Create VariablesRequest message
---@param requestId number
---@param stackFrameId number
---@param variable Variable
---@return string
function M.createVariablesRequest(requestId, stackFrameId, variable)
	local variableData = serializeVariable(variable)
	local totalLength = M.HEADER_SIZE + 4 + 4 + #variableData

	local buf = Buffer.new(totalLength)
	Buffer.writeInt8(buf, M.MessageType.VariablesRequest)
	Buffer.writeInt32LE(buf, totalLength)
	Buffer.writeInt32LE(buf, requestId)
	Buffer.writeInt32LE(buf, stackFrameId)
	Buffer.writeString(buf, variableData)

	return buf.data
end

---Create EvaluateRequest message
---@param requestId number
---@param stackFrameId number
---@param expression string
---@param line number
---@param col number
---@param context string
---@return string
function M.createEvaluateRequest(requestId, stackFrameId, expression, line, col, context)
	local expressionBytes = expression
	local contextBytes = context or ""

	local totalLength = M.HEADER_SIZE
		+ 4 -- requestId
		+ 4 -- stackFrameId
		+ 4 -- expressionLength
		+ #expressionBytes -- expression
		+ 4 -- line
		+ 4 -- col
		+ 4 -- contextLength
		+ #contextBytes -- context

	local buf = Buffer.new(totalLength)
	Buffer.writeInt8(buf, M.MessageType.EvaluateRequest)
	Buffer.writeInt32LE(buf, totalLength)
	Buffer.writeInt32LE(buf, requestId)
	Buffer.writeInt32LE(buf, stackFrameId)
	Buffer.writeInt32LE(buf, #expressionBytes)
	Buffer.writeString(buf, expressionBytes)
	Buffer.writeInt32LE(buf, line or 0)
	Buffer.writeInt32LE(buf, col or 0)
	Buffer.writeInt32LE(buf, #contextBytes)
	Buffer.writeString(buf, contextBytes)

	return buf.data
end

-- Message deserialization

---Deserialize a Variable from buffer
---@param buf table
---@return Variable
local function deserializeVariable(buf)
	local nameLength = Buffer.readInt32LE(buf)
	local name = Buffer.readString(buf, nameLength)
	local variablesReference = Buffer.readInt32LE(buf)
	local typeLength = Buffer.readInt32LE(buf)
	local type = Buffer.readString(buf, typeLength)
	local valueLength = Buffer.readInt32LE(buf)
	local value = Buffer.readString(buf, valueLength)

	return {
		name = name,
		variablesReference = variablesReference,
		type = type,
		value = value,
	}
end

---Deserialize a StackFrame from buffer
---@param buf table
---@return StackFrame
local function deserializeStackFrame(buf)
	local fileLength = Buffer.readInt32LE(buf)
	local filePath = Buffer.readString(buf, fileLength)
	local id = Buffer.readInt32LE(buf)
	local nameLength = Buffer.readInt32LE(buf)
	local name = Buffer.readString(buf, nameLength)
	local line = Buffer.readInt32LE(buf)

	return {
		id = id,
		filePath = filePath,
		name = name,
		line = line,
	}
end

---Deserialize UpdateCallStack message payload
---@param data string
---@return table
function M.deserializeUpdateCallStack(data)
	local buf = Buffer.fromData(data)

	local execSpaceLength = Buffer.readInt32LE(buf)
	local execSpace = Buffer.readString(buf, execSpaceLength)
	local stackFrameCount = Buffer.readInt32LE(buf)
	local stackFrames = {}

	for _ = 1, stackFrameCount do
		table.insert(stackFrames, deserializeStackFrame(buf))
	end

	return {
		execSpace = execSpace,
		stackFrames = stackFrames,
	}
end

---Deserialize FailureResponse message payload
---@param data string
---@return table
function M.deserializeFailureResponse(data)
	local buf = Buffer.fromData(data)

	local requestId = Buffer.readInt32LE(buf)
	local reasonLength = Buffer.readInt32LE(buf)
	local reason = Buffer.readString(buf, reasonLength)

	return {
		requestId = requestId,
		reason = reason,
	}
end

---Deserialize ScopesResponse message payload
---@param data string
---@return table
function M.deserializeScopesResponse(data)
	local buf = Buffer.fromData(data)

	local requestId = Buffer.readInt32LE(buf)
	local scopeCount = Buffer.readInt32LE(buf)
	local scopes = {}

	for _ = 1, scopeCount do
		local nameLength = Buffer.readInt32LE(buf)
		local name = Buffer.readString(buf, nameLength)
		local variablesReference = Buffer.readInt32LE(buf)
		local variableCount = Buffer.readInt32LE(buf)
		local variables = {}

		for _ = 1, variableCount do
			table.insert(variables, deserializeVariable(buf))
		end

		table.insert(scopes, {
			name = name,
			variablesReference = variablesReference,
			variables = variables,
		})
	end

	return {
		requestId = requestId,
		scopes = scopes,
	}
end

---Deserialize VariablesResponse message payload
---@param data string
---@return table
function M.deserializeVariablesResponse(data)
	local buf = Buffer.fromData(data)

	local requestId = Buffer.readInt32LE(buf)
	local variableCount = Buffer.readInt32LE(buf)
	local variables = {}

	for _ = 1, variableCount do
		table.insert(variables, deserializeVariable(buf))
	end

	return {
		requestId = requestId,
		variables = variables,
	}
end

---Deserialize EvaluateResponse message payload
---@param data string
---@return table
function M.deserializeEvaluateResponse(data)
	local buf = Buffer.fromData(data)

	local requestId = Buffer.readInt32LE(buf)
	local variable = deserializeVariable(buf)

	return {
		requestId = requestId,
		variable = variable,
	}
end

---Check if message type is an acknowledgement type
---@param messageType number
---@return boolean
function M.isAckType(messageType)
	return messageType == M.MessageType.FailureResponse
		or messageType == M.MessageType.ScopesResponse
		or messageType == M.MessageType.VariablesResponse
		or messageType == M.MessageType.EvaluateResponse
end

return M
