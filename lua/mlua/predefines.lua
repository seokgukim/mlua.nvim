
-- Predefines loader (modules, globalVariables, globalFunctions) with compression
local utils = require('mlua.utils')

local M = {}

local predefines_cache = {}

-- Simple compression: remove whitespace from JSON
local function compress_json(json_str)
  if not json_str then return nil end
  
  -- Remove unnecessary whitespace while preserving strings
  local in_string = false
  local escape = false
  local result = {}
  
  for i = 1, #json_str do
    local char = json_str:sub(i, i)
    
    if escape then
      table.insert(result, char)
      escape = false
    elseif char == '\\' and in_string then
      table.insert(result, char)
      escape = true
    elseif char == '"' then
      table.insert(result, char)
      in_string = not in_string
    elseif in_string then
      table.insert(result, char)
    elseif char ~= ' ' and char ~= '\n' and char ~= '\t' and char ~= '\r' then
      table.insert(result, char)
    end
  end
  
  return table.concat(result)
end

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
  -- Use proper path joining to handle Windows path separators correctly
  local predefines_dir
  if vim.fs and vim.fs.joinpath then
    predefines_dir = vim.fs.joinpath(installed_dir, "extension", "scripts", "predefines")
    predefines_dir = vim.fn.fnamemodify(predefines_dir, ':p')
  else
    -- Fallback for older Neovim versions
    predefines_dir = vim.fn.fnamemodify(installed_dir .. "/extension/scripts/predefines", ':p')
  end
  
  if vim.fn.isdirectory(predefines_dir) == 0 then
    vim.notify("Predefines directory not found: " .. predefines_dir, vim.log.levels.WARN)
    return nil
  end

  -- Build the index.js path using proper path joining
  local predefines_index
  if vim.fs and vim.fs.joinpath then
    predefines_index = vim.fs.joinpath(predefines_dir, "out", "index.js")
  else
    -- Fallback: ensure we handle path separators correctly on Windows
    predefines_dir = predefines_dir:gsub('\\', '/')
    predefines_index = predefines_dir .. "/out/index.js"
  end
  
  predefines_index = vim.fn.fnamemodify(predefines_index, ':p')
  
  if vim.fn.filereadable(predefines_index) == 0 then
    vim.notify("Predefines index.js not found: " .. predefines_index, vim.log.levels.WARN)
    return nil
  end

  local node_predefines_index = utils.normalize_for_node(predefines_index)

  -- For Node.js require(), use forward slashes (Windows-compatible)
  local escaped_path = node_predefines_index:gsub('\\', '/')
  
  -- IMPORTANT: The index.js exports { Predefines } where Predefines has static methods
  -- We need to call those methods to get the data:
  -- - Predefines.modules() → returns array of modules
  -- - Predefines.globalVariables() → returns array of global variables
  -- - Predefines.globalFunctions() → returns array of global functions
  local script = table.concat({
    "const m = require('" .. escaped_path:gsub("'", "\\'") .. "');",
    "const P = m.Predefines;",
    "const result = {",
    "  modules: P.modules ? P.modules() : [],",
    "  globalVariables: P.globalVariables ? P.globalVariables() : [],",
    "  globalFunctions: P.globalFunctions ? P.globalFunctions() : []",
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

  -- Try to write to cache file for next time (compressed)
  if cache_file then
    local encoded = utils.json_encode(decoded)
    if encoded then
      local compressed = compress_json(encoded)
      if compressed then
        utils.write_text_file(cache_file, compressed)
      end
    end
  end

  return decoded
end

return M
