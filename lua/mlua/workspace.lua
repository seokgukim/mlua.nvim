-- Workspace file scanning and smart loading
local utils = require('mlua.utils')

local M = {}

-- Module state
local workspace_files_cache = {}  -- root_dir -> file_paths[]
local loaded_files_cache = {}     -- client_id:path -> boolean
local file_name_trie = {}         -- {by_name = {}, by_prefix = {}}
local last_buffer_size = {}       -- bufnr -> byte_count

-- Configuration
M.config = {
  smart_load_frequency = 4,  -- Trigger smart load every N bytes (default: 4)
}

function M.setup(opts)
  opts = opts or {}
  M.config.smart_load_frequency = opts.smart_load_frequency or 4
end

-- Build trie/dict for fast file name lookup
local function build_file_name_index(file_paths)
  local index = {
    by_name = {},      -- basename -> full_paths[]
    by_prefix = {},    -- prefix -> full_paths[]
  }
  
  for _, path in ipairs(file_paths) do
    local basename = vim.fn.fnamemodify(path, ':t:r')  -- filename without extension
    local lower_name = basename:lower()
    
    -- Store by exact name
    index.by_name[lower_name] = index.by_name[lower_name] or {}
    table.insert(index.by_name[lower_name], path)
    
    -- Store by prefixes (for tokens >= 4 chars)
    if #lower_name >= 4 then
      for len = 4, #lower_name do
        local prefix = lower_name:sub(1, len)
        index.by_prefix[prefix] = index.by_prefix[prefix] or {}
        table.insert(index.by_prefix[prefix], path)
      end
    end
  end
  
  return index
end

-- Async file scanner using vim.loop
local function scan_mlua_files_async(root_dir, callback)
  if not root_dir or root_dir == '' then
    callback({})
    return
  end

  root_dir = vim.fn.fnamemodify(root_dir, ':p')
  local uv = vim.loop or vim.uv
  local files = {}

  -- Try fast file finders first (async)
  if vim.fn.executable('fd') == 1 then
    local stdout = uv.new_pipe(false)
    local handle = uv.spawn('fd', {
      args = {'-t', 'f', '-e', 'mlua', '.', root_dir},
      stdio = {nil, stdout, nil}
    }, function(code, signal)
      stdout:close()
      if code == 0 then
        callback(files)
      else
        callback({})
      end
    end)

    if handle then
      uv.read_start(stdout, function(err, data)
        if err then
          return
        end
        if data then
          for line in data:gmatch("[^\n]+") do
            table.insert(files, line)
          end
        end
      end)
    else
      callback({})
    end
  elseif vim.fn.executable('rg') == 1 then
    local stdout = uv.new_pipe(false)
    local handle = uv.spawn('rg', {
      args = {'--files', '-g', '*.mlua', root_dir},
      stdio = {nil, stdout, nil}
    }, function(code, signal)
      stdout:close()
      if code == 0 then
        callback(files)
      else
        callback({})
      end
    end)

    if handle then
      uv.read_start(stdout, function(err, data)
        if err then
          return
        end
        if data then
          for line in data:gmatch("[^\n]+") do
            table.insert(files, line)
          end
        end
      end)
    else
      callback({})
    end
  else
    -- Fallback to synchronous find (but schedule callback async)
    vim.schedule(function()
      local found_files = {}
      if vim.fs and vim.fs.find then
        found_files = vim.fs.find(function(name)
          return name:match('%.mlua$')
        end, {
          limit = math.huge,
          type = 'file',
          path = root_dir,
        })
      else
        found_files = vim.fn.globpath(root_dir, "**/*.mlua", false, true)
      end
      callback(found_files)
    end)
  end
end

-- Scan workspace paths only (no content) - very fast
function M.scan_workspace_paths_async(root_dir, callback)
  if not root_dir or root_dir == '' then
    callback({})
    return
  end

  scan_mlua_files_async(root_dir, function(files)
    vim.schedule(function()
      -- Cache the file paths
      workspace_files_cache[root_dir] = files
      
      -- Build fast lookup index
      file_name_trie = build_file_name_index(files)
      
      callback(files)
    end)
  end)
end

-- Load a single file on-demand and send to LSP
function M.load_file_on_demand(client_id, file_path)
  if not file_path or file_path == '' then
    return false
  end
  
  local normalized_path = vim.fn.fnamemodify(file_path, ':p')
  local cache_key = client_id .. ":" .. normalized_path
  
  -- Check if already loaded
  if loaded_files_cache[cache_key] then
    return false  -- Already loaded
  end
  
  -- Read file content
  if vim.fn.filereadable(normalized_path) ~= 1 then
    return false
  end
  
  local content = utils.read_text_file(normalized_path)
  if not content then
    return false
  end
  
  local uri = vim.uri_from_fname(normalized_path)
  
  -- Send textDocument/didOpen to LSP
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return false
  end
  
  local params = {
    textDocument = {
      uri = uri,
      languageId = "mlua",
      version = 0,
      text = content,
    }
  }
  
  client.notify("textDocument/didOpen", params)
  
  -- Mark as loaded
  loaded_files_cache[cache_key] = true
  
  return true
end

