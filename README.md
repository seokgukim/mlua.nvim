# mLua.nvim

```
        .__                                .__
  _____ |  |  __ _______         _______  _|__| _____
 /     \|  | |  |  \__  \       /    \  \/ /  |/     \
|  Y Y  \  |_|  |  // __ \_    |   |  \   /|  |  Y Y  \
|__|_|  /____/____/(____  / /\ |___|  /\_/ |__|__|_|  /
      \/                \/  \/      \/              \/
```

![mlua demo](https://github.com/user-attachments/assets/0f8f2607-d507-45c1-96e0-27049b8d37bc)

Neovim plugin for [mLua](https://marketplace.visualstudio.com/items?itemName=msw.mlua) language support - the scripting language for MapleStory Worlds.

This is a wrapper plugin for the original mLua extension by MapleStory Worlds team.

Visit the MapleStory Worlds [mLua documentation](https://maplestoryworlds-creators.nexon.com/en/docs?postId=1287) for language details.

For more information, see the `./doc/mlua.nvim.txt` file.

## Features

- 🔍 **LSP Integration** - Language server support with autocomplete, go-to-definition, hover, etc.
- 📂 **Full Workspace Loading** - VS Code-style workspace initialization with all files loaded at startup
- 👁️ **ExecSpace Decorations** - Virtual text showing Client/Server/Multicast execution context
- 🧩 **Override Hints** - Inlay-hint virtual text marks properties and methods that override extended scripts
- 📝 **File Watching** - Automatic notifications to LSP when files are created/deleted/modified
- 🌳 **Tree-sitter Support** - Syntax highlighting via Tree-sitter parser
- 📝 **Syntax Highlighting** - Fallback Vim syntax when Tree-sitter is unavailable
- 🔧 **Filetype Detection** - Automatic `.mlua` file recognition

## Requirements

- **Neovim** >= 0.11.0 (uses `vim.lsp.config` / `vim.lsp.enable` API)
- **Node.js** >= 16.0.0 (for running the language server)
- Optional: [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) for Tree-sitter support
- Optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for enhanced autocompletion

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

**Stable version (main branch):**

```lua
{
  "seokgukim/mlua.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter", -- optional, for Tree-sitter support
    "hrsh7th/nvim-cmp", -- optional, for autocompletion
    "hrsh7th/cmp-nvim-lsp", -- optional, for LSP completion source
  },
  ft = "mlua", -- lazy load on mlua filetype
  config = function()
    require("mlua").setup({
      -- Your configuration here (see Configuration section)
    })
  end,
}
```

**Development version (dev branch) — JS proxy layer, Neovim 0.11+ required:**

```lua
{
  "seokgukim/mlua.nvim",
  branch = "dev",
  dependencies = {
    "nvim-treesitter/nvim-treesitter", -- optional
  },
  ft = "mlua",
  config = function()
    require("mlua").setup({})
  end,
}
```

## Tree-sitter Parser Installation

The Tree-sitter parser for mLua ([tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua)) must be built and installed manually.

**Prerequisites:** Git, Node.js, npm, C compiler (gcc or clang; cl.exe on Windows)

```bash
# 1. Clone and build the parser
git clone https://github.com/seokgukim/tree-sitter-mlua.git ~/tree-sitter-mlua
cd ~/tree-sitter-mlua
npm install
npx tree-sitter generate

# 2. Compile and install the parser binary
mkdir -p ~/.local/share/nvim/site/parser
cc -o ~/.local/share/nvim/site/parser/mlua.so \
   -I./src src/parser.c \
   -shared -Os -lstdc++ -fPIC
```

Then point `parser_path` to the cloned directory so mlua.nvim can find the highlight queries:

```lua
require("mlua").setup({
  treesitter = {
    enabled = true,
    parser_path = vim.fn.expand("~/tree-sitter-mlua"), -- default
  },
})
```

Restart Neovim after installation.

If you skip Tree-sitter installation, the plugin falls back to the bundled Vim syntax (`syntax/mlua.vim`) automatically.

## Configuration

Default configuration:

```lua
require("mlua").setup({
  lsp = {
    enabled = true,
    cmd = nil, -- Auto-detected: runs javascript/mlua-server.js via Node.js
    capabilities = nil, -- Will use nvim-cmp capabilities if available
    on_attach = nil, -- Optional: your custom on_attach function
    execspace_decorations = true, -- Enable ExecSpace virtual text (Client/Server/etc)
  },
  treesitter = {
    enabled = true,
    parser_path = vim.fn.expand("~/tree-sitter-mlua"), -- Path to tree-sitter-mlua repo
  },
  keymaps = {
    -- Set to false to disable a specific keymap, or change the key
    hover = "K",
    definition = "gd",
    references = "gr",
    declaration = "gD",
    implementation = "gi",
    rename = "<leader>rn",
    code_action = "<leader>ca",
    format = "<leader>f",
    toggle_inlay_hints = "<leader>h",
  },
  -- Or set keymaps = false to disable all default keymaps
})
```

### How It Works

The plugin uses a **JS proxy layer** that sits between Neovim and the mLua language server:

```
Neovim (LSP client)
      │  stdio (JSON-RPC)
      ▼
javascript/mlua-server.js   ← entry point
      │
javascript/proxy.js         ← protocol adapter
  ├─ Intercepts initialize → injects workspace files via initializationOptions
  ├─ Handles pull diagnostics (textDocument/diagnostic) from cache
  ├─ Bridges push-only clients via textDocument/publishDiagnostics
  ├─ Translates msw.protocol.* custom messages to standard LSP
  └─ Debounces file-change triggered diagnostic refreshes
      │
javascript/indexer.js       ← workspace indexer (with disk cache)
javascript/watcher.js       ← fs.watch for .mlua / .ent files
      │
msw.mlua VS Code extension  ← actual language server
```

1. **On project open**: `indexer.js` scans all `.mlua` files under the project root, including `.d.mlua`, and injects them into `initializationOptions` — no extra round-trips needed. Other filetypes such as `.map`, `.ui`, `.model`, and `.codeblock` are skipped to avoid excessive indexing.
2. **Disk cache**: Index results are cached by snapshot (file count + size + mtime), so restarts are near-instant on unchanged projects. The cache schema is bumped when indexing rules change.
3. **File watching**: `watcher.js` monitors `.mlua` and `.ent` files and triggers re-diagnostics on change
4. **Diagnostic pull/push**: The proxy detects whether the client supports pull diagnostics (`textDocument/diagnostic`) and skips the redundant `textDocument/publishDiagnostics` push for pull-capable clients (Neovim 0.10+), preventing double rendering
5. **Inlay hints**: The proxy forwards `textDocument/inlayHint` to the base mLua server so override virtual text for extended-script properties and methods is rendered by Neovim

### Custom LSP on_attach

```lua
require("mlua").setup({
  lsp = {
    on_attach = function(client, bufnr)
      -- Your custom on_attach logic here
      print("mLua LSP attached to buffer " .. bufnr)
    end,
  },
})
```

### Disable Tree-sitter

```lua
require("mlua").setup({
  treesitter = {
    enabled = false, -- Use Vim syntax highlighting instead
  },
})
```

## Commands

The plugin provides a unified `:Mlua` command with subcommands:

### LSP Management Commands

| Command                     | Description                                                    |
| --------------------------- | -------------------------------------------------------------- |
| `:Mlua install`             | Install mLua language server                                   |
| `:Mlua update`              | Update mLua language server to latest version                  |
| `:Mlua version`             | Check installed vs latest LSP version                          |
| `:Mlua uninstall`           | Uninstall mLua language server                                 |
| `:Mlua restart`             | Restart the language server                                    |
| `:Mlua reload`              | Reload all workspace files (re-index and re-load)              |
| `:Mlua execspace`           | Toggle ExecSpace decorations on/off                            |
| `:Mlua execspacerefresh`    | Refresh ExecSpace decorations for all buffers                  |

### LSP Action Commands

| Command                     | Description                                                    |
| --------------------------- | -------------------------------------------------------------- |
| `:Mlua hover`               | Show hover information                                         |
| `:Mlua definition`          | Go to definition                                               |
| `:Mlua references`          | Find references                                                |
| `:Mlua declaration`         | Go to declaration                                              |
| `:Mlua implementation`      | Go to implementation                                           |
| `:Mlua rename`              | Rename symbol                                                  |
| `:Mlua codeaction`          | Code action                                                    |
| `:Mlua format`              | Format document                                                |
| `:Mlua inlayhints`          | Toggle inlay hints                                             |

### Default LSP Keybindings (mlua buffers only)

When the mLua LSP attaches to a buffer, these keybindings are automatically set:

| Key          | Action                  | Description            |
| ------------ | ----------------------- | ---------------------- |
| `K`          | `vim.lsp.buf.hover`     | Show hover information |
| `gd`         | `vim.lsp.buf.definition`| Go to definition       |
| `gr`         | `vim.lsp.buf.references`| Find references        |
| `gD`         | `vim.lsp.buf.declaration`| Go to declaration     |
| `gi`         | `vim.lsp.buf.implementation`| Go to implementation |
| `<leader>rn` | `vim.lsp.buf.rename`    | Rename symbol          |
| `<leader>ca` | `vim.lsp.buf.code_action`| Code action           |
| `<leader>f`  | `vim.lsp.buf.format`    | Format document        |
| `<leader>h`  | Toggle inlay hints      | Toggle inlay hints     |

### Customizing Keybindings

You can customize keybindings via the `keymaps` config:

```lua
require("mlua").setup({
  keymaps = {
    hover = "K",           -- Keep default
    definition = "gd",     -- Keep default
    references = "<leader>gr", -- Custom key
    rename = false,        -- Disable this keymap
    -- ... other keys
  },
})
```

To disable all default keymaps:

```lua
require("mlua").setup({
  keymaps = false,
})
```

## Performance

The JS proxy layer significantly improves startup and runtime performance:

- **Disk-cached index**: File contents, entry items, and predefines are cached by workspace snapshot (SHA-256 keyed by file count + total size + max mtime). Subsequent restarts on unchanged projects skip re-scanning entirely
- **Debounced re-diagnostics**: File changes trigger a single 800ms debounced diagnostic refresh rather than per-file requests
- **No redundant pushes**: Pull-capable clients (Neovim 0.10+) receive diagnostics only via `textDocument/diagnostic`, avoiding double rendering from simultaneous push+pull delivery

## Debug Commands

The plugin includes debug utilities accessible via `:lua require('mlua.debug')`.

Example usage:

```vim
:lua require('mlua.debug').check_status()
:lua require('mlua.debug').show_logs()
:lua require('mlua.debug').show_capabilities()
```

## File Structure

```
mlua.nvim/
├── ftdetect/          # Filetype detection for .mlua files
│   └── mlua.vim
├── ftplugin/          # Filetype-specific settings
│   └── mlua.vim
├── lua/
│   ├── mlua.lua       # Main plugin module
│   └── mlua/
│       ├── lsp.lua        # LSP client setup (vim.lsp.config/enable), pull-diagnostic handler
│       ├── execspace.lua  # ExecSpace decorations (Client/Server virtual text)
│       ├── workspace.lua  # Workspace reload via custom notification
│       ├── installer.lua  # VS Code extension download/install/update
│       ├── debug.lua      # Debug utilities
│       └── utils.lua      # Utility functions (find_root, etc.)
├── javascript/            # JS proxy layer (Node.js)
│   ├── mlua-server.js     # Entry point; resolves install dir, delegates to proxy.js
│   ├── proxy.js           # Protocol adapter between Neovim and the VS Code extension
│   ├── indexer.js         # Workspace indexer (documents, entries, predefines)
│   ├── cache.js           # Snapshot-based disk cache for indexer results
│   └── watcher.js         # fs.watch for .mlua / .ent file changes
├── queries/           # Tree-sitter queries
│   └── mlua/
│       └── highlights.scm
├── syntax/            # Vim syntax highlighting (fallback)
│   └── mlua.vim
└── plugin/
    └── mlua.lua       # Plugin initialization
```

## Language Features

### Supported mLua Constructs

- ✅ `script` declarations with inheritance
- ✅ `property` declarations (static/readonly)
- ✅ `method` declarations (static/override)
- ✅ `handler` event handlers
- ✅ `constructor` declarations
- ✅ Standard Lua syntax (functions, control flow, etc.)

### LSP Features

- Autocompletion for mLua keywords and constructs
- Go to definition
- Hover documentation
- Rename refactoring
- Find references
- Code actions
- Document formatting
- Inlay hints

## Notes

### Full Workspace Loading

When you open a project, all `.mlua` files under the project root are indexed and injected into the language server at startup via `initializationOptions`, including `.d.mlua` definitions. Other filetypes such as `.map`, `.ui`, `.model`, and `.codeblock` are skipped because injecting those files creates excessive indexing without helping script language features. On large projects the initial scan may take a moment, but subsequent restarts are near-instant thanks to the disk cache.

### Window Compatibility

Since MapleStory Worlds is designed for Windows, **I strongly recommend running Neovim on Windows natively, not in WSL.**
Running in WSL can cause significant I/O overhead and delays with the language server.

How do I know? BRUTE FORCE.

### Not Fully Compatible with MSW

This is a personal project and not an official one from the MSW team.

**Note:** Debugging support has been removed from this plugin. The MSW debugger uses a binary protocol instead of standard JSON-RPC DAP, making it incompatible with nvim-dap. A separate custom debug plugin may be developed in the future.

Someday maybe...

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Projects

- [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) - Tree-sitter parser for mLua

## License

MIT License - see [LICENSE](LICENSE) file for details

## Acknowledgments

- MapleStory Worlds team for creating mLua
- Neovim and Tree-sitter communities
