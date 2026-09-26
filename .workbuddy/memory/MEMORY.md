# 项目长期记忆（loss-land）

> 高频铁律 + 领域指针，**每轮注入 ⇒ 超限会被截断**。细节与历史：`MEMORY-archive.md`（S01~S18 全量）、`MEMORY-archive-2026-09-27.md`（09-27 精简前快照）、每日日志。**待办 = `E:\GameMake\loss\待办.md`**。

## 一、改文件 / 改数据
- **`大纲.md`**：只做用户点名的改动；可标想法、不动其内容、只删我臆造的东西；连带问题以「建议」列出等拍板；新增系统 = 标题 + 一句话定位 + 「待完善」清单（只写"待定"）；禁版本号/代码名/字段名/待办/踩坑；未实装标「（规划中）」。
- **验证链**：改 .gd → `test/gd_static_lint.py`；改 .tres/.tscn → `test/check_data_refs.py`；动过 signal/connect 加 `test/signal_arity_check.py`；**改完 .gd 必须跑一次会加载它的 headless 入口**（lint 查不出"调用了未定义的方法"）。
- **headless**：先 `tasklist | grep -i godot` 确认编辑器没开 ⇒ 主工程直接跑 `bash: "$GODOT" --headless --path . --script res://test/X.gd > log 2>&1; echo exit=$?`。Godot = `E:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`；根 `E:\GameMake\loss`、工程 `loss-land`；`--path` 只认 Windows 路径；`APPDATA` 必须 `C:/…`（写 `/c/…` ⇒ 建不出 `user://`、日志不落盘）。**一律用 Bash**（PowerShell 不等待 GUI 子系统的 Godot）。
- **编辑器开着也要验**：复制工程（`tar` 排除 `.godot` 时**连工程内 `Godot/` 一起排除**）→ **先 `--editor --quit` 生成 class 缓存再 `--script`**（缺缓存 ⇒ 所有 `class_name` 报 not declared）。
- **改 `.gd` 的 `@export`（尤其删字段）必须先关编辑器**（重序列化 .tres 会无声吞字段；铁证 = .tres 多出 `uid=`）。**编辑器外改 .tscn/.tres 先关它的标签页**（否则被回写覆盖）。
- **手工写 .tscn**：`@export` 节点引用须在节点头写 `node_paths=PackedStringArray("属性名")`，漏写 = **静默 null**。最稳 = 编辑器拖拽。
- **删物品 / 移动 .gd 各需同步 5 处**（归档 S02）。**新增 `class_name` 手工补 `.godot/global_script_class_cache.cfg`**（lint 第 4 项查）或 `const X := preload(...)` 绕开。
- 同文件多处 Edit **必须串行**；改完 grep 复核；弱特征会命中错处。误改可救 `~/.workbuddy/file-history/<会话uuid>/<hash>@vN`。

## 二、GDScript 坑
- **`:=` 右侧为 Variant 报错**（当 ERROR）：`.get()`/`.call()`/无返回类型函数/双签名数学函数。**`f` 变体只有 11 个** = `absf/ceilf/clampf/floorf/lerpf/maxf/minf/roundf/signf/snappedf/wrapf`；`sin/cos/tan/atan/atan2/sqrt/pow/exp/log/deg2rad/rad2deg` **没有** → 写了整份脚本解析失败。
- **信号 arity 是运行时检查**（改 `signal` 参数不报错、真触发才炸）。**`.bind()` 参数接在信号参数【后面】**；**能靠"数据自带身份"就别 bind**。
- **`await physics_frame` 在 `_physics_process` 【之前】恢复** ⇒ 要确认"这一帧它已做过某事"须**多放一帧**。
- **同一函数作用域不许重名 `var`** ⇒ 报错即**整份脚本解析失败、测试全灭**。**辅助函数别用引擎虚函数名**（`_set`/`_get`…）⇒ `Parse Error`。
- **「同步重入」**：发信号/调别人方法时对方会在你返回前改你的状态（打死玩家 ⇒ 同步 `died` ⇒ 当前招被置 null ⇒ 回原函数读到空引用）。**规矩：进函数先取局部快照，扣血/发信号后只用局部量；调用方之后必须重新确认状态**。
- **「每帧强制对齐状态」会吃掉外来一次性动画** ⇒ 一次性动画须有独占标志位。

