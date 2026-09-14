extends Node3D

## 3D 场景协调者
## 复用 2D 版的 IslandGenerator / TerrainPlacer / TerrainDiffuser，
## 只把 2D 渲染器换成 3D 版的 MapRenderer3D。

@export var palette: TerrainPalette = preload("res://map_gen/default_palette.tres")

@onready var island_gen: IslandGenerator = $IslandGen
@onready var placer: TerrainPlacer = $Placer
@onready var diffuser: TerrainDiffuser = $Diffuser
@onready var beach: BeachPostProcessor = $Beach
@onready var renderer_3d: MapRenderer3D = $Renderer3D
@onready var regen_button: Button = $UI/Margin/VBox/Row/Side/RegenButton

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# 渲染器初始化（创建海面 MultiMesh、方块 MultiMesh）
	renderer_3d.setup()
	# 配置环境：天空背景 + 环境光，避免纯黑背景和方块暗面过暗
	_setup_environment()
	# 按钮信号
	regen_button.pressed.connect(_on_regen)
	# 首次自动生成
	_on_regen()
	# 注：相机控制由 camera_controller_3d.gd（挂在 Camera3D 上）负责，
	# 它追踪 CameraTarget 空物体（位于地图中心 100,0,100），
	# 支持 Q/E 旋转、滚轮缩放，无需这里手动定位


# 创建带天空的环境，挂到 WorldEnvironment 节点
func _setup_environment() -> void:
	var we: WorldEnvironment = $WorldEnvironment
	var env := Environment.new()
	# 天空背景（渐变蓝），让背景不是纯黑
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# 环境光（让方块暗面也能看清）
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	we.environment = env


func _on_regen() -> void:
	var data := MapData.new()
	data.init()
	_rng.randomize()
	island_gen.generate(data, _rng)
	placer.place(data, _rng)
	diffuser.diffuse(data)
	# 海岸沙滩后处理：在扩散完成后，把岛屿边缘改成沙滩
	beach.apply(data)
	renderer_3d.apply(data)
