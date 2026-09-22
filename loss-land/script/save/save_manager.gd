# script/save/save_manager.gd
# ============================================
# 存档总入口（class_name 静态，不用 autoload——与 BuildingSystem 同理由）
#
# 存什么（对应大纲存档需求）：
#   meta      存档名 / 天数 / 保存时间（主菜单列表只用 meta）
#   player    玩家位置（Physics）、生命、电量、温度值与体温、饱食度、背包、装备四槽
#   world     昼夜时间（day/hour）+ 全部资源实体（位置/状态/再生倒计时，
#             复用 ResourceManager.save_game / ResourceSaveData）
#             + 敌人（位置/血量）+ 地面掉落物 + 相机角度与缩放
#   buildings 已放置建筑（id/位置），储物箱内容随建筑存（Inventory.save）
#
# 敌人采用"按节点路径匹配"而不是重建：
#   当前版本没有刷怪逻辑，敌人是场景里预置的固定几只（Slime / Drone）。
#   存档里记录了谁还活着 → 读档时给它落位回血；
#   存档里没有的 → 说明存档时它已被击杀 → 直接删掉对应节点。
#
# 文件布局：user://saves/slot_<id>.json，一个存档一个文件，槽位不限量。
#
# 跨场景状态用 static var 携带（与 BuildingSystem._placed 同一套路）：
#   active_slot_id / active_slot_name  当前游玩的存档（新建或读档后设置）
#   pending_load_slot                  主菜单点了"载入"，进游戏场景后应用
#
# 读档时序（关键）：
#   主菜单 request_load() 只登记 pending → 切到 map.tscn；
#   map 场景里 ResourceManager._ready 正常要随机生成初始资源，
#   发现有 pending 就跳过随机生成，改用 call_deferred 等整棵场景树
#   （player/equipment/day_night 全部 _ready 完）后再重建存档世界。
#
# 新开局档（meta-only）：新建游戏立刻写一个只有 meta 的文件，
#   让它出现在主菜单列表里；读它时不带 pending，走正常开局生成。
# ============================================

class_name SaveManager
extends RefCounted

## 存档目录与版本
##   v1 = 只有种子（地形靠"种子 + 生成算法"重算）
##   v2 = 增加 map 段：存下地皮瓦片本身（见 _collect_map 的说明）
const SAVE_DIR := "user://saves"
const SAVE_VERSION := 2

## 当前游玩的存档槽（<0 = 没有激活存档，手动保存会被拒绝）
static var active_slot_id: int = -1
static var active_slot_name: String = ""

## 待应用的读档槽（<0 = 无；由主菜单设置、ResourceManager 消费）
static var pending_load_slot: int = -1

## 下一局地图要用的种子（0 = 进游戏时现摇一个）
##
## 为什么必须跟存档一起保存：地图是每次 _ready 现算的（rng.randomize()）。
## 读档时若地形重新随机，存档里的资源与建筑坐标就会落到海里或半空。
## 新建存档时摇一个种子写进 meta，读档时取出来交给地图生成器复现同一张图。
##
## 【v2 起种子的身份变了】地形改为直接从存档里的地皮快照还原（见 pending_map_tiles），
## 种子降级为"这张岛怎么来的"元数据：复现、调试、将来重生成未探索区域都要它，
## 但**正确性不再依赖它** —— 生成算法改过也不影响老存档。
static var pending_map_seed: int = 0

## 待应用的地形快照（空 = 没有，退回用种子重算）
##
## 地图生成器的 _ready 会用这份字节覆盖刚生成的地形，随后立刻清空。
## 存档里存的是压缩后的地皮（1600×1600 压缩后约 10KB 量级），
## 这样"生成算法改一行、所有老存档的岛都变形"这个隐患从根上没有了。
static var pending_map_tiles: PackedByteArray = PackedByteArray()

## 待应用地形快照的尺寸（宽, 高）；用于校验快照与当前地图尺寸是否一致
static var pending_map_size: Vector2i = Vector2i.ZERO

## 待应用地形快照的 SHA-256（16 进制）。保留它只为一条诊断：
## 读档时顺便算一次"当前生成算法"的地形哈希，两者不同就说明生成器变过了 ——
## 让"算法与老存档不一致"这件事在日志里现形，而不是被快照悄悄盖过去。
static var pending_map_hash: String = ""


## 清掉待应用的地形快照（生成器用完后、新建存档时都要调）
static func clear_pending_map_tiles() -> void:
	pending_map_tiles = PackedByteArray()
	pending_map_size = Vector2i.ZERO
	pending_map_hash = ""


