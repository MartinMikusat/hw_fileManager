package file_manager

import "core:slice"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import coretext "ui_framework:coretext"
import devlog "devlog:."

// The interface is laid out in fixed cells, so only monospaced faces are offered.
// "" as a family is the embedded Iosevka, which has the Regular weight only.

foreign import font_catalog_ct "system:CoreText.framework"
foreign import font_catalog_cf "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign font_catalog_ct {
	CTFontCollectionCreateFromAvailableFonts :: proc(options: rawptr) -> rawptr ---
	CTFontCollectionCreateMatchingFontDescriptors :: proc(collection: rawptr) -> rawptr ---
	CTFontDescriptorCopyAttribute :: proc(descriptor: rawptr, attribute: rawptr) -> rawptr ---
	kCTFontNameAttribute: rawptr
	kCTFontFamilyNameAttribute: rawptr
	kCTFontStyleNameAttribute: rawptr
	kCTFontTraitsAttribute: rawptr
	kCTFontSymbolicTrait: rawptr
	kCTFontWeightTrait: rawptr
}

@(default_calling_convention = "c")
foreign font_catalog_cf {
	@(link_name = "CFNumberGetValue") font_cf_get_number :: proc(number: rawptr, number_type: int, value: rawptr) -> bool ---
}

FONT_TRAIT_ITALIC :: i32(1 << 0)
FONT_TRAIT_MONOSPACE :: i32(1 << 10)

Font_Face :: struct {
	family:       string,
	// style is the face's full style name; width and weight_style are its parts:
	// "Bold Semi-Condensed" is width "Semi Condensed" and weight_style "Bold".
	style:        string,
	width:        string,
	weight_style: string,
	postscript:   string,
	weight:       f32,
	italic:       bool,
}

// FONT_WIDTHS maps the width words fonts put in style names to one name each, ordered
// from narrowest to widest. Longer spellings come first so they win the match.
Font_Width :: struct {
	token: string,
	name:  string,
	order: int,
}

FONT_WIDTHS := [?]Font_Width{
	{"UltraCondensed", "Ultra Condensed", -4}, {"ExtraCondensed", "Extra Condensed", -3},
	{"Semi-Condensed", "Semi Condensed", -1}, {"SemiCondensed", "Semi Condensed", -1}, {"Condensed", "Condensed", -2},
	{"UltraExpanded", "Ultra Wide", 4}, {"ExtraExpanded", "Extra Wide", 3},
	{"SemiExpanded", "Semi Wide", 1}, {"SemiWide", "Semi Wide", 1}, {"Expanded", "Wide", 2}, {"Extended", "Wide", 2}, {"Wide", "Wide", 2},
}

font_width_order :: proc(name: string) -> int {
	for width in FONT_WIDTHS {
		if width.name == name {return width.order}
	}
	return 0
}

// font_split_style separates the width word from a style name.
font_split_style :: proc(style: string) -> (width, weight_style: string) {
	for candidate in FONT_WIDTHS {
		index := strings.index(style, candidate.token)
		if index < 0 {continue}
		rest := strings.trim_space(strings.concatenate({style[:index], " ", style[index+len(candidate.token):]}, context.temp_allocator))
		return candidate.name, len(rest) > 0 ? rest : "Regular"
	}
	return "", style
}

Font_Catalog :: struct {
	faces:    [dynamic]Font_Face,
	families: [dynamic]string,
	scanned:  bool,
}

font_catalog: Font_Catalog

font_cf_string :: proc(value: rawptr) -> string {
	if value == nil {return ""}
	buffer: [256]u8
	if !CF.StringGetCString(CF.String(value), raw_data(buffer[:]), CF.Index(len(buffer)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)) {return ""}
	length := 0
	for length < len(buffer) && buffer[length] != 0 {length += 1}
	return strings.clone(string(buffer[:length]))
}

