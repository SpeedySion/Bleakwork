extends Node
class_name SidecarHandler

const SIDECAR_PATH := "res://ExternalScripts/bleak_ws_sidecar.py"

const WS_HOST := "127.0.0.1"
const WS_PORT := 8765

const WANT_ECG := true
const WANT_ACC := true

const BUNDLED_PYTHON := "C:/Users/cgrah/AppData/Local/Programs/Python/Python312/python.exe"

const WS_RETRY_INTERVAL := 1.0
const SIDECAR_RESTART_ON_EXIT := true

signal meta_received(device: String, backend: String, features: Array)
signal ecg_frame(t: float, fs: int, samples: PackedFloat32Array)
signal acc_frame(t: float, fs: int, samples: Array) 
signal ws_connection_changed(connected: bool)

var _pid: int = -1
var _ws: WebSocketPeer
var _ws_connected := false
var _last_ws_attempt := -1.0

# Latest frames cached for easy access
var latest_ecg: PackedFloat32Array = PackedFloat32Array()
var latest_ecg_t: float = 0.0
var latest_ecg_fs: int = 0

var latest_acc: Array = []
var latest_acc_t: float = 0.0
var latest_acc_fs: int = 0

func _ready() -> void:
	_ws = WebSocketPeer.new()
	print("[Sidecar] _ready")
	_launch_sidecar()
	_connect_ws()

func _process(_dt: float) -> void:
	if _ws == null:
		return

	var state := _ws.get_ready_state()
	if state != WebSocketPeer.STATE_OPEN:
		if (Time.get_unix_time_from_system() - _last_ws_attempt) >= WS_RETRY_INTERVAL:
			print("[Sidecar] retry connect; state=", state)
			_connect_ws()
	else:
		if not _ws_connected:
			print("[Sidecar] WS OPEN")
		_ws_connected = true

	_ws.poll()
	while _ws.get_available_packet_count() > 0:
		var pkt: String = _ws.get_packet().get_string_from_utf8()

		var parsed: Variant = JSON.parse_string(pkt)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue

		var data: Dictionary = parsed as Dictionary

		match String(data.get("type","")):
			"meta":
				print("[Sidecar] META: ", data)
				meta_received.emit(
					String(data.get("device","Unknown")),
					String(data.get("backend","")),
					data.get("features", [])
				)
			"ecg":
				latest_ecg_t = float(data.get("t", 0.0))
				latest_ecg_fs = int(data.get("fs", 0))
				var arr: Array = data.get("ecg", [])
				latest_ecg = PackedFloat32Array(arr)
				# print("[Sidecar] ECG n=", latest_ecg.size(), " fs=", latest_ecg_fs)
				ecg_frame.emit(latest_ecg_t, latest_ecg_fs, latest_ecg)
			"acc":
				latest_acc_t = float(data.get("t", 0.0))
				latest_acc_fs = int(data.get("fs", 0))
				latest_acc = data.get("acc", [])
				# print("[Sidecar] ACC n=", latest_acc.size(), " fs=", latest_acc_fs)
				acc_frame.emit(latest_acc_t, latest_acc_fs, latest_acc)
			_:
				pass

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_sidecar()
		get_tree().quit()
	elif what == NOTIFICATION_PREDELETE or what == NOTIFICATION_EXIT_TREE:
		_stop_sidecar()
		_close_ws()


func is_ws_connected() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func _connect_ws() -> void:
	if _ws == null:
		_ws = WebSocketPeer.new()

	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN \
	or state == WebSocketPeer.STATE_CONNECTING \
	or state == WebSocketPeer.STATE_CLOSING:
		return

	_last_ws_attempt = Time.get_unix_time_from_system()
	var url := "ws://%s:%d" % [WS_HOST, WS_PORT]
	var err := _ws.connect_to_url(url)
	print("[Sidecar] connect_to_url(", url, ") -> ", err)

	if err != OK:
		push_warning("WS connect_to_url() failed with %s. Recreating peer…" % str(err))
		_ws = WebSocketPeer.new()
		err = _ws.connect_to_url(url)
		print("[Sidecar] reconnect result -> ", err)

	_ws_connected = (err == OK)
	ws_connection_changed.emit(_ws_connected)

func _close_ws() -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.close()
	_ws = null
	_ws_connected = false
	ws_connection_changed.emit(false)


func _launch_sidecar() -> void:
	if _pid != -1 and OS.is_process_running(_pid):
		return


	var sidecar_abs := ProjectSettings.globalize_path(SIDECAR_PATH)
	if not FileAccess.file_exists(sidecar_abs):
		push_warning("Sidecar script not found at: %s" % sidecar_abs)
		return

	var python := _resolve_python()
	if python == "":
		push_warning("No Python interpreter found; cannot start sidecar.")
		return

	var args: PackedStringArray = [
		sidecar_abs, "--host", WS_HOST, "--port", str(WS_PORT)
	]
	if WANT_ECG: args.append("--ecg")
	if WANT_ACC: args.append("--acc")


	var open_console := false 
	print("[Sidecar] python =", python)
	print("[Sidecar] create_process args=", args)
	_pid = OS.create_process(python, args, open_console)
	print("[Sidecar] create_process pid=", _pid)
	if _pid <= 0:
		push_warning("Failed to start sidecar (create_process returned %s)" % str(_pid))
	else:
		print("Sidecar started (pid=%d)" % _pid)

func _stop_sidecar() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
		print("Sidecar terminated (pid=%d)" % _pid)
	_pid = -1


func _resolve_python() -> String:
	if BUNDLED_PYTHON != "":
		var p := BUNDLED_PYTHON
		if p.begins_with("res://"):
			p = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(p):
			return p

	# 2) Try PATH on each platform
	match OS.get_name():
		"Windows":
			for cand in ["python.exe", "py.exe"]:
				var path := _which(cand)
				if path != "": return path
			return ""
		"macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			for cand in ["python3", "python"]:
				var path2 := _which(cand)
				if path2 != "": return path2
			return ""
		_:
			return ""

func _which(exe: String) -> String:
	var delimiter := ";" if OS.get_name() == "Windows" else ":"
	var paths := OS.get_environment("PATH").split(delimiter)
	for base in paths:
		if base == "": continue
		var candidate := base.path_join(exe)
		if FileAccess.file_exists(candidate):
			return candidate
		if OS.get_name() == "Windows":
			for ext in [".exe", ".bat", ".cmd"]:
				if FileAccess.file_exists(candidate + ext):
					return candidate + ext
	return ""
