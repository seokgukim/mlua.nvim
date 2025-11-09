-- Predefines loader (modules, globalVariables, globalFunctions)
local utils = require('mlua.utils')

local M = {}

local predefines_cache = {}

function M.load_predefines(installed_dir)
  if not installed_dir or installed_dir == '' then
    return nil
  end

  local cached = predefines_cache[installed_dir]
  if cached then
    return cached
  end

  local cache_file = utils.build_cache_path(installed_dir, "predefines.json")
  if cache_file and vim.fn.filereadable(cache_file) == 1 then
    local payload = utils.read_text_file(cache_file)
    if payload then
      local decoded = utils.json_decode(payload)
      if decoded then
        predefines_cache[installed_dir] = decoded
        return decoded
      end
    end
  end

  -- Try to generate predefines if cache doesn't exist
  local predefines_dir = vim.fn.fnamemodify(installed_dir .. "/extension/scripts/predefines", ':p')
  if vim.fn.isdirectory(predefines_dir) == 0 then
    vim.notify("Predefines directory not found", vim.log.levels.WARN)
    return nil
  end

  local predefines_index = vim.fn.fnamemodify(predefines_dir .. "/out/index.js", ':p')
  if vim.fn.filereadable(predefines_index) == 0 then
    vim.notify("Predefines index.js not found", vim.log.levels.WARN)
    return nil
  end

  local node_predefines_index = utils.normalize_for_node(predefines_index)

  local script = table.concat({
    "const predefines = require('" .. node_predefines_index:gsub("\\", "\\\\") .. "');",
    "const result = {",
    "  modules: predefines.modules || [],",
    "  globalVariables: predefines.globalVariables || [],",
    "  globalFunctions: predefines.globalFunctions || []",
    "};",
    "process.stdout.write(JSON.stringify(result));",
  }, '\n')

  local output = vim.fn.system({ "node", "-e", script })
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to load predefines: " .. (output or "unknown error"), vim.log.levels.WARN)
    return nil
  end

  local decoded = utils.json_decode(output)
  if not decoded then
    vim.notify("Failed to parse predefines JSON", vim.log.levels.WARN)
    return nil
  end

  predefines_cache[installed_dir] = decoded

  -- Try to write to cache file for next time
  if cache_file then
    local encoded = utils.json_encode(decoded)
    if encoded then
      utils.write_text_file(cache_file, encoded)
    end
  end

  return decoded
end

return M
