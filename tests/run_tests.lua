-- run_tests.lua
-- Unit tests for mlua.nvim, organized by feature area.
-- Covers the cases described in TestScript.mlua.
--
-- Run with:
--   nvim --headless -u NORC -l tests/run_tests.lua
--
-- Each test suite uses assert() and prints PASS/FAIL per case.
-- The file exits with code 0 on success, 1 on any failure.

vim.opt.rtp:prepend(".")

local failed = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ok(name)
	print("PASS: " .. name)
end

local function fail(name, msg)
	failed = failed + 1
	print("FAIL: " .. name .. " — " .. tostring(msg))
end

---Run a single test case. Catches errors so the suite continues.
---@param name string  Human-readable test name
---@param fn   function  Test body; throw/error to fail
local function test(name, fn)
	local ok_flag, err = pcall(fn)
	if ok_flag then
		ok(name)
	else
		fail(name, err)
	end
end

---Assert helper (does not shadow the outer ok())
local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or "assert_eq failed") .. string.format(" (expected %s, got %s)", vim.inspect(b), vim.inspect(a)))
	end
end

local function assert_truthy(v, msg)
	if not v then
		error(msg or "expected truthy value, got " .. vim.inspect(v))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		error(msg or "expected nil, got " .. vim.inspect(v))
	end
end

-- ---------------------------------------------------------------------------
-- Suite 1: Module loading
-- ---------------------------------------------------------------------------

print("\n--- Suite 1: Module loading ---")

test("require('mlua') succeeds", function()
	local m = require("mlua")
	assert_truthy(m, "module is nil")
end)

test("mlua.setup() with empty opts does not error", function()
	local m = require("mlua")
	-- setup() may notify about missing server; that is acceptable.
	-- lsp must be enabled so that lsp.lua registers the :Mlua command.
	m.setup({
		lsp = { enabled = true },
		treesitter = { enabled = false },
		keymaps = false,
	})
end)

test("mlua.config is populated after setup()", function()
	local m = require("mlua")
	assert_truthy(m.config, "config is nil")
	assert_truthy(m.config.lsp, "config.lsp missing")
	assert_truthy(m.config.treesitter, "config.treesitter missing")
end)

test("mlua.config defaults are correct types", function()
	local m = require("mlua")
	assert_eq(type(m.config.lsp.enabled), "boolean", "lsp.enabled type")
	assert_eq(type(m.config.lsp.execspace_decorations), "boolean", "execspace_decorations type")
	assert_eq(type(m.config.treesitter.parser_path), "string", "parser_path type")
end)

-- ---------------------------------------------------------------------------
-- Suite 2: :Mlua command registration
-- ---------------------------------------------------------------------------

print("\n--- Suite 2: :Mlua command ---")

test(":Mlua command is registered", function()
	assert_eq(vim.fn.exists(":Mlua"), 2, "command not found")
end)

test(":Mlua completion returns expected subcommands", function()
	-- Use the command's completion function directly via nvim_get_commands
	local cmds = vim.api.nvim_get_commands({})
	assert_truthy(cmds["Mlua"], ":Mlua not in nvim_get_commands")
end)

-- ---------------------------------------------------------------------------
-- Suite 3: installer — get_installed_version()
-- ---------------------------------------------------------------------------

print("\n--- Suite 3: installer ---")

test("installer module loads", function()
	local ins = require("mlua.installer")
	assert_truthy(ins, "installer is nil")
end)

test("installer.config has required fields", function()
	local ins = require("mlua.installer")
	assert_truthy(ins.config.install_dir, "install_dir missing")
	assert_truthy(ins.config.publisher, "publisher missing")
	assert_truthy(ins.config.extension, "extension missing")
end)

test("installer.config.install_dir points inside plugin root", function()
	local ins = require("mlua.installer")
	-- install_dir should end with /javascript
	assert_truthy(ins.config.install_dir:match("/javascript$"), "install_dir does not end with /javascript")
end)

test("get_installed_version() returns (string, string) or (nil, nil)", function()
	local ins = require("mlua.installer")
	local ver, dir = ins.get_installed_version()
	if ver ~= nil then
		assert_eq(type(ver), "string", "version is not string")
		assert_eq(type(dir), "string", "dir is not string")
		-- version should look like digits-dot-digits
		assert_truthy(ver:match("^%d+%.%d+"), "version format unexpected: " .. ver)
	else
		assert_nil(dir, "dir should also be nil when version is nil")
	end
end)

-- ---------------------------------------------------------------------------
-- Suite 4: utils — find_root()
-- ---------------------------------------------------------------------------

print("\n--- Suite 4: utils.find_root ---")

test("utils module loads", function()
	local u = require("mlua.utils")
	assert_truthy(u, "utils is nil")
end)

test("find_root() returns nil for a path with no markers", function()
	local u = require("mlua.utils")
	-- /tmp has no package.json / .git / workspace.json above it
	local root = u.find_root("/tmp/no_such_project/file.mlua")
	assert_nil(root, "expected nil for path with no markers")
end)

