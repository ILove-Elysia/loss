# 项目长期记忆（loss-land / 失落之岛）

> 设定（大纲 2026-09-14 纯净版，正文不含版本号）：正式角色＝冒险家/魔女/机器人，**数值全同**（HP100/移速×1.0/攻击×1.0），差异全在系统。电量默认仅机器人；另两位拾「动力核心」装入解锁（可拆）。过冷/过热**所有角色扣血**，有电量者再漏电。**回血＝吃食物**（浆果 +25_food +10HP），**自然回血仅内置电量（robot）**。冒险家开局可选、另两位游戏内解锁，开发期 `ALL_UNLOCKED=true`。测试角色 knight/guard/scout 本期保留。旧设定「织星者/大静默」搁置。**主线（大纲第五章，规划中）**：沙地区＝沙虫（巢穴→沙虫→巢穴坍塌→地下实验室→机械沙虫）；丛林区＝巨鸟（巨树→巨鸟→特殊种子→藤蔓→巨树之上）。两 Boss 共同规则：**濒死不杀（保留 1 血+无敌逃走）**、**脱战回满血**、场地永久变化（巢穴坍塌）。
> 铁律如下，过程见每日日志。
>
> **`loss-land/大纲.md` 的定位（用户要求 2026-09-14）**：它是**给人看的游戏内容说明书**，不是开发日志。**禁止**写入：版本变更记录（v0.x 改动）、决策编号、「✔/○/◆」状态标记、代码文件名 / 字段名 / 函数名、待办清单、"踩过的坑"。**未实装内容统一写「（规划中）」**。开发过程、决策、接口契约放**每日日志**；纯技术设计（流式加载参数等）另开文档。改数值 / 机制后回写大纲，保持文档与游戏一致。整理前的旧版备份在 `.workbuddy/archive/`。

## 0. 排障
- 本机无 Godot：改 .gd → `python test/gd_static_lint.py`（缩进/括号/不可见空白/class_name 缓存/Vector 成员/`:=` Variant）；改 .tres·物品·配方 → `test/check_data_refs.py`；最终实机确认。
- `:=` 右侧是 Variant（`.get()`/`.call()`/`ProjectSettings.get_setting()`/无返回类型函数）→ 整脚本解析失败。新函数必写返回类型。
- 取证目录 `Godot/app_userdata/loss_land/`。高频根因：绑定缺失、class_name 缓存未重扫、内部集合被清空、queue_free 延迟、控件 0×0、先设位置后入树。
- Python 用 Bash 跑（PowerShell 起子进程被静默拦截），偶发 `fork: Permission denied`→重试。多会话并行先看 mtime；Edit 报 "modified since read"→重读再改。
- F5 编辑器内嵌运行不可用（DisplayServer 拒 resize、后处理失效）→ 独立窗口；GraphicsConfig 用 `_can_control_window()`（`root.is_embedded()`）跳过窗口操作。

