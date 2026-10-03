package file_manager

import draw "ui_framework:draw"

SYNTAX_THEME_NAMES := [?]string{"Default", "Gruvbox", "Monokai", "Solarized", "Nord", "Dracula", "One Dark", "Tokyo Night"}

Syntax_Theme :: [Syntax_Kind]draw.Color

rgb :: proc(value: u32) -> draw.Color {
	return {f32(value >> 16 & 0xFF)/255, f32(value >> 8 & 0xFF)/255, f32(value & 0xFF)/255, 1}
}

// syntax_theme_index is the position of a saved theme name; unknown names and the
// empty name select the default.
syntax_theme_index :: proc(name: string) -> int {
	for candidate, index in SYNTAX_THEME_NAMES {
		if candidate == name {return index}
	}
	return 0
}

syntax_theme_step :: proc(name: string, direction: int) -> string {
	count := len(SYNTAX_THEME_NAMES)
	return SYNTAX_THEME_NAMES[((syntax_theme_index(name)+direction)%count+count)%count]
}

// syntax_theme colours each kind of token. Only token colours change; the
// preview keeps the app's own background.
syntax_theme :: proc(index: int) -> Syntax_Theme {
	// Order: plain, keyword, type, function, string, number, comment, directive, tag, property.
	palette :: proc(plain, keyword, type, function, string_, number, comment, directive, tag, property: u32) -> Syntax_Theme {
		return {
			.Plain = rgb(plain), .Keyword = rgb(keyword), .Type = rgb(type), .Function = rgb(function), .String = rgb(string_),
			.Number = rgb(number), .Comment = rgb(comment), .Directive = rgb(directive), .Tag = rgb(tag), .Property = rgb(property),
		}
	}
	switch SYNTAX_THEME_NAMES[clamp(index, 0, len(SYNTAX_THEME_NAMES)-1)] {
	case "Gruvbox":     return palette(0xebdbb2, 0xfb4934, 0xfabd2f, 0x8ec07c, 0xb8bb26, 0xd3869b, 0x928374, 0xfe8019, 0xfb4934, 0x83a598)
	case "Monokai":     return palette(0xf8f8f2, 0xf92672, 0x66d9ef, 0xa6e22e, 0xe6db74, 0xae81ff, 0x75715e, 0xfd971f, 0xf92672, 0xfd971f)
	case "Solarized":   return palette(0x93a1a1, 0x859900, 0xb58900, 0x268bd2, 0x2aa198, 0xd33682, 0x586e75, 0xcb4b16, 0x268bd2, 0x6c71c4)
	case "Nord":        return palette(0xd8dee9, 0x81a1c1, 0x8fbcbb, 0x88c0d0, 0xa3be8c, 0xb48ead, 0x616e88, 0xd08770, 0x81a1c1, 0xebcb8b)
	case "Dracula":     return palette(0xf8f8f2, 0xff79c6, 0x8be9fd, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0x6272a4, 0xff5555, 0xff79c6, 0xffb86c)
	case "One Dark":    return palette(0xabb2bf, 0xc678dd, 0xe5c07b, 0x61afef, 0x98c379, 0xd19a66, 0x5c6370, 0x56b6c2, 0xe06c75, 0xbe5046)
	case "Tokyo Night": return palette(0xc0caf5, 0xbb9af7, 0x2ac3de, 0x7aa2f7, 0x9ece6a, 0xff9e64, 0x565f89, 0x7dcfff, 0xf7768e, 0x73daca)
	}
	return {
		.Plain = COLOR_TEXT, .Keyword = COLOR_SYNTAX_KEYWORD, .Type = COLOR_SYNTAX_TYPE, .Function = COLOR_SYNTAX_FUNCTION,
		.String = COLOR_SYNTAX_STRING, .Number = COLOR_SYNTAX_NUMBER, .Comment = COLOR_DIM, .Directive = COLOR_SYNTAX_DIRECTIVE,
		.Tag = COLOR_SYNTAX_TAG, .Property = COLOR_SYNTAX_PROPERTY,
	}
}
