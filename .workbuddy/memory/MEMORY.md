# 项目长期记忆（loss-land）

> **本文件＝高频铁律 + 领域指针；细节一律在 `MEMORY-details.md`**（角色/温度/电量、建造/存档/九宫格数值、容器交互、相机与渲染属性、攻击/死亡、采集与资源实体、世界与流式、美术资产、Boss/沙虫、文件同步清单）。历史全文 `MEMORY.md.2026-09-18-full.bak`；过程见 `2026-09-*.md`；**待办在 `E:\GameMake\loss\待办.md`**。

## 一、改文件 / 改数据的铁律
- `大纲.md`＝给人看的说明书：禁版本号/状态标记/代码名/字段名/待办/踩坑；未实装标「（规划中）」；改数值后回写。过程与接口契约 → 每日日志。
- **改 .gd → `test/gd_static_lint.py`；改 .tres/.tscn → `test/check_data_refs.py`；最后实机。编辑器开着别跑 headless**（抢 `.godot`）。Godot **4.7.2**＝`E:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`；headless＝`godot --headless --path . --script res://test/<name>.gd`（**仓库根＝`E:\GameMake\loss`**）；从 Git Bash 跑先补 `APPDATA`，否则 `user://` 会落进项目内 `loss-land/Godot/`（`?? Godot/` 是日志、已 .gitignore，别提交）。**`--path` 只认 Windows 路径**，写 Git Bash 的 `/c/…` 会 `Invalid project path specified`。**想「编辑器开着也能 headless 验证」：把工程整个复制到临时目录、删掉副本里的 `.godot`（走全新导入，顺带模拟编辑器首扫）再 `--path` 指副本**，另设 `APPDATA` 隔离 `user://` —— 2026-09-25 实测 `--import` 1756 项 + 回归全绿，不与编辑器抢 `.godot`。
- **lint 查不出「调用了未定义的方法」**（2026-09-24 BossBase 的 `_connect_player_signals` 事故）：`Function "X" not found in base self` **只在真实运行/headless 时才炸**。**改完 .gd 必跑一次 headless 入口**（`test/*.gd` 或实机），静态 7/7 通过 ≠ 能跑。
- **改 `.gd` 的 `@export` 字段（尤其删字段）必须先关编辑器**：编辑器用"中间态脚本"重序列化 .tres，无声吞掉当时不存在的字段（2026-09-22：8 份 .tres 的 `resource_id` 被吞 ⇒ 场上无资源）；铁证＝被编辑器保存的 .tres 多出 `uid=`。**脚本改好 ≠ 数据还在，改完必跑 check_data_refs；它报的每条都要处理**，不许标"历史遗留/与本次无关"跳过。
- **移出 .tscn/.tres 前先在编辑器关掉它的标签页**：编辑器发现文件被外部删除会把内存场景重新落盘（已 3 次）。标签页在 `.godot/editor/editor_layout.cfg`、每次启动恢复 ⇒ 必须「关标签页 + 重启」。
- **手工写 `.tscn`：`@export` 的节点引用属性必须在节点头写 `node_paths=PackedStringArray("属性名")`**，漏写则属性**静默 null 且不报错**（tree.tscn 的 `Visual` 漏写 ⇒ `sprite` 恒 null）。最稳＝编辑器拖拽生成。
- **删物品 / 移动 .gd 各需同步 5 处** → 详章「文件同步清单」。**新增 `class_name` 要手工补 `.godot/global_script_class_cache.cfg`（lint 第 4 项查），或在用到处 `const X := preload("res://…")` 绕开缓存**。核心系统＝`class_name`+`static`，不用 autoload。
- 同文件多处 Edit **必须串行、一条消息只发一个**（并行会静默丢更新，2026-09-24 实测）。改完 grep 复核；批量脚本改文件先 `cp` 后 `diff`；弱特征定位会命中错处 → 特征须含唯一内容。误改可救：`~/.workbuddy/file-history/<会话uuid>/<hash>@vN`。
- 查属性/枚举名 → `raw.githubusercontent.com/godotengine/godot/4.7/doc/classes/<类>.xml`。写错属性名 → `_ready` 抛错 → 灰屏，lint 查不出。

## 二、GDScript 语言坑
- **`:=` 右侧为 Variant 会报错**（WARNING 当 ERROR）：`.get()`/`.call()`/无返回类型函数/双签名数学函数；新函数必写返回类型。**4.x 只有 11 个函数有 `f` 变体**＝`absf/ceilf/clampf/floorf/lerpf/maxf/minf/roundf/signf/snappedf/wrapf`；`sin/cos/tan/asin/acos/atan/atan2/sqrt/pow/exp/log/deg2rad/rad2deg` **没有 sinf/asinf/sqrtf/powf**，写了直接 `Function "asinf" not found` ⇒ **整份脚本解析失败**。`gd_static_lint.py` 第 7 项专查。
- 信号 arity 是**运行时**检查：`signal` 增删参数后回调签名不匹配**不报错**，信号真触发才炸。常驻 `test/signal_arity_check.py`。
- **「每帧强制对齐状态」的函数会吃掉外来的一次性动画**：`physics._update_animation()` 每帧 `else: spr.play("idle")` ⇒ 一次性动画必须有独立独占标志位（见 `is_working`）。

