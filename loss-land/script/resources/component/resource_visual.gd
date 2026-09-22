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

# 用 preload 而不用全局类名 SpriteFacing：
# 全局类名要靠 .godot/global_script_class_cache.cfg，新建脚本若尚未被编辑器
# 扫描登记，运行时就会报"找不到类"。preload 是编译期常量，不依赖那份缓存。
const Facing := preload("res://script/visual/sprite_facing.gd")

# ============================================
# 导出变量
# 在编辑器中可以拖拽设置这些节点引用
# ============================================

# 3D 精灵节点，用于显示资源图片和动画
# 在场景中将 AnimatedSprite3D 节点拖入此处
@export var sprite: AnimatedSprite3D

# 是否让贴图始终正对相机（含俯角补偿）
# 关掉则沿用场景里写死的朝向，贴图在拉远镜头时会被透视压扁
@export var face_camera: bool = true

# 俯角补偿比例：1.0 = 完全正对镜头（屏幕高度不随缩放变化），
# 0.0 = 不补偿（等同旧的 billboard = FIXED_Y）。详见 sprite_facing.gd
@export_range(0.0, 1.0, 0.05) var billboard_tilt: float = 1.0

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

# 贴图中心到锚点（实体原点 = 树根脚下的地面）的高度，取自精灵原始 position.y。
# 每帧的倾斜补偿绕这个锚点转，贴图底边才不会前后滑动、和碰撞体错位。
var _sprite_pivot: float = 0.0

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

	# 兜底：@export 的节点引用没被解析时（.tscn 的节点头部漏写
	# node_paths=PackedStringArray("sprite") 就会这样——**静默**拿到 null，
	# Godot 不报任何错），按场景里的节点名再找一次。
	#
	# 2026-09-22 的事故正是如此：tree.tscn 的 Visual 漏了 node_paths，
	# sprite 永远是 null，于是
	#   ① has_art 判成 false → 真有 25 帧美术的树上又叠了一层灰色兜底网格
	#      （表现为树旁边冒出一个白方块）；
	#   ② 真精灵彻底失去控制（hide_mesh_immediate / _update_sprite_visibility
	#      都因为 sprite == null 直接 return）→ 采集完树还立在原地。
	if sprite == null:
		sprite = _find_sprite_fallback()
		if sprite != null:
			DebugConfig.warn_msg(DebugConfig.CAT_RESOURCE,
				"[视觉] %s 的 sprite 引用未解析（检查 .tscn 是否漏写 node_paths），已按节点名兜底",
				[data.resource_id if data != null else &"?"])

	# 是否"已经配好真美术"：场景里的 AnimatedSprite3D 自带 SpriteFrames。
	#
	# 判据为什么不能用 growing_texture 是否为空？
	#   树的 tscn/prefab/tree.tscn 把 25 帧动画写在
	#   art/props/tree_1/tree_frames.tres 里，由帧资源自己描述完整，
	#   tree_data.tres 的 growing_texture 一直是空的。若沿用旧判据，这棵树会被
	#   当成"没有美术"，于是在真贴图上面**再叠一套**程序化兜底网格。
	var has_art: bool = _sprite_has_art()

	# 老路径：没有帧动画时，用 ResourceData 里的单张贴图当第 0 帧
	if sprite != null and not has_art:
		if sprite.sprite_frames == null:
			sprite.sprite_frames = SpriteFrames.new()
		# sprite_frames 是 AnimatedSprite 的动画帧集合
		# set_frame_texture 设置某一帧的贴图
		_set_single_frame(data.growing_animation, data.growing_texture)
		_set_single_frame(data.harvested_animation, data.harvested_texture)

	# 既没有帧动画、也没有单张贴图时，用程序化 3D 网格兜底，
	# 保证资源在世界上可见、可被靠近交互。
	if not has_art and data.growing_texture == null:
		_build_placeholder_mesh(data)

	# 记录贴图中心高度：倾斜补偿要绕"贴图底边"转（见 _apply_facing），
	# 所以必须知道中心离锚点多高。场景里给的就是这个值。
	if sprite != null:
		_sprite_pivot = sprite.position.y


# ============================================
# 每帧朝向
# ============================================

# ----------------------------------------
# 每渲染帧把贴图摆正到"正对相机 + 俯角补偿"
#
# 为什么不用引擎内置的 billboard = FIXED_Y：
#   它只跟相机的水平旋转（yaw），不跟俯角（pitch）。相机拉到 60° 俯角时，
#   竖直的贴图被透视压缩到只剩 cos60° = 50% 高 —— 同一棵树推近时高、
#   拉远时矮，看起来像换了一棵。改由这里每帧重算，屏幕高度就不随缩放变化。
#
# 只对带真精灵的资源生效（目前是树）；程序化兜底网格是 3D 体块，
# 本身有体积，不需要也不该跟着相机转。
# ----------------------------------------
func _process(_delta: float) -> void:
	if not face_camera or sprite == null or not is_instance_valid(sprite):
		return
	# 已经藏起来的（采集完的树、被流式卸载的）不用算
	if not sprite.visible:
		return
	_apply_facing()


func _apply_facing() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# 锚点 = 实体原点的世界坐标。资源生成时脚下就是地面，
	# 绕这个点倾斜，贴图底边始终贴地、不会和碰撞体错位。
	var root: Node = get_parent()
	var ground: Vector3 = global_position
	if root is Node3D:
		ground = (root as Node3D).global_position
	sprite.global_transform = Facing.facing_transform(
		cam, ground, _sprite_pivot, billboard_tilt)