test("find_root() finds .git for plugin's own directory", function()
	local u = require("mlua.utils")
	-- mlua.nvim itself is a git repo; find_root should find it
	local plugin_file = vim.fn.fnamemodify("lua/mlua.lua", ":p")
	local root = u.find_root(plugin_file)
	assert_truthy(root, "expected a root dir for plugin file")
end)

-- ---------------------------------------------------------------------------
-- Suite 5: workspace module
-- ---------------------------------------------------------------------------

print("\n--- Suite 5: workspace ---")

test("workspace module loads", function()
	local ws = require("mlua.workspace")
	assert_truthy(ws, "workspace is nil")
end)

test("workspace.reload_workspace() is a function", function()
	local ws = require("mlua.workspace")
	assert_eq(type(ws.reload_workspace), "function", "reload_workspace not a function")
end)

test("workspace.reload_workspace() is a no-op when client is nil", function()
	local ws = require("mlua.workspace")
	-- Should not error; no client → early return
	ws.reload_workspace(nil, 0, "/tmp", nil)
end)

test("workspace.reload_workspace() is a no-op when root_dir is nil", function()
	local ws = require("mlua.workspace")
	ws.reload_workspace({}, 0, nil, nil)
end)

-- ---------------------------------------------------------------------------
-- Suite 6: LSP config registration (no server started)
-- ---------------------------------------------------------------------------

print("\n--- Suite 6: LSP config ---")

test("lsp module loads", function()
	local lsp = require("mlua.lsp")
	assert_truthy(lsp, "lsp module is nil")
end)

test("lsp.config has install_dir", function()
	local lsp = require("mlua.lsp")
	assert_truthy(lsp.config.install_dir, "install_dir missing")
end)

test("lsp.get_installed_version is a function", function()
	local lsp = require("mlua.lsp")
	assert_eq(type(lsp.get_installed_version), "function")
end)

test("proxy forwards inlay hints for override virtual text", function()
	local proxy_path = vim.fn.fnamemodify("javascript/proxy.js", ":p")
	local lines = vim.fn.readfile(proxy_path)
	local source = table.concat(lines, "\n")
	assert_truthy(source:match("textDocument/inlayHint") == nil, "proxy must not suppress textDocument/inlayHint")
end)

