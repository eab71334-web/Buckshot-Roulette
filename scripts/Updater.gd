extends Node
# In-game updater. Must stay the FIRST autoload: it mounts the downloaded patch
# before any other game script or scene is loaded.
#
# Updates live on the "updates" branch: version.json + a small .pck holding only
# the files that changed since the installed base build.
#
# Keep this script self contained. A patch cannot replace it.

# Raise BASE only when a full reinstall is needed (permissions, engine, icon...).
const BASE := 1
const MANIFEST_URL := "https://raw.githubusercontent.com/eab71334-web/Buckshot-Roulette/updates/version.json"
const MENU_SCENE := "res://scenes/menu.tscn"
const DIR := "user://update"
const PATCH := DIR + "/patch.pck"
const PENDING := DIR + "/pending.pck"
const STATE := DIR + "/state.cfg"

var manifest_url := MANIFEST_URL
var installed := 0            # number of the update that is running now

var _state := ConfigFile.new()
var _remote := {}
var _healthy_time := 0.0
var _confirmed := false
var _layer : CanvasLayer
var _label : Label
var _yes : Button
var _no : Button
var _http : HTTPRequest
var _downloading := false

func _init():
	DirAccess.make_dir_recursive_absolute(DIR)
	_state.load(STATE)
	_ApplyPending()
	_Mount()

func _Get(key : String, fallback):
	return _state.get_value("update", key, fallback)

func _Set(key : String, value):
	_state.set_value("update", key, value)
	_state.save(STATE)

# A finished download waits as pending.pck until the next launch.
func _ApplyPending():
	var number : int = _Get("pending", 0)
	if (number == 0 || !FileAccess.file_exists(PENDING)): return
	DirAccess.remove_absolute(PATCH)
	if (DirAccess.rename_absolute(PENDING, PATCH) == OK):
		_Set("number", number)
		_Set("trying", false)
		_Set("good", false)
	_Set("pending", 0)

func _Mount():
	var number : int = _Get("number", 0)
	if (number == 0 || !FileAccess.file_exists(PATCH)): return
	# the app was reinstalled with a different base: the old patch no longer fits
	# "trying" still set means the last start with this patch never reached the menu
	if (_Get("base", BASE) != BASE || (_Get("trying", false) && !_Get("good", false))):
		_Discard(number)
		return
	if (!_Get("good", false)): _Set("trying", true)
	if (ProjectSettings.load_resource_pack(ProjectSettings.globalize_path(PATCH), true)):
		installed = number
	else:
		_Discard(number)

func _Discard(number : int):
	DirAccess.remove_absolute(PATCH)
	_Set("bad", number)
	_Set("number", 0)
	_Set("trying", false)
	_Set("good", false)

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	_Check.call_deferred()

func _process(delta):
	var scene = get_tree().current_scene
	var in_menu : bool = scene != null && scene.scene_file_path == MENU_SCENE
	# the patch is trusted once the menu has run for a few seconds
	if (!_confirmed && in_menu):
		_healthy_time += delta
		if (_healthy_time > 3.0):
			_confirmed = true
			if (installed > 0):
				_Set("good", true)
				_Set("trying", false)
			_ShowVersion(scene)
	if (_downloading && _label != null):
		var total = int(_remote.get("size", 0))
		if (total > 0):
			_label.text = "DOWNLOADING  " + str(min(99, int(_http.get_downloaded_bytes() * 100.0 / total))) + "%"

func _ShowVersion(scene : Node):
	var label = scene.get_node_or_null("Camera/dialogue UI/menu ui/main screen/version")
	if (label != null && installed > 0): label.text += "  -  UPDATE " + str(installed)

#CHECKING

