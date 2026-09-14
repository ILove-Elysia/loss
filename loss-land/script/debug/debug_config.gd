# script/debug/debug_config.gd
# ============================================
# 调试信息总开关（纯静态，不依赖 autoload / 场景节点）
#
# 为什么是「静态类」而不是 autoload：
#   与 UIManager 同样的理由——autoload 在 `godot --script` 模式（headless 冒烟
#   测试）下不会被加载，全局名在编译期不可见，引用它的脚本全部编译失败。
#   class_name + static 变量在脚本被加载时就存在，任何脚本都能直接调用，
#   也不需要挂到场景树里。
#
# 使用方式（替代裸 print）：
#   DebugConfig.log_msg(DebugConfig.CAT_RESOURCE, "[采集] 采集最近资源：%s", [id])
#   DebugConfig.warn_msg(DebugConfig.CAT_ITEM, "物品不存在: %s", [item_id])
#
# 两个语义约定：
#   1. 默认全关。正式游玩控制台应当干净，需要排查时再去「设置 → 调试选项」开。
#   2. push_error 不归这里管。它代表真正的程序错误（未注册面板、空引用），
#      静默掉只会掩盖 bug；只有"预期内的分支/提示"才降级为可开关的日志。
#
# 开关会持久化到 user://debug_config.cfg，下次启动保持上次的选择。
# ============================================

class_name DebugConfig
extends RefCounted

# ---------------- 分类常量 ----------------
# 新增分类时：① 加常量 ② 加进 ALL_CATEGORIES ③ 加进 CATEGORY_LABELS
# 顺序即界面上的显示顺序。

## 资源生成 / 采集 / 再生
const CAT_RESOURCE := "resource"
## 敌人 AI、受击、攻击命中判定
const CAT_ENEMY := "enemy"
## 玩家移动、受伤、死亡
const CAT_PLAYER := "player"
## 物品掉落、拾取、使用效果
const CAT_ITEM := "item"
## 装备穿戴 / 卸下
const CAT_EQUIP := "equip"
## 合成配方与制作
const CAT_CRAFTING := "crafting"
## 界面：HUD 状态、小地图、面板管理
const CAT_UI := "ui"
## 玩家脚下地形 / 所属群系（由 TerrainProbe 实时采样）
const CAT_TERRAIN := "terrain"
## 昼夜循环：阶段切换、跨天、时间流速
const CAT_TIME := "time"
## 建造：进入/取消放置模式、落点合法性、放置与拆除
const CAT_BUILD := "build"
## 视野流式加载：屏幕内的东西才装配，离开视野挂起（资源 / 敌人 / 掉落物）
const CAT_STREAM := "stream"

# 用无参数化的 Array：const + 参数化数组在部分 4.x 版本上解析不稳定，
# 而这里只需要"能遍历 + 当字典键"，运行时元素本就是 String。
const ALL_CATEGORIES: Array = [
	CAT_RESOURCE,
	CAT_ENEMY,
	CAT_PLAYER,
	CAT_ITEM,
	CAT_EQUIP,
	CAT_CRAFTING,
	CAT_UI,
	CAT_TERRAIN,
	CAT_TIME,
	CAT_BUILD,
	CAT_STREAM,
]

## 分类 -> 界面上显示的中文名
const CATEGORY_LABELS: Dictionary = {
	CAT_RESOURCE: "资源 / 采集",
	CAT_ENEMY: "敌人 AI / 战斗",
	CAT_PLAYER: "玩家（移动 / 受伤 / 死亡）",
	CAT_ITEM: "物品（掉落 / 拾取 / 使用）",
	CAT_EQUIP: "装备（穿戴 / 卸下）",
	CAT_CRAFTING: "合成",
	CAT_UI: "界面",
	CAT_TERRAIN: "地形（脚下地形 / 所属群系）",
	CAT_TIME: "昼夜（阶段 / 跨天 / 时间）",
	CAT_BUILD: "建造（放置模式 / 落点校验）",
	CAT_STREAM: "视野流式加载（装配 / 挂起）",
}

const SAVE_PATH := "user://debug_config.cfg"
const SECTION := "debug"

# ---------------- 内部状态 ----------------

static var _flags: Dictionary = {}
static var _loaded: bool = false


## 首次访问时把分类表填好并读盘。
## 静态变量没有 _ready 可用，所以用一次性守卫延迟初始化。
static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	for c in ALL_CATEGORIES:
		_flags[c] = false
	_load()


static func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for c in ALL_CATEGORIES:
		if cfg.has_section_key(SECTION, c):
			_flags[c] = bool(cfg.get_value(SECTION, c))


static func _save() -> void:
	var cfg := ConfigFile.new()
	for c in ALL_CATEGORIES:
		cfg.set_value(SECTION, c, _flags.get(c, false))
	# 存盘失败（少见，如目录不可写）不该影响游戏，静默忽略
	cfg.save(SAVE_PATH)


# ---------------- 对外接口 ----------------

## 该分类的调试输出是否开启
static func is_enabled(category: String) -> bool:
	_ensure()
	return bool(_flags.get(category, false))


static func set_enabled(category: String, enabled: bool) -> void:
	_ensure()
	_flags[category] = enabled
	_save()


static func set_all(enabled: bool) -> void:
	_ensure()
	for c in ALL_CATEGORIES:
		_flags[c] = enabled
	_save()


static func any_enabled() -> bool:
	_ensure()
	for c in ALL_CATEGORIES:
		if _flags.get(c, false):
			return true
	return false


## 分类调试日志（走 print）。关闭时直接返回，连字符串格式化都省掉。
static func log_msg(category: String, text: String, args: Array = []) -> void:
	if not is_enabled(category):
		return
	print(text % args if not args.is_empty() else text)


## 分类调试警告（走 push_warning）。
## 用于"预期内的失败分支"——比如背包满了卸不下装备：正式游玩无需打扰玩家，
## 排查时又希望能看到。真正的程序错误请用 push_error，不要走这里。
static func warn_msg(category: String, text: String, args: Array = []) -> void:
	if not is_enabled(category):
		return
	push_warning(text % args if not args.is_empty() else text)
