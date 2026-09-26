# script/ai/enemy/boss/sandworm/boss_sandworm_state.gd
# ============================================
# Boss 状态枚举与谓词（纯静态，无实例）
#
# 为什么要单独一份：
#   1. Boss 的状态要写进存档（world.bosses[].state），必须有一个
#      "稳定字符串 ↔ 枚举" 的映射；枚举数字**只能末尾追加**。
#   2. 三条 Boss 线（沙虫地表 / 机械沙虫 / 巨鸟）共用同一套状态语义。
#
# 形状借鉴 script/resources/component/resource_state_machine.gd 里的
# ResourceState（class_name + 独立文件 + 静态谓词），但语义完全独立：
# 资源是"生长 / 成熟 / 枯竭"，Boss 是"待机 / 登场 / 追击 / 出招 / 脱战 / 濒死"。
#
# 规格见 主线设计规格.md 1.2 / 2.2。
# ============================================

class_name BossSandwormState
extends RefCounted

# ============================================
# 状态枚举
#
# ⚠ 只能末尾追加：中间插入会让老存档的状态含义整体错位。
# ============================================
enum State {
	DORMANT,    ## 待机：在巢穴里/在树上，玩家没来。不可受伤
	EMERGING,   ## 登场演出：钻出沙面 / 降落。不可受伤
	CHASE,      ## 追击：玩家在仇恨圈内，**在地下**朝玩家移动。不可受伤
	TELEGRAPH,  ## 前摇：给玩家躲的窗口（可被打，玩家的输出机会之一）
	STRIKE,     ## 判定生效：真正扣血的那一段
	RECOVER,    ## 后摇：硬直，玩家的主要输出窗口
	RETREAT,    ## 脱战逃走：玩家跑远或死亡 → 回巢回满血。可重复、不推进世界
	FALLEN,     ## 濒死逃走：血量保底 1 点 + 永久无敌。一次性、推进世界
	GONE,       ## 已退场：实例不再参与逻辑，场地已改变
}

## 存档用的稳定标识。
## **不要**存枚举数字：数字会随枚举追加而改变含义。
const SAVE_IDS := [
	&"dormant", &"emerging", &"chase", &"telegraph", &"strike",
	&"recover", &"retreat", &"fallen", &"gone",
]

## 调试面板 / 日志用的短名（给开发者看的，不进存档）
const LABELS := [
	"待机", "登场", "追击", "前摇", "判定", "后摇", "脱战", "濒死", "退场",
]

# ============================================
# 查询
# ============================================

## 状态数量（＝枚举成员数，加成员时两处一起加）
static func count() -> int:
	return SAVE_IDS.size()

## 枚举值是否落在这个状态机的范围内
static func is_valid(state: int) -> bool:
	return state >= 0 and state < SAVE_IDS.size()

## 中文短名，用于调试面板与日志
static func label_of(state: int) -> String:
	if not is_valid(state):
		return "未知(%d)" % state
	var name: String = LABELS[state]
	return name

## 枚举 → 存档字符串
static func save_id(state: int) -> StringName:
	if not is_valid(state):
		return &""
	var id: StringName = SAVE_IDS[state]
	return id

## 存档字符串 → 枚举（认不出来时退回待机，绝不崩）
static func from_save_id(id: StringName) -> int:
	var index: int = SAVE_IDS.find(id)
	if index < 0:
		return State.DORMANT
	return index

# ============================================
# 谓词
# ============================================

## 该状态下 Boss 能不能被 take_damage 扣血。
##
## **追击（CHASE）不可受伤**：沙虫平时在地下潜行，只有露头出招的那几段才打开
## 受击碰撞体。待机/登场/脱战/濒死/退场同样不可受伤 —— 这些状态下它要么不在场上、
## 要么已经"输了这场架"，再掉血会让状态机自相矛盾。
##
## ⚠ 本函数只是**静态规则**（"这个状态理论上开不开"）。有一条例外它表达不了：
##   ③流沙陷落 / ④潜行突袭 的前摇也在地底下（本招 surfaces_in_telegraph = false），
##   状态同样是 TELEGRAPH 却打不到它。运行时真正生效的判据是
##   BossSandwormBase._is_surfaced()，它在本函数之上再叠这一层。
static func can_be_hurt(state: int) -> bool:
	match state:
		State.TELEGRAPH, State.STRIKE, State.RECOVER:
			return true
		_:
			return false

## 是不是"招式三段"之一。
## 决策点 = 走出这三段之后 —— 招式播到一半**绝不**换表换招。
static func is_attack_phase(state: int) -> bool:
	return state == State.TELEGRAPH or state == State.STRIKE or state == State.RECOVER

## 是不是"演出态"：Boss 这段时间由脚本牵着走，不自己决策、不自己移动。
static func is_performing(state: int) -> bool:
	return state == State.EMERGING or state == State.RETREAT or state == State.FALLEN

## 终态：实例已退场，不再参与任何逻辑（也绝不会再回到别的状态）
static func is_terminal(state: int) -> bool:
	return state == State.GONE
