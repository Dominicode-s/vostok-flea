extends RefCounted

# No class_name on purpose: a global class registered from inside a mod archive
# collides across mods and survives reloads badly. Callers preload it.

## Save-persisted record of operations that are in flight.
##
## This is the entire crash-recovery mechanism (§5.1). Everything else in the
## design leans on it: "no failure — crash, timeout, rage-quit, power cut — can
## lose a player's items or money" is only true because this file survives the
## crash and says what was happening.
##
## ## The ordering it exists to enforce
##
##     write(op, phase=LOCAL_COMMITTED)   <- FIRST, and flushed to disk
##     destroy the item / the cash        <- second
##     POST .../confirm or .../settle     <- third
##
## That sequence is not a style preference. It is the only window in the whole
## design where property can actually be lost, and it is entirely client-side:
## destroy before recording, crash in between, and the item is gone with no
## record on either side. Record first and the worst case is a replay.
##
## ## Why entries are never trusted as truth
##
## An entry says "I was doing this", never "this happened". Recovery re-sends
## the original call with the ORIGINAL op_id and believes whatever the server
## answers. The server is the only thing that knows what actually landed, and a
## client that could assert an outcome would be a duplicator.
##
## ## Scope
##
## Per save profile. Profiles are separate worlds, and an operation begun in one
## should not replay while another is loaded — the same class of bug Secure
## Container shipped a fix for. The cost is that an entry stranded in a profile
## the player abandons is never replayed; the server's reservation expiry
## refunds them anyway, so the worst case is a credit note instead of a listing.
##
## Stored under user://FleaMarket/ rather than beside it, because the game's
## Loader.FormatSave() deletes every top-level *.tres in user:// on a save
## reset and lists the directory non-recursively.

## Phases, in order. An entry moves forward only; it never goes back.
##
##   RESERVED         phase 1 returned. Nothing destroyed. Abandoning is free —
##                    the server's window lapses and nothing was ever taken.
##   LOCAL_COMMITTED  the client is about to destroy, or has destroyed, the
##                    goods. THIS is the phase that must reach disk first.
##   CONFIRMED        phase 2 returned. The server has the goods and has said
##                    what it did with them.
##   DONE             fully settled; the entry is dropped.
const RESERVED := "reserved"
const LOCAL_COMMITTED := "local_committed"
const CONFIRMED := "confirmed"
const DONE := "done"

## Operation kinds. Each maps to the phase-2 call recovery must re-send.
const KIND_LISTING := "listing"
const KIND_ORDER := "order"
const KIND_BROKER_SELL := "broker_sell"
const KIND_DELIVERY_ACK := "delivery_ack"

const DIR := "user://FleaMarket"

## Give up re-sending after this many attempts and leave the entry for a human
## to look at. It is never dropped: an entry that cannot be resolved is exactly
## the thing worth keeping.
const MAX_RECOVERY_ATTEMPTS := 8

var _path := ""
var _entries := {}   # op_id -> entry dictionary


func _init(profile_id: String = "default") -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_path = "%s/pending_%s.json" % [DIR, profile_id]
	_read()


# --- Writing ---

## Record a new operation. Returns the entry.
##
## `op_id` is the caller's idempotency key and is generated BEFORE this call,
## because its lifetime is longer than any single request: recovery re-sends
## with the same value, and a key minted per attempt would perform the action
## twice.
func begin(op_id: String, kind: String, payload: Dictionary) -> Dictionary:
	var entry := {
		"op_id": op_id,
		"kind": kind,
		"phase": RESERVED,
		"payload": payload,
		"created_at": int(Time.get_unix_time_from_system()),
		"updated_at": int(Time.get_unix_time_from_system()),
		"attempts": 0,
		"last_error": "",
	}
	_entries[op_id] = entry
	_write()
	return entry


