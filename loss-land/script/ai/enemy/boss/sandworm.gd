# script/ai/enemy/boss/sandworm.gd
# ============================================
# 沙虫 · 地表战（第一条 Boss 线）
#
# 玩家可见的行为（规格 2.1）：
#   1. 靠近巢穴并停留一段时间 → 沙虫钻出沙面
#   2. 在一定距离内**追击**玩家，进入攻击距离就出招
#   3. 招式由两张表（血厚 / 血少）决定，从上往下取第一条不在冷却的
#   4. 玩家拖太远、或玩家死亡 → 回巢**回满血**、回到待机（可重复，不推进世界）
#   5. 血量被打到 1 → 保底 1 点生命 + 永久无敌，逃回巢穴；巢穴坍塌（写世界旗标）
#
# ⚠ 本文件里的数值全是**建议值**（对应 主线设计规格.md 附录"待拍板" #3 / #4）：
#   全部可以在编辑器里 @export 改，也可以实机边打边调。
#   招式表的选取是"从上往下取首条不在 CD 且在射程内"＝**确定性轮转**，不是随机，
#   所以第 1 招永远优先、最后一条只在前面全在 CD 时才出场（玩家可以背板）。
#
# 状态机本体在 boss_base.gd，本文件只负责"性格"（数值 + 招式表）。
# ============================================

class_name Sandworm
extends BossBase

## 稳定身份：存档里用这个认它（**不要**用节点路径 —— Boss 是运行时生成/移除的）
const BOSS_ID := &"sandworm_surface"
## 退场时置的世界旗标
const NEST_FLAG := &"sandworm_nest_state"

## 相位分界线：血量比例 > 这个值用表 1，否则用表 2（规格 2.4）
const PHASE_LINE := 0.5


func _ready() -> void:
	boss_id = BOSS_ID
	display_name = "沙虫"
	nest_flag = NEST_FLAG
	super()


# ============================================
# 招式表
#
# 表 1：血量 > 50%（3 招）
# 表 2：1 < 血量 < 50%（4 招）
#
# 表 2 目前是"表 1 的三招（冷却缩短）+ 新增一招「流沙陷落」"。
# ⚠ 这是**待定项**（原案也可能是"另换四招"）：改这里即可，状态机一行都不用动。
#
# 字段含义见 boss_attack.gd：
#   min_range / max_range  决策点筛选用的射程
#   telegraph_time         前摇 = 给玩家跑的时间（0.9s 对 5.0 m/s 的玩家 ≈ 4.5 m）
#   strike_time            判定生效时长（只判一次）
#   recover_time           后摇 = 玩家的输出窗口
#   cooldown               这一招自己的冷却
# ============================================

func _build_attacks() -> void:
	_phase1_attacks = _make_table([
		{
			"id": &"bite", "name": "撕咬",
			"min_range": 0.0, "max_range": 4.5,
			"damage": 18, "radius": 4.5, "height": 2.6,
			"telegraph_time": 0.9, "strike_time": 0.2, "recover_time": 1.0,
			"cooldown": 4.0,
		},
		{
			"id": &"sweep", "name": "甩尾横扫",
			"min_range": 0.0, "max_range": 7.0,
			"damage": 24, "radius": 7.0, "height": 2.6,
			"telegraph_time": 1.2, "strike_time": 0.3, "recover_time": 1.4,
			"cooldown": 7.0,
		},
		{
			# 远程：只在中距离以上才会被选中（贴脸时不该吐沙）
			"id": &"sand_spit", "name": "吐沙",
			"min_range": 5.0, "max_range": 18.0,
			"damage": 12, "radius": 1.8, "height": 2.6,
			"telegraph_time": 1.1, "strike_time": 0.15, "recover_time": 1.2,
			"cooldown": 9.0,
		},
	])

	_phase2_attacks = _make_table([
		{
			"id": &"bite", "name": "撕咬（急躁）",
			"min_range": 0.0, "max_range": 4.5,
			"damage": 18, "radius": 4.5, "height": 2.6,
			"telegraph_time": 0.75, "strike_time": 0.2, "recover_time": 0.85,
			"cooldown": 2.6,
		},
		{
			"id": &"sweep", "name": "甩尾横扫（急躁）",
			"min_range": 0.0, "max_range": 7.0,
			"damage": 24, "radius": 7.0, "height": 2.6,
			"telegraph_time": 1.0, "strike_time": 0.3, "recover_time": 1.2,
			"cooldown": 5.0,
		},
		{
			"id": &"sand_spit", "name": "吐沙",
			"min_range": 5.0, "max_range": 18.0,
			"damage": 12, "radius": 1.8, "height": 2.6,
			"telegraph_time": 1.0, "strike_time": 0.15, "recover_time": 1.0,
			"cooldown": 6.5,
		},
		{
			# 血量掉到一半以下才解锁的第四招：大范围、长前摇、长后摇
			# （放在表尾 ⇒ 只在前面三招都在 CD 时才出场）
			"id": &"quicksand", "name": "流沙陷落",
			"min_range": 0.0, "max_range": 6.0,
			"damage": 30, "radius": 9.0, "height": 3.0,
			"telegraph_time": 1.6, "strike_time": 0.3, "recover_time": 1.8,
			"cooldown": 12.0,
			"telegraph_color": Color(0.95, 0.72, 0.18),
		},
	])


## 把"字典声明"批量变成 BossAttack。
## 不直接把数组字面量赋给 Array[BossAttack]：字面量的静态类型是 Array，
## 赋给类型化数组会因元素类型不确定而编译报错，所以统一走这个转换函数。
func _make_table(rows: Array) -> Array[BossAttack]:
	var table: Array[BossAttack] = []
	for row in rows:
		var data: Dictionary = row
		table.append(BossAttack.make(data))
	return table


# ============================================
# 退场表现（巢穴坍塌）
# 真正的坍塌动画与"可进入"的锁在 主线设计规格.md 2.6 —— 本步只置旗标，
# 场地外观由巢穴场景读 WorldState 旗标来切。
# ============================================

func _on_gone() -> void:
	_debug("巢穴坍塌：WorldState.%s = 1" % NEST_FLAG)
