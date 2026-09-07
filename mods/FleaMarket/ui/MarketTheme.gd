extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Shared look for every terminal screen.
##
## Centralised so the six screens cannot drift apart, and so a restyle is one
## file rather than a hunt. The palette is a CRT-green terminal against the
## game's dark UI: legible over the shelter interior, and unmistakably a
## machine rather than another inventory panel.

const BG := Color(0.055, 0.063, 0.059, 0.97)
const PANEL := Color(0.085, 0.098, 0.090, 1.0)
const PANEL_ALT := Color(0.11, 0.125, 0.115, 1.0)
const BORDER := Color(0.20, 0.35, 0.26, 1.0)

const TEXT := Color(0.82, 0.90, 0.84, 1.0)
const TEXT_DIM := Color(0.52, 0.60, 0.55, 1.0)
const ACCENT := Color(0.36, 0.94, 0.53, 1.0)
const WARN := Color(0.98, 0.76, 0.32, 1.0)
const DANGER := Color(0.95, 0.42, 0.38, 1.0)

## Market indicator colours. `unknown` deliberately uses the dim text colour
## rather than a signal colour -- "no idea" is an absence, not a verdict.
const INDICATOR_BELOW := Color(0.42, 0.86, 0.98, 1.0)
const INDICATOR_AT := Color(0.72, 0.78, 0.74, 1.0)
const INDICATOR_ABOVE := Color(0.98, 0.62, 0.42, 1.0)

const FONT_SMALL := 13
const FONT_BODY := 15
const FONT_HEAD := 19
const FONT_TITLE := 25


static func panel(colour: Color = PANEL, border_width: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = colour
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	if border_width > 0:
		sb.border_color = BORDER
		sb.set_border_width_all(border_width)
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	return sb


static func label(text: String, size: int = FONT_BODY, colour: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l


static func button(text: String, enabled: bool = true) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", FONT_BODY)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", ACCENT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_stylebox_override("normal", panel(PANEL_ALT, 1))
	b.add_theme_stylebox_override("hover", panel(PANEL_ALT.lightened(0.08), 1))
	b.add_theme_stylebox_override("pressed", panel(PANEL, 1))
	b.add_theme_stylebox_override("disabled", panel(PANEL.darkened(0.2), 1))
	return b


## A separator that reads as part of the machine rather than a default line.
static func rule() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(0, 1)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BORDER
	p.add_theme_stylebox_override("panel", sb)
	return p


## The §8.1 market indicator glyph, as text and colour.
##
## `unknown` MUST render as an absence. "At the average" and "no idea" are
## different statements, and showing the latter as the former invents
## information the market does not have.
static func indicator_glyph(indicator: String) -> Array:
	match indicator:
		"below":
			return ["v", INDICATOR_BELOW, "below the 7-day average"]
		"above":
			return ["^", INDICATOR_ABOVE, "above the 7-day average"]
		"at":
			return ["=", INDICATOR_AT, "at the 7-day average"]
		_:
			return ["-", TEXT_DIM, "no trades in the last 7 days"]


## Money, grouped for legibility. Cash runs to millions and an ungrouped
## 2000000 is unreadable at a glance.
static func money(amount) -> String:
	var value := int(round(float(amount)))
	var negative := value < 0
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = " " + out
	return ("-" if negative else "") + out


## A duration as a countdown a player can read at a glance.
static func duration(seconds) -> String:
	var total := int(max(0, float(seconds)))
	if total < 60:
		return "%ds" % total
	var minutes := total / 60
	if minutes < 60:
		return "%dm %02ds" % [minutes, total % 60]
	var hours := minutes / 60
	return "%dh %02dm" % [hours, minutes % 60]


## How stale cached data is, for the offline banner (§8.3).
##
## Driven by the server's `as_of` rather than a locally-tracked cache time, so
## the banner reports when the MARKET last spoke, not when we last asked.
static func staleness(as_of_iso: String) -> String:
	if as_of_iso == "":
		return "age unknown"
	var parsed := Time.get_unix_time_from_datetime_string(as_of_iso)
	if parsed <= 0:
		return "age unknown"
	var age := int(Time.get_unix_time_from_system()) - int(parsed)
	if age < 60:
		return "moments old"
	if age < 3600:
		return "%dm old" % (age / 60)
	if age < 86400:
		return "%dh old" % (age / 3600)
	return "%dd old" % (age / 86400)
