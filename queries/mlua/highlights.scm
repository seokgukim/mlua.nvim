; Tree-sitter highlight queries for mLua

; Identifiers (fallback)
(identifier) @variable

; Keywords
"do" @keyword
"else" @keyword.conditional
"for" @keyword.repeat
"if" @keyword.conditional
"elseif" @keyword.conditional
"then" @keyword.conditional
"repeat" @keyword.repeat
"while" @keyword.repeat
"until" @keyword.repeat
"end" @keyword
"function" @keyword.function
"local" @keyword
"in" @keyword
"not" @keyword.operator
"or" @keyword.operator
"and" @keyword.operator
"goto" @keyword
"return" @keyword.return

; mLua keywords
"script" @keyword
"method" @keyword.function
"property" @keyword
"member" @keyword
"extends" @keyword
"override" @keyword.modifier
"handler" @keyword.function
"constructor" @keyword.function
"operator" @keyword.function
"emitter" @keyword.function
"static" @keyword.modifier
"readonly" @keyword.modifier



; Statements
(break_statement) @keyword
(continue_statement) @keyword

; Constants
(nil) @variable.builtin
(boolean) @boolean

; Numbers
(number) @number

; Strings
(string) @string
(escape_sequence) @string.escape

; Comments and Annotations
(comment) @comment



; Functions
(function_declaration name: (identifier) @function)
(method_declaration name: (identifier) @function.method)
(handler_declaration name: (identifier) @function)
(constructor_declaration name: (identifier) @constructor)
(emitter_declaration name: (identifier) @function)
(function_expression) @function

; Function calls
(function_call function: (identifier) @function.call)
(function_call function: (dot_index field: (identifier) @function.call))
(function_call function: (method_index method: (identifier) @function.method.call))

; Types and classes
(script_declaration name: (identifier) @type)
(type (identifier) @type)

; Parameters
(parameter name: (identifier) @variable.parameter)
(vararg) @variable.parameter

; Properties and members
(property_declaration name: (identifier) @variable.member)
(member_declaration name: (identifier) @variable.member)
(dot_index field: (identifier) @variable.member)

; Labels
(label name: (identifier) @label)
(goto_statement label: (identifier) @label)

; Operators
[
  "//="
  "+="
  "-="
  "*="
  "/="
  "%="
  "&="
  "|="
  "<<"
  ">>"
  "//"
  ".."
  "=="
  "~="
  "<="
  ">="
  "<"
  ">"
  "+"
  "-"
  "*"
  "/"
  "%"
  "#"
  "^"
  "&"
  "|"
  "~"
  "="
] @operator

; Punctuation
["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" ":"] @punctuation.delimiter
"." @punctuation.delimiter