## 字节的 SHA-256（16 进制串）。用于地形快照的自检与"算法是否变过"的诊断
static func sha256_hex(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


# ============================================
# 槽位列表（主菜单用）
# ============================================

## 扫描存档目录，按保存时间升序返回：
## [{ slot_id, name, day, saved_at, has_world }]
static func list_slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.begins_with("slot_") or not f.ends_with(".json"):
			continue
		var id := int(f.trim_prefix("slot_").trim_suffix(".json"))
		var data := _read_slot(id)
		if data.is_empty():
			continue
		var meta: Dictionary = data.get("meta", {})
		out.append({
			"slot_id": id,
			"name": String(meta.get("name", "存档 %d" % id)),
			"day": int(meta.get("day", 1)),
			"saved_at": String(meta.get("saved_at", "")),
			"has_world": data.has("player"),
			"character_id": String(meta.get("character_id", "")),
		})
	# 旧存档排前面，"继续游戏"取末尾即最新。
	# 时间戳只到分钟，同一分钟内建的两个档字符串相同 → 再用 slot_id 兜底，
	# 否则排序结果不稳定，"继续游戏"会进错档。
	out.sort_custom(func(a, b):
		var ta := String(a.get("saved_at", ""))
		var tb := String(b.get("saved_at", ""))
		if ta != tb:
			return ta < tb
		return int(a.get("slot_id", 0)) < int(b.get("slot_id", 0)))
	return out


## 删除存档文件；若删的是当前激活槽则一并清掉激活状态
static func delete_slot(slot_id: int) -> bool:
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return false
	var ok := dir.remove("slot_%d.json" % slot_id)
	if ok != OK:
		return false
	if active_slot_id == slot_id:
		active_slot_id = -1
		active_slot_name = ""
	return true


# ============================================
# 开新档 / 读档登记
# ============================================

## 新建一个槽位：分配 id、写 meta-only 文件（出现在列表里）并设为激活。
## 世界数据要等游戏内第一次保存才落盘。
##
## character_id：新建游戏时由主菜单「选择角色」面板传入；留空则沿用本局已经
## 选过的角色（游戏内中途建槽的情况），都没有就落 CharacterRegistry 的默认角色。
static func create_slot(slot_name: String, roll_new_seed: bool = true,
		character_id: String = "") -> int:
	var id := _next_slot_id()
	active_slot_id = id
	active_slot_name = slot_name
	# 角色：写进 meta 并设为本局激活角色（physics.gd 进场景后按它换外观与属性）
	var char_id: String = CharacterRegistry.set_active(character_id)
	# 清掉可能残留的读档登记：新建游戏绝不该走"应用存档"那条路。
	# （正常情况下 pending 会在 apply_pending_load 开头被消费掉，
	#   但若上一次读档因异常没走到那里，残留的 pending 会在下一次进
	#   游戏时把新开局劫持成载入旧档。）
	pending_load_slot = -1
	# roll_new_seed：
	#   true  = 新开局，必须重摇。不能沿用上一局回写进来的种子，否则
	#           "返回主菜单 → 新建存档"会得到一张和上一局一模一样的地形。
	#   false = 游戏内中途建槽（没经过主菜单直接开玩后的第一次保存），
	#           地图已经生成好了，只能沿用当前这局的种子，
	#           否则存档记的种子和实际地形对不上，读档就会错位。
	if roll_new_seed or pending_map_seed == 0:
		pending_map_seed = _roll_seed()
	# 新档不谈继承上一局的地形快照：不清的话，"读旧档 → 回主菜单 → 新建游戏"
	# 会把上一档的岛带进新档。地形快照只在读档路径上由 request_load 填入。
	clear_pending_map_tiles()
	_write_slot(id, {
		"version": SAVE_VERSION,
		"meta": {
			"slot_id": id,
			"name": slot_name,
			"day": 1,
			"saved_at": _now_string(),
			"map_seed": pending_map_seed,
			"character_id": char_id,
		},
	})
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[存档] 新建存档槽 %d：%s（角色 %s）",
		[id, slot_name, char_id])
	return id


## 主菜单点了"载入"。返回 true = 该档有世界数据，进场景后要应用读档；
## false = meta-only 新档（或读文件失败），走正常开局生成。
static func request_load(slot_id: int) -> bool:
	pending_load_slot = -1
	var data := _read_slot(slot_id)
	if data.is_empty():
		DebugConfig.warn_msg(DebugConfig.CAT_UI, "[存档] 读档失败：找不到存档 %d", [slot_id])
		return false
	active_slot_id = slot_id
	active_slot_name = String(data.get("meta", {}).get("name", "存档"))
	# 取回这张存档的地图种子：为 0（老存档没有这项）就保持随机
	pending_map_seed = int(data.get("meta", {}).get("map_seed", 0))
	# 取回这张存档的角色：老存档没有这一项 → 落到默认角色，不会读档失败
	CharacterRegistry.set_active(String(data.get("meta", {}).get("character_id", "")))
	# 取回这张存档的地形快照（老存档没有 map 段 → 只能按种子重算地形）
	_load_map_snapshot(data)
	if not data.has("player") or not data.has("world"):
		return false
	pending_load_slot = slot_id
	return true


static func has_pending_load() -> bool:
	return pending_load_slot >= 0


# ============================================
# 保存（游戏内）
# ============================================

