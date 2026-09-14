# script/resources/component/resource_regeneration.gd
# ============================================
# 再生组件 - 管理资源的时间性再生
#
# 这个组件负责：
# 1. 启动再生计时
# 2. 跟踪再生进度
# 3. 在游戏暂停时暂停计时
# 4. 再生完成后通知其他组件
#
# 什么是 Timer？
# Timer 是 Godot 的计时器节点
# 可以设置等待时间，时间到了发出 timeout 信号
# one_shot = true 表示只计时一次，不重复
# ============================================

class_name ResourceRegeneration
extends Node

# ============================================
# 信号定义
# ============================================

# 再生完成时发出
signal regeneration_complete

# 再生进度更新时发出
# 参数：progress - 进度值，范围 0.0 到 1.0
signal regeneration_progress(progress: float)

# ============================================
# 导出变量
# ============================================

# 再生计时器
# 在编辑器中将 Timer 节点拖入此处
@export var regeneration_timer: Timer

# ============================================
# 私有变量
# ============================================

# 资源数据引用
var _resource_data: ResourceData

# 是否正在再生
var _is_regenerating: bool = false

# 已经过的时间（秒）
var _elapsed_time: float = 0.0

# 暂停时保存的剩余时间
var _paused_time: float = 0.0

# ============================================
# 生命周期函数
# ============================================

func _ready() -> void:
	# 如果没有设置计时器，动态创建一个
	if not regeneration_timer:
		_create_default_timer()
	
	# 连接计时器的 timeout 信号
	# 当计时结束时调用 _on_timer_timeout
	regeneration_timer.timeout.connect(_on_timer_timeout)
	
	# 尝试连接游戏管理器的暂停信号
	# 这样游戏暂停时，再生也会暂停
	_connect_to_game_manager()

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置函数
# 初始化再生组件的配置
#
# 参数：data - 资源数据配置
# ----------------------------------------
func setup(data: ResourceData) -> void:
	_resource_data = data

# ----------------------------------------
# 开始再生函数
# 启动再生计时
# 采集完成后由 ResourceEntity 调用
# ----------------------------------------
func start_regeneration() -> void:
	# 检查是否可以再生
	if not _resource_data or not _resource_data.can_regenerate:
		return
	
	_is_regenerating = true
	_elapsed_time = 0.0
	
	# 启动计时器，参数是等待时间（秒）
	regeneration_timer.start(_resource_data.regeneration_time)

# ----------------------------------------
# 恢复再生函数
# 从存档加载时使用
# 从之前保存的剩余时间继续计时
#
# 参数：remaining_time - 剩余的再生时间（秒）
# ----------------------------------------
func resume_regeneration(remaining_time: float) -> void:
	if not _resource_data or not _resource_data.can_regenerate:
		return
	
	_is_regenerating = true
	# 计算已经过的时间
	_elapsed_time = _resource_data.regeneration_time - remaining_time
	
	# 从剩余时间继续计时
	regeneration_timer.start(remaining_time)

# ----------------------------------------
# 取消再生函数
# 停止计时并清掉"正在再生"标记。
# 实体退回对象池时调用（见 ResourceEntity.reset_for_pool）：
# 实体被复用去表示另一个资源，上一世的倒计时必须彻底停掉，
# 否则它会在新资源身上突然触发 regeneration_complete，把已采集的资源变回生长态。
# ----------------------------------------
func cancel_regeneration() -> void:
	_is_regenerating = false
	_elapsed_time = 0.0
	_paused_time = 0.0
	if regeneration_timer:
		regeneration_timer.stop()

# ----------------------------------------
# 暂停再生函数
# 游戏暂停时调用
# ----------------------------------------
func pause_regeneration() -> void:
	if not _is_regenerating:
		return
	
	# 保存剩余时间
	_paused_time = regeneration_timer.time_left
	
	# 停止计时器
	regeneration_timer.stop()

# ----------------------------------------
# 从暂停恢复函数
# 游戏恢复时调用
# ----------------------------------------
func resume_from_pause() -> void:
	if _paused_time <= 0:
		return
	
	# 从保存的时间继续
	regeneration_timer.start(_paused_time)
	_paused_time = 0.0

# ----------------------------------------
# 获取剩余时间函数
# 返回：剩余的再生秒数
# ----------------------------------------
func get_remaining_time() -> float:
	if regeneration_timer and _is_regenerating:
		# time_left 是 Timer 的属性，返回剩余时间
		return regeneration_timer.time_left
	return 0.0

# ----------------------------------------
# 获取再生进度函数
# 返回：0.0 到 1.0 之间的进度值
# 0.0 = 刚开始
# 1.0 = 即将完成
# ----------------------------------------
func get_progress() -> float:
	if not _resource_data or not _is_regenerating:
		return 0.0
	
	# 计算进度 = 1 - (剩余时间 / 总时间)
	var total_time = _resource_data.regeneration_time
	var remaining = regeneration_timer.time_left
	return 1.0 - (remaining / total_time)

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 创建默认计时器函数
# ----------------------------------------
func _create_default_timer() -> void:
	regeneration_timer = Timer.new()
	regeneration_timer.name = "RegenerationTimer"
	# one_shot = true 表示只触发一次，不循环
	regeneration_timer.one_shot = true
	add_child(regeneration_timer)

# ----------------------------------------
# 连接游戏管理器函数
# 尝试连接游戏的暂停/恢复信号
# ----------------------------------------
func _connect_to_game_manager() -> void:
	# get_tree().get_first_node_in_group() 
	# 获取第一个在指定组中的节点
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	
	if game_manager:
		# has_signal 检查节点是否有某个信号
		if game_manager.has_signal("game_paused"):
			# 连接信号
			game_manager.game_paused.connect(_on_game_paused)
		if game_manager.has_signal("game_resumed"):
			game_manager.game_resumed.connect(_on_game_resumed)

# ----------------------------------------
# 计时器超时处理
# 当再生时间结束时调用
# ----------------------------------------
func _on_timer_timeout() -> void:
	_is_regenerating = false
	# 发出再生完成信号
	regeneration_complete.emit()

# ----------------------------------------
# 游戏暂停处理
# ----------------------------------------
func _on_game_paused() -> void:
	pause_regeneration()

# ----------------------------------------
# 游戏恢复处理
# ----------------------------------------
func _on_game_resumed() -> void:
	resume_from_pause()
