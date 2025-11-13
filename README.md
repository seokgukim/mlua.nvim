# mLua.nvim

```
        .__                                .__
  _____ |  |  __ _______         _______  _|__| _____
 /     \|  | |  |  \__  \       /    \  \/ /  |/     \
|  Y Y  \  |_|  |  // __ \_    |   |  \   /|  |  Y Y  \
|__|_|  /____/____/(____  / /\ |___|  /\_/ |__|__|_|  /
      \/                \/  \/      \/              \/
```

Neovim plugin for [mLua](https://marketplace.visualstudio.com/items?itemName=msw.mlua) language support - the scripting language for MapleStory Worlds.

This is a wrapper plugin for the original mLua extension by MapleStory Worlds team.

Visit the MapleStory Worlds [mLua documentation](https://maplestoryworlds-creators.nexon.com/en/docs?postId=1287) for language details.

For more information, see the `./doc/mlua.nvim.txt` file.

## Features

- 🔍 **LSP Integration** - Language server support with autocomplete, go-to-definition, hover, etc.
- � **Event-Driven Loading** - Smart, on-demand workspace file loading via LSP protocol
- 🔎 **Fuzzy Matching** - Intelligent file resolution for cross-file references
- �🌳 **Tree-sitter Support** - Syntax highlighting via Tree-sitter parser
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
    max_matches = 3, -- Max fuzzy matches per token
    max_modified_lines = 5, -- Max modified lines to consider for re-indexing
    trigger_count = 4, -- Triggers load file after N characters typed
  },
  treesitter = {
    enabled = true,
    parser_path = vim.fn.expand("~/tree-sitter-mlua"), -- Path to tree-sitter-mlua repo
  },
})
```

### How It Works

The plugin uses an **event-driven approach** similar to VS Code:

1. **On file open**: LSP starts with minimal data (current file + predefines)
2. **Workspace indexing**: Files are indexed in background (basename → path mapping)
3. **On InsertLeave or type several characters**: Plugin extracts tokens (class names, types) from your code
4. **Fuzzy matching**: Tokens are matched against indexed files using fuzzy search
5. **Load via didOpen**: Matched files are sent to LSP for cross-file features

**No polling, no aggressive loading** - files load only when you finish typing, keeping things fast and predictable.

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

The event-driven system is designed to be lightweight and efficient:

- **Fast startup**: Only current file + predefines loaded initially
- **No polling**: Files load only on `InsertLeave` event, or when several types occur of edits are made
- **Fuzzy matching**: Smart file resolution without exact name matching
- **No cache eviction**: Once loaded, files stay in memory
- **Predictable**: You control when files load (by finishing typing)

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
│       ├── workspace.lua  # Event-driven file loading with fuzzy matching
│       ├── predefines.lua # Predefines loader with JSON compression
│       ├── debug.lua      # Debug utilities
│       ├── entries.lua    # LSP entry definitions
│       └── utils.lua      # Utility functions (fuzzy matching, etc.)
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

### Lazy Loading

The plugin uses lazy loading for workspace files to improve performance.
When you open a file initially, the IntelliSense may show errors for not-yet-loaded information.
This is resolved automatically as you edit - the plugin loads related files on demand when you finish typing.

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
