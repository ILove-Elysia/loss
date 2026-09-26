# 项目长期记忆（loss-land）

> **本文件＝高频铁律 + 领域指针（每轮自动注入，务必保持精简；超过 ~4.8 K 字符就会被截断）**。细节、历史决策、踩坑过程在 **`MEMORY-archive.md`**（2026-09-26 由 18 份旧记忆合并的全量归档：细节详章 / 拆分前备份 / 09-08～09-26 每日日志，见其 `## 目录` S01～S18；**它是冻结快照，别往里追加**，新细节写进本文或项目文档）。**待办在 `E:\GameMake\loss\待办.md`**。

## 一、改文件 / 改数据的铁律
- **改 `大纲.md` 只做用户明确点名的改动**（09-25 / 09-26 两次明确要求）：可以标注想法，但不能动他的内容；删的只能是我臆造的东西。删/加物品时**连带问题（解锁门槛、计数、跨章节引用）先在回复里以「建议」列出、等拍板**，不许顺手改。**新增系统＝标题 + 定位一句话 + 「待完善」问题清单（一律写"待定"，不给候选方案）**，绝不写死具体设定。想法一律只放进回复。`大纲.md` 自身：禁版本号/状态标记/代码名/字段名/待办/踩坑；未实装标「（规划中）」；改数值后回写。
- **改 .gd → `test/gd_static_lint.py`；改 .tres/.tscn → `test/check_data_refs.py`；最后实机。编辑器开着别跑 headless**（抢 `.godot`）。Godot 4.7.2＝`E:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`；headless＝`godot --headless --path . --script res://test/<name>.gd`（仓库根＝`E:\GameMake\loss`，工程在 `loss-land`）；**`--path` 只认 Windows 路径**。**编辑器开着也想 headless 验证：复制工程（⚠ `tar` 排除 `.godot` 时要**连工程内的 `Godot/` 一起排除** —— 那是 `user://` 日志目录，否则会读到上一轮的旧 `godot.log` 误当本次结果）→ ⚠ 副本必须先 `--editor --quit` 生成 `.godot` 再跑 `--script`**（脚本模式不扫项目 ⇒ 缺缓存时**所有** `class_name` 报 not declared，极易误判成"改动把类改坏了"）。**验证一律用 Bash 跑**（会等待子进程，`… > out.txt 2>&1; echo exit=$?` 一次拿全输出与退出码；PowerShell 对 GUI 子系统的 Godot **不等待** ⇒ 命令"完成"实则没跑完、输出被截断、后续语句还可能整段不执行）；**`APPDATA` 必须写 Windows 格式** `C:/…`（写成 `/c/…` ⇒ Godot 报 `Could not create directory: '/c'`、建不出 `user://`、日志根本不落盘）。
- **lint 查不出「调用了未定义的方法」**（09-24 `_connect_player_signals` 事故）：`Function "X" not found in base self` 只在真跑时才炸。**改完 .gd 必跑一次会加载它的 headless 入口。**
- **改 `.gd` 的 `@export`（尤其删字段）必须先关编辑器**：编辑器用中间态脚本重序列化 .tres、无声吞字段（09-22：8 份 .tres 的 `resource_id` 被吞）。铁证＝被编辑器存过的 .tres 多出 `uid=`。**脚本改好 ≠ 数据还在，改完必跑 check_data_refs；它报的每条都要处理。**
- **移出 .tscn/.tres 前先在编辑器关掉它的标签页**（否则编辑器把内存场景重新落盘，已 3 次）；标签页状态在 `.godot/editor/editor_layout.cfg` ⇒ 必须「关标签页 + 重启」。同理：**标签页开着时外部改 .tscn 会被覆盖** ⇒ 关键值改由运行时脚本强制（如 `sandworm_arena._ensure_unshaded_materials()`）。
- **手工写 `.tscn`：`@export` 节点引用必须在节点头写 `node_paths=PackedStringArray("属性名")`**，漏写则**静默 null 且不报错**（tree.tscn 的 `Visual` 事故）。最稳＝编辑器拖拽生成。
- **删物品 / 移动 .gd 各需同步 5 处** → 归档 S02「文件同步清单」。**新增 `class_name` 要手工补 `.godot/global_script_class_cache.cfg`（lint 第 4 项查），或用 `const X := preload("res://…")` 绕开缓存**。核心系统＝`class_name`+`static`，不用 autoload。
- 同文件多处 Edit **必须串行**（并行会静默丢更新）；改完 grep 复核；批量脚本改文件先 `cp` 后 `diff`；弱特征定位会命中错处 → 特征须含唯一内容。误改可救：`~/.workbuddy/file-history/<会话uuid>/<hash>@vN`。
- 查属性/枚举名 → `raw.githubusercontent.com/godotengine/godot/4.7/doc/classes/<类>.xml`。写错属性名 → `_ready` 抛错 → 灰屏，lint 查不出。

