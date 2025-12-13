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
- 📝 **File Watching** - Automatic notifications to LSP when files are created/deleted/modified
- 🌳 **Tree-sitter Support** - Syntax highlighting via Tree-sitter parser
- 📝 **Syntax Highlighting** - Fallback Vim syntax when Tree-sitter is unavailable
- 🔧 **Filetype Detection** - Automatic `.mlua` file recognition

## Requirements

- **Neovim** >= 0.9.0
- **Node.js** (for running the language server)
- [mLua LSP](https://github.com/seokgukim/mlua-lsp) (you can automatically install it to `~/.local/share/nvim/mlua-lsp` by running `:MluaInstall` command)
- Optional: [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) for Tree-sitter support
- Optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for enhanced autocompletion
- Optional: [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) for Tree-sitter parser

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

## Tree-sitter Parser Installation

For enhanced syntax highlighting with Tree-sitter, simply run:

```vim
:MluaTSInstall
```

This command will automatically:

- Clone the [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) repository
- Install npm dependencies
- Generate the parser
- Compile the parser for your system
- Set up highlight queries

**Requirements:**

- Git
- Node.js and npm
- C compiler (gcc or cland, cl.exe on Windows)

**Note:** Restart Neovim after installation to activate Tree-sitter highlighting.

## Configuration

Default configuration:

```lua
require("mlua").setup({
  lsp = {
    enabled = true,
    cmd = nil, -- Auto-detected from LSP module
    capabilities = nil, -- Will use nvim-cmp capabilities if available
    on_attach = nil, -- Optional: your custom on_attach function
    execspace_decorations = true, -- Enable ExecSpace virtual text (Client/Server/etc)
  },
  treesitter = {
    enabled = true,
    parser_path = vim.fn.expand("~/tree-sitter-mlua"), -- Path to tree-sitter-mlua repo
  },
})
```

### How It Works

The plugin now uses a **VS Code-style approach**:

1. **On project open**: All `.mlua` files are loaded into the LSP server (like VS Code)
2. **File watching**: New/deleted/modified files notify the LSP automatically
3. **Entry files**: `.map`, `.ui`, `.model`, `.collisiongroupset` files are monitored for changes
4. **ExecSpace decorations**: Virtual text shows method execution context (Client/Server/etc)

This provides **complete workspace awareness** from the start, matching VS Code's behavior.

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

### LSP Management

| Command             | Description                                                    |
| ------------------- | -------------------------------------------------------------- |
| `:MluaInstall`      | Install mLua language server                                   |
| `:MluaUpdate`       | Update mLua language server to latest version                  |
| `:MluaCheckVersion` | Check installed vs latest LSP version                          |
| `:MluaUninstall`    | Uninstall mLua language server                                 |
| `:MluaTSInstall`    | Automatically install Tree-sitter parser (clone, build, setup) |
| `:MluaRestart`      | Restart the language server                                    |
| `:MluaReloadWorkspace` | Reload all workspace files (re-index and re-load)           |
| `:MluaToggleExecSpace` | Toggle ExecSpace decorations on/off                         |
| `:MluaRefreshExecSpace` | Refresh ExecSpace decorations for all buffers              |

### Buffer-local LSP Commands

When a `.mlua` file is opened with LSP attached, these commands become available:

| Command                 | Description                |
| ----------------------- | -------------------------- |
| `:MluaDefinition`       | Go to definition           |
| `:MluaReferences`       | Find references            |
| `:MluaHover`            | Show hover information     |
| `:MluaRename`           | Rename symbol under cursor |
| `:MluaFormat`           | Format current document    |
| `:MluaToggleInlayHints` | Toggle inlay hints on/off  |

**Note:** No keybindings are set by default. You can map these commands to your preferred keys:

```lua
-- Example keymaps in your config
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == "mlua" then
      local bufnr = args.buf
      local opts = { buffer = bufnr, noremap = true, silent = true }

      -- Navigation
      vim.keymap.set("n", "gd", "<cmd>MluaDefinition<cr>", opts)
      vim.keymap.set("n", "gr", "<cmd>MluaReferences<cr>", opts)

      -- Information
      vim.keymap.set("n", "K", "<cmd>MluaHover<cr>", opts)

      -- Actions
      vim.keymap.set("n", "<space>rn", "<cmd>MluaRename<cr>", opts)
      vim.keymap.set("n", "<space>f", "<cmd>MluaFormat<cr>", opts)
      vim.keymap.set("n", "<space>h", "<cmd>MluaToggleInlayHints<cr>", opts)
    end
  end,
})
```

## Performance

The VS Code-style approach loads all workspace files at startup:

- **Full context**: All files loaded initially, complete IntelliSense from start
- **File watching**: Changes detected automatically via Neovim autocmds
- **Async loading**: Files loaded in batches to avoid blocking UI
- **Cached predefines**: Predefines cached to disk for faster restarts

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
│       ├── lsp.lua        # LSP client setup and commands
│       ├── document.lua   # Document service (file watching, lifecycle notifications)
│       ├── execspace.lua  # ExecSpace decorations (Client/Server virtual text)
│       ├── workspace.lua  # Workspace file loading and indexing
│       ├── predefines.lua # Predefines loader with JSON compression
│       ├── entries.lua    # Entry file parsing (.map, .ui, .model, etc.)
│       ├── debug.lua      # Debug utilities
│       └── utils.lua      # Utility functions (path handling, fuzzy matching, etc.)
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

When you open a project, all `.mlua` files are loaded into the LSP server at startup.
This matches VS Code's behavior and provides complete IntelliSense from the start.
For very large projects, the initial load may take a moment, but you'll see a progress notification.

### Window Compatibility

Since MapleStory Worlds is designed for Windows, **I strongly recommend running Neovim on Windows natively, not in WSL.**
Running in WSL can cause significant I/O overhead and delays with the language server.

How do I know? BRUTE FORCE.

### Not Fully Compatible with MSW

This is a personal project and not an official one from the MSW team.
It does not support debugging features or "Open in MSW Client" functionality.

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
