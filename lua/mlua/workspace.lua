-- Simple workspace management - VS Code style
local utils = require('mlua.utils')

local M = {}

-- Simple file index: basename -> paths
local workspace_index = {}

-- Track which files are loaded in LSP (per client)
local loaded_files = {}

-- Chunked index state: tracks which chunks are loaded per root_dir
local chunk_state = {}  -- { [root_dir] = { chunks = {...}, loaded_indices = {}, chunk_size = N } }

-- Build workspace file index (async, non-blocking)
function M.build_workspace_index_async(root_dir, callback)
  if not root_dir then
    if callback then callback(0) end
    return
  end
  
  -- Normalize root directory
  root_dir = utils.normalize_path(root_dir)
  
  -- Use different command for Windows
  local cmd
  if vim.fn.has('win32') == 1 then
    -- PowerShell command for Windows
    cmd = { 'powershell', '-NoProfile', '-Command',
      string.format('Get-ChildItem -Path "%s" -Filter *.mlua -Recurse -File | ForEach-Object { $_.FullName }', root_dir)
    }
  else
    -- find command for Unix/Linux/macOS
    cmd = { 'find', root_dir, '-type', 'f', '-name', '*.mlua' }
  end
  
  vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        
        local paths = {}
        for _, line in ipairs(data) do
          if line ~= '' then
            -- Normalize path for consistency
            local normalized = utils.normalize_path(line)
            table.insert(paths, normalized)
          end
        end
        
        -- Calculate chunk size: √n
        local total_files = #paths
        local chunk_size = math.max(1, math.floor(math.sqrt(total_files)))
        
        -- Split paths into chunks
        local chunks = {}
        for i = 1, total_files, chunk_size do
          local chunk = {}
          for j = i, math.min(i + chunk_size - 1, total_files) do
            table.insert(chunk, paths[j])
          end
          table.insert(chunks, chunk)
        end
        
        -- Initialize chunk state for this root_dir
        chunk_state[root_dir] = {
          chunks = chunks,
          loaded_indices = {},  -- Track which chunks are loaded
          chunk_size = chunk_size,
        }
        
        -- Build initial empty index (will be populated on-demand)
        workspace_index[root_dir] = {}
        
        if callback then
          vim.schedule(function()
            callback(total_files)
          end)
        end
      end,
    }
  )
end

-- Load a chunk of files into the index
local function load_chunk(root_dir, chunk_index)
  local state = chunk_state[root_dir]
  if not state or state.loaded_indices[chunk_index] then
    return 0  -- Already loaded or invalid
  end
  
  local chunk = state.chunks[chunk_index]
  if not chunk then
    return 0
  end
  
  -- Build index for this chunk
  local index = workspace_index[root_dir]
  local loaded_count = 0
  
  for _, path in ipairs(chunk) do
    -- Handle .d.mlua files specially (declaration files)
    local basename
    if path:match("%.d%.mlua$") then
      basename = path:match("([^/\\]+)%.d%.mlua$")
    else
      basename = vim.fn.fnamemodify(path, ':t:r')
    end
    basename = basename and basename:lower() or ""
    
    if basename ~= "" then
      if not index[basename] then
        index[basename] = {}
      end
      table.insert(index[basename], path)
      loaded_count = loaded_count + 1
    end
  end
  
  -- Mark chunk as loaded
  state.loaded_indices[chunk_index] = true
  
  return loaded_count
end

