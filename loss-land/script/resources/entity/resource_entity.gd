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

# 是否正在采集中
# 采集需要耗时（受装备工具加成），期间拒绝重复请求
var _is_harvesting: bool = false

# 实例ID，用于存档时唯一标识这个资源
# 每个草、每棵树都有不同的 instance_id
var instance_id: int = -1

# 剩余再生时间，用于存档恢复
var regen_time_remaining: float = 0.0

# 钉住标记（视野流式加载用，2026-09-12）
# ResourceManager 会卸载离开玩家视野的资源实体（退回对象池）。
# 但"点击采集订单"（ClickMover._pending_resource）会长期抓着某个实体引用，
# 一旦它被卸载、又被对象池拿去表示别的资源，这个引用就成了幽灵——
# 玩家会朝着错误的位置走、采到另一个东西。所以被订单抓住的实体置 pinned = true，
# 卸载逻辑见到它直接跳过。
var pinned: bool = false

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
	# 0. 加入 resource 组：便于按组查询所有资源（诊断、统计、AI 等）
	if not is_in_group("resource"):
		add_to_group("resource")
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
	# _state_machine 为空 = 本节点还没进树（_ready 尚未跑）。
	# 历史上这里会直接崩（"change_state in base 'Nil'"），加个守卫。
	if _state_machine:
		_state_machine.change_state(new_state)
	state_changed.emit(new_state)

# ----------------------------------------
# 是否正被采集流程占用
#
# 视野流式加载的卸载判定要用：采集是 await 出来的长流程（等 harvest_time、
# 等 transition_duration），中途把实体退回对象池会让 await 回来时对着一具
# 空壳操作，而且 TRANSITIONING 状态存进"记录层"会因为没有计时器接手而永久卡死。
# 所以"忙"的实体一律不卸载。
# ----------------------------------------
func is_busy() -> bool:
	if _is_harvesting:
		return true
	return current_state == ResourceState.State.TRANSITIONING

# ----------------------------------------
# 退回对象池前的复位
#
# 实体是被复用的：同一棵树被卸载后，那个节点可能马上被拿去表示远处的一块石头。
# 如果不复位，上一世的遗留状态（隐藏的网格、还在跑的再生计时器、钉住标记）
# 会串到新资源上。复位成干净的 GROWING，之后由 acquire → set_state 决定真实状态。
# ----------------------------------------
func reset_for_pool() -> void:
	_is_harvesting = false
	pinned = false
	if _regen_component and _regen_component.has_method("cancel_regeneration"):
		_regen_component.call("cancel_regeneration")
	if _visual_component:
		# 用非 immediate 版本：它会把程序化兜底网格重新显示出来
		# （set_visual_state_immediate 只管贴图帧，不管网格可见性）
		_visual_component.set_visual_state(ResourceState.State.GROWING)
	current_state = ResourceState.State.GROWING
	if _state_machine:
		_state_machine.current_state = ResourceState.State.GROWING
		_state_machine.previous_state = ResourceState.State.GROWING

# ----------------------------------------
# 按"记录层"恢复状态（视野流式加载用）
#
# 与 load_save_data 的区别：本方法只处理状态与再生倒计时，不碰 instance_id，
# 也不依赖存档字典。走一次 set_state 让 current_state / 状态机 / 视觉三者同步。
#
# 参数：
#   state            - 记录层保存的状态
#   regen_remaining  - 记录层保存的再生剩余秒数（<=0 表示"从头开始"）
# ----------------------------------------
func apply_record_state(state: ResourceState.State, regen_remaining: float) -> void:
	if current_state != state:
		set_state(state)
	else:
		current_state = state
	if _visual_component:
		_visual_component.set_visual_state(state)
	if state != ResourceState.State.HARVESTED:
		return
	if resource_data == null or not resource_data.can_regenerate:
		return
	if _regen_component == null:
		return
	if regen_remaining > 0.0:
		_regen_component.resume_regeneration(regen_remaining)
	else:
		_regen_component.start_regeneration()

