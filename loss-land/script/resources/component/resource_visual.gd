# script/resources/component/resource_visual.gd
# ============================================
# 视觉组件 - 管理资源的外观显示
#
# 这个组件负责：
# 1. 显示正确的贴图/动画
# 2. 播放状态切换动画
# 3. 处理视觉过渡效果
#
# 什么是 AnimatedSprite3D？
# 这是 Godot 的 3D 精灵节点，可以播放帧动画
# 类似于 2D 游戏中的 AnimatedSprite
# ============================================

class_name ResourceVisual
extends Node3D

# ============================================
# 导出变量
# 在编辑器中可以拖拽设置这些节点引用
# ============================================

# 3D 精灵节点，用于显示资源图片和动画
# 在场景中将 AnimatedSprite3D 节点拖入此处
@export var sprite: AnimatedSprite3D

# 动画播放器，用于播放复杂动画
# 可以播放与 SpriteFrames 不同的 AnimationPlayer 动画
@export var animation_player: AnimationPlayer

# ============================================
# 私有变量
# ============================================

# 资源数据的引用
var _resource_data: ResourceData

# 当前视觉状态
var _current_state: ResourceState.State = ResourceState.State.GROWING

# 程序化兜底网格列表（无美术贴图时自动生成，保证资源可见）
var _mesh_instances: Array[MeshInstance3D] = []

# ============================================
# 设置函数
# ============================================

# ----------------------------------------
# 设置函数
# 初始化视觉组件的配置
# 由 ResourceEntity 在 ready 时调用
#
# 参数：data - 资源数据配置
# ----------------------------------------
func setup(data: ResourceData) -> void:
	_resource_data = data
	
	# 如果设置了精灵和贴图，配置生长状态贴图
	if sprite and data.growing_texture:
		# sprite_frames 是 AnimatedSprite 的动画帧集合
		# set_frame_texture 设置某一帧的贴图
		# 参数1：动画名称
		# 参数2：帧索引
		# 参数3：贴图资源
		sprite.sprite_frames.set_frame_texture(data.growing_animation, 0, data.growing_texture)
	
	# 配置已采集状态贴图
	if sprite and data.harvested_texture:
		sprite.sprite_frames.set_frame_texture(data.harvested_animation, 0, data.harvested_texture)
	
	# 没有精灵/贴图时（当前草/树/石都未配美术资源），
	# 用程序化 3D 网格兜底，保证资源在世界上可见、可被靠近交互。
	if not (sprite and data.growing_texture):
		_build_placeholder_mesh(data)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置视觉状态函数
# 根据状态切换视觉表现
# 由 ResourceEntity 在状态改变时调用
#
# 参数：state - 目标状态
# ----------------------------------------
func set_visual_state(state: ResourceState.State) -> void:
	_current_state = state
	
	# 根据不同状态播放不同动画
	match state:
		ResourceState.State.GROWING:
			# 播放生长动画
			_play_animation(_resource_data.growing_animation if _resource_data else "grow")
		
		ResourceState.State.HARVESTED:
			# 播放已采集动画（枯萎）
			_play_animation(_resource_data.harvested_animation if _resource_data else "harvested")
		
		ResourceState.State.REGENERATING:
			# 播放再生动画
			_play_regen_animation()
		
		ResourceState.State.TRANSITIONING:
			# 播放过渡动画（采集动画）
			_play_transition_animation()

	# 程序化兜底网格：被采集后隐藏，其余状态显示
	if not _mesh_instances.is_empty():
		var show_mesh: bool = (state != ResourceState.State.HARVESTED)
		for mi in _mesh_instances:
			if is_instance_valid(mi):
				mi.visible = show_mesh