-- Find which chunk might contain a token (simple heuristic)
local function find_relevant_chunks(root_dir, tokens)
  local state = chunk_state[root_dir]
  if not state then
    return {}
  end
  
  local relevant = {}
  
  -- Check each unloaded chunk
  for i, chunk in ipairs(state.chunks) do
    if not state.loaded_indices[i] then
      -- Check ALL files in chunk, not just samples (we need accurate matching)
      for _, path in ipairs(chunk) do
        -- Handle .d.mlua files specially
        local basename
        if path:match("%.d%.mlua$") then
          basename = path:match("([^/\\]+)%.d%.mlua$")
        else
          basename = vim.fn.fnamemodify(path, ':t:r')
        end
        basename = basename and basename:lower() or ""
        
        -- Check if this basename matches any token
        for token in pairs(tokens) do
          local score = utils.fuzzy_match(token, basename)
          if score >= 70 then  -- Lower threshold for chunk loading
            table.insert(relevant, i)
            goto next_chunk  -- Found a match in this chunk, move to next chunk
          end
        end
      end
      ::next_chunk::
    end
  end
  
  return relevant
end

-- Load a file into LSP via didOpen
function M.load_file(client_id, file_path)
  if not file_path or file_path == '' then
    return false
  end
  
  local normalized_path = utils.normalize_path(file_path)
  
  -- Check if already loaded
  local client_loaded = loaded_files[client_id] or {}
  if client_loaded[normalized_path] then
    return false
  end
  
  -- Read file content
  if vim.fn.filereadable(normalized_path) ~= 1 then
    return false
  end
  
  local content = utils.read_text_file(normalized_path)
  if not content then
    return false
  end
  
  -- Create proper file:// URI
  local uri = vim.uri_from_fname(normalized_path)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return false
  end
  
  -- Send didOpen to LSP
  client.notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = "mlua",
      version = 0,
      text = content,
    }
  })
  
  -- Track as loaded
  if not loaded_files[client_id] then
    loaded_files[client_id] = {}
  end
  loaded_files[client_id][normalized_path] = true
  
  return true
end

-- Extract tokens from line(s)
local function extract_tokens_from_lines(lines)
  local tokens = {}
  
  for _, line in ipairs(lines) do
    -- 1) Decorator: @Name
    for token in line:gmatch("@([%w_]+)") do
      tokens[token:lower()] = true
    end

    -- 2) extends ClassName
    for token in line:gmatch("extends%s+([%w_]+)") do
      tokens[token:lower()] = true
    end

    -- 3) _name (Logic script) - capture name without the _ prefix
    --    Matches: var = _LogicScript -> "logicscript"
    for token in line:gmatch("[^%w]_([%w_]+)") do
      tokens[token:lower()] = true
    end
    -- Also check start of line
    local logic_token = line:match("^_([%w_]+)")
    if logic_token then
      tokens[logic_token:lower()] = true
    end

    -- 4) .name (component access)
    for token in line:gmatch("%.([%w_]+)") do
      tokens[token:lower()] = true
    end

    -- 5) PascalCase identifiers: must have space before or be at start of line
    for token in line:gmatch("[^%w_]([A-Z]%w+)") do
      tokens[token:lower()] = true
    end
    local pascal_token = line:match("^([A-Z]%w+)")
    if pascal_token then
      tokens[pascal_token:lower()] = true
    end
  end
  
  return tokens
end

