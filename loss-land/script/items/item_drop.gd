# script/items/item_drop.gd
# ============================================
# 世界掉落物实体 - 地上的可拾取物品
#
# 功能：
#   - 携带一份 ItemData + 数量，在世界上悬浮旋转
#   - 玩家走近（半径 pickup_radius 米）后，需按下"拾取"键（空格）才拾取进背包
#   - 靠近时显示"空格拾取"提示；按下后入背包，背包满则留在原地
#   - 背包放不下时留在原地，等玩家腾出空间再来捡
#   - 出生后有 pickup_grace 秒拾取保护，避免"掉进玩家身体里秒被吸走"
#     造成"刚打死的怪东西直接消失"的观感
#
# 使用方式（推荐走静态方法）：
#   ItemDrop.spawn_drop(item_data, count, world_position)
#   ItemDrop.spawn_item_by_id(&"battery", 1, world_position)
#
# 设计说明：
#   - 视觉用小方块 + 物品稀有度颜色，不用贴图——
#     以后换成正式模型只需替换 _build_visual()
#   - 全场景平坦（地面 y=0），掉落物固定悬浮在 y≈0.5
#   - 拾取键取自 InputMap 的 "pickup" 动作（默认绑定空格），可被玩家设置覆盖
# ============================================

class_name ItemDrop
extends Node3D

# ============================================
# 导出变量
# ============================================

## 拾取半径（米）
@export var pickup_radius: float = 1.2

## 拾取保护时间（秒）——出生后这段时间内不能被拾取
@export var pickup_grace: float = 0.4

## 悬浮高度（米）
@export var hover_height: float = 0.5

## 悬浮动画幅度（米）
@export var bob_amplitude: float = 0.08

## 旋转速度（弧度/秒）
@export var spin_speed: float = 2.0

# ============================================
# 状态变量
# ============================================

## 携带的物品数据
var item_data: ItemData = null

## 携带的数量
var count: int = 1

## 出生计时
var _age: float = 0.0

## 视觉节点
var _visual: MeshInstance3D = null

## 拾取检测区域
var _pickup_area: Area3D = null

## 正在播放拾取动画（缩小消失）
var _being_collected: bool = false

## 正在尝试拾取（防重复触发）
var _pickup_pending: bool = false

## 当前在拾取半径内的玩家（无则 null）。只有它才能触发空格拾取
var _nearby_player: Node = null

## 靠近时显示的"空格拾取"提示（Label3D）
var _prompt: Label3D = null

## 初始化是否已完成。
## 视野流式加载（WorldStreamer）会把远处的掉落物移出场景树、走近时再放回，
## 复用同一个节点而不是重建 —— 于是 _ready 必须**幂等**。
## 官方文档明确「节点重新入树不会再调一次 _ready」，但这里若重复执行就有副作用
## （叠加第二套方块视觉 + 第二个拾取判定 Area3D），所以显式加一道守卫，
## 不把正确性寄托在引擎行为上。
var _initialized: bool = false

# ============================================
# 信号
# ============================================

## 物品被拾取时发出。参数：剩余未拾取数量（0 = 全部拾完）
signal picked_up(item: ItemData, taken: int, remaining: int)

# ============================================
# 静态辅助方法
# ============================================

# ----------------------------------------
# 生成掉落物函数
#
# 参数：
#   item - 物品数据
#   amount - 数量
#   position - 世界坐标（x/z 生效，y 忽略）
# 返回：ItemDrop 实例；数据无效时返回 null
# ----------------------------------------
static func spawn_drop(item: ItemData, amount: int, world_position: Vector3) -> ItemDrop:
	if item == null or amount <= 0:
		return null

	var parent := Engine.get_main_loop() as SceneTree
	if parent == null:
		DebugConfig.warn_msg(DebugConfig.CAT_ITEM, "ItemDrop: 场景树不可用，无法生成掉落物")
		return null

	# 优先挂到当前场景；headless 测试模式下 current_scene 为空，回退到 root
	var target_parent: Node = parent.current_scene
	if target_parent == null:
		target_parent = parent.root

	var drop := ItemDrop.new()
	drop.item_data = item
	drop.count = amount
	# 水平方向随机偏移一点点，多个掉落物不会完全重叠
	var angle := randf() * TAU
	var dist := randf() * 0.4
	drop.position = Vector3(
		world_position.x + cos(angle) * dist,
		hover_height_default(),
		world_position.z + sin(angle) * dist
	)
	target_parent.add_child(drop)
	return drop


# ----------------------------------------
# 按物品 ID 生成掉落物函数
# 通过注册表查物品数据再生成
# ----------------------------------------
static func spawn_item_by_id(item_id: StringName, amount: int, world_position: Vector3) -> ItemDrop:
	var registry: ItemRegistry = ItemRegistry.get_registry()
	if registry == null:
		DebugConfig.warn_msg(DebugConfig.CAT_ITEM, "ItemDrop: 物品注册表不可用")
		return null
	return spawn_drop(registry.get_item(item_id), amount, world_position)


