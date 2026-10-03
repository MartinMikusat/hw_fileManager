package file_manager

import "core:odin/tokenizer"
import "core:path/filepath"
import "core:strings"

Syntax_Kind :: enum u8 {
	Plain,
	Keyword,
	Type,
	Function,
	String,
	Number,
	Comment,
	Directive,
	Tag,
	Property,
}

Language :: enum {
	None,
	Odin,
	Json,
	Script,
	Css,
	Markup,
	Shell,
	Markdown,
}

highlight_language :: proc(name: string) -> Language {
	switch strings.to_lower(filepath.ext(name), context.temp_allocator) {
	case ".odin":
		return .Odin
	case ".json", ".jsonc", ".webmanifest":
		return .Json
	case ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx":
		return .Script
	case ".css":
		return .Css
	case ".html", ".htm", ".xml", ".svg", ".plist":
		return .Markup
	case ".sh", ".bash", ".zsh":
		return .Shell
	case ".md", ".markdown":
		return .Markdown
	}
	return .None
}

SCRIPT_KEYWORDS :: []string{
	"async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
	"else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import",
	"in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly",
	"return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
	"void", "while", "with", "yield",
}

SHELL_KEYWORDS :: []string{
	"case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for", "function", "if", "in", "local",
	"read", "return", "select", "set", "shift", "then", "unset", "until", "while", "break", "continue", "source",
}

ODIN_BUILTIN_TYPES :: []string{
	"bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32", "u64",
	"u128", "uintptr", "f16", "f32", "f64", "complex32", "complex64", "complex128", "quaternion64", "quaternion128",
	"quaternion256", "string", "cstring", "rune", "rawptr", "any", "typeid", "byte",
}

// highlight_kinds classifies every byte of text for the language. Cross-line
// tokens (block comments, raw strings) are handled because the whole preview text
// is scanned at once.
highlight_kinds :: proc(language: Language, text: string, allocator := context.allocator) -> []Syntax_Kind {
	kinds := make([]Syntax_Kind, len(text), allocator)
	switch language {
	case .None:
	case .Odin:   highlight_odin(text, kinds)
	case .Json:   highlight_json(text, kinds)
	case .Script: highlight_script(text, kinds)
	case .Css:    highlight_css(text, kinds)
	case .Markup: highlight_markup(text, kinds)
	case .Shell:  highlight_shell(text, kinds)
	case .Markdown: highlight_markdown(text, kinds)
	}
	return kinds
}

highlight_paint :: proc(kinds: []Syntax_Kind, start, end: int, kind: Syntax_Kind) {
	for index in max(start, 0) ..< min(end, len(kinds)) {kinds[index] = kind}
}

highlight_contains :: proc(words: []string, word: string) -> bool {
	for candidate in words {
		if candidate == word {return true}
	}
	return false
}

highlight_is_ident_start :: proc(value: u8) -> bool {
	return value == '_' || value == '$' || (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || value >= 0x80
}

highlight_is_ident :: proc(value: u8) -> bool {
	return highlight_is_ident_start(value) || (value >= '0' && value <= '9')
}

highlight_is_digit :: proc(value: u8) -> bool {
	return value >= '0' && value <= '9'
}

// highlight_next_char is the first non-blank byte at or after index, or 0.
highlight_next_char :: proc(text: string, index: int) -> u8 {
	for position in index ..< len(text) {
		if text[position] != ' ' && text[position] != '\n' {return text[position]}
	}
	return 0
}

highlight_odin :: proc(text: string, kinds: []Syntax_Kind) {
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, text, "", proc(pos: tokenizer.Pos, format: string, args: ..any) {})
	previous := tokenizer.Token_Kind.Invalid
	for _ in 0 ..< len(text)+1 {
		token := tokenizer.scan(&scanner)
		if token.kind == .EOF {break}
		start, end := token.pos.offset, token.pos.offset+len(token.text)
		switch {
		case token.kind == .Comment || token.kind == .File_Tag:
			highlight_paint(kinds, start, end, .Comment)
		case token.kind == .String || token.kind == .Rune:
			highlight_paint(kinds, start, end, .String)
		case token.kind == .Integer || token.kind == .Float || token.kind == .Imag:
			highlight_paint(kinds, start, end, .Number)
		case token.kind == .Hash || token.kind == .At:
			highlight_paint(kinds, start, end, .Directive)
		case token.kind == .Ident:
			switch {
			case previous == .Hash || previous == .At:
				highlight_paint(kinds, start, end, .Directive)
			case highlight_contains(ODIN_BUILTIN_TYPES, token.text):
				highlight_paint(kinds, start, end, .Type)
			case highlight_next_char(text, end) == '(':
				highlight_paint(kinds, start, end, .Function)
			}
		case tokenizer.is_keyword(token.kind):
			highlight_paint(kinds, start, end, .Keyword)
		}
		previous = token.kind
	}
}

