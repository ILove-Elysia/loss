# script/resources/entity/resource_entity.gd
# ============================================
# 资源实体基类 - 所有资源的公共父类
#
# 什么是基类/父类？
# 基类定义公共行为，它的子类继承这些行为
# 例如：ResourceEntity 是所有资源的"祖先"
# 草、树、石头都继承自它，拥有相同的基本功能
#
# 什么是继承？
# class_name TreeEntity extends ResourceEntity
# TreeEntity 会自动拥有 ResourceEntity 的所有属性和方法
# 然后可以添加自己特有的逻辑
#
# 什么是信号(Signal)？
# 信号是 Godot 的事件通知机制
# 当某事发生时，节点可以"发出信号"
# 其他节点可以"监听"这个信号并做出反应
# 例如：草被采集时发出 harvest_requested 信号
# ============================================

class_name ResourceEntity
extends Node3D

# ============================================
# 信号定义
# ============================================

# 当状态改变时发出
# 参数：new_state - 新的状态
signal state_changed(new_state: ResourceState.State)

# 当被采集时发出
# 参数：harvester - 采集者（通常是玩家）
signal harvested(harvester: Node)

# 当被挖掘时发出
# 参数：digger - 挖掘者（通常是玩家）
signal digged(digger: Node)

# 当再生完成时发出
signal regenerated()

# ============================================
# 导出变量
# ============================================

# 资源数据配置
# 这是"模板"，定义了这个资源的所有属性
# 当这个值改变时，会自动调用 _apply_resource_data()
@export var resource_data: ResourceData:
	set(value):
		resource_data = value
		_apply_resource_data()

# ============================================
# 成员变量
# ============================================

# 当前状态
var current_state: ResourceState.State = ResourceState.State.GROWING

# 实例ID，用于存档时唯一标识这个资源
# 每个草、每棵树都有不同的 instance_id
var instance_id: int = -1

# 剩余再生时间，用于存档恢复
var regen_time_remaining: float = 0.0

# ============================================
# 子组件引用
# 使用 _ 前缀表示私有变量（只是约定）
# ============================================
var _state_machine: ResourceStateMachine
var _visual_component: ResourceVisual
var _interaction_component: ResourceInteraction
var _regen_component: ResourceRegeneration

# ============================================
# 生命周期函数
# ============================================

# _ready() 在节点进入场景树时调用一次
# 相当于"出生"时要做的事
func _ready() -> void:
	# 1. 设置各个组件
	_setup_components()
	# 2. 连接组件之间的信号
	_connect_signals()
	# 3. 如果已经设置了资源数据，应用它
	if resource_data:
		_apply_resource_data()

# ============================================
# 组件设置
# ============================================

# ----------------------------------------
# 设置组件函数
# 查找或创建必要的子组件
#
# 为什么需要这个？
# 预制体可能没有提前创建这些组件
# 代码会动态检查并创建缺失的组件
# ----------------------------------------
func _setup_components() -> void:
	# 尝试获取已存在的子节点
	# get_node_or_null() 如果节点不存在会返回 null，不会报错
	# 比 $ 或 get_node() 更安全
	_state_machine = get_node_or_null("StateMachine")
	_visual_component = get_node_or_null("Visual")
	_interaction_component = get_node_or_null("Interaction")
	_regen_component = get_node_or_null("Regeneration")
	
	# 如果子节点不存在，就创建新的
	# 这确保了即使预制体没有这些节点，代码也能正常工作
	
	if not _state_machine:
		_state_machine = ResourceStateMachine.new()
		_state_machine.name = "StateMachine"
		add_child(_state_machine)
	
	if not _visual_component:
		_visual_component = ResourceVisual.new()
		_visual_component.name = "Visual"
		add_child(_visual_component)
	
	if not _interaction_component:
		_interaction_component = ResourceInteraction.new()
		_interaction_component.name = "Interaction"
		add_child(_interaction_component)
	
	if not _regen_component:
		_regen_component = ResourceRegeneration.new()
		_regen_component.name = "Regeneration"
		add_child(_regen_component)

# ----------------------------------------
# 连接信号函数
# 将组件的信号连接到本类的处理函数
#
# 什么是信号连接？
# connect() 将信号的发射者与接收者连接起来
# 当信号发出时，接收者的处理函数会被自动调用
# ----------------------------------------
func _connect_signals() -> void:
	# 当状态机状态改变时，调用 _on_state_changed
	if _state_machine:
		_state_machine.state_changed.connect(_on_state_changed)
	
	# 当交互组件收到采集请求时
	if _interaction_component:
		_interaction_component.harvest_requested.connect(_on_harvest_requested)
		_interaction_component.dig_requested.connect(_on_dig_requested)
	
	# 当再生组件完成再生时
	if _regen_component:
		_regen_component.regeneration_complete.connect(_on_regeneration_complete)

# ----------------------------------------
# 应用资源数据函数
# 将配置数据传递给各个组件
# ----------------------------------------
func _apply_resource_data() -> void:
	if not resource_data:
		return
	
	# 将数据传递给各个组件
	if _visual_component:
		_visual_component.setup(resource_data)
	if _interaction_component:
		_interaction_component.setup(resource_data)
	if _regen_component:
		_regen_component.setup(resource_data)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置状态函数
# 用于改变资源的当前状态
#
# 参数：new_state - 新的状态
# ----------------------------------------
func set_state(new_state: ResourceState.State) -> void:
	if current_state == new_state:
		return
	
	current_state = new_state
	_state_machine.change_state(new_state)
	state_changed.emit(new_state)