-- Find related files based on buffer content
function M.load_related_files(client_id, bufnr, root_dir, line_numbers)
  local index = workspace_index[root_dir]
  if not index then
    return
  end

  -- Get lines to inspect (either provided line numbers or current cursor line)
  local lines = {}
  if line_numbers and #line_numbers > 0 then
    for _, line_num in ipairs(line_numbers) do
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
      if line then
        table.insert(lines, line)
      end
    end
  else
    -- Default: current cursor line
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor and cursor[1] or 1
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    table.insert(lines, line)
  end

  -- Extract tokens from the specified lines
  local tokens = extract_tokens_from_lines(lines)
  
  -- Find and load relevant chunks on-demand (based on tokens from the specified lines)
  -- Limit to maximum 2 chunks per trigger to avoid excessive loading
  local relevant_chunks = find_relevant_chunks(root_dir, tokens)
  local chunks_loaded = 0
  local max_chunks = 2
  for _, chunk_index in ipairs(relevant_chunks) do
    if chunks_loaded >= max_chunks then
      break
    end
    local count = load_chunk(root_dir, chunk_index)
    if count > 0 then
      chunks_loaded = chunks_loaded + 1
    end
  end
  
  -- Load matching files using fuzzy matching
  local loaded_count = 0
  local matches = {}  -- Store all matches with scores
  
  -- For each token, find matching files using fuzzy matching
  for token in pairs(tokens) do
    -- First try exact match in index
    local exact_paths = index[token]
    if exact_paths then
      for _, path in ipairs(exact_paths) do
        table.insert(matches, {path = path, score = 100})
      end
    else
      -- Fuzzy match against all files in index
      for basename, paths in pairs(index) do
        local score = utils.fuzzy_match(token, basename)
        if score >= 70 then  -- Minimum score threshold
          for _, path in ipairs(paths) do
            table.insert(matches, {path = path, score = score})
          end
        end
      end
    end
  end
  
  -- Sort by score (highest first) and remove duplicates
  table.sort(matches, function(a, b) return a.score > b.score end)
  local seen = {}
  local unique_matches = {}
  for _, match in ipairs(matches) do
    if not seen[match.path] then
      table.insert(unique_matches, match)
      seen[match.path] = true
    end
  end

  -- Load top matches
  for _, match in ipairs(unique_matches) do
    if M.load_file(client_id, match.path) then
      loaded_count = loaded_count + 1
    end
  end
  
  if loaded_count > 0 then
    local msg = string.format("Loaded %d related file(s)", loaded_count)
    if chunks_loaded > 0 then
      msg = msg .. string.format(" (%d chunk(s) indexed)", chunks_loaded)
    end
    vim.notify(msg, vim.log.levels.INFO)
  end
end

-- Setup for a buffer (called from on_attach)
function M.setup_for_buffer(client, bufnr, root_dir)
  if not root_dir then
    return
  end
  
  -- First, send the current buffer via didOpen
  local current_path = vim.api.nvim_buf_get_name(bufnr)
  if current_path and current_path ~= '' then
    vim.defer_fn(function()
      M.load_file(client.id, current_path)
    end, 100)
  end
  
  -- Track recently modified lines (keep last 3)
  local modified_lines = {}
  
  -- Track changes to capture recently modified lines
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first_line, old_last_line, new_last_line)
      -- on_lines params are 0-indexed, convert to 1-indexed for nvim_buf_get_lines
      -- Track the range of lines that were modified
      for i = first_line + 1, new_last_line do
        -- Avoid duplicates and keep most recent at front
        local already_tracked = false
        for _, line_num in ipairs(modified_lines) do
          if line_num == i then
            already_tracked = true
            break
          end
        end
        if not already_tracked then
          table.insert(modified_lines, 1, i)  -- Insert at front
        end
      end
      -- Keep only last 3 unique lines
      while #modified_lines > 3 do
        table.remove(modified_lines)
      end
    end
  })
  
  -- InsertLeave: load related files from the last 3 modified lines
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    callback = function()
      if #modified_lines > 0 then
        M.load_related_files(client.id, bufnr, root_dir, modified_lines)
      end
    end,
  })
  
  -- InsertEnter: setup a timer for periodic loading of current line
  local insert_timer = nil
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = bufnr,
    callback = function()
      -- Start a timer that fires every 3 seconds while in insert mode
      if insert_timer then
        vim.fn.timer_stop(insert_timer)
      end
      insert_timer = vim.fn.timer_start(3000, function()
        -- Only load if still in insert mode
        local mode = vim.api.nvim_get_mode().mode
        if mode == 'i' or mode == 'ic' then
          -- Load for current cursor line only (no line_numbers = use cursor line)
          M.load_related_files(client.id, bufnr, root_dir, nil)
        end
      end, { ['repeat'] = -1 })  -- Repeat indefinitely
    end,
  })
  
  -- Stop timer when leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    callback = function()
      if insert_timer then
        vim.fn.timer_stop(insert_timer)
        insert_timer = nil
      end
    end,
  })
end

return M
