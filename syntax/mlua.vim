" Vim syntax file for mLua
" Language: mLua (MapleStory Worlds scripting language)
" Based on TextMate grammar from VS Code extension
" Note: This is a fallback - Tree-sitter parser is preferred

if exists("b:current_syntax")
  finish
endif

" Skip if Tree-sitter is handling highlighting
if get(b:, 'ts_highlight', 0)
  finish
endif

" Keywords (keyword.control)
syn keyword mluaKeyword break continue do else for if elseif goto return then repeat while until end
syn keyword mluaKeyword function local in not or and
syn keyword mluaKeyword script method property member extends override handler constructor operator emitter static readonly

" Constants (constant.language)
syn keyword mluaConstant false nil true _G

" Operators (keyword.operator)
syn match mluaOperator "[+\-*/%#]"
syn match mluaOperator "\^"
syn match mluaOperator "=="
syn match mluaOperator "\~="
syn match mluaOperator "<="
syn match mluaOperator ">="
syn match mluaOperator "<"
syn match mluaOperator ">"
syn match mluaOperator "="
syn match mluaOperator "\.\.\."
syn match mluaOperator "\.\."

" Attributes (entity.other.attribute)
syn match mluaAttribute "@[a-zA-Z][a-zA-Z0-9_]*"

" Numbers (constant.numeric)
syn match mluaNumber "\<\d\+ULL\>"
syn match mluaNumber "\<0[xX][0-9A-Fa-f]\+\>"
syn match mluaNumber "\<0[xX][0-9A-Fa-f]\+\.[0-9A-Fa-f]*\>"
syn match mluaNumber "\<0[xX][0-9A-Fa-f]\+[pP][-+]\?\d\+\>"
syn match mluaNumber "\<\d\+\>"
syn match mluaNumber "\<\d\+\.\d*\>"
syn match mluaNumber "\<\d\+\.\d*[eE][-+]\?\d\+\>"

" Strings (string.quoted)
syn region mluaString start=+'+ end=+'+ skip=+\\\\\|\\'+ contains=mluaEscape
syn region mluaString start=+"+ end=+"+ skip=+\\\\\|\\"+ contains=mluaEscape
syn region mluaString start="\[\z(=*\)\[" end="\]\z1\]"

" Escape sequences (constant.character.escape)
syn match mluaEscape "\\[abfnrtvz\\'\"\n]" contained
syn match mluaEscape "\\\d\{1,3}" contained
syn match mluaEscape "\\x[0-9A-Fa-f]\{2}" contained
syn match mluaEscape "\\u{[0-9A-Fa-f]\+}" contained
syn match mluaEscapeInvalid "\\." contained

" Comments (comment.line, comment.block)
syn match mluaComment "--.*$" contains=mluaAnnotation,mluaTodo
syn region mluaComment start="--\[\z(=*\)\[" end="\]\z1\]" contains=mluaTodo
syn keyword mluaTodo contained TODO FIXME XXX NOTE

" Annotations (keyword.other)
syn match mluaAnnotation contained "---\s*@\w\+.*$" contains=mluaAnnotationKeyword,mluaAnnotationType,mluaAnnotationParam
syn match mluaAnnotationKeyword contained "@type\|@param\|@return\|@description" 
syn match mluaAnnotationType contained "\s\+\w\+\(<[^>]\+>\)\?\s*" 
syn match mluaAnnotationParam contained "\s\+\w\+\s*"

" Script/Class declarations (entity.name.class)
syn match mluaClass "\%(script\s\+\)\@<=\w\+\(<[^>]\+>\)\?"
syn match mluaClass "\%(script\s\+\w\+\%(<[^>]\+>\)\?\s\+extends\s\+\)\@<=\w\+\(<[^>]\+>\)\?"
syn match mluaClass "\%(property\s\+\)\@<=\w\+\(<[^>]\+>\)\?"

" Type in method/operator declarations (entity.name.class)
syn match mluaType "\%(method\s\+\)\@<=\w\+\(<[^>]\+>\)\?"
syn match mluaType "\%(operator\s\+\)\@<=\w\+\(<[^>]\+>\)\?"
syn match mluaType "\%(,\s*\)\@<=\w\+\(<[^>]\+>\)\?"

" Function names (entity.name.function)
syn match mluaFunction "\%(function\s\+\)\@<=\w\+\ze\s*("
syn match mluaFunction "\%(method\s\+\w\+\s\+\)\@<=\w\+\ze\s*("
syn match mluaFunction "\%(operator\s\+\w\+\s\+\)\@<=\w\+\ze\s*("
syn match mluaFunction "\%(handler\s\+\)\@<=\w\+\ze\s*("
syn match mluaFunction "\%(constructor\s\+\)\@<=\w\+\ze\s*("
syn match mluaFunction "\%(emitter\s\+\)\@<=\w\+\ze\s*("

" Parameters (variable.parameter)
syn match mluaParameter "\%((\s*\)\@<=\w\+\%(\s*[,)]\)\@="
syn match mluaParameter "\%(,\s*\)\@<=\w\+\%(\s*[,)]\)\@="

" Members (variable.other.member)
syn match mluaMember "\%(member\s\+\)\@<=\w\+"
syn match mluaMember "\%(property\s\+\w\+\%(<[^>]\+>\)\?\s\+\)\@<=\w\+"

" Labels (entity.name.label)
syn match mluaLabel "::\w\+::"
syn match mluaGoto "\<goto\>\s\+\w\+" contains=mluaKeyword

" Shebang (comment.line.shebang)
syn match mluaShebang "\%^#!.*"

" Storage modifier
syn keyword mluaStorageModifier local

" Define highlighting
hi def link mluaKeyword Keyword
hi def link mluaStorageModifier StorageClass
hi def link mluaConstant Constant
hi def link mluaOperator Operator
hi def link mluaAttribute PreProc
hi def link mluaNumber Number
hi def link mluaString String
hi def link mluaEscape SpecialChar
hi def link mluaEscapeInvalid Error
hi def link mluaComment Comment
hi def link mluaTodo Todo
hi def link mluaAnnotation SpecialComment
hi def link mluaAnnotationKeyword Special
hi def link mluaAnnotationType Type
hi def link mluaAnnotationParam Identifier
hi def link mluaClass Type
hi def link mluaType Type
hi def link mluaFunction Function
hi def link mluaParameter Identifier
hi def link mluaMember Identifier
hi def link mluaLabel Label
hi def link mluaGoto Keyword
hi def link mluaShebang Comment

let b:current_syntax = "mlua"
