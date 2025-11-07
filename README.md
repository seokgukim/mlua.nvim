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


## Features

- 🔍 **LSP Integration** - Language server support with autocomplete, go-to-definition, hover, etc.
- 🌳 **Tree-sitter Support** - Syntax highlighting via Tree-sitter parser
- 📝 **Syntax Highlighting** - Fallback Vim syntax when Tree-sitter is unavailable
- 🔧 **Filetype Detection** - Automatic `.mlua` file recognition

## Requirements

- **Neovim** >= 0.9.0
- **Node.js** or **Bun** (for running the language server)
- [mLua LSP](https://github.com/seokgukim/mlua-lsp) (you can automatically install it to `~/.local/share/nvim/mlua-lsp` by running `:MluaInstall` command)
- Optional: **fd** or **ripgrep** (for faster file searching)
- Optional: [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) for Tree-sitter support
- Optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) for enhanced autocompletion
- Optional: [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) for Tree-sitter parser

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

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

If you want Tree-sitter support, you need to install the [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) parser:

```bash
# Clone the parser repository
git clone https://github.com/seokgukim/tree-sitter-mlua.git ~/tree-sitter-mlua

# Generate and compile the parser
cd ~/tree-sitter-mlua
npm install  # or: yarn
npx tree-sitter generate

# Compile and install
mkdir -p ~/.local/share/nvim/site/parser
cc -o ~/.local/share/nvim/site/parser/mlua.so -I./src src/parser.c -shared -Os -lstdc++ -fPIC
```

## Configuration

Default configuration:

```lua
require("mlua").setup({
  lsp = {
    enabled = true,
    cmd = nil, -- Auto-detected from LSP module
    capabilities = nil, -- Will use nvim-cmp capabilities if available
    on_attach = nil, -- Optional: your custom on_attach function
  },
  treesitter = {
    enabled = true,
    parser_path = vim.fn.expand("~/tree-sitter-mlua"), -- Path to tree-sitter-mlua repo
  },
})
```

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

The plugin provides commands for managing the mLua language server:

| Command | Description |
|---------|-------------|
| `:MluaInstall` | Install mLua language server |
| `:MluaUpdate` | Update mLua language server |
| `:MluaCheckVersion` | Check installed LSP version |
| `:MluaUninstall` | Uninstall mLua language server |
| `:MluaRestart` | Restart the language server |
| `:MluaDebug` | Show LSP debug information |
| `:MluaLogs` | Show LSP logs |
| `:MluaCapabilities` | Show full server capabilities |

### Buffer-local LSP Commands

When the LSP is attached to a buffer, these commands become available:

| Command | Description |
|---------|-------------|
| `:MluaDefinition` | Go to definition |
| `:MluaReferences` | Find references |
| `:MluaHover` | Show hover information |
| `:MluaRename` | Rename symbol under cursor |
| `:MluaFormat` | Format current document |
| `:MluaToggleInlayHints` | Toggle inlay hints on/off |

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
      vim.keymap.set("n", "gD", "<cmd>MluaDeclaration<cr>", opts)
      vim.keymap.set("n", "gr", "<cmd>MluaReferences<cr>", opts)
      vim.keymap.set("n", "gi", "<cmd>MluaImplementation<cr>", opts)
      vim.keymap.set("n", "<space>D", "<cmd>MluaTypeDefinition<cr>", opts)
      
      -- Information
      vim.keymap.set("n", "K", "<cmd>MluaHover<cr>", opts)
      vim.keymap.set("n", "<C-k>", "<cmd>MluaSignatureHelp<cr>", opts)
      
      -- Actions
      vim.keymap.set("n", "<space>rn", "<cmd>MluaRename<cr>", opts)
      vim.keymap.set("n", "<space>ca", "<cmd>MluaCodeAction<cr>", opts)
      vim.keymap.set("n", "<space>f", "<cmd>MluaFormat<cr>", opts)
      vim.keymap.set("n", "<space>h", "<cmd>MluaToggleInlayHints<cr>", opts)
    end
  end,
})
```

## Debug Commands

The plugin includes debug utilities accessible via `:lua require('mlua.debug')` or the provided commands.

Example usage:

```vim
:MluaDebug
:MluaLogs
:MluaCapabilities
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
│       ├── lsp.lua    # LSP configuration
│       ├── debug.lua  # Debug utilities
│       ├── entries.lua # LSP entry definitions
│       └── utils.lua  # Utility functions
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

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Projects

- [tree-sitter-mlua](https://github.com/seokgukim/tree-sitter-mlua) - Tree-sitter parser for mLua

## License

MIT License - see [LICENSE](LICENSE) file for details

## Acknowledgments

- MapleStory Worlds team for creating mLua
- Neovim and Tree-sitter communities