// highlight_string_end returns the index after the string that opens at start,
// ending at the closing quote, a backslash-escaped quote excepted, or at a line
// break unless multiline.
highlight_string_end :: proc(text: string, start: int, multiline: bool) -> int {
	quote := text[start]
	index := start+1
	for index < len(text) {
		switch {
		case text[index] == '\\':
			index += 2
			continue
		case text[index] == quote:
			return index+1
		case text[index] == '\n' && !multiline:
			return index
		}
		index += 1
	}
	return len(text)
}

highlight_number_end :: proc(text: string, start: int) -> int {
	index := start
	for index < len(text) && (highlight_is_ident(text[index]) || text[index] == '.') {index += 1}
	return index
}

highlight_json :: proc(text: string, kinds: []Syntax_Kind) {
	index := 0
	for index < len(text) {
		value := text[index]
		switch {
		case value == '"':
			end := highlight_string_end(text, index, false)
			kind := highlight_next_char(text, end) == ':' ? Syntax_Kind.Property : .String
			highlight_paint(kinds, index, end, kind)
			index = end
		case highlight_is_digit(value) || (value == '-' && index+1 < len(text) && highlight_is_digit(text[index+1])):
			end := highlight_number_end(text, index+1)
			highlight_paint(kinds, index, end, .Number)
			index = end
		case highlight_is_ident_start(value):
			end := index
			for end < len(text) && highlight_is_ident(text[end]) {end += 1}
			word := text[index:end]
			if word == "true" || word == "false" || word == "null" {highlight_paint(kinds, index, end, .Keyword)}
			index = end
		case value == '/' && index+1 < len(text) && (text[index+1] == '/' || text[index+1] == '*'):
			index = highlight_comment(text, kinds, index)
		case:
			index += 1
		}
	}
}

// highlight_comment paints the // or /* comment at start and returns its end.
highlight_comment :: proc(text: string, kinds: []Syntax_Kind, start: int) -> int {
	end := len(text)
	if text[start+1] == '/' {
		if newline := strings.index_byte(text[start:], '\n'); newline >= 0 {end = start+newline}
	} else if close := strings.index(text[start+2:], "*/"); close >= 0 {
		end = start+2+close+2
	}
	highlight_paint(kinds, start, end, .Comment)
	return end
}

highlight_script :: proc(text: string, kinds: []Syntax_Kind) {
	index := 0
	for index < len(text) {
		value := text[index]
		switch {
		case value == '"' || value == '\'' || value == '`':
			end := highlight_string_end(text, index, value == '`')
			highlight_paint(kinds, index, end, .String)
			index = end
		case value == '/' && index+1 < len(text) && (text[index+1] == '/' || text[index+1] == '*'):
			index = highlight_comment(text, kinds, index)
		case highlight_is_digit(value):
			end := highlight_number_end(text, index)
			highlight_paint(kinds, index, end, .Number)
			index = end
		case highlight_is_ident_start(value):
			end := index
			for end < len(text) && highlight_is_ident(text[end]) {end += 1}
			word := text[index:end]
			switch {
			case highlight_contains(SCRIPT_KEYWORDS, word):
				highlight_paint(kinds, index, end, .Keyword)
			case highlight_next_char(text, end) == '(':
				highlight_paint(kinds, index, end, .Function)
			case word[0] >= 'A' && word[0] <= 'Z':
				highlight_paint(kinds, index, end, .Type)
			}
			index = end
		case:
			index += 1
		}
	}
}

