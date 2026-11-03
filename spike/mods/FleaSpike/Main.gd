extends Node

## Milestone 0 capability spike for the Road to Vostok flea market mod.
##
## This is a THROWAWAY probe, not production code. It answers the spec's §3.1
## capability table empirically instead of by assumption, and writes everything
## it learns to user://FleaSpike_Report.json so the findings can be read back
## off the game machine without scraping the Godot log by hand.
##
## Nothing here mutates game state. It makes read-only HTTP calls, writes and
## then deletes one scratch file under user://, and draws one throwaway panel.

const LOG_PREFIX := "[FleaSpike] "
const REPORT_PATH := "user://FleaSpike_Report.json"
const SCRATCH_PATH := "user://FleaSpike_SaveProbe.cfg"

const API_BASE := "https://api.domfragsvostokmods.bid/v1"
# Dev-dataset key from the server handoff notes. Read-only use here.
const TEST_KEY := "rtv_tFRu_Aul389dgU2pDPYpQx_rtbd8qgUIji-h0pVeytY"

const HTTP_TIMEOUT := 20.0
const BODY_LIMIT := 8 * 1024 * 1024

var _report := {}
var _spike_label: Label = null


func _ready() -> void:
	_log("autoload _ready() reached - own GDScript executes in a mod")

	_report = {
		"spike_version": "0.1.0",
		"probed_at_unix": int(Time.get_unix_time_from_system()),
		"probed_at_utc": Time.get_datetime_string_from_system(true),
		"capabilities": {},
		"environment": {},
		"http": {},
	}

	# Row 1: own GDScript executes. If this line runs at all, it is proven.
	_cap("gdscript_executes", true, "This autoload's _ready() ran and logged.")

	_probe_environment()
	_probe_save_roundtrip()
	_probe_frameworks()
	_probe_cash_mod()

	# Give the tree a couple of frames before touching UI or the network, the
	# same wait every other mod in this stack uses before reaching for
	# /root/Interface.
	await get_tree().process_frame
	await get_tree().process_frame

	_probe_ui()
	await _probe_http()

	_write_report()
	_log("spike complete - report at " + REPORT_PATH)


# --- Probes ---

func _probe_environment() -> void:
	_report["environment"] = {
		"godot_version": Engine.get_version_info(),
		"os_name": OS.get_name(),
		"debug_build": OS.is_debug_build(),
		"has_feature_editor": OS.has_feature("editor"),
		"has_feature_template": OS.has_feature("template"),
		"executable": OS.get_executable_path(),
		"user_dir": OS.get_user_data_dir(),
	}

	# The spec insists the ping happen from an exported build, not the editor.
	# OS.has_feature("editor") is the authoritative discriminator.
	var is_exported: bool = not OS.has_feature("editor")
	_cap(
		"running_in_exported_build",
		is_exported,
		"has_feature(editor)=%s debug_build=%s exe=%s" % [
			OS.has_feature("editor"), OS.is_debug_build(), OS.get_executable_path()
		]
	)
	_log("environment: Godot %s on %s, exported=%s" % [
		Engine.get_version_info().get("string", "?"), OS.get_name(), is_exported
	])


func _probe_save_roundtrip() -> void:
	# 3.1: "Write custom keys into the game save - write, reload, read back."
	# Mods persist to user:// via ConfigFile rather than into the game's own
	# save resource, so that is what gets tested here.
	var payload := {
		"nested": {"a": 1, "b": [1, 2, 3]},
		"float": 0.6234,
		"unicode": "AK-74M 62%",
	}

	var writer := ConfigFile.new()
	writer.set_value("probe", "int_key", 424242)
	writer.set_value("probe", "dict_key", payload)
	var save_err := writer.save(SCRATCH_PATH)

	var reader := ConfigFile.new()
	var load_err := reader.load(SCRATCH_PATH)
	var got_int = reader.get_value("probe", "int_key", null)
	var got_dict = reader.get_value("probe", "dict_key", null)

	var ok: bool = (
		save_err == OK
		and load_err == OK
		and got_int == 424242
		and got_dict is Dictionary
		and got_dict.get("unicode", "") == "AK-74M 62%"
		and is_equal_approx(float(got_dict.get("float", 0.0)), 0.6234)
	)

	_cap("save_custom_keys_roundtrip", ok,
		"ConfigFile save=%d load=%d int_ok=%s dict_ok=%s (nested dict, float, UTF-8)" % [
			save_err, load_err, got_int == 424242, got_dict is Dictionary
		])

	# Leave nothing behind.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_PATH))

	# Save-profile discovery: PendingLedger must be scoped per save profile, or
	# a pending op from one save replays against another. Record what is
	# visible so the real ledger can be keyed correctly.
	var profile_hints := []
	var d := DirAccess.open("user://")
	if d != null:
		for f in d.get_files():
			var lf := f.to_lower()
			if lf.begins_with("save") or lf.contains("profile") or lf.ends_with(".sav"):
				profile_hints.append(f)
		for sub in d.get_directories():
			var ls := sub.to_lower()
			if ls.contains("profile") or ls.contains("save"):
				profile_hints.append(sub + "/")
	_report["environment"]["user_dir_save_hints"] = profile_hints


