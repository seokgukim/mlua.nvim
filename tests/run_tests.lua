local function assert(cond, msg)
  if not cond then error(msg or "Assertion failed") end
end

-- Add current directory to runtime path
vim.opt.rtp:prepend(".")

print("Running tests...")

-- Test 1: Require
local ok, mlua = pcall(require, "mlua")
assert(ok, "Could not require mlua: " .. tostring(mlua))
print("PASS: require('mlua')")

-- Test 2: Setup
local ok_setup, err = pcall(mlua.setup, {})
assert(ok_setup, "setup() failed: " .. tostring(err))
print("PASS: mlua.setup()")

-- Test 3: Commands
assert(vim.fn.exists(":MluaInstall") == 2, ":MluaInstall command missing")
print("PASS: Commands registered")

print("All tests passed!")
