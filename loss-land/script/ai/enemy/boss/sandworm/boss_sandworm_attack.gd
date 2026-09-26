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
# 判定形状的四种玩法（互斥，见各自的 @export 说明）：
#   ① 默认        判定段就地按 radius 量"玩家↔判定圆心"的距离
#   ② arc_degrees 再叠一层**面前扇形**限制（撕咬：只咬嘴前面的）
#                 ⇒ 前摇期间地面上会画出**同形状的预警片**（marker_color），
#                   这是它的视觉信号：2026-09-26 用户反馈"撕咬不够明显"加上的
#   ③ rect_length 判定改成**面前一条长条矩形**（突袭：扑出去的那条直线上才咬得到）
#                 ⇒ 同样会自动画出**同形状的预警片**（一条跟着它走的走廊）
#   ④ projectile  判定段改成**射弹道**出去，命中与扣血都归弹道管
#                 （吐沙：躲的是飞行段，不是前摇段）
#                 ⇒ 配 projectile_count > 1 就是**连吐**：逐发瞄准玩家当前位置，
#                   站着不动全吃、持续换位才能甩掉后面的
#
# ⚠ ②（扇形）与 ③（长条）要真的"躲得掉"，前提都是**朝向不跟着玩家转**：
#   撕咬靠"定身招不前摇转向"天然锁住，突袭靠 facing_locked 显式锁住。
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
## **扇形张角（度）**。0 或 ≥360 ⇒ 整个圆；> 0 ⇒ 只打「**面朝方向**左右各 arc/2」的范围。
##
## 撕咬用它：从地里探出头咬一口，只该咬到**嘴前面**的东西，不该咬到屁股后面。
## ⚠ 朝向在**开始前摇那一刻就锁住了**（定身招不前摇转向）⇒ 玩家绕到它背后就能躲开这一口。
##   想让它咬的过程中跟着你转头，把 move_scale 调 > 0（代价是它会边走边转）。
@export var arc_degrees: float = 0.0
## **长条矩形的长度**：从判定圆心沿"面朝方向"往前伸出去多少米。
## 与 rect_width 一起 > 0 才生效（生效后 radius 不再参与判定）。
##
## ④潜行突袭用它：从地底高速窜出来扑一口，咬到的是**它扑出去那条直线上的东西**，
## 站在它侧后方的玩家是安全的 —— 这正是"长条"相对"圆圈"多出来的那条活路。
## ⚠ 只往前延伸、**不往身后延伸**：贴脸重合（沿向 ≈ 0）算命中，背后算落空。
@export var rect_length: float = 0.0
## **长条矩形的宽度**（左右各占一半）。玩家碰撞体半径约 0.4 m ⇒ 别配得比 1.0 还窄，
## 否则"明明在它正前方却擦肩而过"会变成随机事件；配宽了就等于回到圆圈。
@export var rect_width: float = 0.0
## **朝向锁定**：true ⇒ "面朝方向"在决定出招那一刻定格，前摇/判定/后摇都不再修正。
##
## ⚠ 突进类招（配了 move_scale > 0）**必须**开，而且它**同时锁住突进方向** ——
##   移动方向就是"面朝方向"，两者一起定死，它才会沿一条**直线**扑出去。
##   少锁任何一个（只锁朝向 ⇒ 它照样拐弯追人；只锁方向 ⇒ 它照样扭头对准你），
##   扇形/长条就都会永远罩着玩家 ⇒ 等于必中、形状形同虚设。
## 默认关：只要 move_scale = 0（定身招），前摇本来就不转向，开不开都没差别。
@export var facing_locked: bool = false
## 命中扣多少血（玩家护甲会再减免，但至少掉 1）
@export var damage: int = 15

@export_group("射程（决策点筛选用）")
## 小于这个距离不选这招（贴脸时不该放远程）
@export var min_range: float = 0.0
## 大于这个距离不选这招（够不着就别空放）
@export var max_range: float = 5.0

