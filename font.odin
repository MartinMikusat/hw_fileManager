package file_manager

import coretext "ui_framework:coretext"

FONT_NAME :: "IosevkaFileManager-Regular"
// Iosevka Regular, embedded so the app needs no installed face. The full-coverage
// subset is used because file names can be arbitrary Unicode; the OFL ships in
// fonts/OFL.md.
FONT_DATA :: #load("fonts/Iosevka-Regular.woff2")

font_registered: bool

foreign import font_cf "system:CoreFoundation.framework"
foreign font_cf {
	CFDataCreate :: proc "c" (allocator: rawptr, bytes: rawptr, length: int) -> rawptr ---
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
