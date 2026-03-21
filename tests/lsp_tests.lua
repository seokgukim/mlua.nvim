-- tests/lsp_tests.lua
-- Integration tests: start the actual LSP server, attach it to TestScript.mlua,
-- and verify real responses for diagnostics, hover, go-to-def, references, rename.
--
-- Run with:
--   nvim --headless -u NORC -l tests/lsp_tests.lua

vim.opt.rtp:prepend(".")

local PLUGIN_ROOT  = vim.fn.fnamemodify(".", ":p")
local TESTSCRIPT   = PLUGIN_ROOT .. "tests/TestScript.mlua"
local WRAPPER      = PLUGIN_ROOT .. "javascript/mlua-server.js"

local failed = 0

local function pass(name) print("PASS: " .. name) end
local function fail(name, msg)
  failed = failed + 1
  print("FAIL: " .. name .. " — " .. tostring(msg))
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass(name) else fail(name, err) end
end

-- Find the first 1-based line matching a Lua pattern
local function find_line(bufnr, pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match(pattern) then return i end
  end
  return nil
end

-- 0-based LSP position from 1-based vim line/col
local function lsp_pos(line1, col1) return { line = line1 - 1, character = col1 - 1 } end

-- ---------------------------------------------------------------------------
-- 1. Open buffer and start LSP
-- ---------------------------------------------------------------------------

local bufnr = vim.fn.bufadd(TESTSCRIPT)
vim.fn.bufload(bufnr)
vim.api.nvim_set_option_value("filetype", "mlua", { buf = bufnr })
vim.api.nvim_set_current_buf(bufnr)

local refresh_received = false

local client_id = vim.lsp.start({
  name  = "mlua",
  cmd   = { "node", WRAPPER, "--stdio" },
  root_dir = PLUGIN_ROOT,
  handlers = {
    ["workspace/diagnostic/refresh"] = function(_, _, _)
      refresh_received = true
    end,
  },
})

-- Wait for the client to initialise
print("Waiting for LSP to initialise...")
local init_ok = vim.wait(10000, function()
  local c = vim.lsp.get_client_by_id(client_id)
  return c ~= nil and c.initialized == true
end, 100)

if not init_ok then
  print("FATAL: LSP did not initialise within 10s")
  vim.cmd("cquit 1")
end

local client = vim.lsp.get_client_by_id(client_id)
print("LSP initialised (id=" .. client_id .. ")\n")

-- ---------------------------------------------------------------------------
-- Helper: pull diagnostics synchronously (returns items list or nil on timeout)
-- ---------------------------------------------------------------------------
local function pull_diagnostics()
  local result, done = nil, false
  client:request("textDocument/diagnostic", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, function(_, res)
    result = res
    done = true
  end, bufnr)
  vim.wait(10000, function() return done end, 100)
  if result and result.kind == "full" then return result.items end
  return nil
end

-- ---------------------------------------------------------------------------
-- Suite 8: Diagnostics
-- Wait for workspace/diagnostic/refresh (server signals it's ready),
-- then wait 3 s for the proxy cache to populate, then pull.
-- ---------------------------------------------------------------------------

print("--- Suite 8: Diagnostics ---")

print("Waiting for workspace/diagnostic/refresh...")
local refresh_ok = vim.wait(30000, function() return refresh_received end, 100)

if not refresh_ok then
  fail("diagnostics: workspace/diagnostic/refresh", "never received within 30s")
else
  -- Give proxy 3 s to fill its cache from the server's diagnostic response
  vim.wait(3000)
  local items = pull_diagnostics()

  test("diagnostics: server returns items after refresh", function()
    assert(items ~= nil, "pull_diagnostics timed out or returned nil")
    assert(#items > 0, "expected at least one diagnostic, got 0")
  end)

  -- Build a lookup: 0-based line → list of diagnostics
  local by_line = {}
  for _, d in ipairs(items or {}) do
    local ln = d.range.start.line
    by_line[ln] = by_line[ln] or {}
    table.insert(by_line[ln], d)
  end

  -- 2-1: _NonExistentService → error on that line
  test("2-1: undefined global (_NonExistentService) has a diagnostic", function()
    local ln = find_line(bufnr, "_NonExistentService:DoSomething")
    assert(ln, "_NonExistentService line not found in file")
    assert(by_line[ln - 1] and #by_line[ln - 1] > 0,
      "no diagnostic on line " .. ln .. " (0-based " .. ln-1 .. ")")
  end)

  -- 2-2: Vector3(1, 2) → wrong arity
  test("2-2: wrong-arity Vector3 call has a diagnostic", function()
    local ln = find_line(bufnr, "Vector3%(1, 2%)")
    assert(ln, "Vector3(1, 2) line not found")
    assert(by_line[ln - 1] and #by_line[ln - 1] > 0,
      "no diagnostic on line " .. ln)
  end)

  -- 2-4: type mismatch (string → number)
  test("2-4: type mismatch has a diagnostic", function()
    local ln = find_line(bufnr, '"not a number"')
    assert(ln, "'not a number' line not found")
    assert(by_line[ln - 1] and #by_line[ln - 1] > 0,
      "no diagnostic on line " .. ln)
  end)

  -- 1-1: valid property line must be clean
  test("1-1: valid property declaration has no diagnostic", function()
    local ln = find_line(bufnr, "^%s*property string name")
    assert(ln, "property string name line not found")
    assert(not (by_line[ln - 1] and #by_line[ln - 1] > 0),
      "unexpected diagnostic on valid property line " .. ln)
  end)
end

-- ---------------------------------------------------------------------------
-- Suite 9: Hover
-- ---------------------------------------------------------------------------

print("\n--- Suite 9: Hover ---")

local function do_hover(line1, col1)
  local result, done = nil, false
  client:request("textDocument/hover", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = lsp_pos(line1, col1),
  }, function(_, res) result = res; done = true end, bufnr)
  vim.wait(8000, function() return done end, 100)
  return result
end

test("hover on GetCount returns content", function()
  local ln = find_line(bufnr, "^%s*method number GetCount%(%)$")
  assert(ln, "GetCount definition line not found")
  local r = do_hover(ln, 16)
  assert(r, "hover returned nil")
  local content = type(r.contents) == "string" and r.contents
    or (type(r.contents) == "table" and (r.contents.value or vim.inspect(r.contents)))
    or ""
  assert(content ~= "", "hover content is empty")
end)

test("hover on _EntityService returns content", function()
  local ln = find_line(bufnr, "_EntityService:GetEntityByPath")
  assert(ln, "_EntityService line not found")
  local r = do_hover(ln, 10)
  assert(r, "hover returned nil for _EntityService")
  local content = type(r.contents) == "string" and r.contents
    or (type(r.contents) == "table" and (r.contents.value or vim.inspect(r.contents)))
    or ""
  assert(content ~= "", "hover content is empty for _EntityService")
end)

-- ---------------------------------------------------------------------------
-- Suite 10: Go to definition
-- ---------------------------------------------------------------------------

print("\n--- Suite 10: Go to definition ---")

local function do_definition(line1, col1)
  local result, done = nil, false
  client:request("textDocument/definition", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = lsp_pos(line1, col1),
  }, function(_, res) result = res; done = true end, bufnr)
  vim.wait(8000, function() return done end, 100)
  return result
end

test("go-to-def on self:Reset() resolves to Reset definition", function()
  -- call site: line containing `self:Reset()` but not in a comment
  local call_ln  = find_line(bufnr, "^%s*self:Reset%(%)$")
  local def_ln   = find_line(bufnr, "^%s*method void Reset%(%)$")
  assert(call_ln, "self:Reset() call line not found")
  assert(def_ln,  "method void Reset() definition line not found")

  local locs = do_definition(call_ln, 8)
  assert(locs, "definition returned nil")
  local list = vim.islist(locs) and locs or { locs }
  assert(#list > 0, "definition returned empty list")
  local got = (list[1].range or list[1].targetSelectionRange).start.line + 1
  assert(got == def_ln,
    string.format("expected line %d, got %d", def_ln, got))
end)

test("go-to-def on self:GetCount() resolves to GetCount definition", function()
  -- call site: the actual code line, not the comment above it
  local call_ln = find_line(bufnr, "^%s*local current = self:GetCount%(%)$")
  local def_ln  = find_line(bufnr, "^%s*method number GetCount%(%)$")
  assert(call_ln, "local current = self:GetCount() line not found")
  assert(def_ln,  "method number GetCount() definition line not found")

  local locs = do_definition(call_ln, 24)  -- col on "GetCount"
  assert(locs, "definition returned nil")
  local list = vim.islist(locs) and locs or { locs }
  assert(#list > 0, "definition returned empty list")
  local got = (list[1].range or list[1].targetSelectionRange).start.line + 1
  assert(got == def_ln,
    string.format("expected line %d, got %d", def_ln, got))
end)

-- ---------------------------------------------------------------------------
-- Suite 11: Find references
-- ---------------------------------------------------------------------------

print("\n--- Suite 11: Find references ---")

test("references on sharedCount finds >= 3 locations", function()
  local prop_ln = find_line(bufnr, "^%s*property number sharedCount")
  assert(prop_ln, "sharedCount property line not found")

  local result, done = nil, false
  client:request("textDocument/references", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = lsp_pos(prop_ln, 21),
    context  = { includeDeclaration = true },
  }, function(_, res) result = res; done = true end, bufnr)
  vim.wait(8000, function() return done end, 100)

  assert(result, "references returned nil")
  assert(#result >= 3,
    "expected >= 3 references, got " .. #result)
end)

-- ---------------------------------------------------------------------------
-- Suite 12: Rename
-- ---------------------------------------------------------------------------

print("\n--- Suite 12: Rename ---")

test("rename sharedCount returns WorkspaceEdit with >= 3 edits", function()
  local prop_ln = find_line(bufnr, "^%s*property number sharedCount")
  assert(prop_ln, "sharedCount property line not found")

  local result, done = nil, false
  client:request("textDocument/rename", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = lsp_pos(prop_ln, 21),
    newName  = "renamedCount",
  }, function(_, res) result = res; done = true end, bufnr)
  vim.wait(8000, function() return done end, 100)

  assert(result, "rename returned nil")
  local total = 0
  if result.changes then
    for _, edits in pairs(result.changes) do total = total + #edits end
  elseif result.documentChanges then
    for _, dc in ipairs(result.documentChanges) do
      if dc.edits then total = total + #dc.edits end
    end
  end
  assert(total >= 3, "expected >= 3 rename edits, got " .. total)
end)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print(string.format("\n--- Results: %d failed ---", failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  print("All LSP tests passed!")
  vim.cmd("quit")
end
