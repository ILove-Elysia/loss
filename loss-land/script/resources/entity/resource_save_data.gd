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
# ============================================

class_name ResourceSaveData
extends Node

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 保存所有资源函数
# 将所有实体状态转换为字典
#
# 参数：entities - 要保存的实体数组
# 返回：存档数据字典
#
# 保存的数据结构：
# {
#   "version": 1,  # 存档版本号，用于未来升级兼容
#   "resources": [  # 所有资源的存档数据
#       { "instance_id": 0, "resource_id": "grass", ... },
#       { "instance_id": 1, "resource_id": "tree", ... },
#   ]
# }
# ----------------------------------------
func save_all(entities: Array[ResourceEntity]) -> Dictionary:
    # 创建保存数据数组
    var save_data: Array[Dictionary] = []
    
    # 遍历所有实体
    for entity in entities:
        # 检查实体是否有效
        # is_instance_valid 检查对象是否还存在
        if is_instance_valid(entity):
            # 获取每个实体的保存数据
            save_data.append(entity.get_save_data())
    
    # 返回完整的存档结构
    return {
        "version": 1,
        "resources": save_data
    }

# ----------------------------------------
# 加载所有资源函数
# 从存档数据恢复所有资源
#
# 参数：
#   data - 存档数据字典
#   manager - 资源管理器引用
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
# 从数据恢复一个资源实体
# ----------------------------------------
func _load_single_resource(data: Dictionary, manager: ResourceManager) -> void:
    # 获取资源ID
    var resource_id = StringName(data.get("resource_id", ""))
    
    # 获取位置数据
    var pos_data = data.get("position", {})
    var position = Vector3(
        pos_data.get("x", 0.0),
        pos_data.get("y", 0.0),
        pos_data.get("z", 0.0)
    )
    
    # 获取状态
    var state = data.get("state", ResourceState.State.GROWING)
    
    # 通过管理器生成资源
    var entity = manager.spawn_resource(resource_id, position, state)
    
    # 如果生成成功，加载详细数据
    if entity:
        entity.load_save_data(data)
