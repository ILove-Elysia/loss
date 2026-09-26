# script/ai/enemy/boss/sandworm/sandworm.gd
# ============================================
# 沙虫 · 地表战（第一条 Boss 线）
#
# 玩家可见的行为（规格 2.1）：
#   1. 靠近巢穴并停留一段时间 → 沙虫钻出沙面
#   2. 在地下**潜行追击**玩家（只看得到一截背脊，打不到），追进射程就冒头出招
#   3. 招式由两张表（血厚 / 血少）决定，按**固定顺序**轮转（玩家可以背板）：
#        表 1（血 > 50%）   ：① 撕咬 → ② 吐沙 → ③ 流沙陷落
#        表 2（血 ≤ 50%）   ：④ 潜行突袭 → ① 撕咬 → ② 吐沙 → ③ 流沙陷落
#   4. 玩家拖太远、或玩家死亡 → 回巢**回满血**、回到待机（可重复，不推进世界）
#   5. 血量被打到 1 → 保底 1 点生命 + 永久无敌，逃回巢穴；巢穴坍塌（写世界旗标）
#
# ⚠ 本文件里的数值全是**建议值**（对应 主线设计规格.md 附录"待拍板" #3 / #4）：
#   全部可以在编辑器里 @export 改，也可以实机边打边调。
#
# 招式表的选取是**固定顺序轮转**（不是随机、也不是"第 1 招永远优先"）：
#   轮到哪招就出哪招；轮到的那招够不着，就继续潜行逼近、追进射程再放。
#   顺序本身是留给玩家背板的 —— ① 一定是咬、② 一定是吐沙。
#
# **受击窗口**由每招的 surfaces_in_telegraph 决定（这是本设计的核心手感）：
#   true  ⇒ 冒头的前摇就能被打（①②）
#   false ⇒ 它躲在地底下筹备/突进，判定段才破土（③流沙、④突袭）——
#           这两招要么走位躲开，要么等它露头再打，别对着土挥刀
#
# 状态机本体在 boss_sandworm_base.gd，本文件只负责"性格"（数值 + 招式表）。
# ============================================

class_name Sandworm
extends BossSandwormBase

## 稳定身份：存档里用这个认它（**不要**用节点路径 —— Boss 是运行时生成/移除的）
const BOSS_ID := &"sandworm_surface"
## 退场时置的世界旗标
const NEST_FLAG := &"sandworm_nest_state"

# 相位分界线（> 50% 用表 1）在基类的 @export `phase_line` 上，不在这里 ——
# 早先这里放过一个 `const PHASE_LINE`，但基类当时写死了 0.5，改它根本不生效（已删）。


func _ready() -> void:
	boss_id = BOSS_ID
	display_name = "沙虫"
	nest_flag = NEST_FLAG
	super()


# ============================================
# 招式表
#
# 表 1（血量 > 50%，3 招）：① 撕咬 → ② 吐沙 → ③ 流沙陷落
# 表 2（1 < 血量 ≤ 50%，4 招）：④ 潜行突袭 → ① ② ③
# 数组的**排列顺序就是轮转顺序** —— 表 2 把 ④ 放在表头，所以它读作 4123。
#
# 字段含义见 boss_sandworm_attack.gd：
#   min_range / max_range   决策点筛选用的射程
#   telegraph_time          前摇 = 给玩家跑的时间（0.9 s 对满速玩家 ≈ 4.5 m）
#   strike_time             判定生效时长（只判一次）
#   recover_time            后摇 = 玩家的输出窗口
#   cooldown                这一招自己的冷却（固定轮转下基本拦不到，防的是改表改坏）
#   aims_at_player          判定圆心 = 施放瞬间玩家的位置（打地面，不是咬在嘴上）
#   zone_radius             圆形区域半径（圈内单位被持续拉向圆心）
#   surfaces_in_telegraph   前摇期间是否已露头（false = 判定段才破土 ⇒ 前摇打不到）
#
# 手感标尺：玩家满速 5.0 m/s（饥饿 ×0.9、低电量 ×0.7 ⇒ 最低 3.15）。
# "躲不躲得掉" = 前摇时长 × 玩家速度 ≥ 需要跑出去的距离。下面每招都按这个配。
# ============================================