## 把当前游戏状态写进激活槽。暂停菜单手动保存 / 返回主菜单与退出的自动保存共用。
static func save_active_slot() -> bool:
	# 没有激活槽（例如直接跑 map.tscn 调试、不走主菜单）就现建一个。
	# 传 roll_new_seed=false：地图此时已经生成好了，必须沿用当前这局的种子，
	# 重摇一个新种子会让存档记录的地形和实际看到的地形对不上。
	if active_slot_id < 0:
		create_slot("存档 %d" % _next_slot_id(), false)
	if active_slot_id < 0:
		DebugConfig.warn_msg(DebugConfig.CAT_UI, "[存档] 保存失败：没有激活的存档槽", [])
		return false
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return false

	var data := {
		"version": SAVE_VERSION,
		"meta": _make_meta(tree),
		"map": _collect_map(tree),
		"player": _collect_player(tree),
		"world": _collect_world(tree),
		"buildings": _collect_buildings(tree),
	}
	var ok := _write_slot(active_slot_id, data)
	if ok:
		DebugConfig.log_msg(DebugConfig.CAT_UI, "[存档] 已保存到槽 %d（%s，第 %d 天）",
			[active_slot_id, active_slot_name, int(data.meta.get("day", 1))])
	return ok


# ============================================
# 读档应用（游戏场景内，由 ResourceManager 延迟触发）
# ============================================

## 应用 pending 读档。参数是 ResourceManager 节点（资源重建必须经它）。
## 必须在整棵场景树 _ready 完成后调用（ResourceManager 用 call_deferred 保证）。
static func apply_pending_load(resource_manager: Node) -> bool:
	var id := pending_load_slot
	pending_load_slot = -1
	if id < 0 or resource_manager == null:
		return false
	var data := _read_slot(id)
	if data.is_empty() or not data.has("player"):
		DebugConfig.warn_msg(DebugConfig.CAT_UI, "[存档] 应用读档失败：存档 %d 无世界数据", [id])
		return false

	var tree := resource_manager.get_tree()
	_apply_world(tree, data.get("world", {}), resource_manager)
	_apply_player(tree, data.get("player", {}))
	_apply_buildings(tree, data.get("buildings", []))
	DebugConfig.log_msg(DebugConfig.CAT_UI, "[存档] 已从槽 %d 恢复游戏", [id])
	return true


# ============================================
# 私有 - 收集存档数据
# ============================================

## meta：存档名 / 天数 / 保存时间（列表展示与"继续游戏"排序用）
static func _make_meta(tree: SceneTree) -> Dictionary:
	var day := 1
	var day_night := tree.get_first_node_in_group("day_night")
	if day_night != null:
		day = int(day_night.get("day"))
	return {
		"slot_id": active_slot_id,
		"name": active_slot_name,
		"day": day,
		"saved_at": _now_string(),
		"map_seed": pending_map_seed,
		"character_id": CharacterRegistry.get_active_id(),
	}


## 玩家：位置（Physics 的世界坐标）/ 生命 / 电量 / 温度值·体温 / 背包 / 装备四槽
static func _collect_player(tree: SceneTree) -> Dictionary:
	var player: Node = tree.get_first_node_in_group("player")
	if player == null:
		return {}
	var out := {}

	# 位置：玩家根节点只是容器停在原点，真正坐标在 Physics 子节点
	var phys: Node = player.get_node_or_null("Physics")
	if phys is Node3D:
		var p: Vector3 = (phys as Node3D).global_position
		out["position"] = {"x": p.x, "y": p.y, "z": p.z}
	if phys != null:
		out["health"] = int(phys.get("current_health"))

	# 电量 / 温度值 / 体温 / 饱食度（Vitals）
	var vitals: Node = player.get_node_or_null("Vitals")
	if vitals != null:
		out["power"] = float(vitals.get("current_power"))
		# 温度与温度值是两个属性：前者是身体温度，后者是环境热负荷（决定前者怎么变）
		out["temperature_value"] = float(vitals.get("current_temperature_value"))
		out["temperature"] = float(vitals.get("current_temperature"))
		out["hunger"] = float(vitals.get("current_hunger"))
		# 注意：这里**不再存 has_power**。
		# "有没有电"现在是运行时算出来的（内置电量 or 装着核心），
		# 核心状态跟着装备槽一起进档，读档后自然还原，不需要单独一个开关字段。

	# 背包（Inventory 自带 save/load_data）
	var inv: Node = player.get_node_or_null("Inventory")
	if inv != null and inv.has_method("save"):
		out["inventory"] = inv.call("save")

	# 装备四槽：存**物品实例**（核心的电量 / 温度值都在实例上）。
	# 只存 item_id 的话，读档会给核心造一个全新的满电实例，
	# "核心是独立单位"就白做了。老存档这一格是字符串，读档时兼容（见 _apply_player）。
	var equip: Node = player.get_node_or_null("Equipment")
	if equip != null:
		out["equipment"] = {
			"weapon": _collect_equip_slot(equip, int(ItemData.EquipSlot.WEAPON)),
			"armor": _collect_equip_slot(equip, int(ItemData.EquipSlot.ARMOR)),
			"tool": _collect_equip_slot(equip, int(ItemData.EquipSlot.TOOL)),
			"core": _collect_equip_slot(equip, int(ItemData.EquipSlot.CORE)),
		}
	return out