# ----------------------------------------
# 采集函数
# 处理玩家采集资源的行为
#
# 参数：harvester - 采集者（通常是玩家）
#
# 采集流程：
# 1. 检查状态是否允许采集
# 2. 播放过渡动画
# 3. 给玩家物品
# 4. 切换到已采集状态
# 5. 开始再生计时
# ----------------------------------------
func harvest(harvester: Node) -> void:
	# 如果不是生长状态，不能采集
	if current_state != ResourceState.State.GROWING:
		return
	
	# 切换到过渡状态
	set_state(ResourceState.State.TRANSITIONING)
	
	# 播放采集动画
	if _visual_component:
		_visual_component.play_harvest_animation()
	
	# 计算掉落数量
	var drop_count = resource_data.get_drop_count()
	
	# 给玩家物品
	_give_item_to(harvester, resource_data.drop_item_id, drop_count)
	
	# 发出被采集信号
	harvested.emit(harvester)
	
	# 等待过渡动画播放完成
	# await 会暂停这个函数，直到条件满足
	await get_tree().create_timer(resource_data.transition_duration).timeout
	
	# 动画播放完成，切换到已采集状态
	set_state(ResourceState.State.HARVESTED)
	
	# 如果可以再生，开始再生计时
	if resource_data.can_regenerate and _regen_component:
		_regen_component.start_regeneration()

# ----------------------------------------
# 挖掘函数
# 处理玩家用铲子挖掘资源的行为
#
# 参数：digger - 挖掘者（通常是玩家）
#
# 挖掘流程：
# 1. 检查是否可以挖掘
# 2. 给玩家挖掘掉落物
# 3. 移除这个资源实体
# ----------------------------------------
func dig(digger: Node) -> void:
	# 如果这个资源不能被挖掘，直接返回
	if not resource_data.can_dig:
		return
	
	# 给玩家挖掘掉落物
	_give_item_to(digger, resource_data.dig_drop_item_id, resource_data.get_dig_drop_count())
	
	# 发出被挖掘信号
	digged.emit(digger)
	
	# 移除这个资源实体
	# queue_free() 会安全地删除节点
	queue_free()

# ============================================
# 存档相关
# ============================================

# ----------------------------------------
# 获取存档数据函数
# 将当前资源状态转换为可保存的字典
#
# 返回：包含所有需要保存数据的字典
# ----------------------------------------
func get_save_data() -> Dictionary:
	return {
		"instance_id": instance_id,
		"resource_id": str(resource_data.resource_id),
		"position": {
			"x": global_position.x,
			"y": global_position.y,
			"z": global_position.z
		},
		"state": current_state,
		"regen_time_remaining": _regen_component.get_remaining_time() if _regen_component else 0.0
	}

# ----------------------------------------
# 加载存档数据函数
# 从保存的数据恢复资源状态
#
# 参数：data - 之前保存的数据字典
# ----------------------------------------
func load_save_data(data: Dictionary) -> void:
	instance_id = data.get("instance_id", -1)
	current_state = data.get("state", ResourceState.State.GROWING)
	regen_time_remaining = data.get("regen_time_remaining", 0.0)
	
	# 如果状态是已采集
	if current_state == ResourceState.State.HARVESTED:
		# 立即设置视觉状态
		if _visual_component:
			_visual_component.set_visual_state_immediate(ResourceState.State.HARVESTED)
		
		# 如果可以再生且还有剩余时间，继续再生
		if resource_data.can_regenerate and regen_time_remaining > 0 and _regen_component:
			_regen_component.resume_regeneration(regen_time_remaining)

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 获取物品数据函数
# 通过物品ID查找物品数据
#
# 参数：item_id - 物品ID
# 返回：ItemData 对象或 null
# ----------------------------------------
func _get_item_data(item_id: StringName) -> ItemData:
	# 从物品注册表获取
	var registry = ItemRegistry.get_registry()
	if registry:
		return registry.get_item(item_id)
	return null

# ----------------------------------------
# 给予物品函数
# 尝试给目标添加物品
#
# 参数：
#   target - 目标节点（玩家）
#   item_id - 物品ID
#   count - 数量
# ----------------------------------------
func _give_item_to(target: Node, item_id: StringName, count: int) -> void:
	# 获取物品数据
	var item_data = _get_item_data(item_id)
	if not item_data:
		print("错误：找不到物品数据 ", item_id)
		return

	# 方法1：通过子节点 Inventory 添加
	if target.has_node("Inventory"):
		var inventory = target.get_node("Inventory")
		if inventory.has_method("add_item"):
			inventory.add_item(item_data, count)
			return

	# 方法2：直接调用目标的 add_item 方法
	if target.has_method("add_item"):
		target.add_item(item_data, count)

# ============================================
# 信号处理函数
# 这些函数在对应信号发出时被调用
# ----------------------------------------

# 状态改变时的处理
func _on_state_changed(new_state: ResourceState.State) -> void:
	current_state = new_state
	if _visual_component:
		_visual_component.set_visual_state(new_state)

# 收到采集请求时的处理
func _on_harvest_requested(harvester: Node) -> void:
	harvest(harvester)

# 收到挖掘请求时的处理
func _on_dig_requested(digger: Node) -> void:
	dig(digger)

# 再生完成时的处理
func _on_regeneration_complete() -> void:
	set_state(ResourceState.State.GROWING)
	regenerated.emit()
