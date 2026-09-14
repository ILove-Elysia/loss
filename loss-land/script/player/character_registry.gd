# script/player/character_registry.gd
# ============================================
# 可选角色注册表（class_name 静态，不用 autoload——与 ItemRegistry 同理由）
#
# 游戏开始时玩家在「选择角色」面板里挑一个，选择结果会写进存档 meta，
# 读档时从 meta 取回来，所以换存档 = 换角色，不需要重开游戏。
#
# 【设定来源】大纲.md v0.7 · 2.2 角色系统
#   · 正式角色 3 个：冒险家 adventurer / 魔女 witch / 机器人 robot
#   · **三个正式角色的基础数值完全相同**（生命 100 / 移速 ×1.0 / 攻击 ×1.0），
#     **差异全部来自"系统"，不来自"数值"**（大纲 2.2.3）。
#     所以下面三条的 speed_mult / base_health / attack_mult 全是 1.0 / 100 / 1.0，
#     真正的区别是 has_power（有无电量）与 craft_category（专属制作栏）。
#   · 测试角色 3 个（knight / guard / scout）**本期保留**（决策 ①），
#     正式版再删；它们是有数值差异的，专门用来验证换装 / 数值 / 存档流程。
#
# 加新角色（"后续会加"）只需要往 CHARACTERS 里追加一项：
#   1. id 用新的稳定字符串（存档记的是它，改了就找不回来）
#   2. sprite 换成新角色贴图；**必须与基础表同布局**
#      （448×392，8 列 × 7 行，单帧 56×56，动画顺序 attack/die/hurt/idle/walk）
#      换色变体（char_red / char_green）就是按这个布局生成的，
#      所以切换角色只需换贴图，SpriteFrames 里的帧区一个都不用动。
#   3. 面板是遍历 CHARACTERS 动态生成的，不用改 UI 代码。
# ============================================

class_name CharacterRegistry
extends RefCounted

## 默认角色（没选过 / 直接运行 map.tscn 调试 / 存档里角色 id 失效时用）。
## 大纲 2.2.1：正式角色接入后，DEFAULT_ID 换成 adventurer。
const DEFAULT_ID: String = "adventurer"

## 决策 ⑧：**开发 / Demo 期三个角色全部开放**任选开局（降低测试门槛）。
## 正式发布前改成 false，就会收紧为决策 ⑥ 的"冒险家开局 + 另两位游戏内解锁"，
## 只改这一个常量即可，不需要重构。
const ALL_UNLOCKED: bool = true

# --------------------------------------------
# 大纲 2.2.2 通用初始属性（三个正式角色在这几项上完全一致）
# 这些只是**展示用基准**——真正生效的是 physics.gd / vitals.gd 的 @export。
# --------------------------------------------
## 基准生命值
const BASE_HEALTH: int = 100
## 基准攻击力（徒手 10）
const BASE_ATTACK: int = 10
## 基准移动速度（5.0 米/秒）
const BASE_SPEED: float = 5.0
## 基准电量上限（100，仅对 has_power 的角色生效）
const BASE_POWER: float = 100.0
## 基准体温（30）
const BASE_TEMP: float = 30.0

## 专属制作栏分类（大纲 2.2.5 目标态：Category 末尾追加 SURVIVAL/ALCHEMY/MACHINE）。
## 现在只是**数据字段**，合成 UI 还没按角色过滤（那一项是 ○ 待实装）。
const CRAFT_SURVIVAL: StringName = &"SURVIVAL"
const CRAFT_ALCHEMY: StringName = &"ALCHEMY"
const CRAFT_MACHINE: StringName = &"MACHINE"

## 专属制作栏的显示名（面板用）
const CRAFT_CATEGORY_LABELS: Dictionary = {
	&"SURVIVAL": "求生制作",
	&"ALCHEMY": "炼药 / 魔法",
	&"MACHINE": "机械制作",
}

## 面板里角色头像用的帧：idle 动画第 1 帧。
## 精灵表行位置（单帧 56×56，**不是按动画名字母序排的**，取帧前先核对）：
##   idle   → y = 0      （首帧 0,0）
##   attack → y = 56
##   walk   → y = 114
##   hurt   → y = 280
##   die    → y = 336
const PORTRAIT_REGION: Rect2 = Rect2(0, 0, 56, 56)