func _Check():
	if (_http.request(manifest_url) != OK): return
	var result = await _http.request_completed
	if (result[0] != HTTPRequest.RESULT_SUCCESS || result[1] != 200): return   # offline: just play
	var data = JSON.parse_string(result[3].get_string_from_utf8())
	if (!(data is Dictionary)): return
	var number = int(data.get("number", 0))
	if (number <= installed || number == _Get("bad", 0) || number == _Get("pending", 0)): return
	_remote = data
	# wait for the menu intro to finish; never interrupt a running match
	var waited := 0.0
	while (waited < 10.0):
		await get_tree().create_timer(0.5).timeout
		var scene = get_tree().current_scene
		if (scene == null || scene.scene_file_path != MENU_SCENE): return
		waited += 0.5
	if (int(data.get("base", 0)) != BASE):
		_ShowPanel("A NEW VERSION NEEDS\nA FULL REINSTALL", "", "OK")
	else:
		var mb = "%.2f MB" % (int(data.get("size", 0)) / 1048576.0)
		_ShowPanel("UPDATE " + str(number) + " AVAILABLE\n" + str(data.get("notes", "")) + "\n" + mb, "UPDATE", "LATER")

#DOWNLOADING

func _Download():
	_yes.visible = false
	_no.visible = false
	_label.text = "DOWNLOADING"
	var url : String = manifest_url.get_base_dir() + "/" + str(_remote.get("file", "")).uri_encode()
	var temp := DIR + "/download.tmp"
	_http.timeout = 0.0
	_http.download_file = temp
	if (_http.request(url) != OK):
		_Failed()
		return
	_downloading = true
	var result = await _http.request_completed
	_downloading = false
	_http.download_file = ""
	if (result[0] != HTTPRequest.RESULT_SUCCESS || result[1] != 200 || FileAccess.get_sha256(temp) != str(_remote.get("sha256", ""))):
		DirAccess.remove_absolute(temp)
		_Failed()
		return
	DirAccess.remove_absolute(PENDING)
	DirAccess.rename_absolute(temp, PENDING)
	_Set("base", BASE)
	_Set("pending", int(_remote.get("number", 0)))
	_label.text = "UPDATE READY\nclose the game completely\nthen open it again"
	_no.text = "OK"
	_no.visible = true

func _Failed():
	_label.text = "DOWNLOAD FAILED\ncheck your internet and try again"
	_yes.text = "RETRY"
	_yes.visible = true
	_no.visible = true

#PANEL

func _ShowPanel(text : String, yes : String, no : String):
	var font = load("res://fonts/fake receipt.otf")
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)

	var shade = ColorRect.new()
	shade.color = Color(0, 0, 0, 0.85)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(shade)

	var frame = Panel.new()
	frame.position = Vector2(220, 120)
	frame.size = Vector2(520, 300)
	frame.add_theme_stylebox_override("panel", _Box(Color(0.35, 0.95, 0.45, 0.6), Color(0.01, 0.01, 0.01, 1)))
	shade.add_child(frame)

	_label = Label.new()
	_label.position = Vector2(20, 30)
	_label.size = Vector2(480, 160)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", 24)
	_label.text = text
	frame.add_child(_label)

	_yes = _Button(frame, font, yes, Vector2(50, 215))
	_yes.visible = yes != ""
	_yes.pressed.connect(_Download)
	_no = _Button(frame, font, no, Vector2(280 if yes != "" else 165, 215))
	_no.pressed.connect(func(): _layer.queue_free())
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _Box(border : Color, fill : Color) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(2)
	return box

func _Button(parent : Control, font : Font, text : String, at : Vector2) -> Button:
	var button = Button.new()
	button.text = text
	button.position = at
	button.size = Vector2(190, 56)
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_stylebox_override("normal", _Box(Color(1, 1, 1, 0.35), Color(0, 0, 0, 0.8)))
	button.add_theme_stylebox_override("hover", _Box(Color.WHITE, Color(0.16, 0.04, 0.03, 1)))
	button.add_theme_stylebox_override("pressed", _Box(Color(0.78, 0.13, 0.11), Color(0.25, 0.03, 0.02, 1)))
	parent.add_child(button)
	return button