@export_group("逼近（决定要放这一招时的追击）")
## **为了释放这一招，逼近阶段（CHASE 追击）用的移速（m/s）**。0 ⇒ 用基类的 chase_speed。
##
## ④潜行突袭用它，而且是本设计的核心之一（2026-09-27 用户要求："如果要释放潜行突袭，
## 则沙虫的速度大幅增加（**一定要大于玩家的默认速度**）直到释放出潜行突袭后才恢复原来的速度"）：
##   · 轮转指针一落到它头上 ⇒ 沙虫立刻加速扑向玩家，**不管玩家怎么跑都追得上**；
##   · 直到这一招真的放出去（判定结算完、指针推进到下一招）才降回 chase_speed。
## 这就是"快速靠近 + 高速难躲"的实现方式 —— 它的压迫感来自"跑不掉"，不是来自伤害。
##
## ⚠ 它必须是**绝对值**、而且**要大于玩家满速 5.0**（标尺：满速 5.0，饥饿 ×0.9 ⇒ 4.5，
##   低电 ×0.7 ⇒ 3.15）。配 ≤ 5.0 就追不上满速玩家 ⇒ "突袭"变成"在屁股后面吃灰"
##   （老版只有 chase_speed 3.4，正是用户这次说"没实现"的那半边）。
## ⚠ 它**只管逼近**（CHASE 段）：一旦进入招式三段，移速改由 move_scale 决定。
##   ④ 的 move_scale 因为 facing_locked 而没有位移出口 ⇒ 前摇是定身的（见基类 _process_attack），
##   所以"扑到脸上"这件事完全由这一段加速完成。
@export var approach_speed: float = 0.0

@export_group("三段时长")
@export var telegraph_time: float = 0.9
@export var strike_time: float = 0.2
@export var recover_time: float = 1.1
## 这一招自己的冷却（每招一个计时器，不是全局一个）
@export var cooldown: float = 5.0

@export_group("落点与区域")
## true ⇒ 判定圆心 = **施放瞬间玩家的位置**（吐沙 / 流沙这类"朝地面打"的招）；
## false ⇒ 判定圆心 = Boss 自己（撕咬这类"咬在嘴上"的招）。
##
## ⚠ 老版本没有这个字段，于是 sand_spit 的 `max_range` 18 和 `radius` 1.8 互相打架：
##   它只在玩家 5 m 外才被选中，却拿半径 1.8 去量"玩家↔Boss"的距离 ⇒ **永远打不中**。
##   远程招必须把落点钉在玩家身上，而不是量 Boss 到玩家的距离。
@export var aims_at_player: bool = false
## > 0 ⇒ 本招在地面生成一个**圆形区域**：圈内单位被**持续拉向圆心**，计时结束才结算。
## 0 ⇒ 普通招式。流沙陷落用 9.0。
@export var zone_radius: float = 0.0
## 区域内单位被拉向圆心的速度（m/s）。玩家满速 5.0（低电 3.15）
## ⇒ 取 2.6 时"逆着走能出来"，但站着不动会被拖进中心。
@export var zone_pull_speed: float = 2.6
## 地面圈的颜色（占位表现，正式美术接入后由特效取代）
@export var zone_color: Color = Color(0.62, 0.46, 0.20, 0.55)
## 前摇期间**是否已经露头**。
## true  ⇒ 标准三段：冒头（前摇）→ 出招（判定）→ 后摇 → 钻回地底。
## false ⇒ 本招**在地下动作**（潜行冲刺 / 布置流沙），判定段才破土而出
##         ⇒ 于是它的受击窗口只有「判定 + 后摇」，前摇期间玩家**打不到它**。
## 沙虫：③流沙陷落、④潜行突袭 用 false；①②用 true。
@export var surfaces_in_telegraph: bool = true