# ----------------------------------------
# 是否可以采集函数
# 供 ResourceManager.harvest_resource 等外部入口用：
# GROWING 状态 + 资源数据允许采集 + 数据里有 drop_item_id
# 这三项都满足才能进行下一步 harvest()。
# ----------------------------------------
func can_harvest() -> bool:
	if current_state != ResourceState.State.GROWING:
		return false
	if resource_data == null:
		return false
	if not resource_data.can_harvest:
		return false
	if resource_data.drop_item_id == StringName(""):
		return false
	return true

# ----------------------------------------
# 采集函数
# 处理玩家采集资源的行为
#
# 参数：harvester - 采集者（通常是玩家）
#
# 采集流程：
# 1. 检查状态是否允许采集
# 2. 播放过渡动画
# 3. 等待采集耗时（装备对应工具可大幅缩短这一步）
# 4. 给玩家物品
# 5. 切换到已采集状态
# 6. 开始再生计时
#
# 关于"采集速度"：
#   基础耗时取自 resource_data.harvest_time，装备的工具类型
#   与资源匹配时按倍率缩短——这就是木斧/石斧"+50%/+100%"的落地方式。
#   不匹配也能采（只是慢），否则"做斧头要先有木头、砍树要先有斧头"会死锁。
# ----------------------------------------
func harvest(harvester: Node) -> void:
	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] harvest 被调用：资源=%s", [resource_data.resource_id if resource_data else "<无数据>"])

	# 如果不是生长状态，不能采集
	if current_state != ResourceState.State.GROWING:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 状态非 GROWING（当前=%s），跳过", [current_state])
		return

	# 正在采集中，忽略重复请求（否则一次交互会掉两份）
	if _is_harvesting:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 本实体已在采集中，跳过")
		return

	# 工具门槛（权威判定）：树要斧头、大石头/矿要镐子（2026-09-12 用户约定）。
	# 必须在抢锁、切状态之前拒绝——否则会留下"过渡中"的半采状态。
	# 提示由 ResourceManager 统一画在屏幕底部（本组件没有 UI）。
	if resource_data != null and int(resource_data.required_tool) != int(ResourceData.HarvestTool.NONE):
		var tool_equip = _get_harvester_equipment(harvester)
		var current_tool := int(ResourceData.HarvestTool.NONE)
		if tool_equip != null and tool_equip.has_method("get_current_tool"):
			current_tool = int(tool_equip.call("get_current_tool"))
		if current_tool != int(resource_data.required_tool):
			DebugConfig.warn_msg(DebugConfig.CAT_RESOURCE, "[采集] 拒绝：%s 需要%s（当前工具类型=%d）",
				[resource_data.resource_id,
				ResourceData.get_required_tool_name(int(resource_data.required_tool)),
				current_tool])
			_flash_tool_hint()
			return

	# 玩家同时只允许采一个资源：附近多棵草/树/石的 Area3D 会同时把玩家加入
	# 自己的 _nearby_players，按一次空格会让所有相邻 entity 都触发 harvest_requested。
	# 用玩家 Equipment 节点上的 _harvesting 标志做互斥：发现已被占就直接 return。
	# 锁的抢占/释放在 harvest 入口和所有退出路径上（await 期间切场景也要释放）。
	var equipment = _get_harvester_equipment(harvester)
	if equipment == null:
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 找不到 Equipment 节点，harvester=%s", [harvester])
	elif equipment.has_method("is_harvesting") and equipment.is_harvesting():
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 玩家采集互斥锁被占用（若每次都这样=锁卡死了），跳过")
		return

	_is_harvesting = true
	if equipment != null:
		equipment.set_harvesting(true)
	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 已抢占采集锁，开始计时采集")

	# 切换到过渡状态
	set_state(ResourceState.State.TRANSITIONING)

	# 播放采集动画
	if _visual_component:
		_visual_component.play_harvest_animation()

	# 等待采集耗时（工具加成作用在这里）
	var harvest_duration := get_harvest_duration(harvester)
	if harvest_duration > 0.0:
		await get_tree().create_timer(harvest_duration).timeout

	# 等待期间资源可能已被移除（切场景、清档等）
	if not is_instance_valid(self) or is_queued_for_deletion():
		_release_harvest_lock(equipment)
		_is_harvesting = false
		return

	# 计算掉落数量
	var drop_count = resource_data.get_drop_count()

	# 给玩家物品
	_give_item_to(harvester, resource_data.drop_item_id, drop_count)
	DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集调试] 已发放掉落：%s x%d", [resource_data.drop_item_id, drop_count])

	# 物品到账的同一刻就让资源从画面上消失，不再空等 transition_duration。
	# （详见 ResourceVisual.hide_mesh_immediate 的注释）
	if _visual_component:
		_visual_component.hide_mesh_immediate()

	# 发出被采集信号
	harvested.emit(harvester)

	# 此刻就释放采集锁：物品已到手、资源已不可见，玩家应该能马上采下一个。
	# 安全性：current_state 仍是 TRANSITIONING，can_harvest() 返回 false，
	# 所以本实体不会被重复采集；锁定只是不再白占玩家的采集动作。
	_is_harvesting = false
	_release_harvest_lock(equipment)

	# 剩下的过渡时间只用于"枯萎/留树桩"的表现，不再阻塞玩家操作
	await get_tree().create_timer(resource_data.transition_duration).timeout

	if not is_instance_valid(self) or is_queued_for_deletion():
		return

	# 过渡到点，切换到已采集状态
	set_state(ResourceState.State.HARVESTED)

	# 如果可以再生，开始再生计时
	if resource_data.can_regenerate and _regen_component:
		_regen_component.start_regeneration()

