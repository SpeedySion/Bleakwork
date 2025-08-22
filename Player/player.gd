extends CharacterBody3D


const SPEED = 5.0
const ACCELERATION = 4.0
const JUMP_VELOCITY = 4.5

var keycount = 0

@export var mouse_sensitivity = 0.02

@onready var step_sound: AudioStreamPlayer = $Stepping
@onready var step_timer: Timer = $StepTimer

# Get the gravity from the project settings
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

func _ready():
	step_timer.timeout.connect(_on_step_timer_timeout)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta):
	velocity.y += -gravity * delta
	get_move_input(delta)
	
	move_and_slide()
	
	if velocity.length() > 0:
		if not step_timer.is_stopped():
			return
		step_timer.start()
	else:
		step_timer.stop()

func get_move_input(delta):
	var vy = velocity.y
	velocity.y = 0
	var input = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var dir = Vector3(input.x, 0, input.y).rotated(Vector3.UP, $Rotator.rotation.y)
	velocity = lerp(velocity, dir * SPEED, ACCELERATION * delta)
	velocity.y = vy

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		$Rotator.rotation.x -= event.relative.y * mouse_sensitivity
		$Rotator.rotation_degrees.x = clamp($Rotator.rotation_degrees.x, -90.0, 30.0)
		$Rotator.rotation.y -= event.relative.x * mouse_sensitivity

func _stepping_sounds():
	var timer := Timer.new()
	add_child(timer)
	
func _on_step_timer_timeout():
	step_sound.play()
