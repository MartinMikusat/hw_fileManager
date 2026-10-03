package file_manager

import ui "ui_framework:core"
import draw "ui_framework:draw"

FONT_MONO :: ui.Font_Handle(1)

DEFAULT_FONT_SIZE :: 14
FONT_SIZE_MIN :: 12
FONT_SIZE_MAX :: 24
ROW_HEIGHT_RATIO :: f32(22.0/14.0)
COLUMN_GAP :: f32(44)
COLUMN_PAD :: f32(10)
CHROME_HEIGHT :: f32(28)
CONTROL_INSET_CELLS :: f32(1)
CONTROL_CELLS :: f32(3)
CONTROL_STRIDE_CELLS :: f32(4)

COLOR_BACKGROUND    :: draw.Color{0.043, 0.043, 0.051, 1.0}
COLOR_TEXT          :: draw.Color{0.855, 0.855, 0.871, 1.0}
COLOR_DIM           :: draw.Color{0.510, 0.510, 0.541, 1.0}
COLOR_DIRECTORY     :: draw.Color{0.914, 0.643, 0.243, 1.0}
COLOR_SOURCE        :: draw.Color{0.427, 0.620, 0.973, 1.0}
COLOR_DOCUMENT      :: draw.Color{0.878, 0.690, 0.376, 1.0}
COLOR_IMAGE         :: draw.Color{0.541, 0.541, 0.565, 1.0}
COLOR_ARCHIVE       :: draw.Color{0.741, 0.478, 0.478, 1.0}
COLOR_SELECTED      :: draw.Color{1.0, 1.0, 1.0, 1.0}
COLOR_SELECTION_BG  :: draw.Color{0.102, 0.125, 0.180, 1.0}
COLOR_CONNECTOR     :: draw.Color{0.243, 0.400, 0.663, 1.0}
COLOR_CONNECTOR_HOT :: draw.Color{0.494, 0.694, 0.996, 1.0}

CONNECTOR_WIDTH :: f32(1.5)
MIN_COLUMN_WIDTH :: f32(140)
SETTINGS_PANEL_WIDTH :: f32(380)

COLOR_MODAL_BACKDROP :: draw.Color{0.0, 0.0, 0.0, 0.35}

row_height_for :: proc(font_size: f32) -> f32 {
	return font_size*ROW_HEIGHT_RATIO
}

entry_color :: proc(kind: Entry_Kind, hidden: bool) -> draw.Color {
	if hidden {return COLOR_DIM}
	switch kind {
	case .Directory: return COLOR_DIRECTORY
	case .Source:    return COLOR_SOURCE
	case .Document:  return COLOR_DOCUMENT
	case .Image:     return COLOR_IMAGE
	case .Archive:   return COLOR_ARCHIVE
	case .Other:     return COLOR_TEXT
	}
	return COLOR_TEXT
}
