# script/ai/enemy/boss/sandworm/boss_sandworm_attack.gd
# ============================================
# Boss 招式描述（一个 Resource，描述"这一招怎么演"）
#
# 为什么把招式做成数据、而不是像史莱姆那样"在动画结束回调里判距离"：
#   现有敌人把伤害时点绑死在美术动画长度上（slime.gd 的
#   _on_attack_animation_finished → _apply_attack_damage），
#   于是**表达不了"前摇可躲"** —— 想改前摇就得改动画。
#   Boss 必须能精确控制三段时长，所以时长写在数据里，动画只负责好看。
#
# 三段语义（规格 1.7 / 2.4）：
#   telegraph_time  前摇：怪抬手的这段时间，玩家跑出 radius 就能躲开
#   strike_time     判定：真正扣血的那一小段（只判定一次，不是每帧）
#   recover_time    后摇：硬直，玩家的输出窗口
#
# 数值一律 @export，方便实机边打边调；招式表在各自 Boss 脚本里用
# make({...}) 声明（见 sandworm.gd）。
# ============================================

class_name BossSandwormAttack
extends Resource

@export_group("身份")
## 招式标识：冷却表的键、日志/调试面板里显示的名字
@export var attack_id: StringName = &""
## 中文名（调试面板用）
@export var display_name: String = ""

@export_group("判定形状")
@export_enum("CYLINDER", "SPHERE") var shape: int = 0
## CYLINDER：以 Boss 为心的水平圆柱判定半径；SPHERE：以落点为心的球
@export var radius: float = 4.0
## 判定体的高度（玩家碰撞体只有 1.0 m 高，判定要罩得住）
@export var height: float = 2.6
## 命中扣多少血（玩家护甲会再减免，但至少掉 1）
@export var damage: int = 15

@export_group("射程（决策点筛选用）")
## 小于这个距离不选这招（贴脸时不该放远程）
@export var min_range: float = 0.0
## 大于这个距离不选这招（够不着就别空放）
@export var max_range: float = 5.0

@export_group("三段时长")
@export var telegraph_time: float = 0.9
@export var strike_time: float = 0.2
@export var recover_time: float = 1.1
## 这一招自己的冷却（每招一个计时器，不是全局一个）
@export var cooldown: float = 5.0

@export_group("表现")
## 前摇期间能不能移动（0 = 定身，1 = 全速追）。定身＝给玩家跑的机会
@export var move_scale: float = 0.0
## 前摇时的体色（给玩家"要来了"的视觉信号，正式美术接入后由动画取代）
@export var telegraph_color: Color = Color(1.0, 0.42, 0.22)

# ============================================
# 构造
# ============================================

## 用字典声明一条招式。
## 只写关心的字段，其余走默认值 —— 招式表因此可以写得很短。
static func make(data: Dictionary) -> BossSandwormAttack:
	var attack: BossSandwormAttack = BossSandwormAttack.new()
	attack.attack_id = StringName(data.get("id", &""))
	attack.display_name = String(data.get("name", attack.attack_id))
	attack.shape = int(data.get("shape", 0))
	attack.radius = float(data.get("radius", attack.radius))
	attack.height = float(data.get("height", attack.height))
	attack.damage = int(data.get("damage", attack.damage))
	attack.min_range = float(data.get("min_range", attack.min_range))
	attack.max_range = float(data.get("max_range", attack.max_range))
	attack.telegraph_time = float(data.get("telegraph_time", attack.telegraph_time))
	attack.strike_time = float(data.get("strike_time", attack.strike_time))
	attack.recover_time = float(data.get("recover_time", attack.recover_time))
	attack.cooldown = float(data.get("cooldown", attack.cooldown))
	attack.move_scale = float(data.get("move_scale", attack.move_scale))
	attack.telegraph_color = Color(data.get("telegraph_color", attack.telegraph_color))
	return attack

# ============================================
# 查询
# ============================================

## 三段总时长（决策节奏 = 招式的"占位时间"）
func total_time() -> float:
	return telegraph_time + strike_time + recover_time

## 玩家在这个距离能不能被这招够到（决策点筛选用）
func in_range(distance: float) -> bool:
	return distance >= min_range and distance <= max_range

## 调试面板用的一行描述
func describe() -> String:
	var label: String = display_name
	if label.is_empty():
		label = String(attack_id)
	return "%s 伤害%d 射程%.1f~%.1f 前摇%.2f 后摇%.2f CD%.1f" % [
		label, damage, min_range, max_range, telegraph_time, recover_time, cooldown,
	]