## 单个装备槽 → 存档数据。
## 空槽返回空字符串（与老格式一致，肉眼读档也更清爽），满槽返回实例字典。
static func _collect_equip_slot(equip: Node, slot: int) -> Variant:
	if not equip.has_method("get_instance"):
		# 老版本没有 get_instance：退回只存 item_id
		return str(equip.call("get_item_id", slot))
	var inst = equip.call("get_instance", slot)
	if inst == null or inst.get("data") == null:
		return ""
	return inst.call("to_dict")


## 世界：昼夜时间 + 全部资源实体（ ResourceManager.save_game 的结构）
static func _collect_world(tree: SceneTree) -> Dictionary:
	var out := {}
	var day_night: Node = tree.get_first_node_in_group("day_night")
	if day_night != null:
		out["day"] = int(day_night.get("day"))
		out["hour"] = float(day_night.get("hour"))

	var rm: Node = tree.get_first_node_in_group("resource_manager")
	if rm != null and rm.has_method("save_game"):
		out["resources"] = rm.call("save_game")

	# 敌人与掉落物属于"世界内容"，和资源一样必须进存档：
	# 不存的话读档后打死的怪会复活、地上的战利品会凭空消失。
	out["enemies"] = _collect_enemies(tree)
	out["drops"] = _collect_drops(tree)
	out["camera"] = _collect_camera(tree)
	return out


## 地图：地形快照（地皮瓦片）+ 尺寸 + 校验哈希
##
## 【为什么存地皮而不只存种子】
## 地图 = "种子 + 生成算法"算出来的。只要算法动过（改一处参数、调一次随机调用
## 顺序、加一行 randf），同一颗种子就会长出另一座岛；而存档里的资源与建筑坐标
## 是不会跟着变的 —— 结果是建筑进水、资源悬空，而且**不报任何错**。
## 直接存下地皮本身，读档就不必再问生成器要答案：算法想怎么改，老存档都还在。
##
## 体积：1600×1600 = 256 万格，本就是 1 字节/格；DEFLATE 压缩后约 10KB 量级，
## Base64 写进 JSON 约 +14KB（现有存档 476KB，占比约 3%）。
static func _collect_map(tree: SceneTree) -> Dictionary:
	# 取"场景里真实存在的那张地图"，而不是缓存下来的副本 ——
	# 将来地形可被玩家改动（挖地/铺路）时，存档自动就是最新的。
	var gen: Node = tree.get_first_node_in_group("map_gen")
	if gen == null or not gen.has_method("get_terrain_bytes"):
		return {}
	var tiles: PackedByteArray = gen.call("get_terrain_bytes")
	if tiles.is_empty():
		return {}
	return {
		"w": int(gen.call("get_map_width")),
		"h": int(gen.call("get_map_height")),
		"size": tiles.size(),
		"tiles": Marshalls.raw_to_base64(tiles.compress(FileAccess.COMPRESSION_DEFLATE)),
		"tiles_hash": sha256_hex(tiles),
	}


## 读档：解出地形快照放进 pending，交给地图生成器还原
##
## 缺 map 段（v1 老存档）不算错误 —— 退回"用种子重算地形"，只是地形可能与
## 当年不同，所以明确记一条日志，免得日后看到建筑落水却查不出原因。
static func _load_map_snapshot(data: Dictionary) -> void:
	clear_pending_map_tiles()
	var map: Dictionary = data.get("map", {})
	if map.is_empty() or String(map.get("tiles", "")) == "":
		DebugConfig.log_msg(DebugConfig.CAT_TERRAIN,
			"[存档] 该档不含地形快照（v%d 老档），按种子重算地形", [int(data.get("version", 1))])
		return
	var size := int(map.get("size", 0))
	var packed := Marshalls.base64_to_raw(String(map.get("tiles", "")))
	if packed.is_empty() or size <= 0:
		DebugConfig.warn_msg(DebugConfig.CAT_TERRAIN,
			"[存档] 地形快照解码失败（base64/size 异常），退回按种子生成地形", [])
		return
	var tiles := packed.decompress(size, FileAccess.COMPRESSION_DEFLATE)
	if tiles.size() != size:
		DebugConfig.warn_msg(DebugConfig.CAT_TERRAIN,
			"[存档] 地形快照解压异常（期望 %d 字节，得到 %d），退回按种子生成地形",
			[size, tiles.size()])
		return
	# 哈希校验：对不上说明存档文件被改坏过。仍然载入（地皮本身才是真相），
	# 但要让玩家/开发者看到"这份档案可疑"，而不是默默用一份坏数据。
	var want := String(map.get("tiles_hash", ""))
	if want != "" and sha256_hex(tiles) != want:
		DebugConfig.warn_msg(DebugConfig.CAT_TERRAIN,
			"[存档] 地形快照哈希不符，存档文件可能已损坏（仍按快照载入）", [])
	pending_map_tiles = tiles
	pending_map_size = Vector2i(int(map.get("w", 0)), int(map.get("h", 0)))
	pending_map_hash = want
	DebugConfig.log_msg(DebugConfig.CAT_TERRAIN,
		"[存档] 地形快照已就绪：%d × %d（%d 字节）",
		[pending_map_size.x, pending_map_size.y, tiles.size()])