// font_catalog_scan lists the installed monospaced faces, by family and weight.
font_catalog_scan :: proc(catalog: ^Font_Catalog) {
	if catalog.scanned {return}
	catalog.scanned = true
	collection := CTFontCollectionCreateFromAvailableFonts(nil)
	if collection == nil {return}
	defer coretext.CFRelease(collection)
	descriptors := CTFontCollectionCreateMatchingFontDescriptors(collection)
	if descriptors == nil {return}
	defer coretext.CFRelease(descriptors)
	for index in 0 ..< coretext.CFArrayGetCount(descriptors) {
		descriptor := coretext.CFArrayGetValueAtIndex(descriptors, index)
		traits := CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
		if traits == nil {continue}
		defer coretext.CFRelease(traits)
		symbolic: i32
		if number := coretext.CFDictionaryGetValue(traits, kCTFontSymbolicTrait); number != nil {_ = font_cf_get_number(number, 3, &symbolic)}
		if symbolic & FONT_TRAIT_MONOSPACE == 0 {continue}
		weight: f64
		if number := coretext.CFDictionaryGetValue(traits, kCTFontWeightTrait); number != nil {_ = font_cf_get_number(number, 6, &weight)}
		name := CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
		family := CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
		style := CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute)
		face := Font_Face{family = font_cf_string(family), style = font_cf_string(style), postscript = font_cf_string(name), weight = f32(weight), italic = symbolic & FONT_TRAIT_ITALIC != 0}
		for value in ([3]rawptr{name, family, style}) {if value != nil {coretext.CFRelease(value)}}
		if len(face.family) == 0 || len(face.postscript) == 0 || len(face.style) == 0 || face.family[0] == '.' {
			font_face_destroy(&face)
			continue
		}
		width, weight_style := font_split_style(face.style)
		face.width = strings.clone(width)
		face.weight_style = strings.clone(weight_style)
		append(&catalog.faces, face)
	}
	font_catalog_index(catalog)
}

font_face_destroy :: proc(face: ^Font_Face) {
	delete(face.family)
	delete(face.style)
	delete(face.width)
	delete(face.weight_style)
	delete(face.postscript)
	face^ = {}
}

// font_catalog_index sorts the faces and derives the unique family list.
font_catalog_index :: proc(catalog: ^Font_Catalog) {
	slice.sort_by(catalog.faces[:], proc(a, b: Font_Face) -> bool {
		if a.family != b.family {return strings.compare(strings.to_lower(a.family, context.temp_allocator), strings.to_lower(b.family, context.temp_allocator)) < 0}
		return a.weight < b.weight
	})
	clear(&catalog.families)
	for face in catalog.faces {
		if len(catalog.families) == 0 || catalog.families[len(catalog.families)-1] != face.family {append(&catalog.families, face.family)}
	}
}

font_catalog_destroy :: proc(catalog: ^Font_Catalog) {
	for &face in catalog.faces {font_face_destroy(&face)}
	delete(catalog.faces)
	delete(catalog.families)
	catalog^ = {}
}

font_family_known :: proc(catalog: ^Font_Catalog, family: string) -> (string, bool) {
	for candidate in catalog.families {
		if strings.equal_fold(candidate, family) {return candidate, true}
	}
	return "", false
}

// font_family_step is the family after (direction 1) or before (-1) the current one,
// counting the embedded font as the first stop.
font_family_step :: proc(catalog: ^Font_Catalog, family: string, direction: int) -> string {
	count := len(catalog.families)+1
	index := 0
	for candidate, position in catalog.families {
		if candidate == family {index = position+1}
	}
	next := ((index+direction)%count+count)%count
	return next == 0 ? "" : catalog.families[next-1]
}

FONT_WEIGHT_WORDS := [?]string{
	"Thin", "UltraLight", "ExtraLight", "Extralight", "Light", "SemiLight", "Regular", "Book", "Retina",
	"Medium", "SemiBold", "Semibold", "DemiBold", "Bold", "ExtraBold", "Extrabold", "UltraBold", "Black", "Heavy",
}

font_style_is_weight :: proc(style: string) -> bool {
	for word in FONT_WEIGHT_WORDS {
		if word == style {return true}
	}
	return false
}