## 二、GDScript 语言坑
- **`:=` 右侧为 Variant 会报错**（WARNING 当 ERROR）：`.get()`/`.call()`/无返回类型函数/双签名数学函数；新函数必写返回类型。**4.x 只有 11 个函数有 `f` 变体**＝`absf/ceilf/clampf/floorf/lerpf/maxf/minf/roundf/signf/snappedf/wrapf`；`sin/cos/tan/atan/atan2/sqrt/pow/exp/log/deg2rad/rad2deg` **没有** `sinf/asinf/sqrtf/powf`，写了整份脚本解析失败（lint 第 7 项查）。
- 信号 arity 是**运行时**检查：改 `signal` 参数后回调不匹配**不报错**，真触发才炸。常驻 `test/signal_arity_check.py`。
- **辅助 / 工具函数别用引擎虚函数名**（`_set`/`_get`…）：直接 `Parse Error` 加载失败；若发生在 `SceneTree._initialize()` 里，`quit()` 也会走不到、进程挂着不退。
- **「每帧强制对齐状态」的函数会吃掉外来一次性动画**：`physics._update_animation()` 每帧 `else: spr.play("idle")` ⇒ 一次性动画须有独占标志位（见 `is_working`）。
- **「同步重入」：发信号 / 调别人方法时，对方会在你返回之前改你的状态**。典型＝`body.take_damage()` 把玩家打死 ⇒ 玩家**同步**发 `died` ⇒ 我方 `_set_state(RETREAT)` 顺手把当前招置 null ⇒ 回到原函数继续读它＝空引用（09-26 沙虫：一次死亡连报两条 `Invalid access … on Nil`，日志里只看得见第一条）。**规矩：进函数先取局部快照，扣血 / 发信号之后只用局部量；调用方在该调用之后必须重新确认状态**（`if _attack == null: return` + `is_attack_phase(_state)` 守门）。凡"我会改别人 / 别人会改我"的调用都按这条办。

