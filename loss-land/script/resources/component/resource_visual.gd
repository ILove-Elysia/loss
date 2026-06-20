# script/resources/component/resource_visual.gd
# ============================================
# 视觉组件 - 管理资源的外观显示
#
# 这个组件负责：
# 1. 显示正确的贴图/动画
# 2. 播放状态切换动画
# 3. 处理视觉过渡效果
#
# 什么是 AnimatedSprite3D？
# 这是 Godot 的 3D 精灵节点，可以播放帧动画
# 类似于 2D 游戏中的 AnimatedSprite
# ============================================

class_name ResourceVisual
extends Node3D

# ============================================
# 导出变量
# 在编辑器中可以拖拽设置这些节点引用
# ============================================

# 3D 精灵节点，用于显示资源图片和动画
# 在场景中将 AnimatedSprite3D 节点拖入此处
@export var sprite: AnimatedSprite3D

# 动画播放器，用于播放复杂动画
# 可以播放与 SpriteFrames 不同的 AnimationPlayer 动画
@export var animation_player: AnimationPlayer

# ============================================
# 私有变量
# ============================================

# 资源数据的引用
var _resource_data: ResourceData

# 当前视觉状态
var _current_state: ResourceState.State = ResourceState.State.GROWING

# ============================================
# 设置函数
# ============================================

# ----------------------------------------
# 设置函数
# 初始化视觉组件的配置
# 由 ResourceEntity 在 ready 时调用
#
# 参数：data - 资源数据配置
# ----------------------------------------
func setup(data: ResourceData) -> void:
    _resource_data = data
    
    # 如果设置了精灵和贴图，配置生长状态贴图
    if sprite and data.growing_texture:
        # sprite_frames 是 AnimatedSprite 的动画帧集合
        # set_frame_texture 设置某一帧的贴图
        # 参数1：动画名称
        # 参数2：帧索引
        # 参数3：贴图资源
        sprite.sprite_frames.set_frame_texture(data.growing_animation, 0, data.growing_texture)
    
    # 配置已采集状态贴图
    if sprite and data.harvested_texture:
        sprite.sprite_frames.set_frame_texture(data.harvested_animation, 0, data.harvested_texture)

# ============================================
# 公共方法
# ============================================

# ----------------------------------------
# 设置视觉状态函数
# 根据状态切换视觉表现
# 由 ResourceEntity 在状态改变时调用
#
# 参数：state - 目标状态
# ----------------------------------------
func set_visual_state(state: ResourceState.State) -> void:
    _current_state = state
    
    # 根据不同状态播放不同动画
    match state:
        ResourceState.State.GROWING:
            # 播放生长动画
            _play_animation(_resource_data.growing_animation if _resource_data else "grow")
        
        ResourceState.State.HARVESTED:
            # 播放已采集动画（枯萎）
            _play_animation(_resource_data.harvested_animation if _resource_data else "harvested")
        
        ResourceState.State.REGENERATING:
            # 播放再生动画
            _play_regen_animation()
        
        ResourceState.State.TRANSITIONING:
            # 播放过渡动画（采集动画）
            _play_transition_animation()

# ----------------------------------------
# 立即设置视觉状态函数
# 不播放动画，直接切换显示
# 用于加载存档时恢复状态（不需要播放过渡动画）
#
# 参数：state - 目标状态
# ----------------------------------------
func set_visual_state_immediate(state: ResourceState.State) -> void:
    _current_state = state
    
    match state:
        ResourceState.State.GROWING:
            _set_frame_immediate(_resource_data.growing_animation if _resource_data else "grow")
        ResourceState.State.HARVESTED:
            _set_frame_immediate(_resource_data.harvested_animation if _resource_data else "harvested")

# ----------------------------------------
# 播放采集动画函数
# 采集时调用的特殊动画
# ----------------------------------------
func play_harvest_animation() -> void:
    # 检查是否有动画播放器
    if animation_player:
        # has_animation 检查是否有指定名称的动画
        if animation_player.has_animation("harvest"):
            animation_player.play("harvest")

# ============================================
# 私有方法
# ============================================

# ----------------------------------------
# 播放动画函数
# 播放指定名称的动画
# ----------------------------------------
func _play_animation(anim_name: String) -> void:
    # 检查精灵和动画是否存在
    if sprite and sprite.sprite_frames:
        if sprite.sprite_frames.has_animation(anim_name):
            sprite.play(anim_name)

# ----------------------------------------
# 播放再生动画函数
# ----------------------------------------
func _play_regen_animation() -> void:
    if animation_player and animation_player.has_animation("regen"):
        animation_player.play("regen")

# ----------------------------------------
# 播放过渡动画函数
# ----------------------------------------
func _play_transition_animation() -> void:
    if animation_player and animation_player.has_animation("transition"):
        animation_player.play("transition")

# ----------------------------------------
# 立即设置动画帧函数
# 不播放动画，直接跳到指定帧
# 用于快速恢复状态
# ----------------------------------------
func _set_frame_immediate(anim_name: String) -> void:
    if sprite and sprite.sprite_frames:
        if sprite.sprite_frames.has_animation(anim_name):
            sprite.animation = anim_name  # 设置当前动画名称
            sprite.frame = 0              # 设置为第一帧（停止在当前帧）
