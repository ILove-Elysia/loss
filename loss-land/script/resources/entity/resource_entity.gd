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

# 空手（没装工具、或工具没配 harvest_work）每一次作业能完成的工作量。
# 只用在"没设门槛"的资源上——设了白名单的资源空手根本进不来。
const HAND_WORK_PER_HIT: int = 1

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

# 剩余工作量（2026-09-18 加入）
#
# 相当于资源的一条"血条"：树 / 大石头这类资源要累计做满 resource_data.work_amount
# 才采得下来，每挥一次扣掉当前工具的 harvest_work。
# 0 = 未受损（满工作量）。中途走开不会清零——砍到一半的树下次回来接着砍。
var work_remaining: float = 0.0

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
# 视野流式加载的卸载判定要用：采集是 await 出来的长流程（每挥一下等 work_interval、
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
	# 工作量复位成"满"：这具节点马上可能要去表示远处另一棵树
	work_remaining = 0.0
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
# 采集流程（2026-09-18 起统一成一条）：
#
# 1. 检查工具标签白名单——白名单非空 = 必须带对应工具（斧砍树、镐挖石挖矿），
#    空手一律拒绝；白名单为空 = 空手也能采（草、木棍、浆果、小石块）。
# 2. 循环作业：资源播被砍/被挖动画 + 人物播砍伐动作 → 等 work_interval（默认 1 秒）
#    → 扣一次工作量（当前工具的 harvest_work，空手是 1）。
# 3. 工作量扣完才发物品、切已采集；中途走远/死亡则中断，进度保留。
#
# 所有资源走同一条路：work_amount 就是"要采几下"，
# 空手可采的那些配成 1（挥一下就掉），只是每次的间隔不同。
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

	# 工具门槛（唯一判定，就是"工具标签白名单"）：
	#   资源配了白名单（树 &"axe"、大石头/铁矿/煤矿 &"pickaxe"）→ 装备的工具必须带
	#   其中任意一个标签，空手一律拒绝；
	#   没配白名单（草、木棍、浆果、小石块）→ 空手可采。
	# 必须在抢锁、切状态之前拒绝——否则会留下"过渡中"的半采状态。
	# 提示由 ResourceManager 统一画在屏幕底部（本组件没有 UI）。
	if resource_data != null and not _is_tool_allowed(harvester):
		DebugConfig.warn_msg(DebugConfig.CAT_RESOURCE, "[采集] 拒绝：%s 需要%s（当前工具不满足白名单）",
			[resource_data.resource_id,
			ResourceData.get_tool_tag_name(resource_data.primary_tool_tag())])
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

	# 所有资源统一走工作量流程：work_amount 就是"要采几下"
	await _harvest_by_work(harvester, equipment, get_work_per_hit(harvester))

# ----------------------------------------
# 按工作量采集（所有资源共用这一条）
#
# 每一"次"作业 = 资源播一次被砍 / 被挖动画 + 人物播一次作业动画 + 等 work_interval 秒，
# 然后扣掉当前工具的 harvest_work。扣完才算采下来。
#
# 中断（走远、死亡、实体被回收）时**保留已完成的工作量**：
# 工作量是资源的血条，砍到一半走开，回来接着砍剩下的，不用从头再来。
# ----------------------------------------
func _harvest_by_work(harvester: Node, equipment: Node, per_hit: int) -> void:
	if resource_data == null:
		_is_harvesting = false
		_release_harvest_lock(equipment)
		return

	set_state(ResourceState.State.TRANSITIONING)
	if work_remaining <= 0.0:
		work_remaining = float(resource_data.work_amount)

	var interval: float = maxf(0.05, resource_data.work_interval)
	while work_remaining > 0.0:
		# 被砍 / 被挖的资源播自己的动画（树是 25 帧晃动；石头暂无美术，静默）
		if _visual_component:
			_visual_component.play_harvest_animation()
		# 人物播砍伐动作（harvest 动画：直立抬臂 → 俯身下劈）
		_play_harvester_action(harvester)

		await get_tree().create_timer(interval).timeout

		if not is_instance_valid(self) or is_queued_for_deletion():
			_is_harvesting = false
			return

		# 刷新互斥锁的超时：一次完整作业（树 6 下 = 6 秒）可能顶到默认的 8 秒兜底
		if equipment != null and equipment.has_method("set_harvesting"):
			equipment.set_harvesting(true, int((interval + 2.0) * 1000.0))

		if not _is_harvester_still_working(harvester):
			DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集] 作业中断：%s 剩余工作量 %.0f/%.0f（进度保留）",
				[resource_data.resource_id, work_remaining, float(resource_data.work_amount)])
			_abort_harvest(equipment)
			return

		work_remaining = maxf(0.0, work_remaining - float(per_hit))
		DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集] %s 作业一次 −%d：剩余 %.0f/%.0f",
			[resource_data.resource_id, per_hit, work_remaining, float(resource_data.work_amount)])

	_finish_harvest(harvester, equipment)