func _probe_frameworks() -> void:
	var lib = Engine.get_meta("RTVModLib", null)
	var has_lib: bool = lib != null
	var api := {}

	if has_lib:
		api["has_hook"] = lib.has_method("hook")
		api["has_register"] = lib.has_method("register")
		api["has_patch"] = lib.has_method("patch")
		api["has_skip_super"] = lib.has_method("skip_super")
		api["has_frameworks_ready"] = lib.has_signal("frameworks_ready")
		# Registry is an enum, i.e. a script constant, not a property -- the
		# `in` operator would miss it. Ask the script's constant map instead.
		var has_registry := false
		# lib is a Variant, so get_script() has no static type to infer from.
		var lib_script = lib.get_script()
		if lib_script != null:
			has_registry = lib_script.get_script_constant_map().has("Registry")
		api["has_Registry_enum"] = has_registry
		if has_registry:
			# Which registry buckets exist decides how the terminal and the
			# courier crate get placed in the shelter.
			var wanted := [
				"ITEMS", "LOOT", "SCENES", "SCENE_PATHS", "SCENE_NODES",
				"SHELTERS", "MAPS", "INPUTS", "RESOURCES",
			]
			var present := []
			for k in wanted:
				if k in lib.Registry:
					present.append(k)
			api["registry_buckets_present"] = present

	_report["environment"]["rtvmodlib"] = api
	_cap("rtvmodlib_available", has_lib,
		"Engine meta RTVModLib %s" % ("present" if has_lib else "absent"))
	_log("RTVModLib available=%s" % has_lib)


func _probe_cash_mod() -> void:
	# The market depends on the physical-money mod. Probe it read-only; the
	# brief forbids modifying it.
	var cash = Engine.get_meta("CashMain", null)
	var info := {}
	var ok: bool = cash != null

	if ok:
		info["has_CountCash"] = cash.has_method("CountCash")
		info["has_AddCash"] = cash.has_method("AddCash")
		info["has_RemoveCash"] = cash.has_method("RemoveCash")
		info["signals"] = {
			"cash_sold": cash.has_signal("cash_sold"),
			"cash_dropped": cash.has_signal("cash_dropped"),
			"cash_picked_up": cash.has_signal("cash_picked_up"),
		}
		if "cash_item_data" in cash and cash.cash_item_data != null:
			var cd = cash.cash_item_data
			info["cash_item"] = {
				"file": cd.file,
				"name": cd.name,
				"value": cd.value,
				"stackable": cd.stackable,
				"maxAmount": cd.maxAmount,
				"defaultAmount": cd.defaultAmount,
				"showAmount": cd.showAmount,
				"weight": cd.weight,
				"size": [cd.size.x, cd.size.y],
			}

	_report["environment"]["cash_mod"] = info
	_cap("cash_mod_available", ok,
		"Engine meta CashMain %s" % ("present" if ok else "absent"))
	_log("Cash mod available=%s" % ok)


func _probe_ui() -> void:
	# 3.1: "Draw custom UI - render a trivial panel."
	var ok := false
	var detail := "no viable UI parent found"
	var parent: Node = get_node_or_null("/root/Interface")
	if parent == null:
		parent = get_tree().root

	if parent != null:
		var panel := PanelContainer.new()
		panel.name = "FleaSpikePanel"
		panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
		panel.position = Vector2(24, 24)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var label := Label.new()
		label.text = "FLEA SPIKE\nprobing market API..."
		label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
		panel.add_child(label)
		parent.add_child(panel)

		ok = is_instance_valid(panel) and panel.is_inside_tree()
		detail = "PanelContainer + Label parented to %s" % parent.get_path()
		_spike_label = label

	_cap("draw_custom_ui", ok, detail)


