# script/resources/entity/resource_save_data.gd
# ============================================
# 存档数据处理 - 负责保存和加载资源状态
#
# 什么是数据持久化？
# 数据持久化就是把游戏数据保存到硬盘上
# 这样玩家关闭游戏后再打开，之前的数据还在
#
# 为什么要单独一个类？
# 分离关注点，让代码更清晰
# ResourceManager 专注管理资源
# ResourceSaveData 专注处理存档逻辑
#
# 2026-09-12 视野流式加载改造后：
#   资源分成了"记录层（数据）+ 表现层（节点）"两层，
#   存档的权威来源变成**记录层** —— 视野外的资源没有实体，
#   但它们的状态一直躺在记录里，照样要存。
#   键名保持与旧存档完全一致（见下方结构说明），老档可以直接读。
# ============================================

class_name ResourceSaveData
extends Node

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 保存所有资源函数
# 把记录层全部转成可序列化的字典
#
# 参数：records - ResourceManager 的资源记录数组
# 返回：存档数据字典
#
# 保存的数据结构：
# {
#   "version": 1,  # 存档版本号，用于未来升级兼容
#   "resources": [  # 所有资源的存档数据
#       { "instance_id": 0, "resource_id": "grass", "position": {...},
#         "state": 0, "regen_time_remaining": 0.0 },
#   ]
# }
#
# 已实例化的记录以实体为准（实体的再生 Timer 才是活的进度），
# 未实例化的记录直接取记录自身的字段。
# ----------------------------------------
func save_records(records: Array) -> Dictionary:
	var save_data: Array[Dictionary] = []

	for rec in records:
		if not (rec is Dictionary):
			continue
		var item: Dictionary = rec
		var entity = item.get("entity")
		if entity != null and is_instance_valid(entity):
			save_data.append(entity.get_save_data())
			continue
		var p: Vector3 = item.get("pos", Vector3.ZERO)
		save_data.append({
			"instance_id": int(item.get("instance_id", -1)),
			"resource_id": str(item.get("resource_id", "")),
			"position": {"x": p.x, "y": p.y, "z": p.z},
			"state": int(item.get("state", 0)),
			"regen_time_remaining": float(item.get("regen_remaining", 0.0)),
		})

	# 返回完整的存档结构
	return {
		"version": 1,
		"resources": save_data
	}

# ----------------------------------------
# 加载所有资源函数
# 从存档数据恢复所有资源记录
#
# 参数：
#   data - 存档数据字典
#   manager - 资源管理器引用（记录由它创建）
# ----------------------------------------
func load_all(data: Dictionary, manager: ResourceManager) -> void:
	# 获取存档版本
	var version = data.get("version", 1)
	
	# 获取资源数据数组
	var resources_data = data.get("resources", [])
	
	# 遍历并加载每个资源
	for resource_data in resources_data:
		_load_single_resource(resource_data, manager)

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 加载单个资源函数
# 从数据恢复一条资源记录（不创建节点，由视野流式加载决定何时实例化）
# ----------------------------------------
func _load_single_resource(data: Dictionary, manager: ResourceManager) -> void:
	if not (data is Dictionary):
		return
	manager.add_record_from_save(data)
