# script/resources/component/resource_interaction.gd
# ============================================
# 交互组件 - 处理玩家与资源的交互
#
# 这个组件负责：
# 1. 检测玩家是否在资源附近
# 2. 判断玩家是否按下了交互键
# 3. 检测玩家装备的工具类型
# 4. 触发相应的交互（采集或挖掘）
#
# 什么是 Area3D？
# Area3D 是 Godot 的区域检测节点
# 可以检测其他物体进入或离开其范围
# ============================================

class_name ResourceInteraction
extends Node

# ============================================
# 信号定义
# ============================================

# 当玩家请求采集时发出
# 参数：harvester - 采集的玩家
signal harvest_requested(harvester: Node)

# 当玩家请求挖掘时发出
# 参数：digger - 挖掘的玩家
signal dig_requested(digger: Node)

# ============================================
# 导出变量
# ============================================

# 交互检测区域
# 在编辑器中将 Area3D 节点拖入此处
@export var interaction_area: Area3D

# 交互范围（半径）
# 玩家需要进入这个距离内才能交互
@export var interaction_range: float = 2.0

# ============================================
# 私有变量
# ============================================

# 资源数据引用
var _resource_data: ResourceData

# 附近的玩家列表
# 用于追踪所有在交互范围内的玩家
var _nearby_players: Array[Node] = []

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 如果没有设置交互区域，动态创建一个
	if not interaction_area:
		_create_default_interaction_area()
	
	# 连接 Area3D 的信号
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置函数
# 初始化交互组件的配置
# 由 ResourceEntity 在 setup 时调用
#
# 参数：data - 资源数据配置
# ----------------------------------------
func setup(data: ResourceData) -> void:
	_resource_data = data

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 创建默认交互区域函数
# 如果没有在编辑器中设置 Area3D，自动创建一个
# ----------------------------------------
func _create_default_interaction_area() -> void:
	# 创建 Area3D 节点
	interaction_area = Area3D.new()
	
	# 创建碰撞形状节点
	var collision = CollisionShape3D.new()
	
	# 创建球形碰撞体
	var shape = SphereShape3D.new()
	shape.radius = interaction_range
	
	# 将形状赋给碰撞体
	collision.shape = shape
	
	# 将碰撞体添加为 Area3D 的子节点
	interaction_area.add_child(collision)
	
	# 将 Area3D 添加为本节点的子节点
	add_child(interaction_area)

# ----------------------------------------
# 每帧处理函数
# 检测玩家的输入
# _process 会在每一帧被调用
# ----------------------------------------
func _process(_delta: float) -> void:
	# 如果没有玩家在附近，跳过
	if _nearby_players.is_empty():
		return
	
	# 检查每个附近玩家的交互输入
	for player in _nearby_players:
		_check_interaction(player)

# ----------------------------------------
# 物体进入区域处理
# 当玩家进入交互范围时调用
# ----------------------------------------
func _on_body_entered(body: Node) -> void:
	# 检查是否是玩家
	# is_in_group 检查节点是否属于某个组
	# 需要提前将玩家节点添加到这个组
	if body.is_in_group("player"):
		# 添加到附近玩家列表
		_nearby_players.append(body)

# ----------------------------------------
# 物体离开区域处理
# 当玩家离开交互范围时调用
# ----------------------------------------
func _on_body_exited(body: Node) -> void:
	# 如果在列表中，移除它
	if body in _nearby_players:
		_nearby_players.erase(body)

# ----------------------------------------
# 检查交互函数
# 检测玩家是否按下了交互键
# ----------------------------------------
func _check_interaction(player: Node) -> void:
	# 如果没有资源数据，返回
	if not _resource_data:
		return
	
	# 获取玩家当前装备的工具
	var equipped_tool = _get_player_tool(player)
	
	# 检测交互键按下
	# Input.is_action_just_pressed 检测按键是否刚刚按下（这一帧）
	if Input.is_action_just_pressed("interact"):
		# 根据工具类型决定交互方式
		if equipped_tool == ResourceData.HarvestTool.SHOVEL and _resource_data.can_dig:
			# 如果装备了铲子且资源可以被挖掘，发出挖掘请求
			dig_requested.emit(player)
		else:
			# 否则发出采集请求
			harvest_requested.emit(player)

# ----------------------------------------
# 获取玩家工具函数
# 尝试获取玩家当前装备的工具类型
#
# 为什么用多种方法？
# 不同项目可能用不同的方式管理装备
# 我们尝试几种常见的方式，确保兼容性
# ----------------------------------------
func _get_player_tool(player: Node) -> ResourceData.HarvestTool:
	# 方法1：直接调用玩家的方法
	# 假设玩家脚本有 get_equipped_tool() 方法
	if player.has_method("get_equipped_tool"):
		return player.get_equipped_tool()
	
	# 方法2：通过子节点 Equipment 获取
	# 假设玩家有 Equipment 子节点
	if player.has_node("Equipment"):
		var equipment = player.get_node("Equipment")
		if equipment.has_method("get_current_tool"):
			return equipment.get_current_tool()
	
	# 如果都获取不到，返回 NONE（无工具）
	return ResourceData.HarvestTool.NONE

# ----------------------------------------
# 获取最近玩家函数
# 返回最近的一个玩家
# ----------------------------------------
func get_nearest_player() -> Node:
	if _nearby_players.is_empty():
		return null
	return _nearby_players[0]
