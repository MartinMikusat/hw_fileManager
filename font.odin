package file_manager

import "core:strings"
import coretext "ui_framework:coretext"

FONT_NAME :: "IosevkaFileManager-Regular"
// Iosevka Regular, embedded so the app needs no installed face. The full-coverage
// subset is used because app and directory names can be arbitrary Unicode; the
// OFL ships in fonts/OFL.md.
FONT_DATA :: #load("fonts/Iosevka-Regular.woff2")

font_registered: bool

foreign import font_cf "system:CoreFoundation.framework"
foreign font_cf {
	CFDataCreate :: proc "c" (allocator: rawptr, bytes: rawptr, length: int) -> rawptr ---
	CFStringCreateWithCString :: proc "c" (allocator: rawptr, value: cstring, encoding: u32) -> rawptr ---
	CFStringCompare :: proc "c" (self, other: rawptr, options: u64) -> i64 ---
}

foreign import font_cg "system:CoreGraphics.framework"
foreign font_cg {
	CGDataProviderCreateWithCFData :: proc "c" (data: rawptr) -> rawptr ---
	CGDataProviderRelease :: proc "c" (provider: rawptr) ---
	CGFontCreateWithDataProvider :: proc "c" (provider: rawptr) -> rawptr ---
	CGFontRelease :: proc "c" (font: rawptr) ---
}

foreign import font_ct "system:CoreText.framework"
foreign font_ct {
	CTFontManagerRegisterGraphicsFont :: proc "c" (font: rawptr, error: ^rawptr) -> bool ---
	CTFontCreateWithName :: proc "c" (name: rawptr, size: f64, transform: rawptr) -> rawptr ---
	CTFontCopyPostScriptName :: proc "c" (font: rawptr) -> rawptr ---
}

// font_register embeds and registers the face process-locally, so no font
// installation or runtime path is needed and no system face is substituted.
font_register :: proc() -> bool {
	if font_registered {return true}
	data := CFDataCreate(nil, raw_data(FONT_DATA), len(FONT_DATA))
	if data == nil {return false}
	defer coretext.CFRelease(data)
	provider := CGDataProviderCreateWithCFData(data)
	if provider == nil {return false}
	defer CGDataProviderRelease(provider)
	font := CGFontCreateWithDataProvider(provider)
	if font == nil {return false}
	defer CGFontRelease(font)
	error: rawptr
	font_registered = CTFontManagerRegisterGraphicsFont(font, &error)
	if error != nil {coretext.CFRelease(error)}
	return font_registered
}

// font_resolves reports whether CoreText resolves FONT_NAME to the embedded
// face. A wrong PostScript name would otherwise fall back to a substitute
// silently, which is the one failure the renderer cannot see.
font_resolves :: proc() -> bool {
	name := CFStringCreateWithCString(nil, strings.clone_to_cstring(FONT_NAME, context.temp_allocator), CF_UTF8)
	if name == nil {return false}
	defer coretext.CFRelease(name)
	font := CTFontCreateWithName(name, 12, nil)
	if font == nil {return false}
	defer coretext.CFRelease(font)
	actual := CTFontCopyPostScriptName(font)
	if actual == nil {return false}
	defer coretext.CFRelease(actual)
	return CFStringCompare(actual, name, 0) == 0
}
