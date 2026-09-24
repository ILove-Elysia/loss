# 项目长期记忆（loss-land）

> **本文件＝高频铁律 + 领域指针；细节一律在 `MEMORY-details.md`**（角色/温度/电量、建造/存档、九宫格布局数值、容器交互、相机与渲染属性、攻击/死亡、采集数值与资源实体、世界与流式、美术资产）。历史全文 `MEMORY.md.2026-09-18-full.bak`；过程见 `2026-09-*.md`；**待办在 `E:\GameMake\loss\待办.md`**。

## 一、改文件 / 改数据的铁律

- `大纲.md`＝给人看的游戏说明书：禁版本号/状态标记/代码名/字段名/待办/踩坑；未实装写「（规划中）」；改数值后回写。过程与接口契约→每日日志。
- Godot **4.7.2**：`E:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`。**改 .gd → `test/gd_static_lint.py`；改 .tres/.tscn → `test/check_data_refs.py`；最后实机。编辑器开着别跑 headless**（抢 `.godot`）。
- **改 `.gd` 的 `@export` 字段（尤其删字段）必须先关编辑器**：编辑器会用"中间态脚本"重新序列化 .tres 落盘，无声吞掉当时脚本里不存在的字段（2026-09-22：8 份 .tres 的 `resource_id`/`drop_item_id` 被吞 ⇒ 场上一个资源都没有）。铁证＝被编辑器保存过的 .tres 会多出 `uid=`。**脚本改好 ≠ 数据还在，改完必跑 check_data_refs**。
- **`check_data_refs.py` 报的每一条都要处理**，不许标"历史遗留/与本次无关"跳过——2026-09-22 那 16 条「.tres 缺 resource_id」就是线上 bug 本身。
- **移出 .tscn/.tres 前先在编辑器关掉它的标签页**：编辑器发现文件被外部删除会把内存场景重新落盘（已发生 3 次，`grass_entity.tscn` 至今没删成）。标签页存在 `.godot/editor/editor_layout.cfg`、每次启动恢复 ⇒ 必须「关标签页 + 重启」。
- **手工写 `.tscn`：`@export` 的节点引用属性必须在节点头写 `node_paths=PackedStringArray("属性名")`**，漏写则属性**静默 null 且不报错**（2026-09-22：tree.tscn 的 `Visual` 漏写 ⇒ `sprite` 恒 null）。正例 map.tscn/player.tscn；最稳＝编辑器拖拽生成。
- **删物品同步 5 处**：`script/items/data/<id>_item.tres`、`item_registry.tres`（ext_resource 行 + items 条目）、`art/icons/<id>.png`+`.import`（移到 `E:\GameMake\loss\trash_*\`，别硬删）、测试夹具里的 `&"<id>"`、`项目结构说明.md` 物品表。删完 `check_data_refs.py` 会报物品数变化，可当校验。
- **移动 .gd 同步 5 处**：`.gd.uid` / 首行注释 / `.tscn` ext_resource / `test` 的 `load()` / class 缓存；`.godot/editor/*` 留旧路径别改。**新增 `class_name` 要手工补 `.godot/global_script_class_cache.cfg`（lint 第 4 项查），或在使用处 `const X := preload("res://…")` 绕开缓存**。核心系统＝`class_name`+`static`，不用 autoload。
- 同文件多处 Edit **必须串行，且一条消息只发一个**——并行会静默丢更新（2026-09-24 实测：2~3 个 Edit 只有一部分落盘，"成功"回执照给）。改完必 grep 复核；批量脚本改文件先 `cp` 后 `diff`；弱特征定位会命中错处→特征须含唯一内容。误改可救：`~/.workbuddy/file-history/<会话uuid>/<hash>@vN`。
- 查属性/枚举名 → `raw.githubusercontent.com/godotengine/godot/4.7/doc/classes/<类>.xml`。写错属性名 → `_ready` 抛错 → 灰屏，lint 查不出。

## 二、GDScript 语言坑

- **`:=` 右侧为 Variant 会报错**（WARNING 当 ERROR）：`.get()` / `.call()` / 无返回类型函数 / 双签名数学函数；新函数必写返回类型。**4.x 只有 11 个函数有 `f` 变体**＝`absf/ceilf/clampf/floorf/lerpf/maxf/minf/roundf/signf/snappedf/wrapf`；`sin/cos/tan/asin/acos/atan/atan2/sqrt/pow/exp/log/deg2rad/rad2deg` **没有 sinf/asinf/sqrtf/powf**，写了直接 `Function "asinf" not found` ⇒ **整份脚本解析失败**（2026-09-22 sprite_facing.gd 事故）。`gd_static_lint.py` 第 7 项专查。
- 信号 arity 是**运行时**检查：`signal` 增删参数后 `.connect()` 回调签名不匹配**不报错**，直到信号真触发才炸（2026-09-23 storage_ui 少一个 count）。常驻 `test/signal_arity_check.py`。
- **"每帧强制对齐状态"的函数会吃掉外来的一次性动画**：`physics._update_animation()` 每帧 `else: spr.play("idle")`，任何在 `await` 回调里播的动画都会同帧被切走 ⇒ 一次性动画必须有独立独占标志位（见 `is_working`）。

## 三、运行时取证与排查

- 日志：`%APPDATA%\Godot\app_userdata\loss_land\logs\`（`godot.log` 是当次，历史按时间戳存）。分类开关同目录 `debug_config.cfg`（**默认 resource=false**，排查采集/生成先改 true 再跑）。存档 `saves/slot_N.json` 可用 Python 直读（`world.resources.resources` 每条有 resource_id/position/state）。
- **高频根因（先查这 6 个）**：绑定缺失 / 缓存未重扫 / 集合被清空 / queue_free 延迟 / 控件 0×0 / 先设位置后入树。
- 运行时 `new` 的控件**禁用 `set_anchors_preset`**（0×0 会悬停不到且点击穿透到 3D）→ 显式 size/position；居中用 CenterContainer；autowrap Label 给确定正宽度；F5 内嵌运行不可用 → 独立窗口。
- 工具链顺序：`fix_import_paths.py` → `check_data_refs.py` → `find_orphans.py`（**孤岛 ≠ 可删**）→ `gd_static_lint.py` → 实机。查引用要查全工程（预制体在 `tscn/prefab/`）；二进制 `.res` 内部字符串 grep 不到且带长度前缀 → 改路径长度会损坏，只能编辑器拖拽更新；**引用者自身可能是死的**。绝不 `cat` 大 .tres → head/grep；体积用 `os.path.getsize`（`du -sk` 虚报近一倍）。
- **判断"某物品在游戏里是否可得"的唯一权威＝`script/crafting/crafting_system.gd` 配方表 + 掉落/初始背包**，不是 `script/items/data/*.tres` 列表——遗留 .tres 会长期挂在 `item_registry.tres` 且被测试脚本当夹具引用，看着像活的实为死数据。**加档位/写进说明书前先查配方表**。

## 四、位置与距离（易错重灾区）

- **算「玩家到某物」距离必须取 `Physics` 子节点（或 `ViewFrustum.player_position()`），绝不读 `player` 根节点的 `global_position`**：根节点从不位移、永停在出生点，动的是它的 `Physics`(CharacterBody3D)。2026-09-22：采集中断判定读根节点 ⇒ 距离恒为"出生点→资源"(≈59 m) ⇒ 每下都判"走远" ⇒ 全资源采不动。ClickMover 的 `get_parent()` 就是根节点。

## 五、分辨率与 UI 布局

- 1280×720 + `canvas_items` + `expand` + `fractional` ⇒ 设计视口恒 1280×720；GraphicsConfig（静态 → `user://graphics_config.cfg`）管全屏/窗口/界面缩放 0.7~2.0/垂直同步/帧率上限。
- **贴视口边缘锚定（2026-09-24 事故，必守）**：`ui_scale`（→ `content_scale_factor`）>1 会把**逻辑视口缩小**（1.05 ⇒ 1219×686），**写死绝对 x/y 的控件全被裁出屏幕**（玩家报"装备栏超出屏幕"，静态 lint 查不出）。规则：**右列/底部控件一律 `anchor_*=1.0` + 负 offset**（按钮列/状态栏/小地图列/装备栏 `offset_right = -RIGHT_MARGIN`；快捷栏贴底），只有左列/中列用左上锚 + 绝对 offset。改布局后必跑 `test/ui_grid_layout_check.py`（纯 Python 复算，第 5 节专查锚点）+ `ui_grid_layout_test.gd`（临时把 `content_scale_factor` 调到 1.05 复测不越界）。中文 ASCII 图按 `east_asian_width` 排（`test/_gen_layout_art.py`）。**九宫格分区与全部数值 → 详章**。
- 碰撞层只有两层有名字：layer_1＝玩家、layer_2＝地面/障碍；**障碍物一律 layer2 + mask0**（建筑、树干同约定）。详见详章。

## 六、玩家 / 相机 / 战斗（易错点）

- `player`(Node3D) → `Physics`(CharacterBody3D, `take_damage`/`heal`) + Inventory/Equipment/Vitals/ClickMover；相机在 `player/Camera_controller/…/Camera3D`。机位/俯角/Sprite3D 属性表 → 详章。
- **贴图朝向＝`script/visual/sprite_facing.gd`（静态）**，树/玩家/史莱姆三处共用，`billboard` 全关；树用 `facing_transform`、角色/敌人用 `facing_basis` 只覆盖 Visual 的 basis（**别连位置一起写**，会抵消渲染插值）。引用一律 `const Facing := preload("res://script/visual/sprite_facing.gd")`。
- **左右翻转符号（换朝向系统必查）**：`flip_h` 语义取决于该实体自带的镜像次数，**不同实体可能相反、不能互抄**。玩家净剩一次水平镜像 ⇒ `spr.flip_h = not facing_left`；史莱姆无内置镜像 ⇒ `sprite.flip_h = _facing_left`，且判据必须用**相机右方向**（`cam.global_basis.x`）而非世界 X。`sprite_facing_check.py` 第 3/4 项核这个。
- **yaw 必须落在 `rotate_step_degrees`(45°) 整数倍**；松手 `snap_yaw_to_step()`，读档 `_apply_camera` 也要；`_wrap_yaw()` 把 `_yaw`/`_target_yaw` 移回 `[0,2π)`。
- 玩家碰撞体仅 1.0 m 高（精灵 1.48 m）⇒ 平行地面的投射物/射线必须飞 y ≤ 1.2；鼠标点地走**解析求交**，故加碰撞体不影响点击寻路。数值 → 详章。

## 七、世界 / 资源 / 容器（框架 + 指针）

- **采集只有一条路**：`work_amount` ÷ 工具 `harvest_work` ＝ 要采几下；走远/死亡中断但**进度保留**并存档（`work_remaining`）。工具门槛＝`allowed_tool_tags` vs 物品 `tags`，**留空＝空手可采（每击 1）**；**在役工具只有 4 把**（石斧4/石镐4/铁斧6/铁镐6）。作业动画＝SpriteFrames 的 **`harvest`**（不借 attack、不触发伤害），`is_working` 六处配对。地图尺度/区域映射/数值/流式 → 详章。
- 资源实体：**8 种里只有 tree 用专用预制体**，其余走 `tscn/resource_entity.tscn` + `ResourceData.growing_texture`（**8 种全未配贴图 → 程序化兜底网格**）。**兜底判据＝「sprite 是否带 SpriteFrames」**，不是「growing_texture 是否为空」（否则贴了真帧动画的树会被再叠一套网格）。
- 卸载/挂起一律**复用节点**（对象池 or `remove_child`），绝不 queue_free，否则状态丢失。
- **数据层唯一入口＝`Inventory` 静态方法**（UI 只发信号）：`transfer_between`（`count<0` 整堆 / `>0` 拆堆）/ `stash_into`（自动找位、**用实例本身**故核心电量不丢）。
- **四块信息面板（背包/箱子/合成/装备）各占固定区、可同刻全开**（旧 `WINDOW_PANELS` 互斥已废 → `LAYOUT_PANELS`），只有全屏类打开才收它们；面板一律 `anchor=0` + 绝对 `offset`。改这条必须同步改 `ui_smoke_test.gd` §5b。快捷键：**背包内 Shift+左键存入 / Ctrl+拖拽只拿 1 个 / 箱内右键取1·Ctrl取半·Shift全取**；修饰键点击须**延后到松开且未拖拽**再判定，拖拽字典带 `count`。