# ----------------------------------------
# 立即隐藏网格函数
# 采集到物品的那一帧调用，让"物品进背包"和"资源从画面上消失"同时发生。
#
# 为什么需要它：
#   ResourceEntity.harvest() 原先的顺序是「发物品 → 等 transition_duration
#   → 切 HARVESTED → 隐藏网格」。而当前没有动画播放器，这段过渡是**纯空等**，
#   于是东西已经进背包了，草/树/石头还立在原地（草 0.5s、树 1.0s、石 0.6s），
#   观感就是"采了却没消失"。现在发完物品立刻调用本函数收掉网格。
#
# 注意：只影响可见网格，状态机照常走完（决定再生何时开始）。
# 之后若再生，set_visual_state(GROWING) 会把网格重新显示出来。
# ----------------------------------------
func hide_mesh_immediate() -> void:
	for mi in _mesh_instances:
		if is_instance_valid(mi):
			mi.visible = false

# ----------------------------------------
# 立即设置视觉状态函数
# 不播放动画，直接切换显示
# 用于加载存档时恢复状态（不需要播放过渡动画）
#
# 参数：state - 目标状态
# ----------------------------------------
func set_visual_state_immediate(state: ResourceState.State) -> void:
	_current_state = state
	
	match state:
		ResourceState.State.GROWING:
			_set_frame_immediate(_resource_data.growing_animation if _resource_data else "grow")
		ResourceState.State.HARVESTED:
			_set_frame_immediate(_resource_data.harvested_animation if _resource_data else "harvested")

# ----------------------------------------
# 播放采集动画函数
# 采集时调用的特殊动画
# ----------------------------------------
func play_harvest_animation() -> void:
	# 检查是否有动画播放器
	if animation_player:
		# has_animation 检查是否有指定名称的动画
		if animation_player.has_animation("harvest"):
			animation_player.play("harvest")

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 播放动画函数
# 播放指定名称的动画
# ----------------------------------------
func _play_animation(anim_name: String) -> void:
	# 检查精灵和动画是否存在
	if sprite and sprite.sprite_frames:
		if sprite.sprite_frames.has_animation(anim_name):
			sprite.play(anim_name)

# ----------------------------------------
# 播放再生动画函数
# ----------------------------------------
func _play_regen_animation() -> void:
	if animation_player and animation_player.has_animation("regen"):
		animation_player.play("regen")

# ----------------------------------------
# 播放过渡动画函数
# ----------------------------------------
func _play_transition_animation() -> void:
	if animation_player and animation_player.has_animation("transition"):
		animation_player.play("transition")

# ----------------------------------------
# 立即设置动画帧函数
# 不播放动画，直接跳到指定帧
# 用于快速恢复状态
# ----------------------------------------
func _set_frame_immediate(anim_name: String) -> void:
	if sprite and sprite.sprite_frames:
		if sprite.sprite_frames.has_animation(anim_name):
			sprite.animation = anim_name  # 设置当前动画名称
			sprite.frame = 0              # 设置为第一帧（停止在当前帧）

