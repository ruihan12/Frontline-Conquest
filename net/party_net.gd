# Pumps a PartyNetModel's hub connection every frame (the model is a RefCounted).
class_name PartyNet
extends Node

var model


func _init(m) -> void:
	model = m
	name = "PartyNet"


func _ready() -> void:
	model.connect_hub()


func _process(dt: float) -> void:
	model.poll(dt)


func _exit_tree() -> void:
	model.close_hub()
