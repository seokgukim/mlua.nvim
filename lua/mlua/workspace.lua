-- Simple workspace management - VS Code style
local utils = require('mlua.utils')

local M = {}

-- Simple file index: basename -> paths
local workspace_index = {}

-- Track which files are loaded in LSP (per client)
local loaded_files = {}

-- Build workspace file index (async, non-blocking)
function M.build_workspace_index_async(root_dir, callback)
  if not root_dir then
    if callback then callback(0) end
    return
  end
  
  vim.fn.jobstart(
    { 'find', root_dir, '-type', 'f', '-name', '*.mlua' },
    {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if not data then return end
        
        local paths = {}
        for _, line in ipairs(data) do
          if line ~= '' then
            table.insert(paths, line)
          end
        end
        
        -- Build basename index
        local index = {}
        for _, path in ipairs(paths) do
          local basename = vim.fn.fnamemodify(path, ':t:r'):lower()
          if not index[basename] then
            index[basename] = {}
          end
          table.insert(index[basename], path)
        end
        
        workspace_index[root_dir] = index
        
        if callback then
          vim.schedule(function()
            callback(#paths)
          end)
        end
      end,
    }
  )
end

-- Load a file into LSP via didOpen
function M.load_file(client_id, file_path)
  if not file_path or file_path == '' then
    return false
  end
  
  local normalized_path = vim.fn.fnamemodify(file_path, ':p')
  
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

-- Find related files based on buffer content
function M.load_related_files(client_id, bufnr, root_dir)
  local index = workspace_index[root_dir]
  if not index then
    return
  end
  
  -- Get buffer text
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  
  -- Extract potential script names
  local tokens = {}
  
  -- Pattern 1: extends ClassName
  for token in text:gmatch("extends%s+([%w_]+)") do
    tokens[token:lower()] = true
  end
  
  -- Pattern 2: : TypeName (type annotations)
  for token in text:gmatch(":%s*([%u][%w_]*)") do
    tokens[token:lower()] = true
  end
  
  -- Pattern 3: All capitalized identifiers (PascalCase) - likely script names
  -- This catches normal usage like: myVar = PlayerController.new()
  for token in text:gmatch("[%u][%w_]*") do
    -- Only include if 3+ chars and not common keywords
    local lower = token:lower()
    if #lower >= 3 and 
       lower ~= "true" and 
       lower ~= "false" and 
       lower ~= "null" and
       lower ~= "environment" and
       lower ~= "global" then
      tokens[lower] = true
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
    vim.notify(string.format("Loaded %d related file(s)", loaded_count), vim.log.levels.INFO)
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
  
  -- Simple trigger: load related files when leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    callback = function()
      M.load_related_files(client.id, bufnr, root_dir)
    end,
  })
end

return M
