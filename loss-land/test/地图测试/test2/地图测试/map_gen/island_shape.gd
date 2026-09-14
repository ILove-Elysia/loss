class_name IslandShape
extends Resource
## 岛屿形状参数（可保存为 .tres 预设，在检视面板切换）。
## 半径 = base_radius + amp1·sin(freq1·θ+φ1) + amp2·sin(freq2·θ+φ2) + amp3·sin(freq3·θ+φ3)
## 相位 φ 每次随机生成，这里只暴露振幅与频率。

@export var base_radius: float = 78.0
@export var amp1: float = 11.0
@export var amp2: float = 6.0
@export var amp3: float = 4.0
@export var freq1: float = 3.0
@export var freq2: float = 5.0
@export var freq3: float = 7.0
@export var ellipse_jitter: float = 0.12   # 轻微椭圆比例抖动幅度
