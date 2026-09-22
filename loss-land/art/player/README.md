# art/player — 玩家角色美术

**一个角色一个目录。** 角色专属的贴图、头像、装备外观都放各自的目录里，不要平铺在本层。

```
art/player/
├── adventurer/   char_blue.png    ← 冒险家（正式角色）
├── witch/        char_green.png   ← 魔女（正式角色）
└── robot/        char_red.png     ← 机器人（正式角色）
```

---

## 角色 ↔ 贴图映射

游戏里可选 **6 个角色**，但**只有 3 套美术**——三张换色变体表，被测试角色复用。

| 角色 id | 显示名 | 贴图 | 状态 |
|---|---|---|---|
| `adventurer` | 冒险家 | `adventurer/char_blue.png` | 正式角色 |
| `witch` | 魔女 | `witch/char_green.png` | 正式角色 |
| `robot` | 机器人 | `robot/char_red.png` | 正式角色 |
| `knight` | 青铠骑士（测试） | `adventurer/char_blue.png` ← **复用** | 测试用，正式版删 |
| `guard` | 赤铁守卫（测试） | `robot/char_red.png` ← **复用** | 测试用，正式版删 |
| `scout` | 翠影斥候（测试） | `witch/char_green.png` ← **复用** | 测试用，正式版删 |

> **为什么只有 3 个目录？** 因为只有 3 张图。三个测试角色是**借用**正式角色的换色表来验证换装 / 数值 / 存档流程的，它们没有自己的美术。给它们各建目录会是空目录。
> 等它们有了独立美术，新建 `knight/` `guard/` `scout/` 目录，再改 `character_registry.gd` 里对应的 `sprite` 路径即可 —— **不用动任何 UI 代码**，角色选择面板是遍历数据表动态生成的。

---

## 精灵表布局（三张表必须完全一致）

| 项 | 值 |
|---|---|
| 尺寸 | **448 × 392** |
| 网格 | 8 列 × 7 行 |
| 单帧 | **56 × 56** |

### 动画行的 y 坐标

| 动画 | y | 帧数 | 循环 |
|---|---|---|---|
| `idle` | 0 | 6 | ✅ |
| `attack` | 56 | 6 | ✗ |
| `walk` | 114 | 8 | ✅ |
| `hurt` | 280 | 8 | ✗ |
| `die` | 336 | 4 | ✗ |
| `harvest`（游戏内动画，非原始行名） | 168 | 复用 2 帧 | ✗ |

> ⚠ **行号不是按动画名排的，也不是等差数列。** `walk` 在 y=114 而不是 112，且单帧高 57（相邻行的像素会互相渗一点，这是原始素材的实际情况，别"修正"它）。
> 取帧前先核对上表，不要凭 56 的倍数推算。

### 第 4、5 行（y = 168 / y = 224）—— 持械行走，砍树动画从这里取

**2026-09-23 更正：这两行不是空的。** 旧版 README 写"目前是空的"，是当初只扫了前两帧就下的结论——实际它们有内容，且被 `harvest` 动画用上了。

两行合起来是 **16 帧的持械行走**（左手剑、右手圆盾）：y=168 是「俯身 → 起身 → 走 ×6」，y=224 是「走 ×6 → 俯身 → 起身」。

砍树 / 挖矿的 `harvest` 动画就取自 y=168 的前两帧：

| 在 `harvest` 中的位置 | region | 画面 |
|---|---|---|
| 首帧、末帧 | `Rect2(56, 168, 56, 56)` | 直立抬臂（举起斧 / 镐） |
| 中间帧 | `Rect2(0, 168, 56, 56)` | 俯身下劈 |

**为什么不直接用 `attack`（y=56）？** 它的末段帧带一大片白色剑光弧，一眼就是"在打人"；砍树时播它非常出戏（而且会让玩家以为攻击判定生效了）。`attack` 保留给真正的战斗，`harvest` 只在采集时播，**不结算伤害**。

改这两帧之前先跑 `python test/player_anim_check.py`——它会核对 `harvest` 的帧确实来自劳作行、没有退回 `attack` 行。

### 头像

角色选择面板的头像**没有独立立绘**，直接从精灵表左上角裁 `Rect2(0, 0, 56, 56)`（即 idle 首帧）。将来要独立立绘的话，放各自角色目录下（`adventurer/portrait.png`）。

---

## 加新角色 / 换贴图要改哪些地方

新贴图**必须与上表同布局**，否则换装逻辑会取到错帧。换贴图只需换底层图，`SpriteFrames` 里的帧区一个都不用动。

改路径时**必须同步**这 3 处，漏一处就会静默断链（图片空白，不报错）：

| # | 文件 | 内容 |
|---|---|---|
| 1 | `script/player/character_registry.gd` | 该角色 `CHARACTERS` 条目里的 `sprite` 字段 |
| 2 | `tscn/player.tscn` | 第 3 行 `ext_resource` 的 `path`（默认外观，进游戏前显示用） |
| 3 | 新图旁边的 `<图名>.png.import` | `source_file` 字段 |

改完跑：

```bash
python test/fix_import_paths.py    # 自动同步第 3 项
python test/check_data_refs.py     # 校验所有 res:// 引用是否都存在
python test/gd_static_lint.py      # GDScript 静态检查
python test/player_anim_check.py   # 帧区越界 / harvest 是否还在劳作行 / is_working 配对
```

> **在 Godot 里改路径的正确姿势**：关掉编辑器用文件管理器移动，然后手工改上面 1、2 两项 —— 或者直接在编辑器的 FileSystem 面板里拖拽，编辑器会自动重写引用（但 `.gd` 里手写的路径字符串它改不了，还是要自己改）。

---

## 相关文件

- `script/player/character_registry.gd` —— 角色数据表（唯一权威）、头像区域、贴图查询
- `script/player/physics.gd` —— `_apply_character()` 按 `active_id` 应用属性；`_swap_sprite_atlas()` 深拷贝 `SpriteFrames` 后只改 `AtlasTexture.atlas` 指向新表（帧区一个都不动，所以三张表必须同布局）
- `script/player/vitals.gd` —— 温度 / 饱食度 / 电量。运行时"到底有没有电"读它自己的只读属性 `has_power`，**不要**用 `CharacterRegistry.has_power()`
- `script/player/equipment.gd` —— 四槽装备（武器 / 护甲 / 工具 / 核心），槽内存的是 `ItemInstance`