## 默认悬浮高度（静态生成时用）
static func hover_height_default() -> float:
	return 0.5

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 重新入树（流式加载放回）时不重复初始化：见 _initialized 的说明
	if _initialized:
		return
	_initialized = true

	_build_visual()
	_build_prompt()
	_build_pickup_area()
	add_to_group("item_drop")


func _process(delta: float) -> void:
	_age += delta

	# 播放消失动画（缩放到 0 后删除）
	if _being_collected:
		var s := maxf(0.0, _visual.scale.x - delta * 8.0)
		_visual.scale = Vector3.ONE * s
		if s <= 0.01:
			queue_free()
		return

	# 悬浮 + 旋转动画
	if _visual:
		_visual.position.y = sin(_age * 3.0) * bob_amplitude
		_visual.rotation.y += spin_speed * delta

	# 靠近 + 按下拾取键才拾取（不再自动吸取）
	if _nearby_player != null and not _being_collected:
		if Input.is_action_just_pressed("pickup"):
			try_pickup(_nearby_player)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 尝试拾取函数
# 供 Area3D 信号与外部测试调用
#
# 参数：player_root - 玩家根节点（player 组成员）
# 返回：实际拾取的数量（0 = 背包满/未就绪）
# ----------------------------------------
func try_pickup(player_root: Node) -> int:
	if _being_collected or _pickup_pending:
		return 0
	if item_data == null or count <= 0:
		return 0
	if _age < pickup_grace:
		return 0
	if player_root == null:
		return 0

	# 找玩家的背包（player 根下的 Inventory 节点）
	var inventory := player_root.get_node_or_null("Inventory")
	if inventory == null or not inventory.has_method("add_item"):
		return 0

	_pickup_pending = true
	var taken: int = inventory.add_item(item_data, count)
	_pickup_pending = false

	if taken > 0:
		count -= taken
		picked_up.emit(item_data, taken, count)
		DebugConfig.log_msg(DebugConfig.CAT_ITEM, "[拾取] %s x%d%s", [
			item_data.display_name, taken,
			"" if count <= 0 else "（背包放不下，剩余 %d 留在地上）" % count
		])

	if count <= 0:
		# 全部拾完：播放消失动画
		_being_collected = true
		_nearby_player = null
		_hide_prompt()
		_pickup_area.set_deferred("monitoring", false)
	return taken

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 构建视觉函数
# 小方块 + 稀有度颜色；以后替换成正式模型
# ----------------------------------------
func _build_visual() -> void:
	_visual = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.28, 0.28, 0.28)
	_visual.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = _get_visual_color()
	mat.emission_enabled = true
	mat.emission = _get_visual_color()
	mat.emission_energy_multiplier = 0.4  # 微微发光，便于在草丛里看见
	_visual.material_override = mat
	add_child(_visual)


# 视觉颜色：优先稀有度颜色，方便一眼区分掉落品质
func _get_visual_color() -> Color:
	if item_data:
		return item_data.get_rarity_color()
	return Color.WHITE


# ----------------------------------------
# 构建拾取区域函数
# Area3D 检测玩家进入拾取半径
# ----------------------------------------
func _build_pickup_area() -> void:
	_pickup_area = Area3D.new()
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = pickup_radius
	shape.shape = sphere
	_pickup_area.add_child(shape)
	add_child(_pickup_area)

	_pickup_area.body_entered.connect(_on_body_entered)
	_pickup_area.body_exited.connect(_on_body_exited)


# 玩家（或其他身体）进入拾取范围
func _on_body_entered(body: Node3D) -> void:
	if _being_collected:
		return
	# 向上找 player 组成员（玩家碰撞体在 player/Physics 路径下）
	var node: Node = body
	while node:
		if node.is_in_group("player"):
			_nearby_player = node
			_show_prompt()
			return
		node = node.get_parent()


# 玩家离开拾取范围
func _on_body_exited(body: Node3D) -> void:
	if _nearby_player == null:
		return
	var node: Node = body
	while node:
		if node == _nearby_player:
			_nearby_player = null
			_hide_prompt()
			return
		node = node.get_parent()


# ----------------------------------------
# 构建靠近提示函数
# 玩家在范围内时浮现"空格拾取"文字（Label3D，自带朝向相机）
# ----------------------------------------
func _build_prompt() -> void:
	_prompt = Label3D.new()
	_prompt.text = "空格拾取"
	_prompt.font_size = 32
	_prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt.position = Vector3(0, hover_height + 0.6, 0)
	_prompt.no_depth_test = true
	_prompt.modulate = Color(1.0, 0.95, 0.6)
	_prompt.hide()
	add_child(_prompt)


func _show_prompt() -> void:
	if _prompt and is_instance_valid(_prompt):
		_prompt.show()


func _hide_prompt() -> void:
	if _prompt and is_instance_valid(_prompt):
		_prompt.hide()