# ----------------------------------------
# 收尾：发物品 → 资源从画面消失 → 释放锁 → 走完过渡后切"已采集"
# 两条采集路径共用这一段
# ----------------------------------------
func _finish_harvest(harvester: Node, equipment: Node) -> void:
	if resource_data == null:
		_is_harvesting = false
		_release_harvest_lock(equipment)
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
	work_remaining = 0.0
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
# 中止作业：锁放掉、状态回到"生长中"，已做的工作量原样保留
# ----------------------------------------
func _abort_harvest(equipment: Node) -> void:
	_is_harvesting = false
	_release_harvest_lock(equipment)
	if is_instance_valid(self) and not is_queued_for_deletion():
		set_state(ResourceState.State.GROWING)

# ----------------------------------------
# 工具是否允许作业（标签白名单优先）
# ----------------------------------------
func _is_tool_allowed(harvester: Node) -> bool:
	if resource_data == null:
		return false
	# 没配白名单 = 不设门槛，空手也能采（草、木棍、浆果、小石块）
	if resource_data.allowed_tool_tags.is_empty():
		return true
	var tool_item := _get_harvester_tool_item(harvester)
	if tool_item == null:
		return false
	# 配了白名单就必须命中其中一个标签，没有任何"旧规则"兜底
	return resource_data.is_tool_tag_allowed(tool_item.tags)

# ----------------------------------------
# 取采集者装备栏里的工具数据（没装工具返回 null）
# ----------------------------------------
func _get_harvester_tool_item(harvester: Node) -> ItemData:
	var equipment := _get_harvester_equipment(harvester)
	if equipment == null or not equipment.has_method("get_tool_item"):
		return null
	var tool_item: ItemData = equipment.call("get_tool_item")
	return tool_item

# ----------------------------------------
# 本次采集"每一次作业"能完成多少工作量
#
# 取自当前工具的 harvest_work；没装工具、或工具没配这个值 = 空手，每次 1 点。
# 空手只可能采到"没设门槛"的资源（白名单为空），配了白名单的早在
# _is_tool_allowed 里就被拒了，所以这里给 1 点不会让人空手挖穿矿。
# ----------------------------------------
func get_work_per_hit(harvester: Node) -> int:
	if resource_data == null:
		return HAND_WORK_PER_HIT
	var tool_item := _get_harvester_tool_item(harvester)
	if tool_item != null and tool_item.harvest_work > 0:
		return tool_item.harvest_work
	return HAND_WORK_PER_HIT

# ----------------------------------------
# 播放人物的作业动作（砍树 / 挖矿）
# 人物侧播的是 SpriteFrames 里的 harvest 动画（2026-09-23 起不再借用 attack）；
# 不进入攻击状态，也不会误伤到怪
# ----------------------------------------
func _play_harvester_action(harvester: Node) -> void:
	if harvester == null or not is_instance_valid(harvester):
		return
	var physics: Node = harvester.get_node_or_null("Physics")
	if physics != null and physics.has_method("play_harvest_action"):
		physics.call("play_harvest_action")

# ----------------------------------------
# 采集者的世界坐标
#
# 关键：真正移动的是 player 根下的 Physics（CharacterBody3D），而 player 根节点
# 本身（Node3D）从不位移——它的 global_position 一直停在出生点。
# 采集中断判定若直接读根节点坐标，距离会恒等于"出生点到资源"，玩家贴着资源站
# 也会被判成"走远了"→ 每一下作业都中断、永远采不到东西（2026-09-22 实测）。
# ----------------------------------------
func _harvester_world_position(harvester: Node) -> Vector3:
	if harvester == null or not is_instance_valid(harvester):
		return global_position
	var body: Node3D = harvester.get_node_or_null("Physics") as Node3D
	if body != null:
		return body.global_position
	if harvester is Node3D:
		var root: Node3D = harvester as Node3D
		return root.global_position
	# 取不到坐标时退回资源自身位置（距离 0 = 不中断）：宁可少拦一次，
	# 也不要因为坐标拿不到让采集彻底进行不下去。
	return global_position


# ----------------------------------------
# 采集者是否还在好好作业（没死、没走远）
# 每次挥砍结束后查一次，不满足就中止
# ----------------------------------------
func _is_harvester_still_working(harvester: Node) -> bool:
	if harvester == null or not is_instance_valid(harvester):
		return false
	var physics: Node = harvester.get_node_or_null("Physics")
	if physics != null and physics.has_method("is_alive") and not bool(physics.call("is_alive")):
		return false
	# 走出交互范围（留 1.5 倍余量，免得挪半步就断）同样算中断。
	# 坐标必须取真正移动的那个节点：player 根节点从不位移，直接用它会把距离
	# 算成"出生点到资源"，每一下都被误判成走远（详见 _harvester_world_position）。
	var body_pos := _harvester_world_position(harvester)
	var limit: float = 3.0
	if _interaction_component != null:
		limit = _interaction_component.get_interaction_range()
	limit *= 1.5
	var dx: float = body_pos.x - global_position.x
	var dz: float = body_pos.z - global_position.z
	if sqrt(dx * dx + dz * dz) > limit:
		return false
	return true

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
		# 砍到一半的树也把进度存下来（0 = 满工作量/不适用）
		"work_remaining": work_remaining,
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
	# 老档没有这个键 = 满工作量（未受损）
	work_remaining = float(data.get("work_remaining", 0.0))
	
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

# 再生完成时的处理：长回来的是一棵完好的树，工作量回到满
func _on_regeneration_complete() -> void:
	work_remaining = 0.0
	set_state(ResourceState.State.GROWING)
	regenerated.emit()