highlight_css :: proc(text: string, kinds: []Syntax_Kind) {
	index, depth := 0, 0
	for index < len(text) {
		value := text[index]
		switch {
		case value == '{':
			depth += 1
			index += 1
		case value == '}':
			depth = max(depth-1, 0)
			index += 1
		case value == '"' || value == '\'':
			end := highlight_string_end(text, index, false)
			highlight_paint(kinds, index, end, .String)
			index = end
		case value == '/' && index+1 < len(text) && text[index+1] == '*':
			index = highlight_comment(text, kinds, index)
		case value == '@':
			end := index+1
			for end < len(text) && (highlight_is_ident(text[end]) || text[end] == '-') {end += 1}
			highlight_paint(kinds, index, end, .Directive)
			index = end
		case value == '#' && depth > 0:
			end := index+1
			for end < len(text) && highlight_is_ident(text[end]) {end += 1}
			highlight_paint(kinds, index, end, .Number)
			index = end
		case highlight_is_digit(value) || (value == '.' && index+1 < len(text) && highlight_is_digit(text[index+1]) && depth > 0):
			end := highlight_number_end(text, index+1)
			highlight_paint(kinds, index, end, .Number)
			index = end
		case highlight_is_ident_start(value) || value == '-' || ((value == '.' || value == '#') && depth == 0):
			end := index+1
			for end < len(text) && (highlight_is_ident(text[end]) || text[end] == '-') {end += 1}
			switch {
			case depth == 0:
				highlight_paint(kinds, index, end, .Type)
			case highlight_next_char(text, end) == ':':
				highlight_paint(kinds, index, end, .Property)
			case highlight_next_char(text, end) == '(':
				highlight_paint(kinds, index, end, .Function)
			}
			index = end
		case:
			index += 1
		}
	}
}

highlight_markup :: proc(text: string, kinds: []Syntax_Kind) {
	index := 0
	for index < len(text) {
		if text[index] != '<' {
			index += 1
			continue
		}
		if strings.has_prefix(text[index:], "<!--") {
			end := len(text)
			if close := strings.index(text[index:], "-->"); close >= 0 {end = index+close+3}
			highlight_paint(kinds, index, end, .Comment)
			index = end
			continue
		}
		start := index
		index += 1
		if index < len(text) && (text[index] == '/' || text[index] == '!' || text[index] == '?') {index += 1}
		for index < len(text) && (highlight_is_ident(text[index]) || text[index] == '-' || text[index] == ':') {index += 1}
		highlight_paint(kinds, start, index, text[start+1] == '!' || text[start+1] == '?' ? .Directive : .Tag)
		for index < len(text) && text[index] != '>' {
			value := text[index]
			switch {
			case value == '"' || value == '\'':
				end := highlight_string_end(text, index, true)
				highlight_paint(kinds, index, end, .String)
				index = end
			case highlight_is_ident_start(value):
				end := index
				for end < len(text) && (highlight_is_ident(text[end]) || text[end] == '-' || text[end] == ':') {end += 1}
				highlight_paint(kinds, index, end, .Property)
				index = end
			case:
				index += 1
			}
		}
		if index < len(text) {
			highlight_paint(kinds, index, index+1, .Tag)
			index += 1
		}
	}
}

highlight_shell :: proc(text: string, kinds: []Syntax_Kind) {
	index := 0
	for index < len(text) {
		value := text[index]
		blank_before := index == 0 || text[index-1] == ' ' || text[index-1] == '\n' || text[index-1] == ';'
		switch {
		case value == '#' && blank_before:
			end := len(text)
			if newline := strings.index_byte(text[index:], '\n'); newline >= 0 {end = index+newline}
			kind := Syntax_Kind.Comment
			if index == 0 && strings.has_prefix(text, "#!") {kind = .Directive}
			highlight_paint(kinds, index, end, kind)
			index = end
		case value == '"':
			end := highlight_string_end(text, index, true)
			highlight_paint(kinds, index, end, .String)
			// Expansions stay visible inside double quotes.
			for position := index; position < end; position += 1 {
				if text[position] == '$' {
					variable_end := highlight_shell_variable_end(text, position)
					highlight_paint(kinds, position, min(variable_end, end), .Directive)
					position = variable_end-1
				}
			}
			index = end
		case value == '\'':
			end := len(text)
			if close := strings.index_byte(text[index+1:], '\''); close >= 0 {end = index+1+close+1}
			highlight_paint(kinds, index, end, .String)
			index = end
		case value == '$':
			end := highlight_shell_variable_end(text, index)
			highlight_paint(kinds, index, end, .Directive)
			index = max(end, index+1)
		case highlight_is_digit(value) && blank_before:
			end := highlight_number_end(text, index)
			highlight_paint(kinds, index, end, .Number)
			index = end
		case highlight_is_ident_start(value):
			end := index
			for end < len(text) && (highlight_is_ident(text[end]) || text[end] == '-') {end += 1}
			word := text[index:end]
			switch {
			case highlight_contains(SHELL_KEYWORDS, word):
				highlight_paint(kinds, index, end, .Keyword)
			case strings.has_prefix(text[end:], "()"):
				highlight_paint(kinds, index, end, .Function)
			}
			index = end
		case:
			index += 1
		}
	}
}

