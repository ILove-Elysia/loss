# 项目长期记忆 · 详章（低频但详尽）

> 2026-09-18 从 `MEMORY.md` 拆出，因为主文件超出注入预算被截断。需要细节时读本文件；`MEMORY.md` 只有指针和高频条目。

## 角色 / 温度 / 电量
- `character_registry.gd`（静态）唯一权威：DEFAULT_ID="adventurer"、PORTRAIT_REGION、BASE_*（仅面板显示）；adventurer/witch/robot + 测试 knight/guard/scout（借前 3 者精灵表）。
- 温度＝两属性。**温度值 0~1000**（初500，不伤人）由区域系数推动：只有**火山+6/雪地−6**；系数0时 `move_toward(500)` ±10/s，体温自然回温 30（10/分，唯一回温），熔炉热源 +20/s。**档位→体温速度**：<100 −2 / <350 −1 / <650 0 / <900 +1 / ≥900 +2 °/s，用**帧初**温度值判定。体温 −100~100 越界 0.5HP/s ＋**有内置电量者**再 0.5 电/s。HUD 只显示体温。
- 电量两条线。①自身 `vitals.current_power`：仅 `power_embedded`（robot 内置、不可关）可用→归零掉血、低电×0.7 减速、>80且吃饱回血、体温越界漏0.5/s；外置零影响。②核心 `PowerCoreInstance.power` 挂**物品实例**，随物品在背包↔装备槽↔掉落物流转**引用不变**（拆下重装电不满）；仅核心温度值越界（<350过冷/>650过热）时 −0.5/s（`PowerCoreSystem`，共用温度场）。
- `has_power`＝只读属性＝`power_embedded or 装了核心`；读 `vitals.has_power`，别用 `CharacterRegistry.has_power()`；已删 `set_has_power()`，装备变化走 `vitals.on_core_changed()`。HUD 两行：`⚡`自身（占位，仅内置）/`🔋`核心（有才显示，青蓝 CORE_ROW_COLOR）——**别改回 visible=false**（VBox 忽略隐藏控件尺寸→面板变矮），高度用 `reset_size()`。
- 动力核心：`EquipSlot` 末尾加 `CORE`；`power_core_item.tres` 带 `carries_power`+`unlocks_core_tab`；装备槽存 ItemInstance（`get_item` 返 data、`get_core_instance` 取实例）；`inventory.take_item_instance()` 整件取走；入口＝装备面板四槽。存档存实例字典（兼容老档纯 item_id）；**装备恢复排在 Vitals 之前**，收尾**无条件** `resync_core_state()`；`core_tab_unlocked` 静态→`equipment._ready` 必须重置。
- 换装＝换精灵表底层贴图（448×392/8列×7行/56px）：`_swap_sprite_atlas()` 深拷贝 SpriteFrames 只改 AtlasTexture.atlas（**勿直接改 spr.sprite_frames**）；新 PNG 须编辑器导入 + `ResourceLoader.exists()` 守卫。三表逐帧 alpha 轮廓实测**零差异**（纯换色），`test/player_anim_check.py` 第 6 项常驻核对。
- 精灵表 7 行的实际语义：0 idle / 56 attack（末段带白剑光弧）/ 114 walk（单帧 56×57，非 112）/ **168+224 持械行走 16 帧（首尾各有一帧「俯身」，不是空行——旧 README 写"空的"是错的）** / 280 hurt / 336 die。玩家 6 个游戏内动画：idle·walk·attack·**harvest**·hurt·die。
- 存档 `SaveManager.create_slot(name,roll,character_id)` 写 meta.character_id，老档缺→默认角色；physics._ready 早于 HUD→`hud_ui._ready` 补 `_bind_health()`；`_apply_character()` 在 `spr.play("idle")` 前。
- 专属栏：Category 末尾 SURVIVAL/ALCHEMY/MACHINE/**CORE** + FIRST_EXCLUSIVE=5 + **LAST_EXCLUSIVE=7**（漏上界→新分类掉进角色过滤分支而**永不显示且不报错**）；crafting_ui 动态建标签 + `_tabs_char_id`/`_tabs_core_unlocked` 双哨兵；归属映射 CRAFT_CATEGORY_OWNER；权限 exclusive_owner/access_policy/owner_bonus_mult 执行点 ItemEffects，**只卡"使用"**。饱食度满时整次进食作废。未实装：冒险家能力/魔女制药/专属制作站/专属装备权限。

## 建造 / 存档 / UI
- 建筑：工作台 wood×10/熔炉 rock×20+5m 热源+20/s/储物箱 wood×8+20格；`Building.spawn()` 无 tscn；碰撞 layer2。
- **存档 v2 地形存快照**：`map_data`(1600²)→DEFLATE+base64≈14KB 写 `map` 段（+尺寸+hash）；`request_load` 解压进 `pending_map_tiles`，`_apply_terrain_snapshot()` 生成后**覆盖**，用完即清；老档无 `map` 段→按种子重算。敌人按 get_path_to 记路径，存档里没有＝已击杀；重建建筑前清光 Building + `BuildingSystem.clear()`。
- 快捷栏＝背包前9格镜像；UI 不改背包数据，拖放走信号。Esc 只归 UIManager 栈，Tab/C/B 归 hud_ui；世界点击三处 _input 都要 `gui_get_hovered_control()==null` 守卫；WINDOW_PANELS（库存/合成/装备/储物箱）只开一个；HUD＝左上状态栏+右上簇（小地图/按钮列/时钟）+底部快捷栏，MinimapUI 不进面板栈。
- 地图：MapView 基类 ← MinimapUI/BigMapUI（M 键、暂停）；底图 static 共享+分帧生成；**M 键监听在 UIManager._input**；罗盘 `_map_angle=atan2(fwd.x,fwd.z)+PI`，换算经 _rot2/_rot2_inv；储物箱跨面板拖 source_id+cross_dropped→`Inventory.move_between()`。

## 美术资产
- 规范＝`美术资产规范.md`；目录说明＝`art/README.md`、`_source/README.md`、`player/README.md`、`props/tree_1/README.md`。
- **两层结构**：生产层 `icons/`(27 png)、`player/`(3 精灵表)、`enemies/`(6 png，全在用)、`props/tree_1/`(25 帧+tree_frames.tres)；隔离层 `_source/`（第三方包，1687 张）。**art/ 不放 .blend/.psd**（Blender 源在工程外 `E:\GameMake\loss\blender_art\`；`_source/` 内第三方 `.aseprite` 例外）；3D 模型落点 `art/models/`。**生产层只留被引用的**，未引用帧（如 `Mushroom without VFX/`）归 `_source/_loose/`。
- **被引用目录（改动前必查）**：`icons/`(33 处 item .tres)、`player/<角色id>/`(`character_registry.gd` 6 条 sprite+`player.tscn` 默认外观)、`enemies/Forest_Monsters_FREE/`(`slime.tscn` 6 张)、`props/tree_1/`(`tree.tscn`+`tree_frames.tres`)。
- **图标命名硬规则**：`art/icons/<物品id>.png` 与 `script/items/data/<id>_item.tres` 的 id 一致（**30 物品/24 图标**，6 个借图，repair_kit←workbench.png 最误导）；唯一脱节＝`wood_item.tres` 指向 `log.png`（补 wood.png，别改 log 名）。`icons/`(56px 面板图标) 与 `props/`(世界资源物外观) 分开，别按材质分。
- 2026-09-18 已清理（可回滚）：`E:\GameMake\loss\trash_2026-09-18\`(812 文件/15.41MB，含 `grass_entity.tscn`、`tileset_test.res`)；`oak_woods_v1.0`→`art/_source/`；`tree_1.blend`+`.import`→`blender_art/`；备份 `E:\GameMake\loss\art_backup_2026-09-18`。
- **插件（2026-09-22 已清）**：原有 5 个全零调用（PhantomCamera/StateChart/CSVData/TileMapLayer3D；相机是自研 `script/player/camera_3d.gd`）。`TileMapLayer3D`/`phantom_camera`/`godot_state_charts`/`csv-data-importer` 已移入 `trash_2026-09-18/dead_plugins/`，`addons/` 只剩 `script-ide`（留）。**纠正旧记**：`project.godot` 里**既没有** `[editor_plugins]` **也没有** `[autoload]`（全文 176 行核过），5 个插件从未真正启用过 ⇒ 删插件**不需要**改 `project.godot`、也不会启动报错；先前"不删 `[autoload] PhantomCameraManager` 就报错"的说法是自己吓自己，已同步改正 `项目结构说明.md` §1.1/§11/台账21。
- 废弃场景：`tscn/prefab/grass_entity.tscn`（**仍在工程内**，9-18 与 9-22 两次移出都被编辑器写回，须先关标签页）、`tscn/test.tscn`（已移入 `trash_2026-09-18/dead_scenes/`）、`script/ui/probe_ui.gd.uid`（孤儿 uid，已移出）。