## Move an entry to a later phase and flush.
##
## Returns false if the entry is unknown, which the caller must treat as a
## reason to stop rather than continue: destroying goods for an operation the
## ledger has no record of is the one thing this class exists to prevent.
func advance(op_id: String, phase: String, extra: Dictionary = {}) -> bool:
	if not _entries.has(op_id):
		push_error("FleaMarket: advance() on unknown op %s" % op_id)
		return false
	var entry: Dictionary = _entries[op_id]
	entry["phase"] = phase
	entry["updated_at"] = int(Time.get_unix_time_from_system())
	for k in extra:
		entry["payload"][k] = extra[k]
	return _write()


func note_error(op_id: String, message: String) -> void:
	if not _entries.has(op_id):
		return
	var entry: Dictionary = _entries[op_id]
	entry["last_error"] = message
	entry["attempts"] = int(entry.get("attempts", 0)) + 1
	entry["updated_at"] = int(Time.get_unix_time_from_system())
	_write()


## Drop a fully settled operation.
func complete(op_id: String) -> void:
	if _entries.erase(op_id):
		_write()


# --- Reading ---

func has(op_id: String) -> bool:
	return _entries.has(op_id)


func get_entry(op_id: String) -> Dictionary:
	var v = _entries.get(op_id)
	return v if v is Dictionary else {}


func count() -> int:
	return _entries.size()


## Every entry that is not finished, oldest first.
##
## Order matters on recovery: operations are replayed in the sequence they were
## begun, so a listing created before an order settles first.
func outstanding() -> Array:
	var out := []
	for op_id in _entries:
		var entry: Dictionary = _entries[op_id]
		if str(entry.get("phase", "")) != DONE:
			out.append(entry)
	out.sort_custom(func(a, b): return int(a["created_at"]) < int(b["created_at"]))
	return out


## Entries that have failed too often to keep retrying automatically.
func stalled() -> Array:
	var out := []
	for entry in outstanding():
		if int(entry.get("attempts", 0)) >= MAX_RECOVERY_ATTEMPTS:
			out.append(entry)
	return out


func is_stalled(entry: Dictionary) -> bool:
	return int(entry.get("attempts", 0)) >= MAX_RECOVERY_ATTEMPTS


# --- Persistence ---

## Write atomically: full contents to a temporary file, then rename over the
## real one.
##
## A plain overwrite has a window where the file is truncated but not yet
## rewritten, and a crash there loses every in-flight operation at once — the
## precise moment this data is most needed. Rename is atomic on Windows and
## POSIX alike.
func _write() -> bool:
	var tmp := _path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("FleaMarket: cannot write pending ledger (%d)" % FileAccess.get_open_error())
		return false

	f.store_string(JSON.stringify({
		"version": 1,
		"saved_at": int(Time.get_unix_time_from_system()),
		"entries": _entries.values(),
	}, "  "))
	# Close before renaming: the handle must be released or the rename fails on
	# Windows, and a half-flushed file would defeat the point of writing to a
	# temporary at all.
	f.close()

	var dir := DirAccess.open(DIR)
	if dir == null:
		push_error("FleaMarket: cannot open %s to finalise the pending ledger" % DIR)
		return false
	var err := dir.rename(tmp.get_file(), _path.get_file())
	if err != OK:
		push_error("FleaMarket: could not finalise the pending ledger (%d)" % err)
		return false
	return true


func _read() -> void:
	_entries.clear()

	# A leftover .tmp means a crash between writing and renaming. The real file
	# is then the last known-good one and is used as-is; the temporary is
	# discarded rather than trusted, because it may be half-written.
	var tmp := _path + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
		push_warning("FleaMarket: discarded a partial pending-ledger write")

	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		# Keep the unreadable file rather than overwriting it. If it holds a
		# record of destroyed goods, it is evidence, and a support question is
		# far better than silently starting clean.
		push_error("FleaMarket: pending ledger is unreadable; left in place at " + _path)
		return

	var entries = parsed.get("entries", [])
	if not entries is Array:
		return
	for entry in entries:
		if not entry is Dictionary:
			continue
		var op_id := str(entry.get("op_id", ""))
		if op_id == "":
			continue
		if not entry.has("payload") or not entry["payload"] is Dictionary:
			entry["payload"] = {}
		_entries[op_id] = entry
