local uv = vim.loop or vim.uv

local M = {}

local node_platform_cache

function M.trim(value)
  if type(value) ~= "string" then
    return value
  end

  if vim.trim then
    return vim.trim(value)
  end

  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.detect_node_platform()
  if node_platform_cache then
    return node_platform_cache
  end

  local output = vim.fn.system({ "node", "-p", "process.platform" })
  if vim.v.shell_error ~= 0 then
    node_platform_cache = "unknown"
  else
    node_platform_cache = M.trim(output)
  end

  return node_platform_cache
end

-- Normalize path for cross-platform compatibility
function M.normalize_path(path)
  if not path or path == '' then
    return path
  end
  
  -- Check if already absolute (Windows: C:/ or C:\ or UNC; Unix: starts with /)
  local is_absolute = path:match("^[A-Za-z]:[/\\]") or path:match("^/") or path:match("^\\\\")
  
  local absolute
  if is_absolute then
    -- Already absolute, use it directly (don't expand, it can add extensions)
    absolute = path
  else
    -- Expand and make it absolute
    local expanded = vim.fn.expand(path)
    absolute = vim.fn.fnamemodify(expanded, ':p')
  end
  
  -- On Windows, ensure forward slashes for URIs
  if vim.fn.has('win32') == 1 then
    absolute = absolute:gsub('\\', '/')
  end
  
  return absolute
end

function M.normalize_for_node(path)
  if not path or path == '' then
    return path
  end

  local platform = M.detect_node_platform()
  if platform ~= "win32" then
    return path
  end

  if path:match("^%a:[/\\]") then
    return path
  end

  if vim.fn.executable("wslpath") ~= 1 then
    return path
  end

  local converted = vim.fn.system({ "wslpath", "-w", path })
  if vim.v.shell_error ~= 0 then
    return path
  end

  return M.trim(converted)
end

function M.json_decode(payload)
  if payload == nil or payload == '' then
    return nil
  end

  local ok, decoded = pcall(vim.fn.json_decode, payload)
  if not ok then
    return nil
  end

  return decoded
end

function M.json_encode(value)
  if value == nil then
    return nil
  end

  if vim.json and vim.json.encode then
    local ok, encoded = pcall(vim.json.encode, value)
    if ok then
      return encoded
    end
  end

  local ok, encoded = pcall(vim.fn.json_encode, value)
  if ok then
    return encoded
  end

  return nil
end

local function ensure_cache_dir(root)
  if not root or root == '' then
    return nil
  end

  local dir = vim.fn.fnamemodify(root .. "/cache", ':p')
  vim.fn.mkdir(dir, 'p')
  return dir
end

function M.build_cache_path(root, filename)
  local dir = ensure_cache_dir(root)
  if not dir or dir == '' then
    return nil
  end

  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(dir, filename)
  end

  return dir .. '/' .. filename
end

function M.build_project_cache_path(root, project, suffix)
  if not root or root == '' or not project or project == '' then
    return nil
  end

  -- Normalize project path to ensure consistent hashing
  project = vim.fn.fnamemodify(project, ':p')
  
  local hash
  if vim.fn.sha256 then
    hash = vim.fn.sha256(project)
  else
    -- Fallback: create a simpler hash
    hash = project:gsub('[^%w]', '_')
  end

  local filename = string.format("%s-%s", hash, suffix)
  return M.build_cache_path(root, filename)
end

function M.read_text_file(path)
  if not path or path == '' then
    return nil
  end

  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end

  return table.concat(lines, "\n")
end

function M.write_text_file(path, content)
  if not path or path == '' or not content then
    return false
  end

  local ok = pcall(vim.fn.writefile, { content }, path)
  return ok
end

function M.read_file_state(path)
  local bufnr = vim.fn.bufnr(path, false)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return table.concat(lines, "\n"), true
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, false
  end

  local content = table.concat(lines, "\n")
  content = content:gsub("\\", "\\\\")
  return content, false
end

function M.ends_with(str, suffix)
  if type(str) ~= "string" or type(suffix) ~= "string" then
    return false
  end

  if #suffix == 0 then
    return true
  end

  return str:sub(-#suffix) == suffix
end

function M.is_list(value)
  if type(value) ~= "table" then
    return false
  end

  if vim.islist then
    return vim.islist(value)
  end

  if vim.tbl_islist then
    return vim.tbl_islist(value)
  end

  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end

  for i = 1, count do
    if value[i] == nil then
      return false
    end
  end

  return true
end

function M.merge_lists(left, right)
  local combined = {}

  if type(left) == "table" then
    for _, item in ipairs(left) do
      table.insert(combined, item)
    end
  end

  if type(right) == "table" then
    for _, item in ipairs(right) do
      table.insert(combined, item)
    end
  end

  return combined
end

-- Fuzzy matching: returns score (0-100) for how well pattern matches text
-- Higher score = better match
function M.fuzzy_match(pattern, text)
  if not pattern or not text then
    return 0
  end
  
  pattern = pattern:lower()
  text = text:lower()
  
  -- Exact match
  if pattern == text then
    return 100
  end
  
  -- Starts with
  if text:sub(1, #pattern) == pattern then
    return 90
  end
  
  -- Contains
  if text:find(pattern, 1, true) then
    return 80
  end
  
  -- Fuzzy: all characters of pattern appear in order in text
  local pattern_idx = 1
  local text_idx = 1
  local matches = 0
  
  while pattern_idx <= #pattern and text_idx <= #text do
    if pattern:sub(pattern_idx, pattern_idx) == text:sub(text_idx, text_idx) then
      matches = matches + 1
      pattern_idx = pattern_idx + 1
    end
    text_idx = text_idx + 1
  end
  
  -- All characters matched in order
  if matches == #pattern then
    -- Score based on how compact the match is
    local ratio = matches / #text
    return math.floor(70 * ratio)
  end
  
  return 0
end

return M