// font_family_widths are the widths a family comes in, narrowest first; "" is the
// normal width.
font_family_widths :: proc(catalog: ^Font_Catalog, family: string, allocator := context.temp_allocator) -> []string {
	found := make([dynamic]string, 0, 4, allocator)
	for face in catalog.faces {
		if face.family != family || face.italic {continue}
		if !slice.contains(found[:], face.width) {append(&found, face.width)}
	}
	slice.sort_by(found[:], proc(a, b: string) -> bool {return font_width_order(a) < font_width_order(b)})
	return found[:]
}

// font_effective_width is the width that will be used: the one asked for when the
// family has it, else normal, else its narrowest.
font_effective_width :: proc(catalog: ^Font_Catalog, family, width: string) -> string {
	widths := font_family_widths(catalog, family)
	if slice.contains(widths, width) {return width}
	if slice.contains(widths, "") || len(widths) == 0 {return ""}
	return widths[0]
}

font_width_step :: proc(catalog: ^Font_Catalog, family, width: string, direction: int) -> string {
	widths := font_family_widths(catalog, family)
	if len(widths) == 0 {return width}
	current := font_effective_width(catalog, family, width)
	index := 0
	for candidate, position in widths {
		if candidate == current {index = position}
	}
	return widths[((index+direction)%len(widths)+len(widths))%len(widths)]
}

// font_family_weights are a family's upright faces of one width along the weight axis,
// lightest first. A family with none of the plain weight names offers one face per weight.
font_family_weights :: proc(catalog: ^Font_Catalog, family, width: string, allocator := context.temp_allocator) -> []Font_Face {
	found := make([dynamic]Font_Face, 0, 8, allocator)
	for face in catalog.faces {
		if face.family == family && !face.italic && face.width == width && font_style_is_weight(face.weight_style) {append(&found, face)}
	}
	if len(found) == 0 {
		for face in catalog.faces {
			if face.family != family || face.italic || face.width != width {continue}
			if len(found) > 0 && found[len(found)-1].weight == face.weight {continue}
			append(&found, face)
		}
	}
	return found[:]
}

// font_pick_face is the face for a weight style, or the one nearest Regular.
font_pick_face :: proc(faces: []Font_Face, weight_style: string) -> (Font_Face, bool) {
	if len(faces) == 0 {return {}, false}
	best := 0
	for face, index in faces {
		if face.weight_style == weight_style {return face, true}
		if abs(face.weight) < abs(faces[best].weight) {best = index}
	}
	return faces[best], true
}

// font_weight_step is the weight style after (direction 1) or before (-1) the current
// one within the family and width.
font_weight_step :: proc(catalog: ^Font_Catalog, family, width, style: string, direction: int) -> string {
	faces := font_family_weights(catalog, family, font_effective_width(catalog, family, width))
	if len(faces) == 0 {return style}
	current, _ := font_pick_face(faces, style)
	index := 0
	for face, position in faces {
		if face.weight_style == current.weight_style {index = position}
	}
	return faces[((index+direction)%len(faces)+len(faces))%len(faces)].weight_style
}

// font_effective_style is the weight style that will actually be used.
font_effective_style :: proc(catalog: ^Font_Catalog, family, width, style: string) -> string {
	if family == "" {return "Regular"}
	face, ok := font_pick_face(font_family_weights(catalog, family, font_effective_width(catalog, family, width)), style)
	return ok ? face.weight_style : "Regular"
}

font_width_label :: proc(width: string) -> string {
	return len(width) > 0 ? width : "Normal"
}

// font_apply selects the face for a family, width and weight in the text context; an
// unavailable family keeps the embedded font and is logged.
font_apply :: proc(text: ^coretext.Context, catalog: ^Font_Catalog, family, width, style: string) {
	name := string(FONT_NAME)
	if family != "" {
		font_catalog_scan(catalog)
		faces := font_family_weights(catalog, family, font_effective_width(catalog, family, width))
		if face, ok := font_pick_face(faces, style); ok {
			name = face.postscript
		} else {
			devlog.failed(devlog.global(), {feature = "settings", operation = "apply_font"}, {reason = "the configured font family is not installed", severity = .Warning})
		}
	}
	coretext.register_font(text, FONT_MONO, name)
}