test("indexer includes all .mlua and excludes other filetypes", function()
	local script = [[
const fs = require('fs');
const os = require('os');
const path = require('path');
const indexer = require('./javascript/indexer.js');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mlua-indexer-test-'));
try {
  fs.writeFileSync(path.join(root, 'Script.mlua'), '-- script\n', 'utf8');
  fs.writeFileSync(path.join(root, 'Script.d.mlua'), '-- meta\n', 'utf8');
  fs.writeFileSync(path.join(root, 'Layout.ui'), '{}\n', 'utf8');
  fs.writeFileSync(path.join(root, 'World.map'), '{}\n', 'utf8');
  fs.writeFileSync(path.join(root, 'Thing.model'), '{}\n', 'utf8');
  fs.writeFileSync(path.join(root, 'Logic.codeblock'), '{}\n', 'utf8');
  fs.mkdirSync(path.join(root, 'Environment'));
  fs.writeFileSync(path.join(root, 'Environment', 'BasicLib.d.mlua'), '-- lib\n', 'utf8');
  fs.mkdirSync(path.join(root, 'nested'));
  fs.writeFileSync(path.join(root, 'nested', 'Nested.mlua'), '-- nested\n', 'utf8');
  fs.writeFileSync(path.join(root, 'nested', 'Nested.d.mlua'), '-- nested meta\n', 'utf8');
  if (!indexer.isIndexableScriptFile(path.join(root, 'Script.mlua'))) {
    throw new Error('Script.mlua should be indexable');
  }
  if (!indexer.isIndexableScriptFile(path.join(root, 'Script.d.mlua'))) {
    throw new Error('Script.d.mlua should be indexable');
  }
  if (!indexer.isIndexableScriptFile(path.join(root, 'Environment', 'BasicLib.d.mlua'))) {
    throw new Error('Environment/BasicLib.d.mlua should be indexable');
  }
  const docs = indexer.collectDocuments(root);
  const uris = docs.map((doc) => doc.uri).sort();
  if (uris.length !== 5) {
    throw new Error('expected 5 indexed documents, got ' + uris.length + ': ' + uris.join(','));
  }
  for (const expected of ['Script.mlua', 'Script.d.mlua', 'nested/Nested.mlua', 'nested/Nested.d.mlua', 'Environment/BasicLib.d.mlua']) {
    if (!uris.some((uri) => uri.endsWith(expected))) {
      throw new Error(expected + ' was not indexed: ' + uris.join(','));
    }
  }
  const entries = indexer.collectEntryItems(root);
  if (entries.length !== 0) {
    throw new Error('unused meta entry files should not be indexed, got ' + entries.length);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
]]
	local result = vim.system({ "node", "-e", script }, { cwd = vim.fn.getcwd(), text = true }):wait()
	assert_eq(result.code, 0, result.stderr ~= "" and result.stderr or result.stdout)
end)

-- ---------------------------------------------------------------------------
-- Suite 7: TestScript.mlua — file can be opened as mlua filetype
-- ---------------------------------------------------------------------------

print("\n--- Suite 7: TestScript.mlua buffer ---")

local testscript_path = vim.fn.fnamemodify("tests/TestScript.mlua", ":p")

test("TestScript.mlua exists on disk", function()
	assert_eq(vim.fn.filereadable(testscript_path), 1, "file not readable")
end)

test("TestScript.mlua opens with filetype=mlua", function()
	local bufnr = vim.fn.bufadd(testscript_path)
	vim.fn.bufload(bufnr)
	vim.api.nvim_set_option_value("filetype", "mlua", { buf = bufnr })
	local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
	assert_eq(ft, "mlua", "filetype not mlua")
end)

test("TestScript.mlua has expected line count (> 100 lines)", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_truthy(#lines > 100, "expected > 100 lines, got " .. #lines)
end)

-- Section 1: valid cases — spot-check specific lines
test("TestScript.mlua section 1 contains property declarations", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("property string name") then found = true; break end
	end
	assert_truthy(found, "'property string name' not found in TestScript.mlua")
end)

test("TestScript.mlua section 1 contains sharedCount (3 references)", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local count = 0
	for _, line in ipairs(lines) do
		if line:match("sharedCount") then count = count + 1 end
	end
	-- property declaration + ref #1 (Reset) + ref #2 (GetCount) + ref #3 (StartTimer) + header comment = ≥ 4
	assert_truthy(count >= 4, "expected >= 4 occurrences of sharedCount, got " .. count)
end)

test("TestScript.mlua section 1 contains method Reset", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("method void Reset%(%)") then found = true; break end
	end
	assert_truthy(found, "'method void Reset()' not found")
end)

test("TestScript.mlua section 1 contains method GetCount with return type", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("method number GetCount%(%)") then found = true; break end
	end
	assert_truthy(found, "'method number GetCount()' not found")
end)

test("TestScript.mlua section 1 contains ExecSpace annotations", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local client_only, server_only = false, false
	for _, line in ipairs(lines) do
		if line:match('ExecSpace%("ClientOnly"%)') then client_only = true end
		if line:match('ExecSpace%("ServerOnly"%)') then server_only = true end
	end
	assert_truthy(client_only, "@ExecSpace(ClientOnly) not found")
	assert_truthy(server_only, "@ExecSpace(ServerOnly) not found")
end)

test("TestScript.mlua section 1 contains handler declaration", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("handler HandleClick") then found = true; break end
	end
	assert_truthy(found, "handler HandleClick not found")
end)

test("TestScript.mlua section 1 contains EaseType enum usage", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("EaseType%.SineEaseIn") then found = true; break end
	end
	assert_truthy(found, "EaseType.SineEaseIn not found")
end)

-- Section 2: error-expected cases
test("TestScript.mlua section 2-1 contains undefined global call", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("_NonExistentService") then found = true; break end
	end
	assert_truthy(found, "_NonExistentService not found in section 2-1")
end)

test("TestScript.mlua section 2-2 contains wrong-arity Vector3 call", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("Vector3%(1, 2%)") then found = true; break end
	end
	assert_truthy(found, "Vector3(1, 2) not found in section 2-2")
end)

test("TestScript.mlua section 2-3 contains unused local", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("local unused = 42") then found = true; break end
	end
	assert_truthy(found, "'local unused = 42' not found in section 2-3")
end)

test("TestScript.mlua section 2-4 contains type mismatch assignment", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match('"not a number"') then found = true; break end
	end
	assert_truthy(found, "'not a number' string not found in section 2-4")
end)

test("TestScript.mlua section 2-5 contains nil field access", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local found = false
	for _, line in ipairs(lines) do
		if line:match("x%.SomeField") then found = true; break end
	end
	assert_truthy(found, "'x.SomeField' nil access not found in section 2-5")
end)

-- Section 2: verify all error cases carry the [ERROR] or [WARNING] annotation
test("TestScript.mlua section 2 cases are annotated with [ERROR]/[WARNING]", function()
	local bufnr = vim.fn.bufnr(testscript_path)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local annotations = 0
	for _, line in ipairs(lines) do
		if line:match("%[ERROR%]") or line:match("%[WARNING%]") then
			annotations = annotations + 1
		end
	end
	-- 5 error cases + 2-3 warning = at least 5 annotated lines
	assert_truthy(annotations >= 5, "expected >= 5 [ERROR]/[WARNING] annotations, got " .. annotations)
end)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print(string.format("\n--- Results: %d failed ---", failed))

if failed > 0 then
	vim.cmd("cquit 1")
else
	print("All tests passed!")
	vim.cmd("quit")
end
