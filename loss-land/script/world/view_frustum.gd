# script/world/view_frustum.gd
# ============================================
# 世界内容装载范围判定 —— 所有「流式加载」系统的公共开关
#
# 【当前策略：按距玩家的水平距离】
#   玩家周围 LOAD_RADIUS 米内的单位被装载；已装载的要超出 UNLOAD_RADIUS 才卸载。
#   两个半径之差就是滞回带，防止玩家站在边界上微动时反复装卸。
#
# 【为什么不用相机视锥了】（2026-09-12 用户要求改成距离）
#   视锥求交的结果随相机俯角 / 朝向 / 滚轮缩放实时变化：
#     · 想省性能时不知道该调哪个数 —— "视野"是算出来的，不是设出来的；
#     · 想验证效果也没法预期 —— 同一份配置换个分辨率、换个镜头角度，
#       装载量就变了，测试只能断言"有个矩形"，断言不了具体几米。
#   换成固定距离后，屏幕上装了多少是可以直接算的（见下方估算），
#   代价是：把镜头拉到最远时，屏幕最角落可能略微超出半径 → 那一角会早一点点弹入。
#   当前相机参数下这个余量已经留足（见下方参考值）。
#
# 【使用方】ResourceManager（资源 / 建筑）、WorldStreamer（敌人 / 掉落物）。
# 三方共用同一份定义 —— 各写一套的话，边界上会出现"树还在、怪先没了"这种错位，
# 而且调参要改好几处，必然改漏。
#
# （类名沿用 ViewFrustum：它曾经按屏幕视锥实现，改距离制后名字只作"视野范围"理解。）
# ============================================

class_name ViewFrustum
extends RefCounted

# ============================================
# 调参区 —— 想改手感 / 省性能，只动这里，别处不用碰
# ============================================

## 各类型单位的装载半径（米，以玩家为圆心的水平距离）
## 键：resource（资源）/ enemy（敌人）/ drop（地面掉落物）/ building（建筑）
##
## 参考：当前主相机 base_offset (0,5,-8)、fov 50、zoom 0.6~1.8，
##   相对玩家可见的地面大约在身前 33 米（推近）~ 59 米（拉远）、两侧 ±25 米，
##   所以 70 米已经盖住整个可见范围，屏幕边缘不会"走到跟前才冒出来"。
##
## 性能估算：岛半径约 430 米、全图约 2400 个资源 →
##   半径 70 的圆内约 60 个实体（每个实体约 7 个节点 → 约 400 个节点，开销可忽略）。
##   想让常驻节点立刻减半，把这里的数字除以 1.4 即可（半径减半则数量降为 1/4）。
const LOAD_RADIUS := {
	"resource": 70.0,
	"enemy": 70.0,
	"drop": 50.0,
	"building": 70.0,
}

## 卸载滞回（米）：已装载的单位要超出「LOAD_RADIUS + 它」才卸载
## 没有它 = 进出用同一个阈值 —— 玩家在阈值上轻微移动，同一批物体会以
## 每次装配的节拍反复装卸（节点抖动 + 对象池抖动），帧率会出现规律性毛刺。
const UNLOAD_HYSTERESIS := 24.0


# ============================================
# 半径查询
# ============================================

# ----------------------------------------
# 装载半径（米）。kind 不认识时退回 resource 的值，不会返回 0
# ----------------------------------------
static func load_radius(kind: String) -> float:
	return float(LOAD_RADIUS.get(kind, LOAD_RADIUS["resource"]))


# ----------------------------------------
# 卸载半径（米）= 装载半径 + 滞回
# ----------------------------------------
static func unload_radius(kind: String) -> float:
	return load_radius(kind) + UNLOAD_HYSTERESIS


# ============================================
# 距离判定
# ============================================

# ----------------------------------------
# 水平（xz）距离。世界无海拔差异，竖直方向的差不算数 ——
# 无人机 hover 1.5 米、地形起伏，用三维距离会让阈值随高度漂。
# ----------------------------------------
static func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func distance_to_player(tree: SceneTree, pos: Vector3) -> float:
	return flat_distance(pos, player_position(tree))


# ----------------------------------------
# 该位置的单位现在是否应该被装载
# 判定顺序：先问 should_load，再问 should_unload，中间那段就是滞回带，
# 落在带里的单位保持现状（已装载的留着、没装载的不补）
# ----------------------------------------
static func should_load(tree: SceneTree, kind: String, pos: Vector3) -> bool:
	return distance_to_player(tree, pos) <= load_radius(kind)


static func should_unload(tree: SceneTree, kind: String, pos: Vector3) -> bool:
	return distance_to_player(tree, pos) > unload_radius(kind)


# ============================================
# 玩家位置
# ============================================

# ----------------------------------------
# 玩家真实世界坐标
#
# 玩家根节点只是容器、恒在原点，真正移动的是其子节点 Physics，
# 所以优先取 Physics。找不到玩家时返回原点（退化成以原点为圆心）。
# ----------------------------------------
static func player_position(tree: SceneTree) -> Vector3:
	var root := player_root(tree)
	if root == null:
		return Vector3.ZERO
	var phys := root.get_node_or_null("Physics")
	if phys is Node3D:
		return (phys as Node3D).global_position
	if root is Node3D:
		return (root as Node3D).global_position
	return Vector3.ZERO


# ----------------------------------------
# 玩家根节点（player 组成员；其下挂 Inventory / Equipment / Physics）
# ----------------------------------------
static func player_root(tree: SceneTree) -> Node:
	if tree == null:
		return null
	var players := tree.get_nodes_in_group("player")
	return players[0] if not players.is_empty() else null
