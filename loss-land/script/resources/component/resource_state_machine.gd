# script/resources/component/resource_state_machine.gd
# ============================================
# 状态机组件 - 管理资源的状态转换
#
# 什么是状态机？
# 状态机是一种设计模式，用于管理对象的不同状态
# 它确保状态之间的转换是有序和可控的
#
# 为什么需要状态机？
# 假设草有"生长"和"已采集"两种状态
# 如果没有状态机，代码可能乱切状态
# （比如还没采集就变成已采集）
# 使用状态机可以确保：
# 1. 状态按规则切换（采集后才变成已采集）
# 2. 每个状态的行為清晰
# 3. 易于扩展新状态
# ============================================

class_name ResourceStateMachine
extends Node

# ============================================
# 信号定义
# 当状态改变时通知其他组件
# ============================================

# 状态改变信号
# 其他组件可以监听这个信号来响应状态变化
signal state_changed(new_state: ResourceState.State)

# ============================================
# 成员变量
# ============================================

# 当前状态
var current_state: ResourceState.State = ResourceState.State.GROWING

# 上一个状态
# 某些情况下需要知道之前是什么状态
var previous_state: ResourceState.State = ResourceState.State.GROWING

# 状态数据存储
# 用于在状态之间传递数据
# 例如：在 GROWING 状态存储生长进度
var _state_data: Dictionary = {}

# ============================================
# 核心方法
# ============================================

# ----------------------------------------
# 改变状态函数（核心方法）
# 执行状态转换的完整流程
#
# 参数：new_state - 要切换到的新状态
#
# 状态转换流程：
# 1. 检查是否已经是目标状态
# 2. 调用退出当前状态的逻辑
# 3. 更新状态变量
# 4. 调用进入新状态的逻辑
# 5. 发出状态改变信号
# ----------------------------------------
func change_state(new_state: ResourceState.State) -> void:
    # 如果已经是目标状态，不做任何事
    if current_state == new_state:
        return
    
    # 1. 退出当前状态（执行清理逻辑）
    _exit_state(current_state)
    
    # 2. 记录上一个状态
    previous_state = current_state
    
    # 3. 更新当前状态
    current_state = new_state
    
    # 4. 进入新状态（执行初始化逻辑）
    _enter_state(new_state)
    
    # 5. 发出信号通知其他组件
    state_changed.emit(new_state)

# ============================================
# 状态数据操作
# 用于在状态之间存储和获取数据
# ============================================

# ----------------------------------------
# 获取状态数据
# 从当前状态获取存储的数据
#
# 参数：
#   key - 数据的键名
#   default - 如果数据不存在，返回的默认值
# 返回：存储的值或默认值
#
# 示例：
#   machine.set_state_data("progress", 0.5)  # 存储
#   var p = machine.get_state_data("progress", 0.0)  # 读取
# ----------------------------------------
func get_state_data(key: String, default: Variant = null) -> Variant:
    return _state_data.get(key, default)

# ----------------------------------------
# 设置状态数据
# 在状态中存储数据
# ----------------------------------------
func set_state_data(key: String, value: Variant) -> void:
    _state_data[key] = value

# ----------------------------------------
# 清除所有状态数据
# 切换状态时调用，清除旧状态的数据
# ----------------------------------------
func clear_state_data() -> void:
    _state_data.clear()

# ============================================
# 状态进入/退出处理
# ============================================

# ----------------------------------------
# 进入状态函数
# 当切换到这个状态时调用
# 在这里执行状态的初始化逻辑
#
# 例如：
#   GROWING 状态：开始播放生长动画
#   HARVESTED 状态：停止动画，显示枯萎贴图
# ----------------------------------------
func _enter_state(state: ResourceState.State) -> void:
    match state:
        ResourceState.State.GROWING:
            # 进入生长状态
            # 可以在这里播放生长动画或特效
            pass
        ResourceState.State.HARVESTED:
            # 进入已采集状态
            pass
        ResourceState.State.REGENERATING:
            # 进入再生状态
            pass
        ResourceState.State.TRANSITIONING:
            # 进入过渡状态
            pass

# ----------------------------------------
# 退出状态函数
# 当离开这个状态时调用
# 在这里执行状态的清理逻辑
#
# 例如：
#   退出生长状态：停止生长动画
# ----------------------------------------
func _exit_state(state: ResourceState.State) -> void:
    match state:
        ResourceState.State.GROWING:
            # 退出生长状态
            pass
        ResourceState.State.HARVESTED:
            # 退出已采集状态
            pass
        ResourceState.State.REGENERATING:
            # 退出再生状态
            pass
        ResourceState.State.TRANSITIONING:
            # 退出过渡状态
            pass