@export_group("弹道（「射出东西」的招）")
## > 0 ⇒ **弹道招**：判定段从嘴里射出一发沙弹，伤害由它**飞行中命中时**才结算。
## 0 ⇒ 普通招式（判定段就地按 radius 结算）。
##
## 沙虫 ②吐沙 用它。与 aims_at_player 的分工：
##   aims_at_player ⇒ 把落点钉在**地面**上（"朝地面打"），伤害仍在判定段就地结算；
##   弹道            ⇒ 真的飞出去、真的撞上才算命中 ⇒ **玩家可以在飞行段走位躲开**
##                     （躲的是弹道飞行的这零点几秒，不是前摇）。
@export var projectile_speed: float = 0.0
## 沙弹的命中半径：沙弹 ↔ 玩家本体的**平面**距离 ≤ 它就判命中。
## ⚠ 只看平面距离、不看高度差 —— 平射弹道的高度等于发射高度（见 spit_muzzle_height），
##   用三维距离会变成"从头顶飞过永远打不中"（无人机弹幕踩过的坑，见 drone_projectile.gd）。
@export var projectile_hit_radius: float = 0.9
## 沙弹的飞行距离上限（米）。0 ⇒ 直接沿用 max_range。
@export var projectile_max_distance: float = 0.0
## **一次出招连吐几发**（2026-09-26 用户要求"吐沙改为连吐 4 次子弹"）。
## 1 ⇒ 单发（老行为）；> 1 ⇒ 判定段内按 projectile_interval 的节拍连吐。
##
## ⚠ 连发是**逐发瞄准**的：每一发都瞄"那一发出膛的瞬间"玩家在哪 ⇒
##   站着不动 = 每一发都吃满（代价随发数线性增长）；持续换位才能甩掉后面的。
##   这正是"连吐"相对"吐一口大的"的手感差别，所以发数别配太多
##   （4 发 × 0.16 s = 0.64 s，玩家全力跑也就挪 3.2 m —— 刚好够甩掉一半）。
@export var projectile_count: int = 1
## 连发的节拍间隔（秒）。第 i 发（0 起）在判定段开始后 i × 本值 射出。
## ⚠ 判定段的真实长度由 strike_window() 兜底 = max(strike_time, 末发时刻 + 0.05)，
##   所以 strike_time 配小了不会"只吐两发就进后摇"。
@export var projectile_interval: float = 0.16

@export_group("表现")
## 前摇期间能不能移动（0 = 定身，1 = 全速追）。定身＝给玩家跑的机会。
## ⚠ 本值对**三段全程**生效（前摇/判定/后摇都按它算移速）：
##   ④潜行突袭靠它做"地下高速突进"（2.5 ⇒ 3.4 × 2.5 ≈ 8.5 m/s）。
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
	attack.arc_degrees = float(data.get("arc_degrees", attack.arc_degrees))
	attack.rect_length = float(data.get("rect_length", attack.rect_length))
	attack.rect_width = float(data.get("rect_width", attack.rect_width))
	attack.facing_locked = bool(data.get("facing_locked", attack.facing_locked))
	attack.damage = int(data.get("damage", attack.damage))
	attack.min_range = float(data.get("min_range", attack.min_range))
	attack.max_range = float(data.get("max_range", attack.max_range))
	attack.approach_speed = float(data.get("approach_speed", attack.approach_speed))
	attack.telegraph_time = float(data.get("telegraph_time", attack.telegraph_time))
	attack.strike_time = float(data.get("strike_time", attack.strike_time))
	attack.recover_time = float(data.get("recover_time", attack.recover_time))
	attack.cooldown = float(data.get("cooldown", attack.cooldown))
	attack.move_scale = float(data.get("move_scale", attack.move_scale))
	attack.telegraph_color = Color(data.get("telegraph_color", attack.telegraph_color))
	attack.aims_at_player = bool(data.get("aims_at_player", attack.aims_at_player))
	attack.zone_radius = float(data.get("zone_radius", attack.zone_radius))
	attack.zone_pull_speed = float(data.get("zone_pull_speed", attack.zone_pull_speed))
	attack.zone_color = Color(data.get("zone_color", attack.zone_color))
	attack.surfaces_in_telegraph = bool(
		data.get("surfaces_in_telegraph", attack.surfaces_in_telegraph))
	attack.projectile_speed = float(
		data.get("projectile_speed", attack.projectile_speed))
	attack.projectile_hit_radius = float(
		data.get("projectile_hit_radius", attack.projectile_hit_radius))
	attack.projectile_max_distance = float(
		data.get("projectile_max_distance", attack.projectile_max_distance))
	attack.projectile_count = int(
		data.get("projectile_count", attack.projectile_count))
	attack.projectile_interval = float(
		data.get("projectile_interval", attack.projectile_interval))
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

## 这一招的预警圈画多大 —— 有区域就用区域半径，否则用判定半径。
## ⚠ **长条矩形招（is_rect）不看这个值**：它的预警片是"长度 × 宽度"的一条走廊，
##   由 rect_length / rect_width 直接决定（见基类 _apply_marker_shape）。
func marker_radius() -> float:
	if zone_radius > 0.0:
		return zone_radius
	return radius