// highlight_shell_variable_end is the index after the $name, ${...} or $(...)
// that starts at start.
highlight_shell_variable_end :: proc(text: string, start: int) -> int {
	index := start+1
	if index >= len(text) {return index}
	switch text[index] {
	case '{':
		if close := strings.index_byte(text[index:], '}'); close >= 0 {return index+close+1}
		return len(text)
	case '(':
		return index+1
	case '@', '*', '#', '?', '!', '$', '0' ..= '9':
		return index+1
	}
	for index < len(text) && highlight_is_ident(text[index]) {index += 1}
	return index
}

highlight_markdown :: proc(text: string, kinds: []Syntax_Kind) {
	in_fence := false
	line_start := 0
	for line_start < len(text) {
		line_end := len(text)
		if newline := strings.index_byte(text[line_start:], '\n'); newline >= 0 {line_end = line_start+newline}
		line := text[line_start:line_end]
		trimmed := strings.trim_left(line, " ")
		indent := len(line)-len(trimmed)
		switch {
		case strings.has_prefix(trimmed, "```") || strings.has_prefix(trimmed, "~~~"):
			highlight_paint(kinds, line_start, line_end, .Comment)
			in_fence = !in_fence
		case in_fence:
			highlight_paint(kinds, line_start, line_end, .String)
		case strings.has_prefix(trimmed, "#"):
			level := 0
			for level < len(trimmed) && trimmed[level] == '#' {level += 1}
			if level <= 6 && (level == len(trimmed) || trimmed[level] == ' ') {highlight_paint(kinds, line_start, line_end, .Keyword)}
		case strings.has_prefix(trimmed, ">"):
			highlight_paint(kinds, line_start, line_end, .Comment)
		case strings.has_prefix(trimmed, "---") || strings.has_prefix(trimmed, "***"):
			highlight_paint(kinds, line_start, line_end, .Comment)
		case:
			marker := 0
			switch {
			case len(trimmed) > 1 && (trimmed[0] == '-' || trimmed[0] == '*' || trimmed[0] == '+') && trimmed[1] == ' ':
				marker = 1
			case len(trimmed) > 2 && highlight_is_digit(trimmed[0]):
				digits := 0
				for digits < len(trimmed) && highlight_is_digit(trimmed[digits]) {digits += 1}
				if digits+1 < len(trimmed) && trimmed[digits] == '.' && trimmed[digits+1] == ' ' {marker = digits+1}
			}
			if marker > 0 {highlight_paint(kinds, line_start+indent, line_start+indent+marker, .Directive)}
			highlight_markdown_inline(line, kinds[line_start:line_end])
		}
		line_start = line_end+1
	}
}

// highlight_markdown_inline marks `code` spans and [text](target) links.
highlight_markdown_inline :: proc(line: string, kinds: []Syntax_Kind) {
	index := 0
	for index < len(line) {
		switch line[index] {
		case '`':
			if close := strings.index_byte(line[index+1:], '`'); close >= 0 {
				highlight_paint(kinds, index, index+1+close+1, .String)
				index += close+2
				continue
			}
		case '[':
			if close := strings.index(line[index:], "]("); close >= 0 {
				if paren := strings.index_byte(line[index+close:], ')'); paren >= 0 {
					highlight_paint(kinds, index, index+close+1, .Function)
					highlight_paint(kinds, index+close+1, index+close+paren+1, .Comment)
					index += close+paren+1
					continue
				}
			}
		}
		index += 1
	}
}
