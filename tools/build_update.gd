extends SceneTree
# Builds a patch from the listed files:
#   godot --headless --path . -s tools/build_update.gd -- <out.pck> res://a.gd res://b.gd ...
func _initialize():
	var args = OS.get_cmdline_user_args()
	var packer = PCKPacker.new()
	var ok = packer.pck_start(args[0]) == OK
	for path in args.slice(1):
		ok = ok && packer.add_file(path, ProjectSettings.globalize_path(path)) == OK
	ok = ok && packer.flush() == OK
	print("patch ", "built" if ok else "FAILED", ": ", args[0])
	quit(0 if ok else 1)
