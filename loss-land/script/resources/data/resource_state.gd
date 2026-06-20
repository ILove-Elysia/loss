# script/resources/data/resource_state.gd
# ============================================
# 资源状态类 - 定义资源可能处于的所有状态
# 
# 什么是枚举(enum)？
# 枚举是一种数据类型，它把有限的数值起上易读的名字
# 比如 GROWING = 0, HARVESTED = 1, ...
# 这样做的好处是代码更易读：current_state == GROWING 而不是 current_state == 0
#
# 什么是 RefCounted？
# RefCounted 是 Godot 中的引用计数类
# 比 Node 更轻量，适合纯数据类
# ============================================

class_name ResourceState
extends RefCounted

# ----------------------------------------
# 状态枚举
# 定义资源的四种可能状态
# 
# GROWING      - 生长中/完好状态：玩家可以采集
# HARVESTED    - 已采集状态：玩家不能采集，等待再生
# REGENERATING - 再生中状态：正在恢复中
# TRANSITIONING - 过渡中状态：正在播放动画
# ----------------------------------------
enum State {
    GROWING,        # 生长中/完好状态
    HARVESTED,      # 已采集状态
    REGENERATING,   # 再生中状态
    TRANSITIONING   # 过渡中状态（采集中）
}

# ----------------------------------------
# 状态转字符串函数
# 
# 什么是 static？
# static 静态方法可以直接通过 类名.方法名 调用
# 比如 ResourceState.to_string(GROWING) 返回 "生长中"
# 不需要先创建 ResourceState 的实例
#
# 参数：state - 要转换的状态值
# 返回：状态的中文字符串，用于调试显示
# ----------------------------------------
static func to_string(state: State) -> String:
    # match 是 Godot 的 switch 语句
    # 用于根据不同值执行不同代码
    match state:
        State.GROWING:
            return "生长中"
        State.HARVESTED:
            return "已采集"
        State.REGENERATING:
            return "再生中"
        State.TRANSITIONING:
            return "过渡中"
        # _ 下划线表示默认情况（类似 switch 的 default）
        _:
            return "未知"
