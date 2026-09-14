# script/building/building.gd
# ============================================
# 建筑实体 - 放置后的工作台 / 熔炉 / 储物箱
#
# 和 ResourceEntity 一样：项目没有建筑美术，网格全部用代码生成兜底几何体，
# 所以这里直接 new 出来用，不建 .tscn（省去 uid 与场景文件的维护）。
#
# 生命周期：
#   BuildingSystem 不管创建，由 Building.spawn() 统一造：
#     new → 设 building_id → add_child（触发 _ready）→ setup() 建网格并登记
#
# 碰撞（2026-09-11 补）：
#   每个建筑挂一个 StaticBody3D + BoxShape3D，尺寸取定义的 size。
#   层用 layer 2（= 地面/障碍，与 map_generator_3d 的地板同层）：
#     玩家 Physics 的 collision_mask = 3（layer1+2）、史莱姆同为 3，
#     所以人和怪都会撞到建筑，史莱姆的 test_move 避障也会绕开它。
#   不占用 layer 4（那是资源生成的"障碍物"层），免得影响资源刷新判定。
#
#   加了碰撞后有两个连锁影响，已同步处理：
#     1. 放置时不能放在自己脚下 → build_placer._invalid_reason 按建筑宽度动态算最小距离
#     2. 交互（点击开箱）走"射线打地面 + 水平距离"，不依赖建筑碰撞，照旧可用
# ============================================

class_name Building
extends Node3D

## 建筑 id，等于对应物品 id（&"workbench" / &"furnace" / &"storage_box"）
var building_id: StringName = &""

## 储物箱的背包节点（Inventory），非储物箱为 null
var storage: Node = null

var _body_root: Node3D


# ============================================
# 生命周期
# ============================================

func _ready() -> void:
	# spawn() 会先设好 building_id 再 add_child，所以这里能直接建。
	# 若有人直接 new 而不设 id，就保持空壳等 setup() 显式调用。
	if building_id != &"":
		setup()


func _exit_tree() -> void:
	BuildingSystem.unregister(self)


# ============================================
# 初始化
# ============================================

## 建网格 + 建存储 + 登记到 BuildingSystem
func setup() -> void:
	var def := BuildingSystem.get_def(building_id)
	if def.is_empty():
		push_error("Building: 未知建筑 id = %s" % building_id)
		return

	_body_root = Node3D.new()
	_body_root.name = "Body"
	add_child(_body_root)

	_build_mesh(def)
	_build_collision(def)
	_create_storage(int(def.get("storage", 0)))

	BuildingSystem.register(self)


## 统一创建入口：new → 设 id → 入树 → 自动 setup
static func spawn(id: StringName, world_pos: Vector3, parent: Node) -> Building:
	if parent == null:
		return null
	var b := Building.new()
	b.name = String(id)
	b.building_id = id
	parent.add_child(b)
	b.global_position = world_pos
	return b


# ============================================
# 外观（代码生成的兜底几何体）
# ============================================

func _build_mesh(def: Dictionary) -> void:
	var col: Array = def.get("color", [0.6, 0.5, 0.4])
	var base_color := Color(float(col[0]), float(col[1]), float(col[2]))
	var size: Array = def.get("size", [1.2, 1.0])
	var width := float(size[0])
	var height := float(size[1])

	match building_id:
		&"workbench":
			# 桌面（扁平板）+ 四条腿，看着像张工作台
			_add_box(Vector3(width, 0.12, width * 0.7), Vector3(0, height, 0), base_color)
			for sx in [-1, 1]:
				for sz in [-1, 1]:
					_add_box(Vector3(0.12, height, 0.12),
						Vector3(sx * (width * 0.5 - 0.1), height * 0.5, sz * (width * 0.35 - 0.1)),
						base_color * 0.75)

		&"furnace":
			# 炉体 + 发光的炉口
			_add_box(Vector3(width, height, width), Vector3(0, height * 0.5, 0), base_color)
			var mouth := _add_box(Vector3(width * 0.55, height * 0.3, 0.06),
				Vector3(0, height * 0.45, width * 0.5 + 0.02),
				Color(1.0, 0.55, 0.15))
			# 炉口自发光，夜里也能看见（大纲 3.5.2：熔炉"提供光源"的廉价替代表达）
			var mat: StandardMaterial3D = (mouth as MeshInstance3D).get_surface_override_material(0)
			if mat != null:
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.5, 0.12)
				mat.emission_energy_multiplier = 1.5

		&"storage_box":
			# 箱体 + 稍深的盖沿
			_add_box(Vector3(width, height, width), Vector3(0, height * 0.5, 0), base_color)
			_add_box(Vector3(width * 1.05, 0.1, width * 1.05), Vector3(0, height, 0),
				base_color * 0.7)

		_:
			_add_box(Vector3(width, height, width), Vector3(0, height * 0.5, 0), base_color)


## 碰撞体：一个和外观同尺寸的 BoxShape3D，挂在 StaticBody3D 下
func _build_collision(def: Dictionary) -> void:
	var size: Array = def.get("size", [1.2, 1.0])
	var width := float(size[0])
	var height := float(size[1])

	var body := StaticBody3D.new()
	body.name = "CollisionBody"
	# layer 2 = 地面/障碍（玩家与敌人的 collision_mask=3 都含它）
	# 静态体不需要检测别人，mask 置 0
	body.collision_layer = 2
	body.collision_mask = 0
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, height, width)
	shape.shape = box
	# 网格是从 y=0 往上长的（见 _build_mesh 的 offset），碰撞体同样抬半高
	shape.position = Vector3(0.0, height * 0.5, 0.0)
	body.add_child(shape)


func _add_box(size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# 建筑是功能设施，不需要接收阴影的精细表现；关掉可省一点开销
	mat.vertex_color_use_as_albedo = false
	mi.set_surface_override_material(0, mat)

	mi.position = offset
	_body_root.add_child(mi)
	return mi


# ============================================
# 存储（仅储物箱）
# ============================================

func _create_storage(slots: int) -> void:
	if slots <= 0:
		return
	var inv := Inventory.new()
	inv.name = "Storage"
	# max_slots 必须在 add_child 之前设好：
	# Inventory._ready() 会按它初始化槽位数组，之后改不会重建。
	inv.max_slots = slots
	add_child(inv)
	storage = inv


## 是否有存储空间
func has_storage() -> bool:
	return storage != null


# ============================================
# 拆除
# ============================================

## 拆掉本建筑并把物品还给背包。
## 储物箱里还有东西时拒绝拆除——宁可让玩家自己清空，也不要静默吞掉物品。
## 返回是否拆除成功（false = 被拒绝）。
func remove_and_refund(inventory: Node) -> bool:
	if has_storage() and not storage.is_empty():
		return false

	if inventory != null and inventory.has_method("add_item"):
		var registry := ItemRegistry.get_registry()
		if registry != null:
			var data: ItemData = registry.get_item(building_id)
			if data != null:
				var added: int = inventory.add_item(data, 1)
				if added <= 0:
					return false  # 背包满：不拆，免得白丢一个建筑

	# 从登记表移除后再销毁：remove_child + queue_free 一起用，
	# 只 queue_free 的话节点会留到帧末，期间仍可能被 find_nearest 命中。
	BuildingSystem.unregister(self)
	if get_parent() != null:
		get_parent().remove_child(self)
	queue_free()
	return true


# ============================================
# 信息
# ============================================

func get_display_name() -> String:
	return BuildingSystem.get_display_name(building_id)


## 需要的制作站（给合成界面判断用）
func get_station() -> StringName:
	return StringName(BuildingSystem.get_def(building_id).get("station", &""))