# ----------------------------------------
# 精灵是否自带帧动画（= 已配真美术）
# ----------------------------------------
func _sprite_has_art() -> bool:
	if sprite == null or sprite.sprite_frames == null:
		return false
	return not sprite.sprite_frames.get_animation_names().is_empty()


# ----------------------------------------
# 按节点名兜底查找精灵
#
# 场景里两种摆法都有先例：精灵是 Visual 的子节点（旧 grass 场景），
# 或与 Visual 平级、挂在实体根下（tree.tscn）。两种都试一次。
# ----------------------------------------
func _find_sprite_fallback() -> AnimatedSprite3D:
	var own: AnimatedSprite3D = get_node_or_null("Sprite") as AnimatedSprite3D
	if own != null:
		return own
	var root: Node = get_parent()
	if root == null:
		return null
	var by_name: AnimatedSprite3D = root.get_node_or_null("Sprite") as AnimatedSprite3D
	if by_name != null:
		return by_name
	# 名字对不上时按类型兜底：实体下第一个 AnimatedSprite3D 就是它的外观
	for child in root.get_children():
		var spr: AnimatedSprite3D = child as AnimatedSprite3D
		if spr != null:
			return spr
	return null


# ----------------------------------------
# 把单张贴图写进某个动画的第 0 帧
# 动画不存在则先建一个空动画再插帧
# （add_animation 建出来的是 0 帧的空动画，直接 set_frame_texture(anim, 0) 会越界报错）
# ----------------------------------------
func _set_single_frame(anim_name: String, tex: Texture2D) -> void:
	if tex == null or anim_name == "" or sprite == null or sprite.sprite_frames == null:
		return
	if not sprite.sprite_frames.has_animation(anim_name):
		sprite.sprite_frames.add_animation(anim_name)
	if sprite.sprite_frames.get_frame_count(anim_name) == 0:
		sprite.sprite_frames.add_frame(anim_name, tex)
	else:
		sprite.sprite_frames.set_frame_texture(anim_name, 0, tex)

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

	# 真美术精灵：可见性同样按状态收紧
	_update_sprite_visibility(state)


# ----------------------------------------
# 按状态决定精灵是否可见
#
# 为什么要单独管：
#   树没有"树桩"帧，被砍完只能整棵消失。若不管，精灵会停在 chop 的最后一帧上，
#   于是"东西已经进背包了，树还立在原地"——这正是 hide_mesh_immediate 当初要解决的问题，
#   只不过以前它只管程序化网格，管不到真精灵。
#
# GROWING / REGENERATING / TRANSITIONING → 可见
# HARVESTED → 只有配了"已采集"动画（如树桩）才可见，否则整棵藏掉
# ----------------------------------------
func _update_sprite_visibility(state: ResourceState.State) -> void:
	if sprite == null:
		return
	if state != ResourceState.State.HARVESTED:
		sprite.visible = true
		return
	sprite.visible = _has_harvested_art()


# ----------------------------------------
# 是否配了"已采集"美术（如树桩）
# 没有 = 采集完应当整棵消失
# ----------------------------------------
func _has_harvested_art() -> bool:
	if _resource_data == null:
		return false
	return _has_animation(_resource_data.harvested_animation)


# ----------------------------------------
# 精灵帧里是否有这个动画（自带空值守卫）
# ----------------------------------------
func _has_animation(anim_name: String) -> bool:
	if anim_name == "" or sprite == null or sprite.sprite_frames == null:
		return false
	return sprite.sprite_frames.has_animation(anim_name)


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
	# 真美术精灵一并收起。
	# 配了"已采集"帧（树桩）的除外：那种情况要留在场上，等 transition 走完切到 HARVESTED
	# 再显示树桩；此刻就藏会让它先消失一秒再冒出来，反而难看。
	if sprite != null and not _has_harvested_art():
		sprite.visible = false

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

	# 读档恢复到"已采集"时同样要收紧精灵可见性，否则读档回来的树桩位置上
	# 会站着（或消失错）一棵树。
	_update_sprite_visibility(state)

# ----------------------------------------
# 播放采集动画函数
# 采集时调用的特殊动画
# ----------------------------------------
func play_harvest_animation() -> void:
	# 优先播精灵帧里的"采集/砍伐"动画（如树的 chop：25 帧连播 ≈ 0.83s）。
	# 树的每次作业间隔是 1 秒，这一遍 0.83 秒的晃动正好填满两次挥砍之间——
	# 砍 6 下就是晃 6 遍，不会有"动画早停了但人还在挥"的空窗。
	# 这条路走通就不再往下找 AnimationPlayer。
	if _resource_data != null and _has_animation(_resource_data.harvest_animation):
		sprite.visible = true
		# 非循环动画，播完停在最后一帧；随后的 hide_mesh_immediate 会把它收掉
		sprite.play(_resource_data.harvest_animation)
		return

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
	if _has_animation(anim_name):
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
	if _has_animation(anim_name):
		sprite.animation = anim_name  # 设置当前动画名称
		sprite.frame = 0              # 设置为第一帧（停止在当前帧）

# ============================================
# 程序化兜底网格（无贴图时调用）
# 按资源类型生成可辨识的简易 3D 外形，保证"看得见、能交互"
# ============================================
func _build_placeholder_mesh(data: ResourceData) -> void:
	if not _mesh_instances.is_empty():
		return
	# 注意：没有 TREE 分支。树有真美术（tscn/prefab/tree.tscn 的 25 帧动画），
	# 永远不会走到这里；万一帧资源丢失，落 `_` 默认灰盒也比叠旧模型强。
	var rt: int = data.resource_type if data else 0
	match rt:
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
