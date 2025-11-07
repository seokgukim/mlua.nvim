local utils = require('mlua.utils')
local entries = require('mlua.entries')

local M = {}

local attached_buffers = {}
local document_cache = {}
local predefines_cache = {}

local function publish_diagnostics(client, uri, diagnostics)
  if not diagnostics then
    return
  end

  local handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
  if handler then
    handler(nil, { uri = uri, diagnostics = diagnostics }, { client_id = client.id })
  end
end

local function request_document_diagnostics(client, bufnr)
  if not client or not client.supports_method("textDocument/diagnostic") then
    return
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

  client.request("textDocument/diagnostic", params, function(err, result)
    if err then
      vim.notify_once(
        string.format("mLua diagnostics request failed: %s", err.message or tostring(err)),
        vim.log.levels.WARN
      )
      return
    end

    if not result then
      return
    end

    if result.kind == "full" then
      publish_diagnostics(client, params.textDocument.uri, result.items)
    end
  end, bufnr)
end

local function register_buffer_cleanup(client_id, bufnr)
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    once = true,
    callback = function()
      local buckets = attached_buffers[client_id]
      if buckets then
        buckets[bufnr] = nil
      end
    end,
  })
end

local function load_predefines(installed_dir)
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

local function collect_document_items(root_dir)
  if not root_dir or root_dir == '' then
    return {}
  end

  root_dir = vim.fn.fnamemodify(root_dir, ':p')

  local cached = document_cache[root_dir]
  if cached then
    return cached
  end

  local items = {}
  local files = {}
  
  -- Try fast file finders first
  if vim.fn.executable('fd') == 1 then
    -- fd is fastest
    local handle = io.popen(string.format('fd -t f -e mlua . %s', vim.fn.shellescape(root_dir)))
    if handle then
      for line in handle:lines() do
        table.insert(files, line)
      end
      handle:close()
      vim.notify(string.format("Found %d files using fd", #files), vim.log.levels.INFO)
    end
  elseif vim.fn.executable('rg') == 1 then
    -- ripgrep is also very fast
    local handle = io.popen(string.format('rg --files -g "*.mlua" %s', vim.fn.shellescape(root_dir)))
    if handle then
      for line in handle:lines() do
        table.insert(files, line)
      end
      handle:close()
      vim.notify(string.format("Found %d files using ripgrep", #files), vim.log.levels.INFO)
    end
  elseif vim.fs and vim.fs.find then
    -- Fallback to vim.fs.find
    files = vim.fs.find(function(name)
      return name:match('%.mlua$')
    end, {
      limit = math.huge,
      type = 'file',
      path = root_dir,
    })
  else
    -- Last resort: globpath
    files = vim.fn.globpath(root_dir, "**/*.mlua", false, true)
  end

  -- Read all found files
  for _, path in ipairs(files) do
    local normalized_path = vim.fn.fnamemodify(path, ':p')
    if vim.fn.filereadable(normalized_path) == 1 then
      local content = utils.read_text_file(normalized_path)
      if content then
        local uri = vim.uri_from_fname(normalized_path)
        table.insert(items, {
          uri = uri,
          languageId = "mlua",
          version = 0,
          text = content
        })
      end
    end
  end

  document_cache[root_dir] = items
  return items
end

local function check_node_available()
  local handle = io.popen("node --version 2>&1")
  if not handle then
    return false
  end

  local result = handle:read("*a")
  handle:close()

  return result:match("v%d+%.%d+%.%d+") ~= nil
end

local function find_root(fname)
  local markers = { 'Environment', 'Global', 'map', 'RootDesk', 'ui' }
  local path = vim.fn.fnamemodify(fname, ':p:h')
  local home = vim.loop.os_homedir()

  while path ~= home and path ~= '/' do
    local found_all = true
    for _, marker in ipairs(markers) do
      local marker_path = path .. '/' .. marker
      if vim.fn.isdirectory(marker_path) ~= 1 then
        found_all = false
        break
      end
    end
    if found_all then
      return path
    end
    path = vim.fn.fnamemodify(path, ':h')
  end

  return nil
end

M.config = {
  install_dir = vim.fn.expand("~/.local/share/nvim/mlua-lsp"),
  publisher = "msw",
  extension = "mlua",
}

function M.get_latest_version()
  local curl_cmd = string.format([[
    curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json;api-version=3.0-preview.1" \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"%s.%s"}]}],"flags":914}' \
    "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery"
  ]], M.config.publisher, M.config.extension)

  local handle = io.popen(curl_cmd)
  if not handle then
    return nil
  end

  local result = handle:read("*a")
  handle:close()

  local version = result:match("\"version\":\"([^\"]+)\"")
  return version
end

function M.get_installed_version()
  local pattern = M.config.install_dir .. "/" .. M.config.publisher .. "." .. M.config.extension .. "-*"
  local dirs = vim.fn.glob(pattern, false, true)

  if #dirs == 0 then
    return nil
  end

  table.sort(dirs)
  local latest_dir = dirs[#dirs]
  local version = latest_dir:match("%-([%d%.]+)$")
  return version, latest_dir
end

function M.download(version)
  version = version or M.get_latest_version()

  if not version then
    vim.notify("Error: Could not fetch version", vim.log.levels.ERROR)
    return false
  end

  vim.notify("Downloading mLua v" .. version .. "...", vim.log.levels.INFO)

  local download_dir = M.config.install_dir
  local extension_name = M.config.publisher .. "." .. M.config.extension .. "-" .. version
  local vsix_file = download_dir .. "/" .. extension_name .. ".vsix"
  local zip_file = download_dir .. "/" .. extension_name .. ".zip"
  local extract_dir = download_dir .. "/" .. extension_name

  vim.fn.mkdir(download_dir, "p")

  local download_url = string.format(
    "https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/%s/extension/%s/%s/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage",
    M.config.publisher,
    M.config.publisher,
    M.config.extension,
    version
  )

  local download_cmd = string.format('curl -L -o "%s" "%s"', vsix_file, download_url)
  local result = os.execute(download_cmd)

  if result ~= 0 then
    vim.notify("Error: Download failed", vim.log.levels.ERROR)
    return false
  end

  os.rename(vsix_file, zip_file)
  vim.fn.mkdir(extract_dir, "p")

  local extract_cmd
  if vim.fn.has("win32") == 1 then
    extract_cmd = string.format(
      'powershell -Command "Expand-Archive -Path \'%s\' -DestinationPath \'%s\' -Force"',
      zip_file:gsub("/", "\\"),
      extract_dir:gsub("/", "\\")
    )
  else
    extract_cmd = string.format('unzip -q -o "%s" -d "%s"', zip_file, extract_dir)
  end

  os.execute(extract_cmd)
  os.remove(zip_file)

  vim.notify("mLua v" .. version .. " installed successfully!", vim.log.levels.INFO)
  return true, extract_dir
end

function M.update()
  local latest_version = M.get_latest_version()
  local installed_version, installed_dir = M.get_installed_version()

  if not latest_version then
    vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
    return
  end

  if not installed_version then
    vim.notify("mLua not installed. Installing v" .. latest_version .. "...", vim.log.levels.INFO)
    M.download(latest_version)
    return
  end

  vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
  vim.notify("Latest: v" .. latest_version, vim.log.levels.INFO)

  if installed_version == latest_version then
    vim.notify("Already up to date!", vim.log.levels.INFO)
    return
  end

  local confirm = vim.fn.confirm(
    string.format("Update mLua from v%s to v%s?", installed_version, latest_version),
    "&Yes\n&No",
    2
  )

  if confirm ~= 1 then
    vim.notify("Update cancelled", vim.log.levels.INFO)
    return
  end

  local success = M.download(latest_version)

  if success then
    vim.notify("Removing old version...", vim.log.levels.INFO)
    local rm_cmd
    if vim.fn.has("win32") == 1 then
      rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
    else
      rm_cmd = string.format('rm -rf "%s"', installed_dir)
    end
    os.execute(rm_cmd)

    vim.notify("Update complete! Restart Neovim to use the new version.", vim.log.levels.WARN)
  end
end

function M.check_version()
  local latest_version = M.get_latest_version()
  local installed_version = M.get_installed_version()

  if not latest_version then
    vim.notify("Error: Could not fetch latest version", vim.log.levels.ERROR)
    return
  end

  if not installed_version then
    vim.notify("mLua is not installed", vim.log.levels.WARN)
    vim.notify("Latest available: v" .. latest_version, vim.log.levels.INFO)
    vim.notify("Run :MluaInstall to install", vim.log.levels.INFO)
    return
  end

  vim.notify("Installed: v" .. installed_version, vim.log.levels.INFO)
  vim.notify("Latest: v" .. latest_version, vim.log.levels.INFO)

  if installed_version ~= latest_version then
    vim.notify("Update available! Run :MluaUpdate to upgrade", vim.log.levels.WARN)
  else
    vim.notify("You have the latest version!", vim.log.levels.INFO)
  end
end

function M.uninstall()
  local installed_version, installed_dir = M.get_installed_version()

  if not installed_version then
    vim.notify("mLua is not installed", vim.log.levels.WARN)
    return
  end

  local confirm = vim.fn.confirm(
    string.format("Uninstall mLua v%s?", installed_version),
    "&Yes\n&No",
    2
  )

  if confirm ~= 1 then
    vim.notify("Uninstall cancelled", vim.log.levels.INFO)
    return
  end

  local rm_cmd
  if vim.fn.has("win32") == 1 then
    rm_cmd = string.format('rmdir /s /q "%s"', installed_dir:gsub("/", "\\"))
  else
    rm_cmd = string.format('rm -rf "%s"', installed_dir)
  end

  os.execute(rm_cmd)
  vim.notify("mLua v" .. installed_version .. " uninstalled", vim.log.levels.INFO)
end

function M.setup(opts)
  opts = opts or {}

  -- Set global folding option (default: false)
  vim.g.mlua_enable_folding = opts.enable_folding or false

  if not check_node_available() then
    vim.notify("Node.js is not installed or not in PATH. Please install Node.js to use mLua LSP.", vim.log.levels.ERROR)
    return
  end

  local installed_version, installed_dir = M.get_installed_version()

  if not installed_version then
    vim.notify("mLua language server not found. Run :MluaInstall to install.", vim.log.levels.WARN)
    return
  end

  local server_path = installed_dir .. "/extension/scripts/server/out/languageServer.js"

  if vim.fn.filereadable(server_path) == 0 then
    vim.notify("Server file not found at: " .. server_path, vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    pattern = "*.mlua",
    callback = function(args)
      if not vim.api.nvim_buf_is_loaded(args.buf) then
        return
      end

      local bufname = vim.api.nvim_buf_get_name(args.buf)
      local root_dir = opts.root_dir or find_root(bufname)
      local is_project = root_dir ~= nil
      
      if is_project then
        root_dir = vim.fn.fnamemodify(root_dir, ':p')
      else
        -- If no project root found, use the directory of the current file
        -- instead of cwd to avoid scanning unrelated directories
        root_dir = vim.fn.fnamemodify(bufname, ':p:h')
      end
      
      local client_capabilities = opts.capabilities or vim.lsp.protocol.make_client_capabilities()
      client_capabilities.workspace = client_capabilities.workspace or {}
      client_capabilities.workspace.diagnostic = client_capabilities.workspace.diagnostic or {
        refreshSupport = true,
      }
      client_capabilities.textDocument = client_capabilities.textDocument or {}
      client_capabilities.textDocument.diagnostic = client_capabilities.textDocument.diagnostic or {
        dynamicRegistration = false,
        relatedDocumentSupport = false,
      }
      -- client_capabilities.textDocument.semanticTokens = client_capabilities.textDocument.semanticTokens or {
      --   dynamicRegistration = false,
      --   tokenTypes = {
      --     "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
      --     "parameter", "variable", "property", "enumMember", "event", "function",
      --     "method", "macro", "keyword", "modifier", "comment", "string", "number",
      --     "regexp", "operator", "decorator"
      --   },
      --   tokenModifiers = {
      --     "declaration", "definition", "readonly", "static", "deprecated", "abstract",
      --     "async", "modification", "documentation", "defaultLibrary"
      --   },
      --   formats = { "relative" },
      --   requests = {
      --     range = true,
      --     full = {
      --       delta = true
      --     }
      --   },
      --   multilineTokenSupport = false,
      --   overlappingTokenSupport = false,
      --   serverCancelSupport = true,
      --   augmentsSyntaxTokens = true
      -- }

      local function refresh_attached_diagnostics(client)
        local tracked = attached_buffers[client.id]
        if not tracked then
          return
        end

        for bufnr in pairs(tracked) do
          request_document_diagnostics(client, bufnr)
        end
      end

      local handlers = vim.tbl_extend(
        "force",
        {
          ["workspace/diagnostic/refresh"] = function(_, _, ctx)
            local client = vim.lsp.get_client_by_id(ctx.client_id)
            if client then
              refresh_attached_diagnostics(client)
            end
            return vim.NIL
          end,
        },
        opts.handlers or {}
      )

      local user_on_attach = opts.on_attach

      local function track_buffer(client, bufnr)
        attached_buffers[client.id] = attached_buffers[client.id] or {}
        attached_buffers[client.id][bufnr] = true
        register_buffer_cleanup(client.id, bufnr)
      end

      local function default_on_attach(_, bufnr)
        vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr, desc = 'Go to definition' })
        vim.keymap.set('n', 'K', vim.lsp.buf.hover, { buffer = bufnr, desc = 'Hover' })
        vim.keymap.set('n', 'gr', vim.lsp.buf.references, { buffer = bufnr, desc = 'References' })
        vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { buffer = bufnr, desc = 'Rename' })
        vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { buffer = bufnr, desc = 'Code action' })
      end

      local function combined_on_attach(client, bufnr)
        track_buffer(client, bufnr)
        request_document_diagnostics(client, bufnr)
        
        -- Enable semantic tokens if server supports it (silently)
        -- if client.server_capabilities.semanticTokensProvider then
        --   vim.lsp.semantic_tokens.start(bufnr, client.id)
        -- end

        if user_on_attach then
          local ok, err = pcall(user_on_attach, client, bufnr)
          if not ok then
            vim.notify("mLua on_attach callback failed: " .. tostring(err), vim.log.levels.ERROR)
          end
        else
          default_on_attach(client, bufnr)
        end
      end

      -- Load predefines and workspace data before starting LSP
      local predefines = load_predefines(installed_dir) or {}
      local document_items = {}
      local entry_items = {}
      
      -- Only collect workspace documents/entries if we have a project root
      if is_project then
        document_items = collect_document_items(root_dir)
        entry_items = entries.collect_entry_items(installed_dir, root_dir, document_items) or {}
      end

      -- Always include current buffer
      local current_uri = vim.uri_from_bufnr(args.buf)
      local has_current = false
      for _, item in ipairs(document_items) do
        if item.uri == current_uri then
          has_current = true
          break
        end
      end

      if not has_current then
        local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
        local text = table.concat(lines, "\n")
        table.insert(document_items, {
          uri = current_uri,
          languageId = "mlua",
          version = 0,
          text = text,
        })
      end

      local init_options_table = {
        documentItems = document_items,
        entryItems = entry_items,
        modules = predefines.modules or {},
        globalVariables = predefines.globalVariables or {},
        globalFunctions = predefines.globalFunctions or {},
        stopwatch = false,
        profileMode = 0,
        capabilities = {
          completionCapability = {
            codeBlockScriptSnippetCompletion = true,
            codeBlockBTNodeSnippetCompletion = true,
            codeBlockComponentSnippetCompletion = true,
            codeBlockEventSnippetCompletion = true,
            codeBlockMethodSnippetCompletion = true,
            codeBlockHandlerSnippetCompletion = true,
            codeBlockItemSnippetCompletion = true,
            codeBlockLogicSnippetCompletion = true,
            codeBlockPropertySnippetCompletion = true,
            codeBlockStateSnippetCompletion = true,
            codeBlockStructSnippetCompletion = true,
            attributeCompletion = true,
            eventMethodCompletion = true,
            overrideMethodCompletion = true,
            overridePropertyCompletion = true,
            annotationCompletion = true,
            keywordCompletion = true,
            luaCodeCompletion = true,
            commitCharacterSupport = true,
          },
          definitionCapability = {},
          diagnosticCapability = {
            needExtendsDiagnostic = true,
            notEqualsNameDiagnostic = true,
            duplicateLocalDiagnostic = true,
            introduceGlobalVariableDiagnostic = true,
            parseErrorDiagnostic = true,
            annotationParseErrorDiagnostic = true,
            unavailableAttributeDiagnostic = true,
            unavailableTypeDiagnostic = true,
            unresolvedMemberDiagnostic = true,
            unresolvedSymbolDiagnostic = true,
            assignTypeMismatchDiagnostic = true,
            parameterTypeMismatchDiagnostic = true,
            deprecatedDiagnostic = true,
            overrideMemberMismatchDiagnostic = true,
            unavailableOptionalParameterDiagnostic = true,
            unavailableParameterNameDiagnostic = true,
            invalidAttributeArgumentDiagnostic = true,
            notAllowPropertyDefaultValueDiagnostic = true,
            assignToReadonlyDiagnostic = true,
            needPropertyDefaultValueDiagnostic = true,
            notEnoughArgumentDiagnostic = true,
            tooManyArgumentDiagnostic = true,
            duplicateMemberDiagnostic = true,
            cannotOverrideMemberDiagnostic = true,
            tableKeyTypeMismatchDiagnostic = true,
            duplicateAttributeDiagnostic = true,
            invalidEventHandlerParameterDiagnostic = true,
            unavailablePropertyNameDiagnostic = true,
            annotationTypeNotFoundDiagnostic = true,
            annotationParamNotFoundDiagnostic = true,
            unbalancedAssignmentDiagnostic = true,
            unexpectedReturnDiagnostic = true,
            needReturnDiagnostic = true,
            duplicateParamDiagnostic = true,
            returnTypeMismatchDiagnostic = true,
            expectedReturnValueDiagnostic = true,
          },
          documentSymbolCapability = {},
          hoverCapability = {},
          referenceCapability = {},
          semanticTokensCapability = {},
          signatureHelpCapability = {},
          typeDefinitionCapability = {},
          renameCapability = {},
          inlayHintCapability = {},
          documentFormattingCapability = {},
          documentRangeFormattingCapability = {},
        },
      }

      local init_options_json = vim.fn.json_encode(init_options_table)

      -- Prefer Bun over Node.js for better performance
      local runtime = 'node'
      if vim.fn.executable('bun') == 1 then
        runtime = 'bun'
        vim.notify("Using Bun runtime for mLua LSP", vim.log.levels.INFO)
      end

      vim.lsp.start({
        name = 'mlua',
        cmd = { runtime, server_path, '--stdio' },
        root_dir = root_dir,
        init_options = init_options_json,
        settings = opts.settings or {},
        handlers = handlers,
        flags = {
          debounce_text_changes = 150,
          allow_incremental_sync = true,
        },
        on_init = function(client, initialize_result)
          vim.notify("mLua LSP initialized successfully", vim.log.levels.INFO)
        end,
        on_attach = combined_on_attach,
        on_error = function(code, err)
          vim.notify("mLua LSP error [" .. tostring(code) .. "]: " .. tostring(err), vim.log.levels.ERROR)
        end,
        capabilities = client_capabilities,
      }, {
        bufnr = args.buf,
      })
    end,
  })

  vim.notify("mLua LSP v" .. installed_version .. " configured", vim.log.levels.INFO)