## 全部可选角色。字段说明：
##   id                存档里的稳定标识
##   name              显示名
##   desc              一句话定位
##   trait             特性短标签（面板上的一行小字）
##   sprite            精灵表路径（与基础表同布局）
##   speed_mult        移速倍率（乘在 physics.gd 的 speed 上）
##   base_health       最大生命值
##   attack_mult       攻击力倍率（乘在 physics.gd 的 attack_damage 上）
##   has_power         **是否有电量系统**（大纲 2.2.3：仅机器人为 true）。
##                     决定 HUD 电量行是"亮起"还是"占位"、过冷过热是否额外漏电。
##                     ⚠ 它**不决定**回血 / 掉血 / 减速 —— 那三条归 power_embedded。
##                     冒险家 / 魔女为 false，
##                     但可拾取「动力核心」解锁（大纲 3.1.3）→ 运行时可变，见 vitals.set_has_power()。
##   power_embedded    **电量是否内置**（机器人机械身体自带，仅 robot 为 true）。
##                     这是"电量能否影响人物本体"的总闸门：
##                       内置（机器人）：电量是它的生命线 → 不可关闭、
##                                       归零**掉血**、低电**减速**、>80 且吃饱**缓慢回血**
##                       外置（装上动力核心的角色）：电量是身外设备（类似外挂电池），
##                                       对人物本体**零影响**：不掉血、不减速、**也不回血**
##                     两者唯一共有的是过冷 / 过热**额外漏电**。
##                     详见 vitals.gd 的 _update_power_effects / get_speed_multiplier。
##   craft_category    专属制作栏分类（空 = 无专属栏）。见 CRAFT_* 常量。
##   default_unlocked  正式版下是否默认可选（决策 ⑥：仅冒险家）。
##                     ALL_UNLOCKED = true 时本字段不生效。
const CHARACTERS: Array = [
	# ---------------- 正式角色（数值完全一致，差异在系统） ----------------
	{
		"id": "adventurer",
		"name": "冒险家",
		"desc": "靠双手与头脑在荒岛立足的生存者。没有电量负担，是规则的基准角色。",
		"trait": "基准 · 无电量",
		"sprite": "res://art/player/char_blue.png",
		"speed_mult": 1.0,
		"base_health": 100,
		"attack_mult": 1.0,
		"has_power": false,
		"power_embedded": false,
		"craft_category": &"SURVIVAL",
		"default_unlocked": true,
	},
	{
		"id": "witch",
		"name": "魔女",
		"desc": "用草药与符文改写规则的法术使用者。制药与魔法的深度仍待定（决策 ⑤）。",
		"trait": "制药魔法 · 无电量",
		"sprite": "res://art/player/char_green.png",
		"speed_mult": 1.0,
		"base_health": 100,
		"attack_mult": 1.0,
		"has_power": false,
		"power_embedded": false,
		"craft_category": &"ALCHEMY",
		"default_unlocked": false,
	},
	{
		"id": "robot",
		"name": "机器人",
		"desc": "以电力驱动的机械生命。多一条电量补给线，也多背一份过冷过热的漏电惩罚。",
		"trait": "电量系统 · 双份惩罚",
		"sprite": "res://art/player/char_red.png",
		"speed_mult": 1.0,
		"base_health": 100,
		"attack_mult": 1.0,
		"has_power": true,
		"power_embedded": true,
		"craft_category": &"MACHINE",
		"default_unlocked": false,
	},
	# ---------------- 测试角色（决策 ①：本期保留，正式版再删） ----------------
	{
		"id": "knight",
		"name": "青铠骑士（测试）",
		"desc": "测试角色：验证换装 / 数值 / 存档流程用，正式版会删除。",
		"trait": "测试 · 均衡",
		"sprite": "res://art/player/char_blue.png",
		"speed_mult": 1.0,
		"base_health": 100,
		"attack_mult": 1.0,
		"has_power": false,
		"craft_category": &"",
		"default_unlocked": true,
	},
	{
		"id": "guard",
		"name": "赤铁守卫（测试）",
		"desc": "测试角色：高血高攻但走得慢，用来验证数值差异是否生效。",
		"trait": "测试 · 高血高攻慢",
		"sprite": "res://art/player/char_red.png",
		"speed_mult": 0.9,
		"base_health": 130,
		"attack_mult": 1.3,
		"has_power": false,
		"craft_category": &"",
		"default_unlocked": true,
	},
	{
		"id": "scout",
		"name": "翠影斥候（测试）",
		"desc": "测试角色：高速低血，用来验证数值差异是否生效。",
		"trait": "测试 · 高速低血",
		"sprite": "res://art/player/char_green.png",
		"speed_mult": 1.25,
		"base_health": 80,
		"attack_mult": 0.85,
		"has_power": false,
		"craft_category": &"",
		"default_unlocked": true,
	},
]

## 本局正在游玩的角色 id（进游戏时由 physics.gd / vitals.gd 依据它应用外观与属性）。
## 存档时 SaveManager 会把它写进 meta；读档时由 meta 回填。
static var active_id: String = ""


# ============================================
# 查询
# ============================================

## 全部 id（按面板显示顺序）
static func all_ids() -> Array:
	var out: Array = []
	for c in CHARACTERS:
		out.append(String(c.get("id", "")))
	return out