-- Extract tokens from buffer that might reference other files
local function extract_candidate_tokens(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  
  local tokens = {}
  
  -- Extract extends declarations
  for token in text:gmatch("extends%s+([%w_]+)") do
    tokens[token:lower()] = true
  end
  
  -- Extract type annotations (: Type)
  for token in text:gmatch(":%s*([%u][%w_]*)") do
    tokens[token:lower()] = true
  end
  
  -- Extract capitalized identifiers (potential script names)
  for token in text:gmatch("[^%w]([%u][%w_]+)[^%w]") do
    -- Filter out common keywords/folders
    if token ~= "Environment" and token ~= "Global" and #token >= 4 then
      tokens[token:lower()] = true
    end
  end
  
  return tokens
end

-- Find files matching the given tokens using the trie index
local function find_files_for_tokens(tokens)
  local matched_files = {}
  local seen = {}
  
  for token in pairs(tokens) do
    local token_lower = token:lower()
    local token_len = #token_lower
    
    -- For short tokens (< 4 chars), only exact name match
    if token_len < 4 then
      local exact_matches = file_name_trie.by_name[token_lower]
      if exact_matches then
        for _, path in ipairs(exact_matches) do
          if not seen[path] then
            table.insert(matched_files, path)
            seen[path] = true
          end
        end
      end
    else
      -- For longer tokens, prefix match
      local prefix_matches = file_name_trie.by_prefix[token_lower]
      if prefix_matches then
        for _, path in ipairs(prefix_matches) do
          if not seen[path] then
            table.insert(matched_files, path)
            seen[path] = true
          end
        end
      end
    end
  end
  
  return matched_files
end

-- Smart load dependencies based on buffer content
function M.smart_load_dependencies(client_id, bufnr, root_dir)
  if not root_dir or not workspace_files_cache[root_dir] then
    return 0
  end
  
  -- Extract token candidates from buffer
  local tokens = extract_candidate_tokens(bufnr)
  if vim.tbl_isempty(tokens) then
    return 0
  end
  
  -- Find matching files
  local matching_files = find_files_for_tokens(tokens)
  
  -- Load unloaded files
  local loaded_count = 0
  for _, file_path in ipairs(matching_files) do
    if M.load_file_on_demand(client_id, file_path) then
      loaded_count = loaded_count + 1
    end
  end
  
  if loaded_count > 0 then
    vim.notify(string.format("Smart-loaded %d file(s)", loaded_count), vim.log.levels.INFO)
  end
  
  return loaded_count
end

-- Setup smart loading triggers for a buffer
function M.setup_smart_load_triggers(client, bufnr, root_dir)
  local smart_load_timer = nil
  
  -- Automatically send current file to LSP via didOpen if not already sent
  local current_path = vim.api.nvim_buf_get_name(bufnr)
  if current_path and current_path ~= '' then
    vim.defer_fn(function()
      M.load_file_on_demand(client.id, current_path)
    end, 100)
  end
  
  -- Initialize buffer size tracking
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "")
  last_buffer_size[bufnr] = #text
  
  -- Setup smart loading triggers
  local group = vim.api.nvim_create_augroup("MluaSmartLoad_" .. bufnr, { clear = true })
  
  -- Trigger on insert leave (after user finishes typing)
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      if smart_load_timer then
        vim.fn.timer_stop(smart_load_timer)
      end
      smart_load_timer = vim.fn.timer_start(300, function()
        M.smart_load_dependencies(client.id, bufnr, root_dir)
      end)
    end,
  })
  
  -- Byte-based trigger: check every N bytes inserted (configurable)
  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    group = group,
    buffer = bufnr,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "")
      local current_size = #text
      local last_size = last_buffer_size[bufnr] or 0
      
      local trigger_threshold = M.config.smart_load_frequency or 4
      
      -- Check if N or more bytes were added
      if current_size >= last_size + trigger_threshold then
        last_buffer_size[bufnr] = current_size
        
        -- Debounced smart load
        if smart_load_timer then
          vim.fn.timer_stop(smart_load_timer)
        end
        smart_load_timer = vim.fn.timer_start(500, function()
          M.smart_load_dependencies(client.id, bufnr, root_dir)
        end)
      end
    end,
  })
  
  -- Additional trigger for insert mode on specific keywords
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Get current line to check for trigger keywords
      local line = vim.api.nvim_get_current_line()
      
      -- Check for trigger patterns that indicate cross-file dependencies
      local trigger_patterns = {
        "extends%s+%w+",              -- extends ClassName
        ":%s*%u%w+",                  -- : TypeName
        "script%s+%w+%s+extends",     -- script Foo extends Bar
        "import%s+",                  -- import statements (if supported)
      }
      
      local should_trigger = false
      for _, pattern in ipairs(trigger_patterns) do
        if line:match(pattern) then
          should_trigger = true
          break
        end
      end
      
      if should_trigger then
        -- Stop existing timer
        if smart_load_timer then
          vim.fn.timer_stop(smart_load_timer)
        end
        -- Shorter debounce for keyword triggers (more responsive)
        smart_load_timer = vim.fn.timer_start(300, function()
          M.smart_load_dependencies(client.id, bufnr, root_dir)
        end)
      end
    end,
  })
  
  -- Cleanup on buffer unload
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      last_buffer_size[bufnr] = nil
    end,
  })
  
  -- Initial smart load on attach
  vim.defer_fn(function()
    M.smart_load_dependencies(client.id, bufnr, root_dir)
  end, 1000) -- Wait 1s after attach
end

-- Get workspace status for debugging
function M.get_status(root_dir)
  local file_count = workspace_files_cache[root_dir] and #workspace_files_cache[root_dir] or 0
  local loaded_count = 0
  for _ in pairs(loaded_files_cache) do
    loaded_count = loaded_count + 1
  end
  
  local name_count = vim.tbl_count(file_name_trie.by_name or {})
  local prefix_count = vim.tbl_count(file_name_trie.by_prefix or {})
  
  return {
    indexed = file_count,
    loaded = loaded_count,
    names = name_count,
    prefixes = prefix_count,
  }
end

return M
