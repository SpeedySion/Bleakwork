extends Node3D

@onready var player = $Player

func _physics_process(delta):
	get_tree().call_group("enemy", "_update_target_location", player.global_transform.origin)
	if GlobalValues.KeysGained >= 5:
		print(GlobalValues.ECGData)
		save_to_file(GlobalValues.ECGData)
		get_tree().change_scene_to_file("res://Scenes/success.tscn")

func save_to_file(content):
	var file = FileAccess.open("res://Data/ECGData.txt", FileAccess.WRITE)
	file.store_string(content)