func _probe_http() -> void:
	# The one genuinely unproven row. Three calls, escalating:
	#   1. unauthenticated GET over HTTPS  -> transport + TLS
	#   2. authenticated GET with a Bearer -> custom request headers + auth
	#   3. POST with a JSON body           -> mutating-call shape
	var ping := await _request("GET", "/ping", false, "")
	_report["http"]["ping"] = ping

	var transport_ok: bool = ping.get("result") == HTTPRequest.RESULT_SUCCESS
	var https_ok: bool = transport_ok and ping.get("code", 0) == 200

	_cap("httprequest_works", transport_ok,
		"GET %s/ping -> result=%d code=%d in %dms" % [
			API_BASE, ping.get("result", -1), ping.get("code", 0), ping.get("elapsed_ms", -1)
		])
	_cap("https_tls_in_exported_build", https_ok,
		"Scheme was https://. TLS handshake %s." % ("succeeded" if https_ok else "FAILED"))
	_log("ping result=%d code=%d body=%s" % [
		ping.get("result", -1), ping.get("code", 0), str(ping.get("body_text", "")).substr(0, 200)
	])

	# Only worth attempting if the transport is alive at all.
	if transport_ok:
		var cat := await _request("GET", "/catalog", true, "")
		# Trim: the catalog body is large and the report only needs its shape.
		var cat_summary := {
			"result": cat.get("result"),
			"code": cat.get("code"),
			"elapsed_ms": cat.get("elapsed_ms"),
			"body_bytes": cat.get("body_bytes"),
		}
		var parsed = cat.get("json", null)
		if parsed is Dictionary:
			cat_summary["catalog_version"] = parsed.get("catalog_version", null)
			cat_summary["top_level_keys"] = parsed.keys()
			var entries = parsed.get("items", parsed.get("catalog", null))
			if entries is Array:
				cat_summary["entry_count"] = entries.size()
				cat_summary["first_entries"] = entries.slice(0, mini(3, entries.size()))
		_report["http"]["catalog"] = cat_summary

		_cap("bearer_auth_headers_work", cat.get("code") == 200,
			"GET /catalog with Authorization: Bearer -> code=%d" % cat.get("code", 0))
		_log("catalog code=%d version=%s entries=%s" % [
			cat.get("code", 0),
			str(cat_summary.get("catalog_version", "?")),
			str(cat_summary.get("entry_count", "?")),
		])

		# A read-only POST probe. /listings phase 1 records a descriptor and
		# moves nothing (server handoff note 1), so this is safe: it destroys
		# no items, charges no fee, and is never confirmed. A deliberately
		# invalid item_key is used so the interesting answer is the validator's
		# 422 rather than a stray phase-1 record against a real item.
		var body := JSON.stringify({
			"idempotency_key": _uuid4(),
			"ask_price": 1,
			"descriptor": {
				"descriptor_version": 1,
				"item_key": "__flea_spike_probe__",
				"quantity": 1,
			},
		})
		var post := await _request("POST", "/listings", true, body)
		_report["http"]["post_probe"] = {
			"result": post.get("result"),
			"code": post.get("code"),
			"elapsed_ms": post.get("elapsed_ms"),
			"body_text": str(post.get("body_text", "")).substr(0, 600),
		}
		_cap("post_with_json_body_works",
			post.get("result") == HTTPRequest.RESULT_SUCCESS,
			"POST /listings with an intentionally invalid item_key -> code=%d. Any HTTP response proves the POST path; 4xx is the expected answer." % post.get("code", 0))
		_log("post probe code=%d body=%s" % [
			post.get("code", 0), str(post.get("body_text", "")).substr(0, 200)
		])

	if _spike_label != null and is_instance_valid(_spike_label):
		_spike_label.text = "FLEA SPIKE\nHTTPS %s - ping %s" % [
			("OK" if https_ok else "FAIL"),
			("200" if https_ok else str(ping.get("code", 0))),
		]
		_spike_label.add_theme_color_override(
			"font_color", Color(0.4, 1.0, 0.5) if https_ok else Color(1.0, 0.4, 0.4))


# --- HTTP helper ---

func _request(method: String, path: String, auth: bool, body: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = HTTP_TIMEOUT
	req.body_size_limit = BODY_LIMIT
	add_child(req)

	var headers := ["Accept: application/json", "User-Agent: vostok-flea-spike/0.1.0"]
	if auth:
		headers.append("Authorization: Bearer " + TEST_KEY)
	if body != "":
		headers.append("Content-Type: application/json")

	var url := API_BASE + path
	var verb := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var started := Time.get_ticks_msec()

	var err := req.request(url, headers, verb, body)
	if err != OK:
		req.queue_free()
		return {
			"url": url,
			"method": method,
			"request_error": err,
			"result": -1,
			"code": 0,
			"elapsed_ms": 0,
			"note": "HTTPRequest.request() refused the call outright (err=%d)" % err,
		}

	var res: Array = await req.request_completed
	var elapsed := Time.get_ticks_msec() - started
	req.queue_free()

	var raw: PackedByteArray = res[3]
	var text := raw.get_string_from_utf8()
	var out := {
		"url": url,
		"method": method,
		"request_error": OK,
		"result": res[0],
		"code": res[1],
		"elapsed_ms": elapsed,
		"body_bytes": raw.size(),
		"body_text": text.substr(0, 2000),
		"response_headers": res[2],
	}
	var parsed = JSON.parse_string(text)
	if parsed != null:
		out["json"] = parsed
	return out


# --- Utilities ---

func _cap(key: String, ok: bool, detail: String) -> void:
	_report["capabilities"][key] = {"ok": ok, "detail": detail}
	_log("CAP %-34s %s  (%s)" % [key, "PASS" if ok else "FAIL", detail])


func _uuid4() -> String:
	# Adequate for a probe. The production client gets a real v4 generator.
	var b := PackedByteArray()
	b.resize(16)
	for i in range(16):
		b[i] = randi() % 256
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)
	]


func _write_report() -> void:
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f == null:
		_log("ERROR could not open report for writing: %d" % FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(_report, "  "))
	f.close()


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
