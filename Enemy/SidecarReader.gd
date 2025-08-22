extends Node

@export var ecgData = []

func _ready():
	pass


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if SideCarHandler.is_ws_connected():
		var ecg: PackedFloat32Array = SideCarHandler.latest_ecg
		var acc: Array = SideCarHandler.latest_acc
		print("ECG:", ecg)
		var x = 0
		if len(ecg) > 0:
			for i in range(len(ecg)):
				x += ecg[i]
			x /= len(ecg)
		#print("ECG MEAN:", x)
		ecgData.append(x)
		GlobalValues.ECGData.append(x+100)
		print("ACC:", acc)

