" mLua filetype plugin
" Language: mLua (MapleStory Worlds scripting language)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

" Check if Tree-sitter is available and has mlua parser
" If so, disable Vim syntax in favor of Tree-sitter
lua << EOF
  local ts_available = pcall(require, 'nvim-treesitter')
  local has_parser = false
  if ts_available then
    local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
    if ok and parsers.has_parser('mlua') then
      has_parser = true
      vim.b.ts_highlight = true
    end
  end
  vim.b.mlua_has_treesitter = has_parser
EOF

" Basic settings
setlocal expandtab
setlocal shiftwidth=4
setlocal softtabstop=4
setlocal tabstop=4
setlocal commentstring=--\ %s

" Optional folding settings (controlled by g:mlua_enable_folding)
if get(g:, 'mlua_enable_folding', 0)
  setlocal foldmethod=expr
  setlocal foldexpr=mlua#FoldExpr()
  setlocal foldtext=mlua#FoldText()
endif

" Match words for % navigation
if exists("loaded_matchit")
  let b:match_ignorecase = 0
  let b:match_words =
    \ '\<\%(do\|then\|else\|function\|repeat\|while\|method\|handler\|script\)\>:' .
    \ '\<\%(elseif\|else\)\>:' .
    \ '\<end\>,' .
    \ '\<repeat\>:\<until\>,' .
    \ '\%(--\)\=\[\(=*\)\[:]\1]'
  if get(g:, 'mlua_enable_folding', 0)
    let b:undo_ftplugin = "setl et< sw< sts< ts< cms< fdm< fde< fdt< | unlet! b:match_words b:match_ignorecase"
  else
    let b:undo_ftplugin = "setl et< sw< sts< ts< cms< | unlet! b:match_words b:match_ignorecase"
  endif
else
  if get(g:, 'mlua_enable_folding', 0)
    let b:undo_ftplugin = "setl et< sw< sts< ts< cms< fdm< fde< fdt<"
  else
    let b:undo_ftplugin = "setl et< sw< sts< ts< cms<"
  endif
endif

" Auto pairs and indentation patterns
let b:AutoPairs = {'(':')', '[':']', '{':'}', '"':'"', "'":"'"}

" Define fold functions (only if folding is enabled)
if get(g:, 'mlua_enable_folding', 0)
  function! mlua#FoldExpr()
    let line = getline(v:lnum)
    if line =~? '^\s*--region\>'
      return 'a1'
    elseif line =~? '^\s*--endregion\>'
      return 's1'
    elseif line =~? '\<\%(do\|then\|function\|repeat\|while\|method\|handler\|script\)\>'
      return 'a1'
    elseif line =~? '^\s*end\>'
      return 's1'
    endif
    return '='
  endfunction

  function! mlua#FoldText()
    let line = getline(v:foldstart)
    let nucolwidth = &fdc + &number * &numberwidth
    let windowwidth = winwidth(0) - nucolwidth - 3
    let foldedlinecount = v:foldend - v:foldstart
    let line = strpart(line, 0, windowwidth - 2 -len(foldedlinecount))
    let fillcharcount = windowwidth - len(line) - len(foldedlinecount)
    return line . '…' . repeat(" ",fillcharcount) . foldedlinecount . '…' . ' '
  endfunction
endif

" Configure semantic token highlighting only if Tree-sitter is not available
" Tree-sitter provides better native highlighting
if !get(b:, 'mlua_has_treesitter', 0)
lua << EOF
  -- Set up semantic token highlight groups for mLua
  vim.api.nvim_set_hl(0, '@lsp.type.class.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.type.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.parameter.mlua', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, '@lsp.type.variable.mlua', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, '@lsp.type.property.mlua', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, '@lsp.type.function.mlua', { link = 'Function' })
  vim.api.nvim_set_hl(0, '@lsp.type.method.mlua', { link = 'Function' })
  vim.api.nvim_set_hl(0, '@lsp.type.keyword.mlua', { link = 'Keyword' })
  vim.api.nvim_set_hl(0, '@lsp.type.string.mlua', { link = 'String' })
  vim.api.nvim_set_hl(0, '@lsp.type.number.mlua', { link = 'Number' })
  vim.api.nvim_set_hl(0, '@lsp.type.operator.mlua', { link = 'Operator' })
  vim.api.nvim_set_hl(0, '@lsp.type.comment.mlua', { link = 'Comment' })
  vim.api.nvim_set_hl(0, '@lsp.type.decorator.mlua', { link = 'PreProc' })
  vim.api.nvim_set_hl(0, '@lsp.type.namespace.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.enum.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.interface.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.struct.mlua', { link = 'Type' })
  vim.api.nvim_set_hl(0, '@lsp.type.enumMember.mlua', { link = 'Constant' })
  vim.api.nvim_set_hl(0, '@lsp.type.event.mlua', { link = 'Special' })
  
  -- Token modifiers
  vim.api.nvim_set_hl(0, '@lsp.mod.readonly.mlua', { link = 'Constant' })
  vim.api.nvim_set_hl(0, '@lsp.mod.static.mlua', { link = 'Special' })
  vim.api.nvim_set_hl(0, '@lsp.mod.deprecated.mlua', { link = 'Error' })
EOF
endif
