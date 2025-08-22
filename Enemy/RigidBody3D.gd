# EnemyChase.gd
extends RigidBody3D

@export var player_path: NodePath = "res://Player/player.tscn"
@export var speed: float = 6.0
@export var repath_interval: float = 0.2
@export var stop_distance: float = 0.8
@export var face_move_dir: bool = true

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var player: Node3D = get_node_or_null(player_path)

var _repath_accum := 0.0

func _ready() -> void:
	# NavigationAgent settings
	agent.path_desired_distance = 0.25
	agent.target_desired_distance = stop_distance
	agent.avoidance_enabled = true

	# RigidBody setup for manual movement
	freeze = false
	can_sleep = false
	gravity_scale = 1.0

func _physics_process(delta: float) -> void:
	if player == null:
		return

	# periodically refresh target
	_repath_accum += delta
	if _repath_accum >= repath_interval:
		_repath_accum = 0.0
		agent.set_target_position(player.global_transform.origin)

	if agent.is_navigation_finished():
		linear_velocity = Vector3.ZERO
		return

	var cur := global_transform.origin
	var next_pos := agent.get_next_path_position()
	var to_next := next_pos - cur
	to_next.y = 0  # stay on ground plane

	if to_next.length() < stop_distance:
		linear_velocity = Vector3.ZERO
		return

	var desired_vel := to_next.normalized() * speed
	# Smoothly apply velocity to RigidBody
	linear_velocity.x = desired_vel.x
	linear_velocity.z = desired_vel.z

	agent.set_velocity(desired_vel)

	if face_move_dir and desired_vel.length() > 0.1:
		var f := desired_vel.normalized()
		f.y = 0.0
		if f.length() > 0.0:
			look_at(cur + f, Vector3.UP)