## 敌人：场景里预置的固定几只，按节点路径记录。
## 状态为 dead（正在播死亡动画/下沉）的跳过——它们马上就 queue_free，
## 存进去等于读档后原地复活。
##
## 【2026-09-12 流式加载】有 WorldStreamer 时交给它收集：
## 视野外的敌人已被移出场景树，扫组根本扫不到，会被当成"已击杀"删掉。
## 没有流式加载的场景（旧测试场景）自动退回下面的扫组逻辑。
static func _collect_enemies(tree: SceneTree) -> Array:
	var ws := _get_streamer(tree)
	if ws != null:
		return ws.collect_enemies()

	var out: Array = []
	var scene := tree.current_scene
	if scene == null:
		return out
	for e in tree.get_nodes_in_group("enemy"):
		if e == null or not is_instance_valid(e):
			continue
		if not e.has_method("get_save_data"):
			continue
		if str(e.get("_state")) == "dead":
			continue
		var entry: Dictionary = e.call("get_save_data")
		entry["path"] = String(scene.get_path_to(e))
		out.append(entry)
	return out


## 地面掉落物：物品 id + 数量 + 坐标（ItemDrop 自己的随机偏移不进档）
## 同样优先交给 WorldStreamer（视野外的掉落物不在场景树里）
static func _collect_drops(tree: SceneTree) -> Array:
	var ws := _get_streamer(tree)
	if ws != null:
		return ws.collect_drops()

	var out: Array = []
	for d in tree.get_nodes_in_group("item_drop"):
		if d == null or not is_instance_valid(d):
			continue
		# 已被捡起、正在播消失动画的不存
		if bool(d.get("_being_collected")):
			continue
		var item = d.get("item_data")
		if item == null or int(d.get("count")) <= 0:
			continue
		var p: Vector3 = d.position
		var entry: Dictionary = {
			"item_id": str(item.item_id),
			"count": int(d.get("count")),
			"position": {"x": p.x, "y": p.y, "z": p.z},
		}
		# 核心掉落物：连电量与温度值一起存。核心是独立单位，
		# 不给它存状态的话，读一次档地上那枚用了一半的核心就自动满电了。
		if d.has_method("get_core_state"):
			var core_state = d.call("get_core_state")
			if core_state != null:
				entry["core"] = core_state
		out.append(entry)
	return out


## 相机：Q/E 转出来的朝向与滚轮缩放（纯观感，但读档后视角乱跳很明显）
static func _collect_camera(tree: SceneTree) -> Dictionary:
	var scene := tree.current_scene
	if scene == null:
		return {}
	for c in scene.find_children("*", "Camera3D", true, false):
		return {
			"yaw": float(c.get("_target_yaw")),
			"zoom": float(c.get("_target_zoom")),
		}
	return {}


## 建筑：id + 位置；储物箱的格子内容一并带走
static func _collect_buildings(tree: SceneTree) -> Array:
	var out: Array = []
	for b in BuildingSystem.get_placed():
		if b == null or not is_instance_valid(b):
			continue
		var entry := {
			"id": str(b.get("building_id")),
		}
		if b is Node3D:
			var p: Vector3 = (b as Node3D).global_position
			entry["position"] = {"x": p.x, "y": p.y, "z": p.z}
		var storage = b.get("storage")
		if storage != null and is_instance_valid(storage) and storage.has_method("save"):
			entry["storage"] = storage.call("save")
		out.append(entry)
	return out


# ============================================
# 私有 - 应用存档数据
# ============================================

## 世界：先设时间，再让 ResourceManager 清场并按存档重建所有资源
static func _apply_world(tree: SceneTree, world: Dictionary, resource_manager: Node) -> void:
	var day_night: Node = tree.get_first_node_in_group("day_night")
	if day_night != null and day_night.has_method("set_time"):
		day_night.call("set_time", float(world.get("hour", 8.0)), int(world.get("day", 1)))

	if resource_manager.has_method("load_game"):
		resource_manager.call("load_game", _normalize_resource_states(world.get("resources", {})))

	# 世界内容按 敌人 → 掉落物 → 相机 的顺序补回。
	# 用 has() 判断而不是取默认值：老存档没有这几个键，
	# 传空数组进去会触发"清场"逻辑，把新开局的敌人和掉落物全删光。
	if world.has("enemies"):
		_apply_enemies(tree, world.get("enemies", []))
	if world.has("drops"):
		_apply_drops(tree, world.get("drops", []))
	_apply_camera(tree, world.get("camera", {}))


