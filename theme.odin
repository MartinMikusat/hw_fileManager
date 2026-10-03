package file_manager

import ui "ui_framework:core"
import draw "ui_framework:draw"
import "core:time"

FONT_MONO :: ui.Font_Handle(1)

DEFAULT_FONT_SIZE :: 14
FONT_SIZE_MIN :: 10
FONT_SIZE_MAX :: 24
ROW_HEIGHT_RATIO :: f32(22.0/14.0)
COLUMN_GAP :: f32(20)
COLUMN_PAD :: f32(10)
NAME_MAX_CHARS :: 30
CHROME_HEIGHT :: f32(28)
CONTROL_INSET_CELLS :: f32(1)
CONTROL_CELLS :: f32(3)
CONTROL_STRIDE_CELLS :: f32(4)

COLOR_BACKGROUND    :: draw.Color{0.043, 0.043, 0.051, 1.0}
COLOR_TEXT          :: draw.Color{0.855, 0.855, 0.871, 1.0}
COLOR_DIM           :: draw.Color{0.510, 0.510, 0.541, 1.0}
COLOR_RECENT        :: draw.Color{0.427, 0.620, 0.973, 1.0}
// Terminal orange at the stale end of the recency gradient.
COLOR_STALE         :: draw.Color{1.0, 0.647, 0.0, 1.0}
ENTRY_AGE_SPAN      :: 30*24*time.Hour
COLOR_SELECTED      :: draw.Color{1.0, 1.0, 1.0, 1.0}
COLOR_SELECTION_BG  :: draw.Color{0.102, 0.125, 0.180, 1.0}
COLOR_SEARCH        :: draw.Color{0.420, 0.860, 0.790, 1.0}
COLOR_COPY          :: draw.Color{1.0, 0.360, 0.360, 1.0}
COLOR_ERROR         :: draw.Color{1.0, 0.230, 0.230, 1.0}
COLOR_CARET         :: draw.Color{0.855, 0.855, 0.871, 1.0}
COLOR_SELECTION_INK :: draw.Color{0.420, 0.860, 0.790, 0.35}
COLOR_CONNECTOR     :: draw.Color{0.243, 0.400, 0.663, 1.0}
COLOR_CONNECTOR_HOT :: draw.Color{0.494, 0.694, 0.996, 1.0}

CONNECTOR_WIDTH :: f32(1.5)
ACTION_GAP_CELLS :: f32(2)
NOTICE_MAX :: 96
SETTINGS_PANEL_WIDTH :: f32(380)

COLOR_MODAL_BACKDROP :: draw.Color{0.0, 0.0, 0.0, 0.35}

row_height_for :: proc(font_size: f32) -> f32 {
	return font_size*ROW_HEIGHT_RATIO
}

// entry_color fades from blue for fresh files to terminal orange for everything
// older than ENTRY_AGE_SPAN, a continuous recency cue rather than kind buckets.
entry_color :: proc(modified, now: time.Time, hidden: bool) -> draw.Color {
	if hidden {return COLOR_DIM}
	t := clamp(f32(time.diff(modified, now))/f32(ENTRY_AGE_SPAN), 0, 1)
	return color_lerp(COLOR_RECENT, COLOR_STALE, t)
}

color_lerp :: proc(a, b: draw.Color, t: f32) -> draw.Color {
	return {a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t, a[2]+(b[2]-a[2])*t, a[3]+(b[3]-a[3])*t}
}