## 三、运行时取证
- 日志 `%APPDATA%\Godot\app_userdata\loss_land\logs\`（`debug_config.cfg` 开关默认 resource=false）；存档 `saves/slot_N.json` 可 Python 直读。
- **高频根因先查 6 个**：绑定缺失 / 缓存未重扫 / 集合被清空 / queue_free 延迟 / 控件 0×0 / 先设位置后入树。
- **一串 `Could not parse global class "X"` 先 `git status`/`git diff`**，别怀疑类缓存（误击键会被编辑器自动保存落盘）。
- **"颜色不对/看不清/变白"出图取证**：隔离副本开窗口 `--script <截图脚本> --quit-after N`，把**取样像素打进日志**（`项目结构说明.md §4.9`）。
- **调试接口不被玩法规则门禁**：`debug_*()` 与正式入口共用核心函数、调试路径**故意绕过**新规则；测试断言新规则就**直接读它改的状态量**，不为内部机制另开接口。
- **写"两个值应当相等"前先看会不会退化成同一常量**；**测试输入必须"非平凡"**。
- **"某物品是否可得"唯一权威 = `script/crafting/crafting_system.gd` 配方表 + 掉落/初始背包**，不是 `items/data/*.tres`。工具链 = `fix_import_paths.py` → `check_data_refs.py` → `find_orphans.py`（**孤岛 ≠ 可删**）→ `gd_static_lint.py`。

## 四、位置与距离（重灾区）
- **算「玩家到某物」距离必须取 `Physics` 子节点（或 `ViewFrustum.player_position()`），绝不读 `player` 根节点**（根节点从不位移、永停出生点）。

## 五、领域高频点（细节看 `项目结构说明.md` / `主线设计规格.md`）
- **渲染**：3D 网格一律 `SHADING_MODE_UNSHADED`；环境光 `0.83 × 9.0` ⇒ **albedo 亮过 0.45 变纯白**；占位件别漏 `material_override`。
- **UI/朝向/容器/采集/资源实体**：右列与底部控件 `anchor_*=1.0` + 负 offset（视口 1280×720）；运行时 `new` 的控件**禁用 `set_anchors_preset`**（0×0 点击穿透到 3D）→ 显式 size/position；朝向一律 `sprite_facing.gd`（`flip_h` **不能互抄**、yaw 落在 45° 整数倍）；数据层唯一入口 = `Inventory` 静态方法；采集中断**进度保留**；资源实体兜底判据 = **sprite 是否带 SpriteFrames**。
- **碰撞层**：只有 layer_1 玩家、layer_2 地面/障碍有名；障碍物 layer2 + mask0；玩家碰撞体 1.0 m 高 ⇒ 平射物/射线 y ≤ 1.2；点地走**解析求交**。
- **Boss/沙虫**：独立 `"boss"` 组、**绝不进 `"enemy"`**；世界状态只走 `WorldState`；终态 `GONE`（无 `dead`）；**脱战判据 = 玩家↔巢穴**（`player_home_distance()`）。场地 `tscn/sandworm_test.tscn`（F6）+ 回归 `test/boss_state_test.gd`（96 断言）。**两个距离旋钮**：够得着它 = 挥砍 2.0 + 受击体半径（现 r0.8 ⇒ ≈2.8 m）；**出手 = `max_range`，表头的值就是"开始交锋距离"**（够不着 ⇒ `return null` 不推指针；现 ①1.0/②15/③20/④0.5 ⇒ **玩家不贴进 1 m 它一招不出**）。
- **沙虫 4 条铁律**：① 形状基准 = `_facing`（绝不读 Visual）；`facing_locked` 同时锁 `_facing` 与 `_move_dir`（只锁其一都不够），锁住后**前摇定身**；② 🔴 判"目标在不在形状里"用**位移分量**、不用归一化点乘（重合时 `_horizontal_dir()` 返 ZERO ⇒ 贴脸永远打不中）；③ 受击窗口判据**只有 `_is_surfaced()` 一处**，切 `collision_layer`（8↔0）、**绝不切 mask**；④ **给玩家看的信号必须与判定同源**（形状/朝向/颜色都从判定字段派生；"钉死 or 跟随"看判定原点）。
- **沙虫弹道/连发/轮转/流沙**：弹道用线段↔**平面**距离（不隧穿、不碰物理查询），伤害落在三段之外（`struck` 回传）；连发 = 判定段按节拍多结算（`while` 防漏发），**判定段真值 = `strike_window() = max(strike_time, 末发 + 0.05)`** ⇒ 可配值只当**下限**（通用路子）；轮转 `_rotation_index`、够不着 ⇒ 无招且不推指针、换表归零，⚠ **`min_range > 0` 会死锁**；流沙吸引**改 `global_position` 不塞 `velocity`**、被拉对象走**组名遍历**、判定段 Boss **瞬移到圆心**。
