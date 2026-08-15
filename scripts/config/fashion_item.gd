class_name FashionItem
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_enum("back", "body", "hands", "face", "head") var slot: String = "head"
@export var texture: Texture2D
