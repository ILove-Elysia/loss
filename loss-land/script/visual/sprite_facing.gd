# script/visual/sprite_facing.gd
# ============================================
# 广告牌朝向工具（class_name + static，不挂节点）
#
# 解决的问题：
#   本作的树、角色、敌人都是一张平面贴图。贴图必须"正对镜头"才好看，
#   但"正对镜头"有三种做法，差别很大：
#
#   ① billboard = FIXED_Y（引擎内置，绕着世界 Y 轴转）
#      → 只跟水平方向（yaw），不跟俯角（pitch）。
#        相机俯角拉到 60° 时，竖直的贴图被透视压缩成 cos60° = 50% 高——
#        同一个东西推近时高、拉远时矮，看起来"不是同一棵树"。
#
#   ② billboard = ENABLED（完全朝向相机）
#      → 连俯角一起跟，但贴图会绕视线自转，镜头一动整张图就歪，观感很差。
#
#   ③ 本工具：水平朝向相机 + 只补偿俯角（绕贴图自己的水平轴后仰）
#      → 底边仍然水平、贴图仍然站在地上，只是整体"向后仰"到正对镜头。
#        屏幕上的高度不再随俯角变化：推近和拉远看到的是同一个高度。
#
# 补偿比例（tilt_ratio）：
#   1.0 = 完全正对镜头，屏幕高度恒定（本作采用）
#   0.0 = 完全不补偿，等同旧的 FIXED_Y（高俯角时会被压扁）
#   0.5 = 折中，保留一点"立体感"，代价是高度仍略有变化
#
# 为什么倾斜是绕"贴图底部"而不是绕中心：
#   绕底部转，贴图底边始终原地贴地，锚点不会前后滑动——
#   碰撞体、点击判定、寻路全在锚点上，视觉不会和物理对不上。
#   只有贴图的上半部分朝远离相机的方向倒，那是纯视觉偏移，不影响判定。
# ============================================

class_name SpriteFacing
extends RefCounted


# ----------------------------------------
# 求"正对相机"的旋转
#
# 返回的 Basis 约定：
#   · +Z 列 = 贴图正面法线，指向相机（贴图正对镜头）
#   · +Y 列 = 贴图的"上"，向上并朝远离相机的方向倾斜（贴图后仰）
#   · +X 列 = 贴图的"右"，仍在水平面内且与视线垂直 ——
#             所以贴图底边保持水平贴地，不会歪向一侧
#
# camera     - 当前 3D 相机（一般是 get_viewport().get_camera_3d()）
# tilt_ratio - 俯角补偿比例，0 ~ 1（见文件头说明）
# ----------------------------------------
static func facing_basis(camera: Camera3D, tilt_ratio: float = 1.0) -> Basis:
	if camera == null or not is_instance_valid(camera):
		return Basis()

	# 相机 basis 的 +Z 列是"相机后方"，也就是从物体指向相机的方向。
	# 相机 basis 本身是正交归一的，这一列已经是单位向量。
	var to_camera: Vector3 = camera.global_transform.basis.z
	# 相机俯角：低头看物体时 to_camera.y 为正（相机在物体上方）
	# 注：三角函数在 4.x 只有 float 签名，没有 asinf / cosf / sinf 变体，
	#     写了会直接 "Function not found in base self" 解析失败。
	#     （只有同时存在 Variant 重载的函数才是 f 变体，如 absf / floorf / clampf）
	var pitch: float = asin(clampf(to_camera.y, -1.0, 1.0))

	# 水平分量：把相机方向压平到水平面 —— 这正是 FIXED_Y 广告牌用的方向
	var flat := Vector3(to_camera.x, 0.0, to_camera.z)
	if flat.length_squared() < 0.000001:
		# 相机几乎在正上方（俯角 ≈ 90°）时水平分量退化，随便定一个方向
		flat = Vector3(0.0, 0.0, -1.0)
	flat = flat.normalized()

	var tilt: float = pitch * clampf(tilt_ratio, 0.0, 1.0)
	var c: float = cos(tilt)
	var s: float = sin(tilt)

	var z_axis: Vector3 = (flat * c + Vector3.UP * s).normalized()
	var y_axis: Vector3 = (Vector3.UP * c - flat * s).normalized()
	# 右手系：X = Y × Z，结果必然落在水平面内
	var x_axis: Vector3 = y_axis.cross(z_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


# ----------------------------------------
# 直接给出"整张精灵"的世界变换（自带底部锚点）
#
# 用于精灵挂在实体根节点下、需要自己管位置的情况（如树）。
# 若精灵在某个「视觉根」下、由父节点统一控制位置（角色 / 敌人），
# 改用 facing_basis() 只覆盖父节点的旋转即可。
#
# ground       - 贴图底边锚点的世界坐标（一般就是实体原点、脚底）
# pivot_height - 贴图中心到锚点的高度（= 精灵原始 position.y）
# ----------------------------------------
static func facing_transform(camera: Camera3D, ground: Vector3,
		pivot_height: float, tilt_ratio: float = 1.0) -> Transform3D:
	var b: Basis = facing_basis(camera, tilt_ratio)
	# 中心 = 锚点 + 沿贴图自身"上"方向抬 pivot_height。
	# 倾斜后"上"不再是世界 Y，所以这一步必须用 b.y（变换后的上轴）。
	return Transform3D(b, ground + b.y * pivot_height)