## 取某个角色的定义；id 不存在返回空字典（调用方自行决定回退策略）
static func get_character(id: String) -> Dictionary:
	for c in CHARACTERS:
		if String(c.get("id", "")) == id:
			return c
	return {}


## 把任意 id 规整成有效 id：空 / 已失效（老存档里的角色被删掉了）都落到默认角色
static func resolve_id(id: String) -> String:
	if get_character(id).is_empty():
		return DEFAULT_ID
	return id


## 取某个角色的贴图；路径配错或还没被引擎导入（新加的美术文件）时返回 null，
## 调用方保持原贴图即可，不要让它崩。
static func get_sprite(id: String) -> Texture2D:
	var c := get_character(resolve_id(id))
	var path := String(c.get("sprite", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is Texture2D:
		return res as Texture2D
	return null


## 该角色是否带电量系统（大纲 2.2.3：仅机器人为 true）。
## 冒险家 / 魔女默认 false —— 拾取「动力核心」后才变 true（大纲 3.1.3）。
## ⚠ 这是**开局默认值**。装上 / 拆下动力核心后真实状态在 `vitals.has_power`，
##   运行时查询请优先读 vitals 的字段，不要拿这个函数当实时状态。
static func has_power(id: String) -> bool:
	return bool(get_character(resolve_id(id)).get("has_power", false))


## 该角色的电量是否**内置**（仅机器人为 true：机械身体自带，不需要道具）。
## 决定电量归零 / 低电时是否惩罚**人物本体**：
##   内置 → 归零掉血、低电减速（电量就是它的命）
##   外置 → 归零只让电量相关效果下线，不扣血、不减速
## 见 vitals.gd 的 _update_power_effects() 与 get_speed_multiplier()。
static func has_embedded_power(id: String) -> bool:
	return bool(get_character(resolve_id(id)).get("power_embedded", false))


## 专属制作栏分类（空 StringName = 无专属栏）
static func get_craft_category(id: String) -> StringName:
	return StringName(get_character(resolve_id(id)).get("craft_category", &""))


## 专属制作栏的显示名；无专属栏返回空串
static func get_craft_category_label(id: String) -> String:
	var cat: StringName = get_craft_category(id)
	if cat == &"":
		return ""
	return String(CRAFT_CATEGORY_LABELS.get(cat, ""))


## 专属栏 → 拥有它的角色 id（反查表）。合成系统用它判断"这条专属配方归谁"。
## 与 CHARACTERS 里的 craft_category 必须成对维护：加角色时两边一起改。
const CRAFT_CATEGORY_OWNER: Dictionary = {
	&"SURVIVAL": "adventurer",
	&"ALCHEMY": "witch",
	&"MACHINE": "robot",
}


## 某个专属栏归哪个角色所有；不是专属栏（空/未知）返回空串
static func craft_category_owner(cat: StringName) -> String:
	return String(CRAFT_CATEGORY_OWNER.get(cat, ""))


## 该角色是否拥有这个专属制作栏。
## 注意：只回答**专属栏**；通用栏不归任何角色所有，这里一律 false。
static func has_craft_category(id: String, cat: StringName) -> bool:
	if cat == &"":
		return false
	return get_craft_category(id) == cat


## 是否在「选择角色」面板里可选。
## ALL_UNLOCKED = true（开发 / Demo 期，决策 ⑧）时一律可选；
## 否则只有 default_unlocked 的角色可选（正式版：仅冒险家）。
static func is_selectable(id: String) -> bool:
	if ALL_UNLOCKED:
		return true
	return bool(get_character(resolve_id(id)).get("default_unlocked", false))


## 面板展示用的**绝对值**（把倍率换算成大纲口径的数字）。
## 换算基准是上面的 BASE_* 常量；与 physics 实际生效的值一致。
static func get_display_stats(id: String) -> Dictionary:
	var c := get_character(resolve_id(id))
	return {
		"health": int(c.get("base_health", BASE_HEALTH)),
		"attack": int(round(float(BASE_ATTACK) * float(c.get("attack_mult", 1.0)))),
		"speed": float(BASE_SPEED) * float(c.get("speed_mult", 1.0)),
		"power": int(round(float(BASE_POWER))) if has_power(id) else 0,
	}


# ============================================
# 当前角色
# ============================================

## 设置本局角色（非法 id 自动落到默认角色），返回最终生效的 id
static func set_active(id: String) -> String:
	active_id = resolve_id(id)
	return active_id


## 当前角色 id（从未设置过时返回默认角色，不修改 active_id）
static func get_active_id() -> String:
	return resolve_id(active_id)


## 当前角色定义
static func get_active() -> Dictionary:
	return get_character(get_active_id())