# ============================================
# 程序化兜底网格（无贴图时调用）
# 按资源类型生成可辨识的简易 3D 外形，保证"看得见、能交互"
# ============================================
func _build_placeholder_mesh(data: ResourceData) -> void:
	if not _mesh_instances.is_empty():
		return
	var rt: int = data.resource_type if data else 0
	match rt:
		ResourceData.ResourceType.TREE:
			_add_mesh(_make_cylinder(0.22, 0.28, 1.6), Color(0.45, 0.30, 0.18), Vector3(0, 0.8, 0))
			_add_mesh(_make_cone(1.1, 1.8), Color(0.20, 0.55, 0.25), Vector3(0, 2.0, 0))
		ResourceData.ResourceType.STONE:
			_add_mesh(_make_box(0.9, 0.7, 0.9), Color(0.62, 0.62, 0.66), Vector3(0, 0.35, 0))
		ResourceData.ResourceType.PEBBLE:
			# 小石块：矮矮的两三块碎石，和大石头一眼就能区分
			_add_mesh(_make_box(0.42, 0.26, 0.42), Color(0.66, 0.66, 0.70), Vector3(-0.10, 0.13, 0.06))
			_add_mesh(_make_box(0.28, 0.18, 0.28), Color(0.55, 0.55, 0.60), Vector3(0.20, 0.09, -0.16))
		ResourceData.ResourceType.IRON_ORE:
			# 灰岩母岩 + 顶部几块橙锈色矿脉，远看就能和普通石头区分开
			_add_mesh(_make_box(1.1, 0.9, 1.1), Color(0.52, 0.52, 0.57), Vector3(0, 0.45, 0))
			_add_mesh(_make_box(0.34, 0.24, 0.34), Color(0.86, 0.50, 0.18), Vector3(0.18, 0.9, 0.16))
			_add_mesh(_make_box(0.22, 0.2, 0.22), Color(0.74, 0.42, 0.14), Vector3(-0.24, 0.88, -0.20))
		ResourceData.ResourceType.COAL:
			# 近黑色的煤块 + 一点灰亮面，与铁矿的橙色形成对比
			_add_mesh(_make_box(1.1, 0.9, 1.1), Color(0.14, 0.14, 0.16), Vector3(0, 0.45, 0))
			_add_mesh(_make_box(0.30, 0.20, 0.30), Color(0.34, 0.34, 0.38), Vector3(0.20, 0.90, -0.14))
		ResourceData.ResourceType.BUSH:
			# 浆果丛：绿色灌木球 + 几颗红果，空手可采（是饱食度的主要来源）
			_add_mesh(_make_sphere(0.55), Color(0.25, 0.65, 0.30), Vector3(0, 0.5, 0))
			_add_mesh(_make_sphere(0.12), Color(0.85, 0.18, 0.22), Vector3(0.28, 0.62, 0.16))
			_add_mesh(_make_sphere(0.12), Color(0.85, 0.18, 0.22), Vector3(-0.26, 0.55, -0.20))
			_add_mesh(_make_sphere(0.11), Color(0.92, 0.28, 0.30), Vector3(0.06, 0.78, -0.24))
		ResourceData.ResourceType.FLOWER:
			_add_mesh(_make_box(0.15, 0.6, 0.15), Color(0.40, 0.70, 0.30), Vector3(0, 0.3, 0))
			_add_mesh(_make_sphere(0.25), Color(0.90, 0.30, 0.50), Vector3(0, 0.7, 0))
		ResourceData.ResourceType.TWIG:
			# 地上一撮散落的树枝：三根细棍交叉，比单根竖棍容易辨认
			_add_mesh(_make_box(0.10, 0.55, 0.10), Color(0.55, 0.40, 0.25), Vector3(0.00, 0.28, 0.00))
			_add_mesh(_make_box(0.09, 0.48, 0.09), Color(0.48, 0.35, 0.22), Vector3(0.22, 0.24, 0.10))
			_add_mesh(_make_box(0.09, 0.42, 0.09), Color(0.60, 0.45, 0.28), Vector3(-0.18, 0.21, -0.12))
		ResourceData.ResourceType.GRASS:
			_add_mesh(_make_box(0.9, 0.45, 0.9), Color(0.30, 0.75, 0.30), Vector3(0, 0.22, 0))
		_:
			_add_mesh(_make_box(0.7, 0.7, 0.7), Color(0.70, 0.70, 0.70), Vector3(0, 0.35, 0))

# 创建一个带纯色材质的网格并挂到本组件下
func _add_mesh(mesh: Mesh, color: Color, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	_mesh_instances.append(mi)

func _make_box(x: float, y: float, z: float) -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b

func _make_sphere(r: float) -> Mesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s

func _make_cylinder(top: float, bottom: float, h: float) -> Mesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	return c

func _make_cone(r: float, h: float) -> Mesh:
	# 用 PrismMesh（棱锥）代替 ConeMesh，避免某些编辑器版本/缓存中 ConeMesh 类名未解析
	var p := PrismMesh.new()
	p.size = Vector3(r * 2.0, h, r * 2.0)
	return p