## 敌人：还给活着的那些落位回血，存档里没出现的直接删掉（= 已被击杀）
## 有 WorldStreamer 时整段委托给它 —— 它同时管着"被挂起（移出场景树）"的敌人
static func _apply_enemies(tree: SceneTree, list: Array) -> void:
	var ws := _get_streamer(tree)
	if ws != null:
		ws.apply_enemies(list)
		return

	var scene := tree.current_scene
	if scene == null:
		return
	var alive := {}
	for entry in list:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var path := String(e.get("path", ""))
		if path.is_empty():
			continue
		var node := scene.get_node_or_null(NodePath(path))
		if node == null or not is_instance_valid(node):
			DebugConfig.warn_msg(DebugConfig.CAT_UI, "[存档] 敌人节点已不存在，跳过：%s", [path])
			continue
		alive[node] = true
		if node.has_method("apply_save_data"):
			node.call("apply_save_data", e)

	for n in tree.get_nodes_in_group("enemy"):
		if n == null or not is_instance_valid(n) or alive.has(n):
			continue
		# remove_child + queue_free 一起用：只 queue_free 的话节点会留到帧末，
		# 期间仍可能被敌人的攻击判定或玩家的攻击命中"打到尸体"
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()


## 掉落物：先清场再按存档逐个重建（有 WorldStreamer 时委托给它）
static func _apply_drops(tree: SceneTree, list: Array) -> void:
	var ws := _get_streamer(tree)
	if ws != null:
		ws.apply_drops(list)
		return

	for d in tree.get_nodes_in_group("item_drop"):
		if d == null or not is_instance_valid(d):
			continue
		if d.get_parent() != null:
			d.get_parent().remove_child(d)
		d.queue_free()

	for entry in list:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := StringName(String(e.get("item_id", "")))
		var count := int(e.get("count", 1))
		if id == &"" or count <= 0:
			continue
		var pos := _to_vec3(e.get("position", {}))
		var drop := ItemDrop.spawn_item_by_id(id, count, pos)
		if drop == null:
			continue
		# spawn_drop 会随机偏移一点避免重叠，读档要还原到精确坐标
		drop.position = pos
		# 跳过出生保护期：读档后玩家可能就站在掉落物上，
		# 不该让他干等 0.4 秒才能按空格
		drop.set("_age", 10.0)
		# 还原核心自己的状态（电量 + 温度值），核心掉落物才不会被读档回满
		var core_state = e.get("core")
		if core_state is Dictionary:
			drop.call("restore_core_state", core_state)


## 相机：把 yaw / zoom 直接写进内部状态（同时写目标值与当前值，
## 只写目标值会让镜头在进游戏后自己转一大圈）
static func _apply_camera(tree: SceneTree, data: Dictionary) -> void:
	if data.is_empty():
		return
	var scene := tree.current_scene
	if scene == null:
		return
	for c in scene.find_children("*", "Camera3D", true, false):
		var yaw := float(data.get("yaw", 0.0))
		var zoom := float(data.get("zoom", 1.0))
		c.set("_target_yaw", yaw)
		c.set("_yaw", yaw)
		c.set("_target_zoom", zoom)
		c.set("_zoom", zoom)
		# 老存档可能是在"连续旋转不归位"的旧版里存的，yaw 是任意角度 →
		# 读进来后大小地图（跟随相机 yaw）是歪的。这里统一归到最近档位。
		if c.has_method("snap_yaw_to_step"):
			c.call("snap_yaw_to_step")
		return


## 资源状态归一化（读档前清洗一遍存档数据）
##
## 为什么需要：资源状态机里有 GROWING / HARVESTED / REGENERATING / TRANSITIONING
## 四个状态，但只有 GROWING 和 HARVESTED 是"稳定态"——另外两个全靠运行中的
## 计时器推进。存档时如果正好停在：
##   TRANSITIONING（采集中途保存）→ 读档后没有计时器把它推到 HARVESTED，
##   REGENERATING（再生倒计时中）  → 读档后倒计时不继续，
## 这两个资源就永久卡死（看不见也采不了）。统一按"已采集"恢复，
## ResourceEntity.load_save_data 会接上再生倒计时。
static func _normalize_resource_states(resources: Dictionary) -> Dictionary:
	var list: Array = resources.get("resources", [])
	for e in list:
		if not (e is Dictionary):
			continue
		var state := int(e.get("state", int(ResourceState.State.GROWING)))
		if state != int(ResourceState.State.GROWING) and state != int(ResourceState.State.HARVESTED):
			e["state"] = int(ResourceState.State.HARVESTED)
	return resources