## 地面预警片的颜色。
##   · 区域招（③流沙）→ 用 zone_color（它本来就是为地面圈配的）；
##   · **面前扇形**（①撕咬）→ 用前摇警示色压到半透明 —— 与"前摇体色变红"**同源**：
##     玩家看到的红体和红扇形是同一个信号，不会互相打架。
##   （2026-09-26 用户反馈"撕咬释放时不够明显"：光变体色不够，得让玩家看见**哪块地危险**。）
func marker_color() -> Color:
	if zone_radius > 0.0:
		return zone_color
	return Color(telegraph_color.r, telegraph_color.g, telegraph_color.b, 0.5)


## 有没有"圆形流沙区域"（会把圈内单位持续拉向圆心）
func has_zone() -> bool:
	return zone_radius > 0.0


## 是不是"面前扇形"（0 或 360 度 = 全圆，不做角度限制）
func is_sector() -> bool:
	return arc_degrees > 0.0 and arc_degrees < 360.0


## 扇形的半张角（弧度）—— 判定用"面朝方向 · 指向玩家的方向 ≥ cos(半张角)"
func half_arc_radians() -> float:
	return deg_to_rad(clampf(arc_degrees, 0.0, 360.0) * 0.5)


## 是不是"长条矩形"判定（沿面朝方向前伸的一条走廊）。
## 生效后 radius / arc_degrees **都不再参与判定** —— 形状只有这一种，不许叠加。
func is_rect() -> bool:
	return rect_length > 0.0 and rect_width > 0.0


## 长条矩形的半宽。判定用"侧向偏移的绝对值 ≤ 它"。
func rect_half_width() -> float:
	return rect_width * 0.5


## 是不是"射出弹道"的招（判定段从嘴里射一发，命中由弹道自己负责）
func has_projectile() -> bool:
	return projectile_speed > 0.0


## 弹道能飞多远：没单独配 projectile_max_distance 就沿用 max_range
func projectile_range() -> float:
	if projectile_max_distance > 0.0:
		return projectile_max_distance
	return max_range


## 判定段要"结算"几次：
##   · 非弹道招恒为 1（就是"就地判一次"，撕咬 / 流沙）；
##   · 弹道招 = 连吐发数（吐沙 4）。
func shot_count() -> int:
	if not has_projectile():
		return 1
	return maxi(1, projectile_count)


## 第 index 发（0 起）在判定段开始后第几秒射出。
func shot_delay(index: int) -> float:
	return float(index) * maxf(projectile_interval, 0.0)


## 判定段**实际**要持续多久：
##   · 单发招 = strike_time（原语义不变）；
##   · 连发招 = max(strike_time, 末发时刻 + 0.05 的尾巴)
##     ⇒ 即使 strike_time 配小了，也不会"连发只吐了 2 发就进后摇"。
## 基类用它判"何时离开判定段"，strike_time 因此只是连发窗口的**下限**。
func strike_window() -> float:
	var shots: int = shot_count()
	if shots <= 1 or projectile_interval <= 0.0:
		return strike_time
	return maxf(strike_time, shot_delay(shots - 1) + 0.05)


## 判定圆心该怎么算。**真正的落点要在施放那一刻取一次然后记住** ——
## 区域招的圆心是钉死的，玩家跑出去就等于躲开了（这就是"可躲"的实现方式）。
## ⚠ 别每帧重算：那样圈会跟着玩家跑，变成必中。
func strike_origin_from(boss_position: Vector3, player_position: Vector3) -> Vector3:
	return player_position if aims_at_player else boss_position


## 调试面板用的一行描述
func describe() -> String:
	var label: String = display_name
	if label.is_empty():
		label = String(attack_id)
	var line: String = "%s 伤害%d 射程%.1f~%.1f 前摇%.2f 后摇%.2f CD%.1f" % [
		label, damage, min_range, max_range, telegraph_time, recover_time, cooldown,
	]
	if approach_speed > 0.0:
		line += " 逼近%.1fm/s" % approach_speed
	if is_sector():
		line += " 扇形%.0f°" % arc_degrees
	if is_rect():
		line += " 长条%.1fm×%.1f" % [rect_length, rect_width]
	if facing_locked:
		line += " [朝向锁定]"
	if has_projectile():
		line += " 弹道%.0fm/s(命中半径%.1f)" % [projectile_speed, projectile_hit_radius]
		if shot_count() > 1:
			line += " ×%d连发(间隔%.2fs)" % [shot_count(), projectile_interval]
	if has_zone():
		line += " 区域%.1fm(拉%.1f)" % [zone_radius, zone_pull_speed]
	if not surfaces_in_telegraph:
		line += " [地下筹备]"
	return line
