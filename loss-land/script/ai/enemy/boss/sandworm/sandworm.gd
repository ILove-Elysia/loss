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
# **判定形状**由每招的字段决定（三种，见 boss_sandworm_attack.gd）：
#   ① 撕咬 = **面前扇形**（arc_degrees 120°，朝向在前摇锁住 ⇒ 绕到背后能躲）
#   ② 吐沙 = **弹道**（projectile_speed + projectile_count 4 ⇒ **连吐 4 发**；
#            躲的是**飞行段**，不是前摇，而且必须**连续换位**才甩得掉后面几发）
#   ③④    = 就地圆形
#
# **前摇的可见信号**（2026-09-26 用户反馈"撕咬不够明显、难以察觉"补的，走基类）：
#   · 地面预警片：区域招画圈、**扇形招画同形状的扇形**（形状与朝向都和判定同源）；
#   · 体色脉动（telegraph_pulse_hz），不是静态变红。
#   这两条不需要在招式表里配任何字段 —— 由形状字段自动派生。
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
#   arc_degrees             面前扇形张角（0/360 = 全圆；>0 ⇒ 只打嘴前面）
#   projectile_speed        弹道初速（> 0 ⇒ 判定段射出去，命中归弹道自己）
#   projectile_hit_radius   弹道的命中半径（平面距离）
#   projectile_count        一次出招**连吐几发**（> 1 ⇒ 逐发瞄准，站定全吃）
#   projectile_interval     连发的节拍间隔（秒）
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
		# ---- ① 撕咬：冒头咬一口（**只咬嘴前面的扇形**） ----
		# 只在贴近时被选中（max_range = 判定半径 4.5）⇒ 轮转轮到它但玩家在远处时，
		# 它会继续潜行逼近，追进 4.5 m 才冒头。前摇 0.9 s × 5.0 = 4.5 m，
		# 正好够"从嘴边跑到判定圈外"；虚弱状态（3.15）跑不掉。
		# 扇形 120°（左右各 60°）：够得着还不够，还得在**嘴前面**。
		#   ⚠ 朝向在**开始前摇那一刻就锁住了**（定身招不前摇转向，见基类 _facing 的说明），
		#     所以贴脸时"**绕着它转**"也能躲开这一口（2 m 处横移 ~3.5 m 就出扇形）——
		#     这是"扇形"相对"圆圈"多出来的那条活路。
		#     想让它咬的过程中还跟着你转头：把 arc_degrees 调小、或给它 move_scale > 0
		#     （后者代价是它会边走边转，那扇形就形同虚设了）。
		# **前摇的可见信号**（2026-09-26 用户反馈"释放时不够明显、难以察觉"补的）：
		#   ① 体色**脉动**（telegraph_pulse_hz，见基类 _refresh_body_color）；
		#   ② 地面上画出**同一块扇形**（形状 = 判定形状、朝向 = 判定朝向）⇒
		#      玩家一眼看懂"嘴前面这块地会挨咬，往侧面跑"。
		#   这两条都不用改这招的数据：只要 arc_degrees > 0 就会自动画出来。
		{
			"id": &"bite", "name": "撕咬",
			"min_range": 0.0, "max_range": 4.5,
			"damage": 18, "radius": 4.5, "height": 2.6,
			"arc_degrees": 120.0,
			"telegraph_time": 0.9, "strike_time": 0.2, "recover_time": 1.0,
			"cooldown": 4.0,
			"surfaces_in_telegraph": true,
		},
		# ---- ② 吐沙：冒头朝玩家**连吐 4 发沙弹**（真弹道，靠走位躲） ----
		# 判定段按 0.16 s 的节拍吐满 4 发（0 / 0.16 / 0.32 / 0.48 s），
		# **每一发都瞄"那一发出膛的瞬间"玩家在哪** ⇒
		#   站着不动 = 4 发全吃（4 × 6 = 24 伤，比撕咬的 18 还高）；
		#   持续换位 = 可以甩掉后面几发（每发都是"发射那一刻"的位置，不追踪）。
		# 距离决定难度：3 m 处飞行只要 0.17 s ⇒ 满速也只挪 0.85 m（< 命中半径 0.9）⇒ 必吃满；
		#   10 m 处飞行 0.56 s ⇒ 能挪 2.8 m ⇒ 从容躲掉。**越近越该跑，别贴着它站桩**。
		# ⚠ strike_time 对连发招只是**下限**：真实判定段长度由 strike_window() 兜底
		#   （= max(strike_time, 末发时刻 + 0.05)），所以配小了也不会"只吐 2 发就进后摇"。
		# ⚠ 它**不再画地面圈**（aims_at_player 已去掉）：地面圈是给"落点钉在地面"的招用的。
		# ⚠ 判定完全归弹道 ⇒ radius / arc_degrees / height 对这招**都没有意义**，故不写。
		{
			"id": &"sand_spit", "name": "吐沙",
			"min_range": 0.0, "max_range": 16.0,
			"damage": 6,
			"telegraph_time": 0.75, "strike_time": 0.6, "recover_time": 1.2,
			"cooldown": 5.0,
			"projectile_speed": 18.0,
			"projectile_hit_radius": 0.9,
			"projectile_count": 4,
			"projectile_interval": 0.16,
			"surfaces_in_telegraph": true,
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