func _build_attacks() -> void:
	# ①②③ 是两张表**共用**的同一份数组 —— 这里不复制粘贴，否则改了一张漏另一张，
	# 玩起来就成了"血量一破、手感突变"（老版两张表各写一份、数值还不一样）。
	var shared: Array = [
		# ---- ① 撕咬：冒头咬一口 ----
		# 只在贴近时被选中（max_range = 判定半径 4.5）⇒ 轮转轮到它但玩家在远处时，
		# 它会继续潜行逼近，追进 4.5 m 才冒头。前摇 0.9 s × 5.0 = 4.5 m，
		# 正好够"从嘴边跑到判定圈外"；虚弱状态（3.15）跑不掉。
		{
			"id": &"bite", "name": "撕咬",
			"min_range": 0.0, "max_range": 4.5,
			"damage": 18, "radius": 4.5, "height": 2.6,
			"telegraph_time": 0.9, "strike_time": 0.2, "recover_time": 1.0,
			"cooldown": 4.0,
			"surfaces_in_telegraph": true,
		},
		# ---- ② 吐沙：冒头朝玩家吐一口沙 ----
		# 落点钉在**施放瞬间玩家的位置**（aims_at_player），所以它不必贴脸。
		# 玩家要在 0.75 s 里跑开 3.5 m 才躲得掉（满速 3.75 m ✓，虚弱 2.36 m ✗）。
		# ⚠ 老版的 sand_spit 拿半径 1.8 去量"玩家↔沙虫"的距离，又配了 min_range 5
		#   ⇒ 它永远打不中。远程招的判定圆心必须落在玩家身上，不是 Boss 自己。
		{
			"id": &"sand_spit", "name": "吐沙",
			"min_range": 0.0, "max_range": 16.0,
			"damage": 14, "radius": 3.5, "height": 2.6,
			"telegraph_time": 0.75, "strike_time": 0.15, "recover_time": 1.2,
			"cooldown": 5.0,
			"aims_at_player": true,
			"surfaces_in_telegraph": true,
			"zone_color": Color(0.72, 0.60, 0.30, 0.40),
		},
		# ---- ③ 流沙陷落：以玩家为圆心圈一块地，然后从圆心破土吞噬 ----
		# 圈内所有单位（玩家 + 其他生物）被持续拖向圆心，2.8 s 后沙虫从圆心冒出，
		# 把还留在圈里的单位一口吞掉。半径 7 m、拉力 2.0：
		#   满速玩家净速度 3.0 m/s × 2.8 s = 8.4 m > 7 m ⇒ 立刻起跑就跑得掉；
		#   虚弱玩家净速度 1.15 m/s ⇒ 只有 3.2 m ⇒ 站在圈里就必被吞。
		# ⚠ 这一招在地下筹备（surfaces_in_telegraph = false）：前摇期间它埋着、打不到，
		#   应对方式是**走位**而不是输出 —— 对着土挥刀是打不中的。
		{
			"id": &"quicksand", "name": "流沙陷落",
			"min_range": 0.0, "max_range": 20.0,
			"damage": 30, "radius": 7.0, "height": 3.0,
			"telegraph_time": 2.8, "strike_time": 0.3, "recover_time": 1.8,
			"cooldown": 6.0,
			"aims_at_player": true,
			"zone_radius": 7.0, "zone_pull_speed": 2.0,
			"surfaces_in_telegraph": false,
			"zone_color": Color(0.55, 0.40, 0.16, 0.55),
		},
	]
	# 表 1（血量 > 50%）：顺序 ① → ② → ③
	_phase1_attacks = _make_table(shared)

	# ---- ④ 潜行突袭：在地下高速逼近，破土咬一口 ----
	# move_scale 2.5 ⇒ 突进速度 3.4 × 2.5 = 8.5 m/s，前摇只有 0.35 s。
	# 判定圆心 = **它咬下去那一刻自己的位置**（不是施放瞬间）⇒ 本质是一次短扑：
	#   max_range 6.0 是起手距离上限，0.35 s 冲 3 m，把距离压进 4 m 判定圈。
	#   站桩必中（0.35 s 只够走 1.75 m，而它冲 3 m）；
	#   边退边打就躲得掉（6 m 外起跑 ⇒ 它冲到 3 m 时你已在 4 m 判定圈外）。
	# 伤害刻意压到 12：这是"几乎躲不掉的税"，不该同时又是高伤。
	# ⚠ 它在地下突进（surfaces_in_telegraph = false）⇒ 前摇那 0.35 s 打不到它。
	var dash_bite: Dictionary = {
		"id": &"dash_bite", "name": "潜行突袭",
		"min_range": 0.0, "max_range": 6.0,
		"damage": 12, "radius": 4.0, "height": 2.6,
		"telegraph_time": 0.35, "strike_time": 0.2, "recover_time": 1.2,
		"cooldown": 6.0,
		"move_scale": 2.5,
		"surfaces_in_telegraph": false,
	}

	# 表 2（血量 ≤ 50%）：④ 打头 + ①②③ ⇒ 顺序读作 **4123**
	_phase2_attacks = _make_table([dash_bite] + shared)


## 把"字典声明"批量变成 BossSandwormAttack。
## 不直接把数组字面量赋给 Array[BossSandwormAttack]：字面量的静态类型是 Array，
## 赋给类型化数组会因元素类型不确定而编译报错，所以统一走这个转换函数。
func _make_table(rows: Array) -> Array[BossSandwormAttack]:
	var table: Array[BossSandwormAttack] = []
	for row in rows:
		var data: Dictionary = row
		table.append(BossSandwormAttack.make(data))
	return table


# ============================================
# 退场表现（巢穴坍塌）
# 真正的坍塌动画与"可进入"的锁在 主线设计规格.md 2.6 —— 本步只置旗标，
# 场地外观由巢穴场景读 WorldState 旗标来切。
# ============================================

func _on_gone() -> void:
	_debug("巢穴坍塌：WorldState.%s = 1" % NEST_FLAG)
