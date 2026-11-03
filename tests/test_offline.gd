extends SceneTree

## Offline behaviour (§8.3): a designed state, not an error path.

const MarketClientScript := preload("res://mods/FleaMarket/MarketClient.gd")
const MarketTheme := preload("res://mods/FleaMarket/ui/MarketTheme.gd")

var _passed := 0
var _failed := 0

func _init() -> void:
	print("")
	print("Offline behaviour")
	print("=================")
	_run()

func _run() -> void:
	await process_frame
	await process_frame

	var client = MarketClientScript.new()
	root.add_child(client)
	# A port nothing is listening on: the transport fails, which is what being
	# offline actually looks like.
	client.configure("http://127.0.0.1:9/v1", "test-key")

	var seen_offline := [false]
	client.online_changed.connect(func(on): if not on: seen_offline[0] = true)

	_check("starts assumed online", client.is_online())

	var res: Dictionary = await client.get_json("/listings")
	_check("an unreachable market is not ok", not res["ok"])
	_check("it is reported as offline, not as an error",
		str(res.get("error", "")) == "offline")
	_check("the message is written for a player",
		str(res.get("message", "")).length() > 10)
	_check("the client knows it is offline", not client.is_online())
	_check("it emitted online_changed(false)", seen_offline[0])

	# Staleness drives the banner from the server's own as_of, so it reports
	# when the MARKET last spoke rather than when this client last asked.
	_check("staleness of an empty as_of is honest",
		MarketTheme.staleness("") == "age unknown")
	var recent := Time.get_datetime_string_from_unix_time(
		int(Time.get_unix_time_from_system()) - 7200, true) + "Z"
	_check("a two-hour-old cache reads as hours",
		MarketTheme.staleness(recent).ends_with("h old"))

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s" % label)
