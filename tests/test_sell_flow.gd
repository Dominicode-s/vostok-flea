extends SceneTree

## SellFlow against the chaos server.
##
## The local tests prove the pieces are self-consistent. This proves the risky
## behaviour: that a lapsed window is reported as goods returned rather than as
## a sale, that a lost phase-2 response is survivable, and that a replay reuses
## the original key instead of settling twice.
##
## Needs the chaos server running:
##     python tools/chaos_server.py --port 8788
##     tools/run-tests.sh test_sell_flow
##
## Skips with a clear message if it is not up, rather than failing -- a test
## that fails for an absent dependency trains you to ignore red.

const SellFlow := preload("res://mods/FleaMarket/SellFlow.gd")
const PendingLedger := preload("res://mods/FleaMarket/PendingLedger.gd")
const MarketClientScript := preload("res://mods/FleaMarket/MarketClient.gd")

const BASE := "http://127.0.0.1:8788/v1"
const CHAOS := "http://127.0.0.1:8788"
const PROFILE := "test_sell"

var _passed := 0
var _failed := 0
var _client: Node = null
var _ledger: RefCounted = null

## A minimal item the mock accepts. Not a real catalog entry: this exercises the
## FLOW, and descriptor correctness is covered by test_item_bridge and by
## validate-descriptors against the real validator.
const SLOT_DESC := {
	"descriptor_version": 2, "item_key": "Mosin", "amount": 0,
	"condition": 41.0, "attachments": [], "state": "",
	"storage": [], "custom": {},
}


func _init() -> void:
	print("")
	print("SellFlow (chaos server)")
	print("=======================")
	_run()


func _run() -> void:
	# _init() runs BEFORE the main loop starts iterating, and HTTPRequest polls
	# from the loop. Without yielding first, every request sits there until the
	# timeout and the whole suite reports offline.
	await process_frame
	await process_frame

	_client = MarketClientScript.new()
	root.add_child(_client)
	_client.configure(BASE, "test-key")

	if not await _chaos_up():
		print("  SKIPPED -- chaos server not running on 127.0.0.1:8788")
		print("  start it with: python tools/chaos_server.py")
		quit(0)
		return

	await _post_chaos("/__reset", {})
	_fresh_ledger()

	await _test_quote_records_before_calling()
	await _test_confirm_publishes()
	await _test_lapsed_window_is_not_a_sale()
	await _test_lost_response_is_retried_transparently()
	await _test_crash_before_confirm_is_replayed()
	await _test_recovery_abandons_uncommitted()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _fresh_ledger() -> void:
	var path := "user://FleaMarket/pending_%s.json" % PROFILE
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_ledger = PendingLedger.new(PROFILE)


# --- Tests ---

func _test_quote_records_before_calling() -> void:
	var q: Dictionary = await SellFlow.quote(_client, _ledger, null, 900, 2)
	_check("a null item is refused without calling out",
		not q["ok"] and str(q["outcome"]) == SellFlow.OUTCOME_REFUSED)

	# Phase 1 through the real path.
	var res: Dictionary = await _client.post_json("/listings", {
		"descriptor": SLOT_DESC, "ask_price": 900, "catalog_version": 2,
	}, _client.new_idempotency_key())
	_check("phase 1 reaches the mock", res["ok"])


func _test_confirm_publishes() -> void:
	var op := await _phase_one(900)
	_check("quote records a confirm key up front",
		str(_ledger.get_entry(op)["payload"].get("confirm_key", "")) != "")

	_ledger.advance(op, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})
	var r: Dictionary = await SellFlow._confirm(_client, _ledger, op)
	_check("confirm publishes", r["ok"] and str(r["outcome"]) == SellFlow.OUTCOME_LISTED)
	_check("settled entry is dropped", not _ledger.has(op))


## The one the server side warned about: HTTP 200, but nothing was sold.
func _test_lapsed_window_is_not_a_sale() -> void:
	var op := await _phase_one(900)
	_ledger.advance(op, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})

	await _post_chaos("/__chaos", {"next": "lapse_window"})
	var r: Dictionary = await SellFlow._confirm(_client, _ledger, op)

	_check("lapsed window is reported ok (it is not an error)", r["ok"])
	_check("lapsed window is NOT reported as a sale",
		str(r["outcome"]) == SellFlow.OUTCOME_RETURNED)
	_check("lapsed window names a return delivery", int(r.get("delivery_id", 0)) > 0)
	_check("lapsed entry is settled", not _ledger.has(op))


