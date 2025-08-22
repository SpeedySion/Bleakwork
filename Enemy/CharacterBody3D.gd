extends CharacterBody3D

@onready var nav_agent = $NavigationAgent3D
@onready var SPEED = 3.0


func _physics_process(delta):
	var curr_location = global_transform.origin
	var next_location = nav_agent.get_next_path_position()
	var new_velocity = (next_location - curr_location).normalized() * SPEED
	
	velocity = velocity.move_toward(new_velocity, 0.25)
	move_and_slide()

func _update_target_location(target_location):
	look_at(target_location)
	rotation_degrees.y -= 180
	nav_agent.target_position = target_location


func _on_area_3d_body_entered(body):
	if body.name == 'Player':
		print(GlobalValues.ECGData)
		save_to_file(GlobalValues.ECGData)
		get_tree().change_scene_to_file("res://Scenes/fail.tscn")

func save_to_file(content):
	var file = FileAccess.open("res://Data/ECGData.txt", FileAccess.WRITE)
	file.store_string(content)