end

-- Install Tree-sitter parser and queries
function M.install_treesitter()
  local parser_dir = vim.fn.expand("~/tree-sitter-mlua")
  local parser_path = vim.fn.stdpath("data") .. "/site/parser/mlua.so"
  local queries_dir = vim.fn.stdpath("data") .. "/site/queries/mlua"
  
  -- Check if parser repo exists, if not, clone it
  if vim.fn.isdirectory(parser_dir) == 0 then
    vim.notify("Cloning tree-sitter-mlua repository...", vim.log.levels.INFO)
    local clone_cmd = string.format(
      'git clone https://github.com/seokgukim/tree-sitter-mlua.git "%s" 2>&1',
      parser_dir
    )
    local handle = io.popen(clone_cmd)
    local clone_output = handle:read("*a")
    local success = handle:close()
    
    if not success then
      vim.notify("Failed to clone repository:\n" .. clone_output, vim.log.levels.ERROR)
      return false
    end
    vim.notify("✓ Repository cloned successfully", vim.log.levels.INFO)
  end

  vim.notify("Setting up Tree-sitter parser for mLua...", vim.log.levels.INFO)

  -- Check if npm is installed
  local npm_check = io.popen("command -v npm 2>&1")
  local npm_path = npm_check:read("*a")
  npm_check:close()
  
  if npm_path == "" then
    vim.notify("Error: npm not found. Please install Node.js and npm first.", vim.log.levels.ERROR)
    return false
  end

  -- Install npm dependencies
  vim.notify("Installing npm dependencies...", vim.log.levels.INFO)
  local npm_install_cmd = string.format('cd "%s" && npm install 2>&1', parser_dir)
  local npm_handle = io.popen(npm_install_cmd)
  local npm_output = npm_handle:read("*a")
  local npm_success = npm_handle:close()
  
  if not npm_success then
    vim.notify("Failed to install npm dependencies:\n" .. npm_output, vim.log.levels.ERROR)
    return false
  end
  vim.notify("✓ Dependencies installed", vim.log.levels.INFO)

  -- Generate parser
  vim.notify("Generating parser...", vim.log.levels.INFO)
  local generate_cmd = string.format('cd "%s" && npx tree-sitter generate 2>&1', parser_dir)
  local gen_handle = io.popen(generate_cmd)
  local gen_output = gen_handle:read("*a")
  local gen_success = gen_handle:close()
  
  if not gen_success then
    vim.notify("Failed to generate parser:\n" .. gen_output, vim.log.levels.ERROR)
    return false
  end
  vim.notify("✓ Parser generated", vim.log.levels.INFO)

  -- Compile parser
  vim.notify("Compiling parser...", vim.log.levels.INFO)
  vim.fn.mkdir(vim.fn.stdpath("data") .. "/site/parser", "p")
  local compile_cmd = string.format(
    'cd "%s" && cc -o "%s" -I./src src/parser.c -shared -Os -lstdc++ -fPIC 2>&1',
    parser_dir,
    parser_path
  )
  
  local compile_handle = io.popen(compile_cmd)
  local compile_output = compile_handle:read("*a")
  local compile_success = compile_handle:close()

  if not compile_success or compile_output:match("error") then
    vim.notify("Failed to compile parser:\n" .. compile_output, vim.log.levels.ERROR)
    return false
  end
  vim.notify("✓ Parser compiled", vim.log.levels.INFO)

  -- Create queries directory and symlink
  vim.notify("Installing highlight queries...", vim.log.levels.INFO)
  vim.fn.mkdir(queries_dir, "p")
  local highlights_src = parser_dir .. "/queries/highlights.scm"
  local highlights_dst = queries_dir .. "/highlights.scm"
  
  -- Remove existing symlink/file
  if vim.fn.filereadable(highlights_dst) == 1 or vim.fn.isdirectory(highlights_dst) == 1 then
    os.remove(highlights_dst)
  end
  
  -- Create symlink
  local symlink_cmd
  if vim.fn.has("win32") == 1 then
    symlink_cmd = string.format('mklink "%s" "%s"', highlights_dst, highlights_src)
  else
    symlink_cmd = string.format('ln -sf "%s" "%s"', highlights_src, highlights_dst)
  end
  
  os.execute(symlink_cmd)
  vim.notify("✓ Queries installed", vim.log.levels.INFO)

  vim.notify("", vim.log.levels.INFO)
  vim.notify("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", vim.log.levels.INFO)
  vim.notify("✓ Tree-sitter setup complete!", vim.log.levels.INFO)
  vim.notify("  Parser: " .. parser_path, vim.log.levels.INFO)
  vim.notify("  Queries: " .. highlights_dst, vim.log.levels.INFO)
  vim.notify("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", vim.log.levels.INFO)
  vim.notify("Restart Neovim to activate Tree-sitter highlighting.", vim.log.levels.WARN)
  
  return true
