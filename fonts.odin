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
	family:     string,
	style:      string,
	postscript: string,
	weight:     f32,
	italic:     bool,
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
		append(&catalog.faces, face)
	}
	font_catalog_index(catalog)
}

font_face_destroy :: proc(face: ^Font_Face) {
	delete(face.family)
	delete(face.style)
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

// font_family_weights are a family's upright faces along the weight axis, lightest
// first. Faces that also vary in width (Extended, Wide, Condensed) are left out;
// a family with none of the plain weight names offers one face per weight instead.
font_family_weights :: proc(catalog: ^Font_Catalog, family: string, allocator := context.temp_allocator) -> []Font_Face {
	found := make([dynamic]Font_Face, 0, 8, allocator)
	for face in catalog.faces {
		if face.family == family && !face.italic && font_style_is_weight(face.style) {append(&found, face)}
	}
	if len(found) == 0 {
		for face in catalog.faces {
			if face.family != family || face.italic {continue}
			if len(found) > 0 && found[len(found)-1].weight == face.weight {continue}
			append(&found, face)
		}
	}
	return found[:]
}

// font_pick_face is the face for a style name, or the one nearest Regular.
font_pick_face :: proc(faces: []Font_Face, style: string) -> (Font_Face, bool) {
	if len(faces) == 0 {return {}, false}
	best := 0
	for face, index in faces {
		if face.style == style {return face, true}
		if abs(face.weight) < abs(faces[best].weight) {best = index}
	}
	return faces[best], true
}

// font_weight_step is the style after (direction 1) or before (-1) the current one
// within the family; the embedded font has only Regular.
font_weight_step :: proc(catalog: ^Font_Catalog, family, style: string, direction: int) -> string {
	faces := font_family_weights(catalog, family)
	if len(faces) == 0 {return style}
	current, _ := font_pick_face(faces, style)
	index := 0
	for face, position in faces {
		if face.style == current.style {index = position}
	}
	return faces[((index+direction)%len(faces)+len(faces))%len(faces)].style
}

// font_effective_style is the style that will actually be used for a family.
font_effective_style :: proc(catalog: ^Font_Catalog, family, style: string) -> string {
	if family == "" {return "Regular"}
	face, ok := font_pick_face(font_family_weights(catalog, family), style)
	return ok ? face.style : "Regular"
}

// font_apply selects the face for a family and style in the text context; an
// unavailable family keeps the embedded font and is logged once.
font_apply :: proc(text: ^coretext.Context, catalog: ^Font_Catalog, family, style: string) {
	name := string(FONT_NAME)
	if family != "" {
		font_catalog_scan(catalog)
		if face, ok := font_pick_face(font_family_weights(catalog, family), style); ok {
			name = face.postscript
		} else {
			devlog.failed(devlog.global(), {feature = "settings", operation = "apply_font"}, {reason = "the configured font family is not installed", severity = .Warning})
		}
	}
	coretext.register_font(text, FONT_MONO, name)
}
