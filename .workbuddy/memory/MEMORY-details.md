# 项目长期记忆 · 详章（低频但详尽）

> 2026-09-18 从 `MEMORY.md` 拆出，因为主文件超出注入预算被截断。需要细节时读本文件；`MEMORY.md` 只有指针和高频条目。

## 角色 / 温度 / 电量
- `character_registry.gd`（静态）唯一权威：DEFAULT_ID="adventurer"、PORTRAIT_REGION、BASE_*（仅面板显示）；adventurer/witch/robot + 测试 knight/guard/scout（借前 3 者精灵表）。
- 温度＝两属性。**温度值 0~1000**（初500，不伤人）由区域系数推动：只有**火山+6/雪地−6**；系数0时 `move_toward(500)` ±10/s，体温自然回温 30（10/分，唯一回温），熔炉热源 +20/s。**档位→体温速度**：<100 −2 / <350 −1 / <650 0 / <900 +1 / ≥900 +2 °/s，用**帧初**温度值判定。体温 −100~100 越界 0.5HP/s ＋**有内置电量者**再 0.5 电/s。HUD 只显示体温。
- 电量两条线。①自身 `vitals.current_power`：仅 `power_embedded`（robot 内置、不可关）可用→归零掉血、低电×0.7 减速、>80且吃饱回血、体温越界漏0.5/s；外置零影响。②核心 `PowerCoreInstance.power` 挂**物品实例**，随物品在背包↔装备槽↔掉落物流转**引用不变**（拆下重装电不满）；仅核心温度值越界（<350过冷/>650过热）时 −0.5/s（`PowerCoreSystem`，共用温度场）。**掉落物也带 `instance`**，`_tick_core` 用它自身坐标推进核心温度值。
- `has_power`＝只读属性＝`power_embedded or 装了核心`；读 `vitals.has_power`，别用 `CharacterRegistry.has_power()`；已删 `set_has_power()`，装备变化走 `vitals.on_core_changed()`。HUD 两行：`⚡`自身（占位，仅内置）/`🔋`核心（有才显示，青蓝 CORE_ROW_COLOR）——**别改回 visible=false**（VBox 忽略隐藏控件尺寸→面板变矮），高度用 `reset_size()`。
- 动力核心：`EquipSlot` 末尾加 `CORE`；`power_core_item.tres` 带 `carries_power`+`unlocks_core_tab`；装备槽存 ItemInstance（`get_item` 返 data、`get_core_instance` 取实例）；`inventory.take_item_instance()` 整件取走；入口＝装备面板四槽。存档存实例字典（兼容老档纯 item_id）；**装备恢复排在 Vitals 之前**，收尾**无条件** `resync_core_state()`；`core_tab_unlocked` 静态→`equipment._ready` 必须重置。
- 换装＝换精灵表底层贴图（448×392/8列×7行/56px）：`_swap_sprite_atlas()` 深拷贝 SpriteFrames 只改 AtlasTexture.atlas（**勿直接改 spr.sprite_frames**）；新 PNG 须编辑器导入 + `ResourceLoader.exists()` 守卫。三表逐帧 alpha 轮廓实测**零差异**（纯换色），`test/player_anim_check.py` 第 6 项常驻核对。
- 精灵表 7 行的实际语义：0 idle / 56 attack（末段带白剑光弧）/ 114 walk（单帧 56×57，非 112）/ **168+224 持械行走 16 帧（首尾各有一帧「俯身」，不是空行——旧 README 写"空的"是错的）** / 280 hurt / 336 die。玩家 6 个游戏内动画：idle·walk·attack·**harvest**·hurt·die。
- 存档 `SaveManager.create_slot(name,roll,character_id)` 写 meta.character_id，老档缺→默认角色；physics._ready 早于 HUD→`hud_ui._ready` 补 `_bind_health()`；`_apply_character()` 在 `spr.play("idle")` 前。
- 专属栏：Category 末尾 SURVIVAL/ALCHEMY/MACHINE/**CORE** + FIRST_EXCLUSIVE=5 + **LAST_EXCLUSIVE=7**（漏上界→新分类掉进角色过滤分支而**永不显示且不报错**）；crafting_ui 动态建标签 + `_tabs_char_id`/`_tabs_core_unlocked` 双哨兵；归属映射 CRAFT_CATEGORY_OWNER；权限 exclusive_owner/access_policy/owner_bonus_mult 执行点 ItemEffects，**只卡"使用"**。饱食度满时整次进食作废。未实装：冒险家能力/魔女制药/专属制作站/专属装备权限。

## 建造 / 存档 / UI
- 建筑：工作台 wood×10/熔炉 rock×20+5m 热源+20/s/储物箱 wood×8+20格；`Building.spawn()` 无 tscn；碰撞 layer2。
- **存档 v2 地形存快照**：`map_data`(1600²)→DEFLATE+base64≈14KB 写 `map` 段（+尺寸+hash）；`request_load` 解压进 `pending_map_tiles`，`_apply_terrain_snapshot()` 生成后**覆盖**，用完即清；老档无 `map` 段→按种子重算。敌人按 get_path_to 记路径，存档里没有＝已击杀；重建建筑前清光 Building + `BuildingSystem.clear()`。
- 快捷栏＝背包前9格镜像；UI 不改背包数据，拖放走信号。Esc 只归 UIManager 栈，Tab/C/B 归 hud_ui；世界点击三处 _input 都要 `gui_get_hovered_control()==null` 守卫；**四块布局面板（`LAYOUT_PANELS`＝背包/合成/装备/储物箱）各占固定区域，可同刻全开**；HUD＝左列面板区＋**右上角小地图/时钟与按钮列/状态栏**＋右列下半装备栏＋底部快捷栏，MinimapUI 不进面板栈。
- 地图：MapView 基类 ← MinimapUI/BigMapUI（M 键、暂停）；底图 static 共享+分帧生成；**M 键监听在 UIManager._input**；罗盘 `_map_angle=atan2(fwd.x,fwd.z)+PI`，换算经 _rot2/_rot2_inv；储物箱跨面板拖 source_id + `cross_dropped` → `Inventory.transfer_between()`。

### 九宫格布局数值（2026-09-24，经三次改版）
- **⚠ 锚点分两类（三改核心）**：**右列 + 底部贴视口边缘**（`anchor_* = 1.0` + 负 offset），**左列 + 中列**照旧左上锚 + 绝对 offset。原因：`GraphicsConfig.ui_scale` → `window.content_scale_factor` >1 时，`canvas_items` + `expand` 把**逻辑视口缩小**（1.05 ⇒ 1219×686），写死绝对坐标的右列/底部会被裁出屏幕（玩家报"装备栏 UI 超出屏幕"）。改布局后必跑 `ui_grid_layout_check.py` 第 5 节（它把这些锚点固化成断言）。
- **`hud_ui.gd` 常量**：`MARGIN=10`、`LEFT_COL_LEFT=10 / LEFT_COL_RIGHT=502`、`MAP_COL_LEFT=510 / MAP_COL_RIGHT=786`、`RIGHT_COL_LEFT=794 / RIGHT_COL_RIGHT=1270`、**`RIGHT_MARGIN := 1280 − RIGHT_COL_RIGHT`（=10，右列贴边距）**、**`PANEL_W=412`（左列三块统一宽）、`PANEL_GAP=8`（左列块间距）**、`CONTENT_BOTTOM=626`（**只管左列/中列**）、`HOTBAR_TOP=634 / HOTBAR_BOTTOM=710`。右上角组合块另起一组：`BTN_COUNT=3`、`BTN_W=160`、`BTN_H=32`、`BTN_SEP=6`、`BLOCK_GAP=8`、`BTN_COL_BOTTOM := MARGIN + (BTN_H+BTN_SEP)*BTN_COUNT − BTN_SEP`（=118）、`CLUSTER_BOTTOM=274`、`STATUS_WIDTH=160`、`STATUS_TOP := BTN_COL_BOTTOM + BLOCK_GAP`（=126）。**派生量写成表达式**（改按钮数/高度时状态栏自动跟随），`ui_grid_layout_check.py` 能解析这种表达式常量。
- **面板**（2026-09-24 第四次调整：物品格缩到 36 后左列三块跟着收窄上移、铺满到 626）：`inventory_ui.RECT_INVENTORY = Rect2(10, 10, 412, 182)`；`storage_ui.RECT_STORAGE = Rect2(10, 200, 412, 162)`；`crafting_ui.RECT_CRAFTING = Rect2(10, 370, 412, 256)` —— **这三块 `anchor_* = 0.0` + 绝对 offset，统一宽 `PANEL_W=412`、块间距 `PANEL_GAP=8`**。`equipment_ui.RECT_EQUIPMENT = Rect2(850, 370, 420, 340)`（三改从 `794,284,476,426` 缩到此值），**`anchor_*` 全 1.0**、`offset_* = RECT_* − DESIGN_SIZE(1280,720)`（⇒ 1280 视口下正好落在 RECT，视口缩小则整体往左上收）；顶让开小地图列、底贴 `HOTBAR_BOTTOM=710`。
- **HUD（右上角组合块）**：快捷栏**贴底**（`anchor_top=anchor_bottom=1.0`，`offset_top=HOTBAR_TOP−720=−86 / bottom=−10`）+ `grow_horizontal=BOTH`，`offset_left=offset_right=(10+786)*0.5−640=−238`（中心 640→398），槽 **52×52**（另标 `size_flags_vertical=SIZE_SHRINK_CENTER`——容器高 76 而槽只有 52，不写这行 HBox 会把它沿交叉轴拉成 52×76 的长方形），横向只占 x148~648。状态栏**贴右边缘**：`anchor_left=anchor_right=1.0`、`offset_right=−RIGHT_MARGIN(−10)`、`offset_left=−(STATUS_WIDTH+RIGHT_MARGIN)=−170`、`offset_top=STATUS_TOP(126)`（按钮列正下方），排版 `STATUS_FONT_SIZE=14 / STATUS_ROW_SEP=4 / STATUS_PAD=8`（可用高 `126..370` = 244px，5 行最坏 ≈132px）；`_update_status_panel_size()` 在 `reset_size()` 后**再把两条 offset 重钉回贴边**（防内容变宽把右边缘顶出视口）。`_create_topright_cluster()` 生成的 **`TopRightMap`**（原 `TopCenterMap`）：`offset_right = −(BTN_W+BLOCK_GAP+RIGHT_MARGIN) = −178`、`offset_left = −390`（⇒ 1280 视口下 x890~1102，与按钮列留 8px），内含小地图 212×232 + 时钟 28 高，列底 274；**必须和按钮列一起贴右**，否则视口缩小时两者叠住。`_create_button_column()` 生成的 `TopRightButtons`：`offset_left = −(BTN_W+RIGHT_MARGIN) = −170`、`offset_right = −10`（⇒ x1110~1270），暂停/大地图/小地图竖排各 **160×32**、间距 6。吐司在中列 x510~786、y556~582。
- **右下角操作提示（`ControlHints`）已删除**（2026-09-24 用户要求"删掉后装备栏下移"）：`_create_control_hints()` / `update_control_hints()` / `_hints_label` 全删，只剩 `hud_ui.gd` 里一段 tombstone 注释；`ui_smoke_test.gd` 与 `ui_grid_layout_check.py` 都加了"源码里不该再创建它"的反向断言。按键说明只在暂停菜单 / `大纲.md` 6.4 查。
- **校验工具**：`test/ui_grid_layout_check.py`（纯 Python 读源码常量复算几何，**不用起引擎**，**77 项**；含 `CLUSTER_BOTTOM` 与 `minimap_ui.gd` 尺寸的交叉核对；**第 5 节专查"右列/底部贴视口边锚定"，第 6 节把物品格尺寸固化成断言**）+ `test/ui_grid_layout_test.gd`（实机量真实 `Rect2`；开头显式把 `root.content_scale_factor` 归零以保证 1280×720 设计视口，**末段再临时调到 1.05 复测四个贴边控件不越界**）。画示意图用 `test/_gen_layout_art.py`（按 `east_asian_width` 排，中文才不会错位）。
- **尺寸压缩史**：背包/箱子 9 列×60 → 10 列×44 → **10 列×36**（`@export var slot_size`；10×36+9×4=396 + 左右各 8 = `PANEL_W`）；共用槽默认 64 → **52**、贴图 margin 4→**3**、数量字号 14→**12**、拖拽预览 48→**40**；装备栏槽 box 190×60 → 110×60 → **均分内容宽**（`SIZE_EXPAND_FILL`，420 宽下每格约 94）、图标 40→32→28→**24**、可点区高 40→**34**；合成详情图标 40→**32**；制作栏列表 Scroll (150,100) + 详情包进 `detail_scroll (170,100)`。
- `ui_manager.gd`：`WINDOW_PANELS` → `LAYOUT_PANELS`；`open_panel_impl` 只在 `FULLSCREEN_PANELS.has(name)` 时 `_close_group(LAYOUT_PANELS, "")`；删掉 `_inventory_borrowed_by_storage` / `_borrow_inventory_for_storage()` / `_set_inventory_companion_layout()` 与 `inventory_ui.set_companion_layout()`。

### 容器交互：背包 / 箱子 / 快捷栏（2026-09-23 新规则）

- **数据层唯一入口＝`Inventory` 的静态方法**（UI 只发信号、不碰数据）：
  - `move_item(from, to)` —— 同容器格内整理；
  - `move_between(...)` —— 整堆搬运，向后兼容旧调用（内部转调 transfer_between 的 `count=-1`）；
  - **`transfer_between(from_inv, from_slot, to_inv, to_slot, count=-1) -> int`** —— `count<0` = 整堆；`>0` = 只搬这么多（会拆堆）；**允许 `from_inv == to_inv`** 做同容器拆堆。落点三种行为：空位放下 / 同类合并 / 异类只在"整堆"时才交换（部分搬运遇异类 = 不做）。
  - **`stash_into(src, from_slot, dst) -> int`** —— **无目标格**：先合并同类、再找空格、超出 `max_stack` 就拆多格。**用物品实例本身**搬（不是新建），故动力核心的电量/温度不丢。
- **拖拽数据字典带 `count`**：`ItemSlotUI._get_drag_data()` 返回 `{"from_slot","source","count"}`；拖拽时按 **Ctrl ⇒ count=1**，预览框显**青色**数量（整堆为白）。`item_dropped` / `cross_dropped` 两个信号都带 `count`。
- **修饰键点击必须延后到"松开且没拖拽"再判定**：`ItemSlotUI` 用 `_pending_click_button`（带修饰键按下时先存着不立刻发信号）+ `_press_dragged`（在 `_get_drag_data` 里置位）；松开时 `if _pending_click_button >= 0 and not _press_dragged` 才 `clicked.emit`。**否则 Ctrl 一按下就整堆转账、直接抢掉拖拽。**
- **四块信息面板各占固定区、可同刻全开**（2026-09-24 起旧 `WINDOW_PANELS` 互斥废掉 → 改名 `LAYOUT_PANELS`）；只有 `FULLSCREEN_PANELS`（暂停/设置/调试/画面/大地图）打开时才 `_close_group(LAYOUT_PANELS, "")` 收掉它们。`_borrow_inventory_for_storage()` / `_inventory_borrowed_by_storage` / `set_companion_layout()` 均已删除。
- 布局：背包与箱子都在左列（`RECT_INVENTORY` / `RECT_STORAGE`，见上文），槽位 **36×36**。快捷栏槽 `source_id="player"`（与背包同源才能互拖）。
- 快捷方式总表：**背包内 Shift+左键 = 快速存入箱子**（走 `stash_into` 自动找位）；**Ctrl+拖拽 = 只拿 1 个**；**箱内右键取 1 / Ctrl 取半 / Shift 全取**。
- 常驻核对：`test/signal_arity_check.py`（信号参数个数）、`test/storage_transfer_test.gd`（搬运语义 13 例）。

## 数据表 / 枚举 / 日志约定

- 数据表字符串标签 ≠ 已实装；枚举只能末尾追加（.tres 存数字）；对外集合 `.duplicate()`；只走 `DebugConfig.log_msg/warn_msg`。
- 地形号：7 海 / 8 沙滩 / 10 草原 / 11 丛林 / 12 矿区 / 13 沙地 / 14 火山 / 15 雪地。

## 美术资产
- 规范＝`美术资产规范.md`；目录说明＝`art/README.md`、`_source/README.md`、`player/README.md`、`props/tree_1/README.md`。
- **两层结构**：生产层 `icons/`(27 png)、`player/`(3 精灵表)、`enemies/`(6 png，全在用)、`props/tree_1/`(25 帧+tree_frames.tres)；隔离层 `_source/`（第三方包，1687 张）。**art/ 不放 .blend/.psd**（Blender 源在工程外 `E:\GameMake\loss\blender_art\`；`_source/` 内第三方 `.aseprite` 例外）；3D 模型落点 `art/models/`。**生产层只留被引用的**，未引用帧（如 `Mushroom without VFX/`）归 `_source/_loose/`。
- **被引用目录（改动前必查）**：`icons/`(33 处 item .tres)、`player/<角色id>/`(`character_registry.gd` 6 条 sprite+`player.tscn` 默认外观)、`enemies/Forest_Monsters_FREE/`(`slime.tscn` 6 张)、`props/tree_1/`(`tree.tscn`+`tree_frames.tres`)。
- **图标命名硬规则**：`art/icons/<物品id>.png` 与 `script/items/data/<id>_item.tres` 的 id 一致（**30 物品/24 图标**，6 个借图，repair_kit←workbench.png 最误导）；唯一脱节＝`wood_item.tres` 指向 `log.png`（补 wood.png，别改 log 名）。`icons/`(56px 面板图标) 与 `props/`(世界资源物外观) 分开，别按材质分。
- 2026-09-18 已清理（可回滚）：`E:\GameMake\loss\trash_2026-09-18\`(812 文件/15.41MB，含 `grass_entity.tscn`、`tileset_test.res`)；`oak_woods_v1.0`→`art/_source/`；`tree_1.blend`+`.import`→`blender_art/`；备份 `E:\GameMake\loss\art_backup_2026-09-18`。
- **插件（2026-09-22 已清）**：原有 5 个全零调用（PhantomCamera/StateChart/CSVData/TileMapLayer3D；相机是自研 `script/player/camera_3d.gd`）。`TileMapLayer3D`/`phantom_camera`/`godot_state_charts`/`csv-data-importer` 已移入 `trash_2026-09-18/dead_plugins/`，`addons/` 只剩 `script-ide`（留）。**纠正旧记**：`project.godot` 里**既没有** `[editor_plugins]` **也没有** `[autoload]`（全文 176 行核过），5 个插件从未真正启用过 ⇒ 删插件**不需要**改 `project.godot`、也不会启动报错；先前"不删 `[autoload] PhantomCameraManager` 就报错"的说法是自己吓自己，已同步改正 `项目结构说明.md` §1.1/§11/台账21。
- 废弃场景：`tscn/prefab/grass_entity.tscn`（**仍在工程内**，9-18 与 9-22 两次移出都被编辑器写回，须先关标签页）、`tscn/test.tscn`（已移入 `trash_2026-09-18/dead_scenes/`）、`script/ui/probe_ui.gd.uid`（孤儿 uid，已移出）。

## 相机 / 贴图朝向 / 渲染属性

- 相机 `base_fov=50`；机位＝`_focus + Vector3(0,sin(俯角),-cos(俯角))*(9.434*zoom)` 后 `look_at`；俯角 30°(zoom0.6)~55°(1.8)，默认 1.0≈38°。
- **精灵局部 +X 的朝向**：`SpriteFacing` 的 +X == 相机右方向（与引擎 billboard 同侧）；旧的 `look_at(相机方向)` 的 +X == −相机右方向（镜像）。换朝向系统时这两者不能混。
- **`flip_h` 符号表（换朝向系统必查，2026-09-22 踩过）**：语义取决于该实体节点自带的镜像次数，**不同实体可能相反、不能互抄**。玩家 `player.tscn` 的 BaseBody 烘了 `scale(-2.6434,…)`（绕 Z 转 180°）+ `flip_v=true`，两者抵消后**净剩一次水平镜像** ⇒ **`spr.flip_h = not facing_left`**（true=屏幕上朝右）。史莱姆的 Sprite 是单位变换、无内置镜像 ⇒ **`sprite.flip_h = _facing_left`**（true=朝左），且判据必须用**相机右方向**（`cam.global_basis.x`）而非世界 X，否则 Q/E 转镜头 90° 后左右就反。`test/sprite_facing_check.py` 第 3 项核手性、第 4 项核这两个符号。
- **Sprite3D 实查**：`shaded` 默认 **false** ⇒ 不吃光照。`billboard`：0=关（**本项目一律 0**，朝向交给 SpriteFacing）、2=FIXED_Y（只跟 yaw、高俯角下被压扁 cos 值）、1=ENABLED（随俯角倾倒）。`alpha_cut`：**2 = OPAQUE_PREPASS（边缘软 + 排序正确）**、0 混合（排序问题）、1 DISCARD（边缘硬，未开 AA）。`render_priority` 仅 `alpha_cut=0` 有效。**精灵是双面渲染的平面**，屏幕上左右只看局部 +X 落在哪一侧。

## 攻击 / 伤害 / 死亡

- 攻击＝`intersect_shape(mask=0xFFFFFFFF, 最多10个)` + 沿父链找 `take_damage`；判定体＝半径 2 m、360° 竖直圆柱（高 2.6、中心 y=脚下+1.0）。**不用 `visual_node.basis` 当朝向**（广告牌）。敌人受击靠 Area3D；无人机无碰撞（layer/mask 全 0，`anchor_on_ready` 须在 `add_child` 前）。该查询对所有层生效 ⇒ 新增碰撞体会占名额。
- 死亡：HP=0/落水 → `_on_death()`（幂等）→ RespawnSystem + `FilterSystem.DEATH`，HUD 5 s → `revive()`；敌人判定统一 `Physics.is_alive()`。死亡冻结温度值；复活半属性：HP/饱食度/自身电量各半、体温常温、`reset()` 清零核心、`revive()` 半血 `maxi(int(max_health*0.5),1)`。

## 采集数值 / 区域资源 / 资源实体

- 区域→资源 `task_system.REGION_RESOURCE_MAP`：草原/丛林=twig·grass·tree·berry·pebble；矿区=pebble·stone·iron_ore；火山=coal·iron_ore；雪地/沙地/沙滩=twig·pebble。**石头只在矿区、煤只在火山**；`wood`＝"木材"；树要斧、大石/矿要镐；采集入口 `ResourceManager._try_harvest_nearest()`（水平 3 m、不挂 Area3D、只采最近一个）。
- 采集数值：`work_amount` 树/大石头/铁矿/煤矿均 24（**石 6 下 / 铁 4 下**），草/木棍/浆果/小石块 = 1（挥一下就掉）；间隔 0 / 0.2 / 0.4 / 0.3。
- 碰撞层补充：`ResourceSpawner.obstacle_layers=[4]`（层 3）、水体在**层 8**。
- 作业动画 `harvest` 的 SpriteFrames 帧坐标：取自玩家精灵表**第 4 行 y=168**，`Rect2(56,168)`（抬臂）↔ `Rect2(0,168)`（俯身），共 3 帧、`loop=0`、`speed=5`。
- 资源实体＝`ResourceEntity`(Node3D) + 组件 StateMachine/Visual/Interaction/Regeneration。**8 种里只有 tree 用专用预制体**，其余走 `tscn/resource_entity.tscn` + `ResourceData.growing_texture`（都未配 → `_build_placeholder_mesh()` 兜底）。**兜底判据是「sprite 是否带 SpriteFrames」**，不是「growing_texture 是否为空」，否则贴了真帧动画的树会被再叠一套网格。
- `tscn/prefab/tree.tscn`：根 Node3D(`resource_entity.gd`+`tree_data.tres`) / `Sprite`(AnimatedSprite3D，**billboard 0**——朝向由 `resource_visual.gd::_apply_facing` 每帧接管、`alpha_cut 2`) / `Visual`(`resource_visual.gd`，`sprite=NodePath("../Sprite")`) / `CollisionBody`(CharacterBody3D layer2 mask0) + `CollisionShape3D`(Cylinder r0.45 h2.0 中心 y1.0)。帧动画＝`art/props/tree_1/tree_frames.tres`（`growing` 单帧 / `chop` 25 帧@30fps 不循环 / `sway` 25 帧@7fps 循环备用），`ResourceData.harvest_animation` 指定砍伐动画名。**尺寸耦合**：`pixel_size=0.004` ⇒ 贴图矩形 4.0×4.8 m、内容高 3.5 m；Sprite `position.y=1.756` 让树干底落 y=0（**改 pixel_size 必须重算**）。那 25 帧实为风摆循环（帧0=帧12=帧24），非砍伐形变。

## 世界 / 采集框架 / 流式加载（补充）

- 地图 **1600×1600**，岛半径 ≈430，出生点＝中央草原；海洋格无碰撞 ⇒ 掉海即自由落体（触发死亡）。
- **采集只有一条路**（2026-09-18 统一）：`work_amount`（资源血量）÷ 工具 `harvest_work`（每击伤害）＝要采几下。`_harvest_by_work()` 每下＝资源播 `harvest_animation` + 人物播作业动画 + 等 `work_interval` + 扣一次工作量，扣完才掉落；走远/死亡中断但**进度保留**，随记录层存档（`work_remaining`）。旧的一次性 `_harvest_once` / `harvest_time` / `required_tool` / `harvest_speed_bonus` / `get_harvest_speed_multiplier` 全删。
- 工具门槛＝资源 `allowed_tool_tags`（树 `axe`、大石头/铁矿/煤矿 `pickaxe`）vs 物品 `tags`，**留空＝空手可采**，没有任何旧判定兜底；空手每击 `HAND_WORK_PER_HIT=1`。**在役工具只有 4 把**：石斧 4 / 石镐 4 / 铁斧 6 / 铁镐 6（均有配方）。`ItemData.tool_type` 只剩说明文案用途。
- `is_working` 的**六处配对**（play 置位 / finished 清 / 移动让位 / 攻击抢占 / 死亡 / 复活）＝作业动画独占标志位；漏一处就会被 `physics._update_animation()` 每帧的 `else: spr.play("idle")` 切走。
- 流式 `ViewFrustum`：LOAD_RADIUS = {resource / enemy / building: 70, drop: 50}，HYSTERESIS = 24；判定＝距玩家**平面**距离（勿用屏幕视锥）。资源 `_records`(数据) ↔ `_entities`(表现)，卸载退对象池**绝不** queue_free，存档源＝`_records`。敌人/掉落物挂起＝`remove_child`（保状态），放回＝`add_child` + 设 `global_position`，**绝不重建**。
- 碰撞层只有两层有名字：layer_1＝玩家、layer_2＝地面/障碍；玩家与史莱姆 `collision_mask=3`。**障碍物一律 layer2 + mask0**（建筑、树干同约定）；`ResourceSpawner.obstacle_layers=[4]`（层 3）、水体在**层 8**。
- 玩家碰撞体**仅 1.0 m 高**（h=1.0 / r=0.33）但精灵 1.48 m ⇒ 平行地面的投射物/射线必须飞 y ≤ 1.2。地形＝单个 StaticBody3D 挂多段薄盒（厚 1.0、中心 −0.5）⇒ 岛面恒 y=0。
- 鼠标点地＝相机射线与"玩家脚下高度水平面"**解析求交**（`_ground_point_under_mouse`），**不走物理射线** ⇒ 加碰撞体不影响点击寻路。

## Boss / 沙虫（2026-09-24 实装骨架，未上美术）

> 规格＝`loss-land/主线设计规格.md`（§3 为已实装清单）；结构说明＝`项目结构说明.md` §4.9；回归＝`test/boss_state_test.gd`（46 断言）。

- 类（均 `class_name`，已补进 `.godot/global_script_class_cache.cfg`）：`script/ai/enemy/boss/boss_state.gd`（`BossState`，9 态枚举 RefCounted）、`boss_attack.gd`（`BossAttack`，Resource，`BossAttack.make(dict)`）、`boss_base.gd`（`BossBase extends CharacterBody3D`）、`sandworm.gd`（`Sandworm extends BossBase`）；`script/world/world_state.gd`（`WorldState`，纯静态 flag）。
- **必须走独立 `"boss"` 组，绝不能进 `"enemy"` 组**：`map_generator_3d._place_enemies()` 会把所有 `"enemy"` 组节点搬去丛林；且 `save_manager`/`world_streamer` 对 enemy 的语义是"不在档＝已击杀"，对 Boss 恰好相反。
- 状态枚举：`DORMANT/EMERGING/CHASE/TELEGRAPH/STRIKE/RECOVER/RETREAT/FALLEN/GONE`——**没有 `dead`，终态是 `GONE`**；`SAVE_IDS`/`LABELS` 只允许**末尾追加**（枚举存数字）。`can_be_hurt` 只在 CHASE/TELEGRAPH/STRIKE/RECOVER 为真。
- **阶段切换是隐式闩锁**：没有 `_phase` 字段，`_current_table()` 只在决策点调用 ⇒ 攻击中途不会换表。规则＝按优先级取第一个「`cooldown_left==0` 且玩家在 `[min_range,max_range]`」的技能；**一个都没有 → 回 CHASE**（没有 idle/空放）。
- 距离一律取 `player/Physics`（`CharacterBody3D`），**不读 `player` 根节点**（见主文件铁律四）。`take_damage` 首行 `_untouchable`/`can_be_hurt` 守卫 ⇒ 防同帧多段伤害穿透保底的 1 HP（玩家 `intersect_shape(...,10)` 一击可命中多个碰撞体）。
- 保底 1 HP → `_enter_fallen()`（一次性，写 `WorldState` 巢穴塌陷 flag）→ `_process_going_home()` 到底后转 `GONE`；`RETREAT` 与 `FALLEN` **共用** `_process_going_home()`，区别是 RETREAT 可重复、不写世界状态。玩家死亡 → `_on_player_died` → RETREAT 回家**回满血**再 DORMANT。
- `RETREAT`/`FALLEN` 回家途中「太远（`leash_radius` 超时）或玩家死」→ 回家；`trigger_radius`+`trigger_dwell` 决定唤醒。
- **测试场地**：`tscn/sandworm_test.tscn`（根脚本 `test/sandworm_arena.gd`）＝平地 90×90 + player + 巢穴 + 调试面板；场地圆环在**运行时按 Boss 的 `@export` 半径生成**（所以改数值圆环会跟着变）。必须带 `test/arena_flat_map_gen.gd`（`add_to_group("map_gen")` 的桩，因为 `physics.gd`/`vitals.gd` 要查地形组）。**只能用 F6 独立窗口跑，F5 内嵌运行不可用**。
- 按键：T 传送到巢边 / H 传送到远处 / K 杀玩家 / W `debug_wake()` / 1→60% 血 / 2→40% 血 / 9→1 HP / R 重置（`WorldState.reset()` + 复活）。查询接口：`get_state/get_health/current_phase/current_attack_id/debug_line`。
- `test/mock_boss_target.gd`（`signal died`、真会死）与旧的 `mock_player_body.gd`（"挨打但不死"）**语义不同，别混用**。
- `BossBase._face(dir)` 目前只转占位 `Visual` 的 yaw——**上真美术（SpriteFacing）时必须删掉它**，否则会和 `sprite_facing.gd` 抢朝向。
- 待办（见 `待办.md` 与规格）：存档 `world.bosses`/`world.flags` 段（别碰现有 `_collect_enemies`）、新游戏/回主菜单时 `WorldState.reset()`、巢穴实体（读 flag 切 完好/坍塌/可进入）、沙虫真美术与沙地战场；三个待拍板＝阶段 2 表是"3+1 新"还是"4 全换"、是否要"钻地无敌"阶段、`GONE` 后能否再挑战。全部数值（trigger_radius/leash/chase_speed/各技能 range 与时长）均为 `@export` 建议值，**未经用户确认**。

## 文件同步清单（批量改名 / 删除 / 移动 .gd 与物品时）

- **删一件物品同步 5 处**：① `script/items/data/<id>_item.tres`；② `item_registry.tres`（`ext_resource` 行 + `items` 数组条目）；③ `art/icons/<id>.png` + `.import`（**移到 `E:\GameMake\loss\trash_*\`，别硬删**）；④ 测试夹具里的 `&"<id>"`；⑤ `项目结构说明.md` 物品表。删完 `check_data_refs.py` 会报物品数变化，可当校验。
- **移动一个 .gd 同步 5 处**：① 同名 `.gd.uid`（一起移）；② 文件首行注释里的路径；③ 引用它的 `.tscn` 的 `ext_resource` 路径；④ `test/*.gd` 里的 `load()` 路径；⑤ `.godot/global_script_class_cache.cfg`。`.godot/editor/*` 里留的旧路径**别改**（编辑器自己会更新）。
- **新增 `class_name`**：补 `.godot/global_script_class_cache.cfg`（`gd_static_lint.py` 第 4 项会查），或在使用处写 `const X := preload("res://…")` 直接绕开缓存（编辑器开着时缓存可能未重扫，这样最稳）。
