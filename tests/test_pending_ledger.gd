extends SceneTree

## PendingLedger tests, with the crash windows simulated rather than hoped about.
##
## The ledger is the whole crash-recovery mechanism, so the cases worth testing
## are the ugly ones: a half-written file, an unreadable file, a process that
## died between phases, and a replay that must reuse the original op_id.
##
##     tools/run-tests.sh test_pending_ledger

const PendingLedger := preload("res://mods/FleaMarket/PendingLedger.gd")

var _passed := 0
var _failed := 0

const PROFILE := "test_profile"
var _path := ""


func _init() -> void:
	print("")
	print("PendingLedger")
	print("=============")

	_path = "user://FleaMarket/pending_%s.json" % PROFILE
	_cleanup()

	_test_roundtrip()
	_test_ordering()
	_test_survives_restart()
	_test_partial_write_discarded()
	_test_unreadable_file_kept()
	_test_attempts_and_stalling()
	_test_advance_unknown_refused()

	_cleanup()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	for p in [_path, _path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _fresh() -> RefCounted:
	return PendingLedger.new(PROFILE)


# --- Tests ---

func _test_roundtrip() -> void:
	_cleanup()
	var led = _fresh()

	led.begin("op-1", PendingLedger.KIND_LISTING, {"listing_id": 7, "ask_price": 58000})
	_check("begins in reserved",
		str(led.get_entry("op-1")["phase"]) == PendingLedger.RESERVED)

	led.advance("op-1", PendingLedger.LOCAL_COMMITTED)
	_check("advances phase",
		str(led.get_entry("op-1")["phase"]) == PendingLedger.LOCAL_COMMITTED)

	# Extra payload merges rather than replacing: recovery needs the listing_id
	# from phase 1 as well as anything learned since.
	led.advance("op-1", PendingLedger.CONFIRMED, {"status": "active"})
	var payload: Dictionary = led.get_entry("op-1")["payload"]
	_check("payload merges on advance",
		int(payload.get("listing_id", 0)) == 7 and str(payload.get("status", "")) == "active")

	led.complete("op-1")
	_check("complete drops the entry", not led.has("op-1") and led.count() == 0)


func _test_ordering() -> void:
	_cleanup()
	var led = _fresh()
	led.begin("op-a", PendingLedger.KIND_LISTING, {})
	led.begin("op-b", PendingLedger.KIND_ORDER, {})
	led.begin("op-c", PendingLedger.KIND_BROKER_SELL, {})

	# Replay order is the order operations were begun, so a listing created
	# before an order settles first.
	var ids := []
	for entry in led.outstanding():
		ids.append(str(entry["op_id"]))
	_check("outstanding is oldest first", ids == ["op-a", "op-b", "op-c"])


## The case the whole class exists for: the process dies after the goods were
## destroyed but before phase 2 landed.
func _test_survives_restart() -> void:
	_cleanup()
	var led = _fresh()
	led.begin("op-crash", PendingLedger.KIND_ORDER,
		{"order_id": 42, "total": 58000})
	led.advance("op-crash", PendingLedger.LOCAL_COMMITTED)
	# ...cash destroyed here, and the process dies before settle.

	var reopened = _fresh()
	var entry: Dictionary = reopened.get_entry("op-crash")
	_check("entry survives a restart", not entry.is_empty())
	_check("phase survives", str(entry.get("phase", "")) == PendingLedger.LOCAL_COMMITTED)
	_check("payload survives", int(entry["payload"].get("order_id", 0)) == 42)

	# Recovery must re-send with the ORIGINAL key. A fresh key would settle a
	# second time.
	_check("op_id is preserved for replay", str(entry.get("op_id", "")) == "op-crash")
	_check("outstanding includes it", reopened.outstanding().size() == 1)


## A crash between writing the temporary file and renaming it.
func _test_partial_write_discarded() -> void:
	_cleanup()
	var led = _fresh()
	led.begin("op-good", PendingLedger.KIND_LISTING, {"listing_id": 1})

	# Simulate the crash: a truncated temporary alongside a good real file.
	var f := FileAccess.open(_path + ".tmp", FileAccess.WRITE)
	f.store_string('{"version": 1, "entries": [{"op_id": "op-tr')
	f.close()

	var reopened = _fresh()
	_check("good entry survives a partial write", reopened.has("op-good"))
	_check("partial write is discarded", not FileAccess.file_exists(_path + ".tmp"))
	_check("truncated entry is not loaded", reopened.count() == 1)


## An unreadable ledger must be kept, not silently replaced. If it records
## destroyed goods it is evidence, and starting clean would hide that.
func _test_unreadable_file_kept() -> void:
	_cleanup()
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string("this is not json at all")
	f.close()

	var led = _fresh()
	_check("unreadable ledger loads as empty", led.count() == 0)
	_check("unreadable ledger is left on disk", FileAccess.file_exists(_path))

	var raw := FileAccess.open(_path, FileAccess.READ)
	var text := raw.get_as_text()
	raw.close()
	_check("unreadable ledger is not overwritten on load",
		text == "this is not json at all")


func _test_attempts_and_stalling() -> void:
	_cleanup()
	var led = _fresh()
	led.begin("op-flaky", PendingLedger.KIND_LISTING, {})

	for i in range(PendingLedger.MAX_RECOVERY_ATTEMPTS):
		led.note_error("op-flaky", "connection reset")

	var entry: Dictionary = led.get_entry("op-flaky")
	_check("attempts are counted",
		int(entry.get("attempts", 0)) == PendingLedger.MAX_RECOVERY_ATTEMPTS)
	_check("last error is recorded", str(entry.get("last_error", "")) == "connection reset")
	_check("entry is reported stalled", led.stalled().size() == 1)
	# Stalled means "stop retrying automatically", never "discard".
	_check("stalled entry is still outstanding", led.outstanding().size() == 1)

	var reopened = _fresh()
	_check("attempt count survives a restart",
		int(reopened.get_entry("op-flaky").get("attempts", 0))
			== PendingLedger.MAX_RECOVERY_ATTEMPTS)


func _test_advance_unknown_refused() -> void:
	_cleanup()
	var led = _fresh()
	print("  -- the next check expects an ERROR line: advancing an unknown op")
	_check("advancing an unknown op is refused",
		led.advance("op-nope", PendingLedger.LOCAL_COMMITTED) == false)


# --- Reporting ---

func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)