## 三、运行时取证与排查
- 日志 `%APPDATA%\Godot\app_userdata\loss_land\logs\`（`godot.log` 是当次，历史按时间戳）；分类开关同目录 `debug_config.cfg`（**默认 resource=false**，排查采集/生成先改 true）。存档 `saves/slot_N.json` 可 Python 直读。
- **高频根因（先查这 6 个）**：绑定缺失 / 缓存未重扫 / 集合被清空 / queue_free 延迟 / 控件 0×0 / 先设位置后入树。
- **报一串 `Could not parse global class "X" from "res://…"` 时，先 `git status` / `git diff`，别急着怀疑类缓存**（2026-09-25：`boss_base.gd` 第 403 行被误敲进一个 `1` ⇒ BossBase 解析失败 ⇒ 所有 `extends BossBase`／`: BossBase` 的脚本连带报错，共 33 条）。**编辑器脚本自动保存（默认 10 s）会把误击键静默落盘**，所以「我没改过」不成立；`git diff` 为空＝与已验证版本逐字节一致，是最快的证伪与修复确认手段。
- 运行时 `new` 的控件**禁用 `set_anchors_preset`**（0×0 悬停不到且点击穿透到 3D）→ 显式 size/position；居中用 CenterContainer；autowrap Label 给确定正宽度；F5 内嵌运行不可用 → 独立窗口。
- 工具链顺序：`fix_import_paths.py` → `check_data_refs.py` → `find_orphans.py`（**孤岛 ≠ 可删**）→ `gd_static_lint.py` → 实机。二进制 `.res` 内字符串 grep 不到且带长度前缀 ⇒ 改路径长度会损坏，只能编辑器拖拽更新；**引用者自身可能是死的**；绝不 `cat` 大 .tres。
- **判断"某物品是否可得"的唯一权威＝`script/crafting/crafting_system.gd` 配方表 + 掉落/初始背包**，不是 `items/data/*.tres`——遗留 .tres 会长期挂 `item_registry.tres` 且被测试当夹具，看着像活的实为死数据。**加档位/写进说明书前先查配方表**。

## 四、位置与距离（重灾区）
- **算「玩家到某物」距离必须取 `Physics` 子节点（或 `ViewFrustum.player_position()`），绝不读 `player` 根节点的 `global_position`**：根节点从不位移、永停在出生点，动的是它的 `Physics`(CharacterBody3D)。2026-09-22：采集中断判定读根节点 ⇒ 距离恒≈59 m ⇒ 每下都判"走远" ⇒ 全资源采不动。ClickMover 的 `get_parent()` 就是根节点。

## 五、领域高频点（数值与细节 → 详章）
- **UI 锚点**：右列/底部控件必须 `anchor_*=1.0` + 负 offset（`ui_scale` >1 会缩小逻辑视口、把写死坐标的控件裁出屏幕，2026-09-24 装备栏事故）；改布局必跑 `ui_grid_layout_check.py` + `ui_grid_layout_test.gd`。设计视口恒 1280×720。
- **碰撞层**：只有 layer_1＝玩家、layer_2＝地面/障碍有名；**障碍物一律 layer2 + mask0**；玩家碰撞体仅 1.0 m 高（精灵 1.48 m）⇒ 平行地面的投射物/射线飞 y ≤ 1.2；鼠标点地走**解析求交**，加碰撞体不影响寻路。
- **朝向**：一律 `script/visual/sprite_facing.gd`（静态）、`billboard` 全关；`facing_basis` 只覆盖 Visual 的 basis（别连位置写）。`flip_h` 符号**随实体自带镜像次数而异、不能互抄**（玩家 `= not facing_left`；史莱姆 `= _facing_left` 且判据用**相机右方向**）；yaw 必须落在 `rotate_step_degrees`(45°) 整数倍。
- **容器**：数据层唯一入口＝`Inventory` 静态方法（`transfer_between`/`stash_into`，用实例本身故核心电量不丢）；四块信息面板各占固定区、**可同刻全开**（`LAYOUT_PANELS`）；修饰键点击须**延后到"松开且未拖拽"**再判定，拖拽字典带 `count`。
- **采集**：`work_amount` ÷ 工具 `harvest_work`＝要采几下，中断**进度保留**并随档存 `work_remaining`；门槛＝`allowed_tool_tags` vs 物品 `tags`，**留空＝空手可采**；在役工具只有 4 把；作业动画＝SpriteFrames 的 **`harvest`**（不借 attack、不触发伤害），`is_working` 六处配对。
- **资源实体**：8 种只有 tree 用专用预制体，其余走 `tscn/resource_entity.tscn`；**兜底判据＝「sprite 是否带 SpriteFrames」**；卸载/挂起一律**复用节点**（对象池 / `remove_child`），绝不 queue_free。
- **Boss / 沙虫（2026-09-24）**：走独立 `"boss"` 组、**绝不进 `"enemy"` 组**（`_place_enemies()` 会把 enemy 全搬去丛林；存档对 enemy 是"不在档＝已击杀"，语义相反）；永久世界状态只走 `WorldState`（纯静态 flag）；状态机**没有 `dead`、终态是 `GONE`**；阶段切换是**隐式闩锁**（只在决策点换表）；技能全 CD 时**回 CHASE**。测试场地 `tscn/sandworm_test.tscn`（**F6 独立窗口**，非 F5）＋ `test/sandworm_arena.gd`；回归 `test/boss_state_test.gd`（46 断言）。