## 玩家：位置 / 生命 / 电量体温 / 背包 → 装备（顺序不能反：装备恢复要往背包里塞东西）
static func _apply_player(tree: SceneTree, player_data: Dictionary) -> void:
	var player: Node = tree.get_first_node_in_group("player")
	if player == null:
		return

	# 位置：设到 Physics（真实移动体）上
	var phys: Node = player.get_node_or_null("Physics")
	if phys is Node3D and player_data.has("position"):
		var pd: Dictionary = player_data.get("position", {})
		(phys as Node3D).global_position = Vector3(
			float(pd.get("x", 0.0)), float(pd.get("y", 0.0)), float(pd.get("z", 0.0)))
		# 角色被瞬移了，两件事必须同步做掉，否则进档第一眼画面是错的：
		#   1. 相机吸附到新坐标——不然镜头会从出生点平滑"飞"到玩家身上；
		#   2. 重置视觉插值——不然精灵会从旧位置拖一条残影过来。
		if phys.has_method("reset_visual_interp"):
			phys.call("reset_visual_interp")
		var cam: Node = tree.get_first_node_in_group("player_camera")
		if cam != null and cam.has_method("snap_to_target"):
			cam.call("snap_to_target")

	# 生命（顺手把 HUD 血条刷一遍，否则读档后血量显示是旧值）
	if phys != null and player_data.has("health"):
		phys.set("current_health",
			clampi(int(player_data.get("health", 100)), 1, int(phys.get("max_health"))))
		if phys.has_method("_update_hud_health"):
			phys.call("_update_hud_health")

	# 背包
	var inv: Node = player.get_node_or_null("Inventory")
	if inv != null and inv.has_method("load_data") and player_data.has("inventory"):
		inv.call("load_data", player_data.get("inventory", {}))
		# load_data 直接写内部数组、不发 item_changed，UI 得手动刷一次，
		# 否则 HUD 快捷栏还显示着读档前的旧物品
		if inv.has_method("notify_all_slots"):
			inv.call("notify_all_slots")

	# 装备：直接写槽位，不走 equip()
	# （equip 要先从背包取 1 件，读档时背包常常是满的，会静默丢装备）
	#
	# ⚠ 顺序：装备恢复排在「电量」之前 —— 核心槽一变，Vitals 就会重算
	# "有没有电"并刷 HUD。先摆好装备再写数值，读档期间就不会出现
	# "先亮起、后熄灭"的一帧闪烁。
	#
	# 槽里存的是**物品实例**（核心的电量 / 温度值都在实例上）。
	# 老存档这一格是纯 item_id 字符串，走下面的兼容分支：
	# 那种档里的核心当然没有状态可恢复，按出厂满电处理即可。
	var equip: Node = player.get_node_or_null("Equipment")
	if equip != null and player_data.has("equipment"):
		var eq: Dictionary = player_data.get("equipment", {})
		var slots := {
			"weapon": int(ItemData.EquipSlot.WEAPON),
			"armor": int(ItemData.EquipSlot.ARMOR),
			"tool": int(ItemData.EquipSlot.TOOL),
			"core": int(ItemData.EquipSlot.CORE),
		}
		for key in slots:
			var raw = eq.get(key, "")
			var slot: int = int(slots[key])

			# 新格式：物品实例字典
			if raw is Dictionary:
				var d: Dictionary = raw
				if d.is_empty():
					continue
				var inst := ItemInstance.new()
				if not inst.from_dict(d):
					DebugConfig.warn_msg(DebugConfig.CAT_UI,
						"[存档] 装备恢复失败：物品实例无效（槽 %d）", [slot])
					continue
				if equip.has_method("set_slot_instance"):
					equip.call("set_slot_instance", slot, inst)
				continue

			# 老格式：只有 item_id
			var item_id := StringName(String(raw))
			if item_id == &"":
				continue
			_restore_equip_slot_by_id(equip, slot, item_id, inv)

	# 无条件重算一次核心槽状态。上面的循环只处理"槽里真有东西"的情况，
	# 读一个没装核心的档时它整段跳过 —— 那样上一档留下的
	# 外置电量与「核心」制作栏就会跟着串到这一档来。
	if equip != null and equip.has_method("resync_core_state"):
		equip.call("resync_core_state")

	# 电量 / 温度值 / 体温 / 饱食度
	var vitals: Node = player.get_node_or_null("Vitals")
	if vitals != null:
		# 这里只还原**自身电量**（内置电量的机器人）。
		# 核心电量不在这里 —— 它随核心实例一起从装备槽恢复（见上一步），
		# "有没有电"也由装备推导，不再有单独的开关字段要还原。
		if player_data.has("power") and vitals.has_method("set_power"):
			vitals.call("set_power", float(player_data.get("power")))
		# 温度值先于体温还原（体温怎么走由温度值档位决定，顺序反了没有实质影响，
		# 但保持"因 → 果"的顺序更不容易在以后改坏）。都走 setter 以刷新信号缓存。
		# 老存档没有 temperature_value → 保持 _ready 的初值（500 = 正常档）。
		if player_data.has("temperature_value") and vitals.has_method("set_temperature_value"):
			vitals.call("set_temperature_value", float(player_data.get("temperature_value")))
		if player_data.has("temperature") and vitals.has_method("set_temperature"):
			vitals.call("set_temperature", float(player_data.get("temperature")))
		# 走 set_hunger 而不是直接写变量：它会发 hunger_changed，
		# HUD 的 _last_hunger_shown 缓存才会被刷新（旧存档没这个字段则保持满值）
		if player_data.has("hunger") and vitals.has_method("set_hunger"):
			vitals.call("set_hunger", float(player_data.get("hunger")))