## 1. 架构铁律
- 核心系统＝class_name + static（UIManager/ItemRegistry/CraftingSystem/BuildingSystem/SaveManager/GraphicsConfig/ViewFrustum/WorldStreamer/DebugConfig/RespawnSystem/FilterSystem/CharacterRegistry），**不用 autoload**；新增 class_name 手工补 `.godot/global_script_class_cache.cfg`。
- 枚举只能末尾追加（.tres 存数字）；对外暴露集合必须 `.duplicate()`。先 add_child 再设 global_position / 调依赖 _ready 的组件。
- 同一文件多处 Edit 必须**串行**（并行静默丢改动），改完 grep 复核。
- 只走 DebugConfig.log_msg/warn_msg，不裸 print；新分类同步 const + ALL_CATEGORIES + CATEGORY_LABELS。地形号 7海/8沙滩/10草原/11丛林/12矿区/13沙地/14火山/15雪地。
- 移动 .gd 同步 5 处：.gd.uid、.tscn ext_resource path、test/*.gd 的 load()、global_script_class_cache.cfg path、首行注释。编辑器**正在运行**时 `.godot/editor/*`（open_scripts/script_editor_cache）会留旧路径——不要去改，切回 Godot 窗口触发重扫即可（uid 未变 → 自动识别为移动）。移动后必跑 gd_static_lint（含 class_name 缓存一致性校验）。
- **敌人 AI 目录约定**（2026-09-14 用户要求）：`script/ai/enemy/` 下先分档次 `mob/`（普通小怪）、`boss/`（Boss）；**单个怪物有多个脚本**时为它建同名子文件夹收在一起（`mob/drone/`＝drone.gd + drone_projectile.gd），单脚本怪物平铺（`mob/slime.gd`）。
- 运行时 new 的控件禁用 `set_anchors_preset`（得 0×0，点击穿透到 3D）→ 显式给 size/position；全屏面板走 UIManager size_changed→on_viewport_resized()。
- `_ready` 最小尺寸不可信：① 居中用 CenterContainer，勿手算 offset；② autowrap Label 必须给确定正宽度 + `max_lines_visible`（宽 0 → 最小高度虚高 → 面板比窗口高）。
- 属性名必须对 `doc/classes/*.xml` 核：Godot 4 是 `text_overrun_behavior`（非 `overrun_behavior`），写错 → _ready 抛错 → 整片灰屏，lint 查不出。Environment 只有 `adjustment_enabled/saturation/brightness/contrast`，无 `adjustment_color`/`vignette_*`。

## 2. 分辨率
- 唯一开关 `project.godot [display]`：1280×720 + canvas_items + expand + fractional（`test/display_scale_test.gd` 钉住）⇒ `get_viewport_rect()` 恒 1280×720，**UI 一律按 1280×720 写**；3D 按原生分辨率。
- GraphicsConfig（静态 → user://graphics_config.cfg）：全屏/窗口尺寸/界面缩放 0.7~2.0/垂直同步/帧率上限；`has_saved_config=false` 时不动窗口。面板＝GRAPHICS_PANEL，由 UIManager._ready() 应用。同一设置项只允许一份状态。

## 3. 玩家 / 相机 / 战斗
- 层级：player(Node3D,"player"组)→Physics(CharacterBody3D,current_health/take_damage/heal)+Inventory/Equipment/Vitals/ClickMover；相机 player/Camera_controller/Camera_Target/Camera3D。
- 瞬移必须 `camera_3d.snap_to_target()`（相机入 "player_camera" 组）：teleport_player_to_start、SaveManager._apply_player、Physics.revive；并 `reset_visual_interp()` 否则拖残影。
- vitals `_tick()` 顺序 体温→饱食度→电量。体温不在 10~40 开区间：**先扣血**（所有角色 0.5/s），有电量者再漏电 0.5/s。饱食度 ≤20 减速×0.9 且停自然回血，=0 每秒 -0.5HP。
- 攻击＝physics.gd._on_attack_hitbox_active 的 intersect_shape + 沿父链找 take_damage；**判定体＝以玩家为圆心、半径 2m 的 360° 竖直圆柱**（高 2.6、中心 y=脚下+1.0）。**绝不用 visual_node.basis 当朝向**（它是永远 look_at 摄像机的广告牌）。敌人受击靠 Area3D 命中盒；无人机无碰撞（layer/mask 全 0，`anchor_on_ready=false` 须在 add_child 前设）。
- **玩家物理碰撞体只有 1.0m 高**（Physics 下圆柱 h=1.0 / r=0.33，中心 y=0.5015 ⇒ 落在 y∈[0,1]），但精灵高 1.48m —— 两者不匹配。**任何"平行地面"的投射物/射线都必须飞在 y≤1.2**，否则从玩家头顶漏过（无人机弹幕的坑：`fire_height=0.9`，球 r=0.3 ⇒ 覆盖 [0.6,1.2]）。地形碰撞是平铺薄盒（中心 y=-0.5、厚 1.0 ⇒ 岛面恒在 y=0，全岛无高度差）。
- 死亡：HP=0 或落水（脚下地形=7 且 y<-0.6）→ `_on_death()`（幂等）→ RespawnSystem.on_died() + FilterSystem.apply(DEATH)；HUD 5s 倒计时 → Physics.revive()。敌人目标判定统一 `Physics.is_alive()`。
- 滤镜 filter_system.gd（静态）：Filter{NONE,DEATH,LOW_HEALTH,HIT,BURN,FREEZE,CUSTOM}；apply/clear/pulse/set_low_health/tick（由 hud_ui._process 驱）；与昼夜共用 map.tscn 的 WorldEnvironment。

## 3.5 角色与电量
- `character_registry.gd`（静态）唯一权威：`DEFAULT_ID="adventurer"`、`ALL_UNLOCKED=true`（发布改 false）、PORTRAIT_REGION、BASE_*（仅供面板显示，生效值在 physics/vitals 的 @export）。加角色只改这里；main_menu_ui._build_char_screen() 遍历出卡片。六角色：正式 adventurer/witch/robot + 测试 knight/guard/scout。
- **两种电量语义（`power_embedded`，用户决策 2026-09-14）**——分界线是"电量能否影响人物本体"：
  - 内置（robot）：不可关闭（set_has_power(false) 被拒）、归零掉血、低电 ×0.7 减速、**>80 且吃饱缓慢回血**。
  - 外置（冒险家/魔女装核心）：**零影响** —— 不掉血、不减速、**不回血**；只保留过冷过热漏电与"耗电交互可用"。
  - ⚠ `has_power` 是**运行时状态**（核心可装可拆）→ 实时电量读 `vitals.has_power`，别用 `CharacterRegistry.has_power()`（只返回开局默认）。
- HUD 电量行＝**常驻占位**（`_power_label` 永在 vbox，offset_bottom=152 固定 4 行）：亮起 `⚡ 100` 暖黄 / 占位 `⚡ --` 灰；`hud_ui.set_power_active()` 由 vitals._push_hud 推，`_last_power_active_shown=-1` 哨兵保首帧必推。**别改回 visible=false**（VBoxContainer 忽略隐藏控件尺寸→面板变矮）。
- 动力核心：**接口已备、本体未做** —— `vitals.set_has_power(active)`（装入满电/拆除清零/内置拒关）、`CharacterRegistry.has_embedded_power(id)`。缺 power_core 物品、投放点、装入·拆除入口、`has_power` 存档字段。
- 换装＝换精灵表底层贴图（448×392，8列×7行，56px）：`physics._swap_sprite_atlas()` 深拷贝 SpriteFrames 后只改 AtlasTexture.atlas，**勿直接改 spr.sprite_frames**（共享子资源串色）。新 PNG 须编辑器导入（本机生不成 .ctex）→ ResourceLoader.exists() 守卫+退回。
- 持久化：`SaveManager.create_slot(name, roll, character_id)` 写 meta.character_id + CharacterRegistry.set_active()；老存档缺字段→默认角色。顺序坑：physics._ready 早于 HUD → hud_ui._ready 必须补 `_bind_health()`；`_apply_character()` 在 `spr.play("idle")` 之前。
- 专属制作栏（2.2.5）：Category 末尾追加 SURVIVAL/ALCHEMY/MACHINE + FIRST_EXCLUSIVE=5 + COMMON_CATEGORIES；CraftingSystem.is_category_visible()/_is_recipe_visible()/get_visible_categories(char_id) 过滤；crafting_ui 动态建标签，`_tabs_char_id` 检测换角色重建；归属映射 CRAFT_CATEGORY_OWNER。
- 专属物品权限（决策⑦）：ItemData 加 exclusive_owner/access_policy(ANYONE|OWNER_BONUS|OWNER_ONLY)/owner_bonus_mult；执行点 ItemEffects.access_denied_reason()+apply()（再判一次）。**只卡"使用"，拾取/携带放开**；被拒走 HUD.show_toast()。现状：power_cell=OWNER_ONLY(robot)、repair_kit=OWNER_BONUS(robot,×1.5)，其余 ANYONE。
- item_effects 支持一条效果改多值（正则 `\+([0-9.]+)_(power|food|health)`）；**饱食度满时整次进食作废**（含回血，判断在结算前）。
- ◆ 未实装：① power_core 本体；② 冒险家能力（决策②）、魔女制药（决策⑤）；③ 专属制作站；④ 专属**装备**权限（equip_slot 未判）。

## 4. 世界与资源
- 地图 1600×1600，岛半径≈430，出生点＝孤岛中央草原区（海洋格无碰撞 → 走进去自由落体）。
- 区域→资源权威 `task_system.REGION_RESOURCE_MAP`：草原/丛林=twig·grass·tree·berry·pebble；矿区=pebble·stone·iron_ore；火山=coal·iron_ore；雪地/沙地/沙滩=twig·pebble。**石头只在矿区、煤只在火山**。物品 id 是 `wood`（显示"木材"）；树要斧、大石/矿要镐。
- 采集权威 `ResourceManager._try_harvest_nearest()`（水平 3m）；判定对象是记录，不给资源挂 Area3D。

## 5. 流式加载（ViewFrustum）
- LOAD_RADIUS={resource:70,enemy:70,drop:50,building:70} + UNLOAD_HYSTERESIS=24；判定＝距玩家平面距离，勿用屏幕视锥。
- 资源（resource_manager）：数据层 _records + 表现层 _entities；卸载退回对象池绝不 queue_free；is_busy()/pinned 不卸载；存档源=_records。
- 敌人+掉落物（world_streamer）：挂起=remove_child（状态保留），放回=add_child+设 global_position，**绝不重建**；`_sync_rec_from_node` 须在 remove_child 前取坐标；放回显式 add_to_group。

## 6. 建造 / 昼夜 / 存档
- 建筑：工作台 wood×10 / 熔炉 rock×20 + 5m 热源 35° / 储物箱 wood×8 + 20 格；`Building.spawn(id,pos,parent)` 无 tscn；station（永久解锁配方）与"须靠近"两套判定；碰撞 layer2。
- **存档 v2：地形存快照，不再只存种子**（用户决策 2026-09-14）。`map_data` 是 `PackedByteArray`（1600×1600，2.56MB）→ `compress(DEFLATE)`+base64 ≈ 14KB 写进 `map` 段（+尺寸+`tiles_hash` SHA256）；`request_load` 解压进 `pending_map_tiles`，`map_generator_3d._apply_terrain_snapshot()` 在生成流水线跑完后**覆盖**地形（派生数据仍需生成），用完即清。老档无 `map` 段 → 按种子重算 + 记日志。诊断：比对哈希能说出"生成算法已变"。`SAVE_VERSION` 1→2（此前只写不读）。**种子降级为元数据**。改随机调用顺序不再毁老档。验证：`test/verify_save_map.py`（无需 Godot，检查地形↔实体坐标一致，实体不该落海）。
- 存档全量化；敌人按 get_path_to 记路径，存档里没有＝已击杀→删节点；重建建筑前清光 Building + BuildingSystem.clear()；资源过程态归一为 HARVESTED。

## 7. UI 约定
- 快捷栏＝背包前 9 格镜像；UI 不改背包数据，拖放走信号。Esc 只归 UIManager 栈，Tab/C/B 归 hud_ui。面板懒创建 + on_shown 钩子；世界点击三处 _input 都要 `gui_get_hovered_control()==null` 守卫。
- 面板互斥：WINDOW_PANELS（inventory/crafting/equipment/storage）只开一个；FULLSCREEN_PANELS 打开时收掉窗口类，覆盖类之间可叠。
- HUD：左上状态栏（固定 4 行，电量行常驻占位）、右上簇（小地图+按钮列+时钟）、底部快捷栏；MinimapUI 是 HUD 子组件**不进面板栈**。
- 地图：MapView 基类 ← MinimapUI/BigMapUI（M 键、BIGMAP_PANEL、modal 暂停）；底图 static 共享 + 分帧生成；**M 键监听在 UIManager._input**。罗盘旋转 `_map_angle=atan2(fwd.x,fwd.z)+PI`，坐标换算全经 _rot2/_rot2_inv。
- 储物箱跨面板拖：source_id + cross_dropped → `Inventory.move_between()`；返回主菜单前 paused=false 且 UIManager.instance=null。