end

vim.api.nvim_create_user_command('MluaInstall', M.download, { desc = 'Install mLua language server' })
vim.api.nvim_create_user_command('MluaUpdate', M.update, { desc = 'Update mLua language server' })
vim.api.nvim_create_user_command('MluaCheckVersion', M.check_version, { desc = 'Check mLua version' })
vim.api.nvim_create_user_command('MluaUninstall', M.uninstall, { desc = 'Uninstall mLua language server' })
vim.api.nvim_create_user_command('MluaTSInstall', M.install_treesitter, { desc = 'Install Tree-sitter parser for mLua' })
vim.api.nvim_create_user_command('MluaRestart', function()
  vim.lsp.stop_client(vim.lsp.get_clients({ name = 'mlua' }))
  vim.defer_fn(function()
    vim.cmd('edit')
  end, 500)
end, { desc = 'Restart mLua language server' })
vim.api.nvim_create_user_command('MluaDebug', function()
  require('mlua.debug').check_status()
end, { desc = 'Show mLua LSP debug information' })
vim.api.nvim_create_user_command('MluaLogs', function()
  require('mlua.debug').show_logs()
end, { desc = 'Show LSP logs' })
vim.api.nvim_create_user_command('MluaCapabilities', function()
  require('mlua.debug').show_capabilities()
end, { desc = 'Show full server capabilities' })

return M