## 老存档的装备格（纯 item_id 字符串）恢复：查注册表拿物品数据再写槽。
##
## 为什么单独一个函数：新格式走实例、老格式走 item_id，
## 两条路径的失败处理不一样（老格式查不到物品时只能警告跳过）。
static func _restore_equip_slot_by_id(
		equip: Node, slot: int, item_id: StringName, inv: Node) -> void:
	var registry = ItemRegistry.get_registry()
	if registry == null:
		return
	var item_data = registry.get_item(item_id)
	if item_data == null:
		DebugConfig.warn_msg(DebugConfig.CAT_UI,
			"[存档] 装备恢复失败：未知物品 %s", [item_id])
		return
	# 有 set_slot_item 就直接写槽；老版本没有该方法时退回 equip 流程
	if equip.has_method("set_slot_item"):
		equip.call("set_slot_item", slot, item_data)
	elif inv != null:
		inv.call("add_item", item_data, 1)
		equip.call("equip", item_id)


## 建筑：按存档重放 Building.spawn；储物箱内容直接 load_data 回填
static func _apply_buildings(tree: SceneTree, building_list: Array) -> void:
	# 先清光场景里现存的建筑：地图生成器会在出生点无条件放一个测试储物箱，
	# 不清掉的话读档后它会和存档里的箱子叠在一起（还占掉一格存储）。
	var scene := tree.current_scene
	if scene != null:
		# find_children 按类名递归，能捞出挂在任意父节点下的 Building
		for old in scene.find_children("*", "Building", true, false):
			if old.get_parent() != null:
				old.get_parent().remove_child(old)
			old.queue_free()
	# _placed 是静态登记表、跨场景不清空，这里必须显式清一次
	BuildingSystem.clear()

	var root := _get_building_root(tree)
	for entry in building_list:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := StringName(String(e.get("id", "")))
		if id == &"" or BuildingSystem.get_def(id).is_empty():
			continue
		var b := Building.spawn(id, _to_vec3(e.get("position", {})), root)
		if b != null and e.has("storage") and b.has_storage():
			b.storage.call("load_data", e.get("storage", {}))


## 视野流式加载管理器（敌人 + 掉落物的装配/挂起）。
## 场景里没有它（旧测试场景）时返回 null，调用方会退回"扫组"逻辑。
static func _get_streamer(tree: SceneTree) -> WorldStreamer:
	if tree == null:
		return null
	return tree.get_first_node_in_group("world_streamer") as WorldStreamer


## 建筑容器：与 build_placer._building_root() 同一套懒创建约定
static func _get_building_root(tree: SceneTree) -> Node3D:
	var existing := tree.get_first_node_in_group("building_root") as Node3D
	if existing != null:
		return existing
	var scene := tree.current_scene
	if scene == null:
		return null
	var root := Node3D.new()
	root.name = "BuildingRoot"
	root.add_to_group("building_root")
	scene.add_child(root)
	return root


# ============================================
# 私有 - 文件 IO
# ============================================

static func _slot_path(slot_id: int) -> String:
	return SAVE_DIR + "/slot_%d.json" % slot_id


static func _read_slot(slot_id: int) -> Dictionary:
	var path := _slot_path(slot_id)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary == false:
		return {}
	return parsed


static func _write_slot(slot_id: int, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var file := FileAccess.open(_slot_path(slot_id), FileAccess.WRITE)
	if file == null:
		push_error("[存档] 无法写入 %s（错误码 %d）" % [_slot_path(slot_id), FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## 下一个空闲槽 id = 现有最大 id + 1
static func _next_slot_id() -> int:
	var next_id := 1
	var dir := DirAccess.open(SAVE_DIR)
	if dir != null:
		for f in dir.get_files():
			if not f.begins_with("slot_") or not f.ends_with(".json"):
				continue
			next_id = maxi(next_id, int(f.trim_prefix("slot_").trim_suffix(".json")) + 1)
	return next_id


static func _now_string() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


## 摇一个地图种子（避开 0，0 在本模块里表示"还没定种子"）
static func _roll_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return maxi(1, rng.randi() % 2147483647)


static func _to_vec3(dict: Dictionary) -> Vector3:
	return Vector3(
		float(dict.get("x", 0.0)),
		float(dict.get("y", 0.0)),
		float(dict.get("z", 0.0)))