## 三、运行时取证与排查
- 日志 `%APPDATA%\Godot\app_userdata\loss_land\logs\`（`godot.log` 当次 + 历史时间戳）；同目录 `debug_config.cfg` 分类开关（**默认 resource=false**）。存档 `saves/slot_N.json` 可 Python 直读。
- **高频根因（先查这 6 个）**：绑定缺失 / 缓存未重扫 / 集合被清空 / queue_free 延迟 / 控件 0×0 / 先设位置后入树。
- **报一串 `Could not parse global class "X"` 先 `git status`/`git diff`，别怀疑类缓存**（09-25：`boss_base.gd` 被误敲进一个 `1` ⇒ 所有 `extends`/`: BossBase` 连坐 33 条）。**编辑器脚本自动保存（默认 10 s）会把误击键静默落盘**，「我没改过」不成立；`git diff` 为空＝与已验证版本逐字节一致。
- **"颜色不对 / 看不清 / 变白"要出图取证**：headless 渲染不出画面 ⇒ 隔离副本里开窗口跑 `--script <截图脚本> --quit-after N`，**并把取样像素打进日志**（比肉眼看图更硬）。⚠ `_initialize()` 里报一次错就永远走不到 `quit()`、进程挂着不退 ⇒ 必须 `--quit-after` 兜底。完整做法见 `项目结构说明.md §4.9`。
- 运行时 `new` 的控件**禁用 `set_anchors_preset`**（0×0 悬停不到且点击穿透到 3D）→ 显式 size/position；居中用 CenterContainer；autowrap Label 给确定正宽度；F5 内嵌运行不可用 → 独立窗口。
- 工具链顺序：`fix_import_paths.py` → `check_data_refs.py` → `find_orphans.py`（**孤岛 ≠ 可删**）→ `gd_static_lint.py` → 实机。二进制 `.res` 内字符串 grep 不到且带长度前缀 ⇒ 改路径长度会损坏，只能编辑器拖拽更新；**引用者自身可能是死的**；绝不 `cat` 大 .tres。
- **判断"某物品是否可得"的唯一权威＝`script/crafting/crafting_system.gd` 配方表 + 掉落/初始背包**，不是 `items/data/*.tres`（遗留 .tres 会长期挂 registry 还被测试当夹具）。**加档位/写说明书前先查配方表**。
## 四、位置与距离（重灾区）
- **算「玩家到某物」距离必须取 `Physics` 子节点（或 `ViewFrustum.player_position()`），绝不读 `player` 根节点**：根节点从不位移、永停出生点，动的是 `Physics`(CharacterBody3D)。09-22 采集中断读根节点 ⇒ 判定恒≈59 m ⇒ 全资源采不动。ClickMover 的 `get_parent()` 就是根节点。

## 五、领域高频点（一句话触发；数值与细节 → 归档 S02）
- **渲染 / 材质**：**全工程 3D 网格一律 `SHADING_MODE_UNSHADED`**（地形/海面见 `map_generator_3d.gd`）。环境光＝`ambient_light_color(0.83) × energy(9.0)`（map.tscn）⇒ 受光面抬亮 ≈2.2 倍、**albedo 亮过 0.45 直接变纯白**（09-26 沙虫"变白看不清"，实测体色/地面像素都 `#ffffff`）。占位件别漏 `material_override`（漏了＝引擎默认的白色受光材质）；体色要比地形瓦片色**暗一档**。细则见 `项目结构说明.md §4.9`。
- **UI**：右列/底部控件必须 `anchor_*=1.0` + 负 offset（`ui_scale` >1 会缩小逻辑视口、把写死坐标裁出屏）；改布局必跑 `ui_grid_layout_check.py` + `ui_grid_layout_test.gd`。设计视口恒 1280×720。
- **碰撞层**：只有 layer_1＝玩家、layer_2＝地面/障碍有名；**障碍物一律 layer2 + mask0**；玩家碰撞体仅 1.0 m 高 ⇒ 平行地面的投射物/射线飞 y ≤ 1.2；鼠标点地走**解析求交**、加碰撞体不影响寻路。
- **朝向**：一律 `script/visual/sprite_facing.gd`、`billboard` 全关；`facing_basis` 只覆盖 Visual 的 basis。`flip_h` 符号**随实体自带镜像次数而异、不能互抄**；yaw 必须落在 `rotate_step_degrees`(45°) 整数倍。
- **容器**：数据层唯一入口＝`Inventory` 静态方法；四块信息面板可同刻全开（`LAYOUT_PANELS`）；修饰键点击须**延后到"松开且未拖拽"**再判定。
- **采集**：工作量 ÷ 工具每击伤害＝要采几下，中断**进度保留**（存 `work_remaining`）；工具门槛留空＝空手可采；在役工具 4 把；作业动画＝SpriteFrames 的 **`harvest`**。
- **资源实体**：8 种只有 tree 有专用预制体，其余走 `tscn/resource_entity.tscn`；**兜底判据＝「sprite 是否带 SpriteFrames」**；卸载/挂起一律**复用节点**，绝不 queue_free。
- **Boss / 沙虫**：独立 `"boss"` 组、**绝不进 `"enemy"` 组**；永久世界状态只走 `WorldState`；状态机**没有 `dead`、终态 `GONE`**；换表**只在决策点**；技能全 CD 时**回 CHASE**；**领地/脱战判据＝玩家↔巢穴**（`player_home_distance()`，别与 `player_distance()` 混），追击/出招受**领地绳**约束、回家不受限。场地 `tscn/sandworm_test.tscn`（**F6 独立窗口**）＋回归 `test/boss_state_test.gd`（57 断言，用例 13＝扣血同步重入）。