# ----------------------------------------
# 采集耗时函数
#
# 参数：harvester - 采集者（用于查询其装备的工具）
# 返回：本次采集需要等待的秒数
# ----------------------------------------
func get_harvest_duration(harvester: Node) -> float:
	if not resource_data:
		return 0.0
	var base: float = resource_data.harvest_time
	if base <= 0.0:
		return 0.0
	var multiplier := _get_harvester_speed_multiplier(harvester)
	if multiplier <= 0.0:
		multiplier = 1.0
	return maxf(0.05, base / multiplier)

# ----------------------------------------
# 获取采集者的采集速度倍率函数
# 查询玩家 Equipment 节点，工具类型匹配才加成
#
# 返回：1.0 = 原速，1.5 = 快 50%，2.0 = 快一倍
# ----------------------------------------
func _get_harvester_speed_multiplier(harvester: Node) -> float:
	if harvester == null or not resource_data:
		return 1.0
	var equipment = _get_harvester_equipment(harvester)
	if equipment != null and equipment.has_method("get_harvest_speed_multiplier"):
		return float(equipment.call(
			"get_harvest_speed_multiplier", int(resource_data.required_tool)))
	return 1.0

# ----------------------------------------
# 获取采集者的 Equipment 节点
# 找不到/不挂脚本时返回 null，调用方做能力检测
# ----------------------------------------
func _get_harvester_equipment(harvester: Node) -> Node:
	if harvester == null:
		return null
	return harvester.get_node_or_null("Equipment")

# ----------------------------------------
# 缺工具时闪一条屏幕提示
# 提示的绘制和文案都在 ResourceManager（组 "resource_manager"），本实体只转发
# ----------------------------------------
func _flash_tool_hint() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var mgr = tree.get_first_node_in_group("resource_manager")
	if mgr != null and mgr.has_method("flash_hint") and mgr.has_method("get_tool_missing_hint"):
		mgr.call("flash_hint", mgr.call("get_tool_missing_hint", self))

# ----------------------------------------
# 释放采集互斥锁
# Equipment 节点存在且有 set_harvesting 方法时调用；
# 否则 no-op（避免非玩家 harvester 崩溃）
# ----------------------------------------
func _release_harvest_lock(equipment: Node) -> void:
	if equipment != null and equipment.has_method("set_harvesting"):
		equipment.set_harvesting(false)

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
		
		# 如果可以再生，接续再生计时。
		# remaining<=0 说明是"采集中途保存的档"（那时还没开始计时），
		# 这里按完整时长重新起一次，否则这类资源会永远停在已采集状态。
		if resource_data.can_regenerate and _regen_component:
			if regen_time_remaining > 0.0:
				_regen_component.resume_regeneration(regen_time_remaining)
			else:
				_regen_component.start_regeneration()

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
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "错误：找不到物品数据 %s", [item_id])
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
