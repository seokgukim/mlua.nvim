-- Debug helper for mLua LSP
-- Place this in your config and call :lua require('mlua.debug').check_status()

local M = {}

function M.check_status()
  print("=== mLua LSP Debug Info ===\n")
  
  -- Check Node.js
  local node_handle = io.popen("node --version 2>&1")
  if node_handle then
    local node_version = node_handle:read("*a")
    node_handle:close()
    print("Node.js version: " .. vim.trim(node_version))
  else
    print("Node.js: NOT FOUND")
  end
  
  -- Check installation
  local mlua = require("mlua.lsp")
  local version, install_dir = mlua.get_installed_version()
  
  if version then
    print("mLua LSP version: " .. version)
    print("Install directory: " .. install_dir)
    
    local server_path = install_dir .. "/extension/scripts/server/out/languageServer.js"
    if vim.fn.filereadable(server_path) == 1 then
      print("Server file: ✓ FOUND")
    else
      print("Server file: ✗ NOT FOUND")
    end
  else
    print("mLua LSP: NOT INSTALLED")
    print("Run :MluaInstall to install")
  end
  
  -- Check active LSP clients
  print("\nActive LSP clients:")
  local clients = vim.lsp.get_clients({ name = "mlua" })
  if #clients > 0 then
    for _, client in ipairs(clients) do
      print(string.format("  - Client ID: %d, Name: %s", client.id, client.name))
      print(string.format("    Root dir: %s", client.config.root_dir or "N/A"))
      
      -- Check server capabilities
      if client.server_capabilities then
        print(string.format("    Capabilities: semanticTokensProvider = %s", 
          tostring(client.server_capabilities.semanticTokensProvider ~= nil)))
        print(string.format("    Capabilities: completionProvider = %s", 
          tostring(client.server_capabilities.completionProvider ~= nil)))
      end
      
      -- Check if client is running
      if client.is_stopped and client.is_stopped() then
        print("    Status: ✗ STOPPED")
      else
        print("    Status: ✓ RUNNING")
      end
    end
  else
    print("  No mLua LSP clients active")
  end
  
  -- Check current buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  print("\nCurrent buffer:")
  print("  Filetype: " .. ft)
  
  if ft == "mlua" then
    local buf_clients = vim.lsp.get_clients({ bufnr = bufnr })
    print("  LSP clients attached: " .. #buf_clients)
  end
  
  -- LSP log level
  print("\nLSP Log Level: " .. vim.lsp.get_log_path())
  
  print("\n=== End Debug Info ===")
end

function M.restart_lsp()
  print("Restarting mLua LSP...")
  local clients = vim.lsp.get_clients({ name = "mlua" })
  for _, client in ipairs(clients) do
    vim.lsp.stop_client(client.id)
  end
  
  vim.defer_fn(function()
    vim.cmd("edit")
    print("LSP restarted. Reopening buffer...")
  end, 500)
end

-- Command to show LSP logs
function M.show_logs()
  local log_path = vim.lsp.get_log_path()
  vim.cmd("edit " .. log_path)
end

-- Show detailed server capabilities
function M.show_capabilities()
  local clients = vim.lsp.get_clients({ name = "mlua" })
  if #clients == 0 then
    print("No mLua LSP clients active")
    return
  end
  
  for _, client in ipairs(clients) do
    print("=== mLua Server Capabilities ===\n")
    print("Client ID: " .. client.id)
    print("\nFull capabilities:")
    print(vim.inspect(client.server_capabilities))
    print("\n=== End Capabilities ===")
  end
end

return M