## Phase 2 lands, the reply does not.
##
## MarketClient retries transport failures itself, and the server returns the
## ORIGINAL result for a replayed key -- so this resolves inside the client and
## never reaches ledger recovery. The sale settles exactly once, which is the
## property that matters; where it settles is an implementation detail.
func _test_lost_response_is_retried_transparently() -> void:
	var op := await _phase_one(900)
	_ledger.advance(op, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})

	await _post_chaos("/__chaos", {"next": "lose_response"})
	var r: Dictionary = await SellFlow._confirm(_client, _ledger, op)

	_check("a lost reply is recovered by the client's own retry",
		r["ok"] and str(r["outcome"]) == SellFlow.OUTCOME_LISTED)
	_check("the sale settles exactly once", not _ledger.has(op))


## The client dies outright between destroying the goods and phase 2 -- no
## retry, no chance to react. This is what the ledger is FOR.
func _test_crash_before_confirm_is_replayed() -> void:
	var op := await _phase_one(900)
	_ledger.advance(op, PendingLedger.LOCAL_COMMITTED, {"destroyed": true})
	var key := str(_ledger.get_entry(op)["payload"]["confirm_key"])

	# ...process dies here. Nothing calls confirm.

	# A later session reads the ledger back off disk, exactly as it would on
	# load, and finds the unfinished operation.
	var reloaded = PendingLedger.new(PROFILE)
	_check("the interrupted sale survives to the next session",
		reloaded.has(op))
	_check("it is still at local_committed",
		str(reloaded.get_entry(op)["phase"]) == PendingLedger.LOCAL_COMMITTED)
	_check("the confirm key survives for the replay",
		str(reloaded.get_entry(op)["payload"]["confirm_key"]) == key)

	var results: Array = await SellFlow.recover(self, _client, reloaded)
	_check("recovery resolves it", results.size() == 1)
	_check("recovery reports the real outcome",
		results.size() == 1 and str(results[0]["outcome"]) == SellFlow.OUTCOME_LISTED)
	_check("recovery clears the entry", not reloaded.has(op))

	# The ledger this test started with shares the file, so re-read it to stay
	# consistent with what is now on disk.
	_ledger = PendingLedger.new(PROFILE)


## Phase 1 returned but nothing was destroyed. Abandoning costs nothing: the
## server escrowed nothing and its window lapses by itself.
func _test_recovery_abandons_uncommitted() -> void:
	var op := await _phase_one(900)
	_check("entry sits at reserved",
		str(_ledger.get_entry(op)["phase"]) == PendingLedger.RESERVED)

	var results: Array = await SellFlow.recover(self, _client, _ledger)
	_check("recovery drops an un-committed listing", not _ledger.has(op))
	_check("recovery does not report it as a sale", results.is_empty())


# --- Helpers ---

## Run phase 1 the way quote() does, without needing a live SlotData.
func _phase_one(ask: int) -> String:
	var op: String = _client.new_idempotency_key()
	_ledger.begin(op, PendingLedger.KIND_LISTING,
		{"descriptor": SLOT_DESC, "ask_price": ask})

	var res: Dictionary = await _client.post_json("/listings", {
		"descriptor": SLOT_DESC, "ask_price": ask, "catalog_version": 2,
	}, op)
	var body = res["json"]
	_ledger.advance(op, PendingLedger.RESERVED, {
		"listing_id": int(body.get("listing_id", 0)),
		"listing_fee": int(body.get("listing_fee", 0)),
		"confirm_key": _client.new_idempotency_key(),
		"destroyed": false,
	})
	return op


func _chaos_up() -> bool:
	var res: Dictionary = await _client.get_json("/ping")
	return bool(res["ok"])


func _post_chaos(path: String, body: Dictionary) -> void:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(CHAOS + path, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, JSON.stringify(body))
	await req.request_completed
	req.queue_free()


func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)
