extends Control

@export var palette: TerrainPalette = preload("res://map_gen/default_palette.tres")

@onready var island_gen: IslandGenerator = $IslandGen
@onready var placer: TerrainPlacer = $Placer
@onready var diffuser: TerrainDiffuser = $Diffuser
@onready var renderer: MapRenderer = $Renderer

@onready var map_texture: TextureRect = $Margin/VBox/Row/MapPanel/MapTexture
@onready var regen_button: Button = $Margin/VBox/Row/Side/RegenButton

var _rng := RandomNumberGenerator.new()
var _gen_id: int = 0
var _cur_tween: Tween = null


func _ready() -> void:
	renderer.setup(palette)
	map_texture.texture = renderer.get_texture()
	regen_button.pressed.connect(regenerate)
	regenerate()


func regenerate() -> void:
	_gen_id += 1
	if _cur_tween != null and _cur_tween.is_valid():
		_cur_tween.kill()
		_cur_tween = null
	_run(_gen_id)


func _run(gid: int) -> void:
	renderer.render_ocean(palette)
	await get_tree().create_timer(0.25).timeout
	if gid != _gen_id:
		return

	var data := MapData.new()
	data.init()
	_rng.randomize()
	island_gen.generate(data, _rng)
	placer.place(data, _rng)
	diffuser.diffuse(data)
	renderer.prepare_reveal(data, palette)
	await get_tree().create_timer(0.25).timeout
	if gid != _gen_id:
		return

	var dur: float = clampf(float(data.max_dist) / 60.0, 0.8, 1.4)
	_cur_tween = create_tween()
	_cur_tween.tween_method(renderer.reveal_to, 0.0, 1.0, dur)
	_cur_tween.tween_callback(_on_gen_done.bind(gid))


func _on_gen_done(gid: int) -> void:
	if gid != _gen_id:
		return
	renderer.reveal_all()
