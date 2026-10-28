# 交接文档：在本机用 Bambu Studio 切片「三层小推车」模型

> 给本机 Claude Code 的任务说明。用户在 Windows 上，装有 Bambu Studio，打印机是 **Bambu Lab X2D（0.4 喷嘴）**，耗材 **PETG**。
> 目标：把 `cart_model/stl/` 里的零件切成两盘可直接打印的 `.gcode.3mf`，最后由**用户本人**在 Bambu Studio 里确认并点"打印"。
> **不要替用户发送打印任务**，切完片停下来汇报。

---

## 0. 背景

- 模型：儿童玩具三层推车，高 200 mm，免螺丝插销拼装，假轮子。
- 生成脚本：`cart_model/build_cart.py`（Python，manifold3d）。STL 已生成好，一般不需要重跑。
- 文件位置：用户下载到了 `%USERPROFILE%\Downloads\cart_model\stl\`（先确认，路径可能不同）。

| 文件 | 数量 | 说明 |
|---|---|---|
| `side_frame_x2.stl` | 2 | 侧框，已平放，200×69×8 mm |
| `basket_x3.stl` | 3 | 篮子，开口朝上，115×65.6×26 mm，外壁带藤编纹 |
| `assembly_preview.*` | – | **只是预览，不要打印** |

X2D 打印范围 256×256×261 mm，两盘都放得下。

---

## 1. 检查环境

```powershell
# 1) 找到 STL
Get-ChildItem "$env:USERPROFILE\Downloads\cart_model\stl"

# 2) 找到 Bambu Studio（常见安装位置）
$BS = "C:\Program Files\Bambu Studio\bambu-studio.exe"
Test-Path $BS
# 不在的话搜一下：
# Get-ChildItem "C:\Program Files*" -Recurse -Filter bambu-studio.exe -ErrorAction SilentlyContinue

# 3) 系统预设目录
$PROF = "C:\Program Files\Bambu Studio\resources\profiles\BBL"
Get-ChildItem "$PROF\machine"  -Filter "*X2D 0.4*"
Get-ChildItem "$PROF\process"  -Filter "*@BBL X2D.json"
Get-ChildItem "$PROF\filament" -Filter "*PETG*X2D 0.4*"
```

确认存在这几个预设（名字以本机实际版本为准）：
- 打印机：`Bambu Lab X2D 0.4 nozzle`
- 工艺：`0.16mm Standard @BBL X2D`、`0.12mm High Quality @BBL X2D`
- 耗材：优先 `Bambu PETG Matte @BBL X2D 0.4 nozzle`，没有则 `Bambu PETG HF @BBL X2D 0.4 nozzle`，再不行 `Bambu PETG Basic @BBL X2D 0.4 nozzle`

**先问用户实际装的是哪种 PETG**（哑光/HF/Basic/第三方），再选耗材预设。

---

## 2. 切片参数

### 盘 1：侧框 ×2
| 参数键 | 值 | 说明 |
|---|---|---|
| `layer_height` | 0.16 | |
| `wall_loops` | 3 | |
| `sparse_infill_density` | 20% | |
| `ironing_type` | `top` | 仅最顶层熨烫 |
| `ironing_flow` | 10% | PETG 用 10% |
| `seam_position` | `aligned` | |
| `outer_wall_speed` | 60 | |
| `wall_sequence` | `inner wall/outer wall` | |
| `curr_bed_type` | `Textured PEI Plate` | PETG 不要用光面板 |

### 盘 2：篮子 ×3
| 参数键 | 值 | 说明 |
|---|---|---|
| `layer_height` | 0.12 | |
| `wall_loops` | 3 | |
| `sparse_infill_density` | 15% | |
| `ironing_type` | `no ironing` | |
| `fuzzy_skin` | `none` | **必须关**，否则会糊掉藤编纹 |
| `seam_position` | `back` | 藤编纹会盖住接缝 |
| `outer_wall_speed` | 60 | |
| `wall_sequence` | `inner wall/outer wall` | |
| `curr_bed_type` | `Textured PEI Plate` | |

两盘都**不需要支撑**（`enable_support` = 0）。

---

## 3. 用命令行切片（推荐做法）

两盘分开切，各出一个 `.gcode.3mf`。

1. 在 `cart_model\slice\` 下建两个**覆盖用的工艺 JSON**，继承系统预设，只改上表里的键。示例 `process_frames.json`：

```json
{
  "type": "process",
  "name": "cart frames PETG X2D",
  "inherits": "0.16mm Standard @BBL X2D",
  "from": "User",
  "layer_height": "0.16",
  "wall_loops": "3",
  "sparse_infill_density": "20%",
  "ironing_type": "top",
  "ironing_flow": "10%",
  "seam_position": "aligned",
  "outer_wall_speed": ["60"],
  "enable_support": "0",
  "compatible_printers": ["Bambu Lab X2D 0.4 nozzle"]
}
```

   `process_baskets.json` 同理：继承 `0.12mm High Quality @BBL X2D`，按盘 2 的表改。

   > 注意：键名和取值格式（字符串、数组、带不带 `%`）要对照本机 `$PROF\process\` 下同名系统预设和它的父预设来写。有些键在 X2D 上是数组（双喷头）。不确定就打开父预设看原格式。

2. 运行切片（以盘 1 为例）：

```powershell
$OUT = "$env:USERPROFILE\Downloads\cart_model\slice"
& $BS --debug 2 `
  --load-settings "$PROF\machine\Bambu Lab X2D 0.4 nozzle.json;$OUT\process_frames.json" `
  --load-filaments "$PROF\filament\Bambu PETG HF @BBL X2D 0.4 nozzle.json" `
  --curr-bed-type "Textured PEI Plate" `
  --arrange 1 --orient 0 `
  --slice 0 `
  --export-3mf "$OUT\plate1_frames.gcode.3mf" `
  "$env:USERPROFILE\Downloads\cart_model\stl\side_frame_x2.stl" `
  "$env:USERPROFILE\Downloads\cart_model\stl\side_frame_x2.stl"
```

   - 同一个 STL 传两次 = 两个侧框。篮子盘就把 `basket_x3.stl` 传 3 次，换成 `process_baskets.json`，输出 `plate2_baskets.gcode.3mf`。
   - `--orient 0`：**不要**让切片软件自动旋转，零件朝向已经摆好。
   - 先跑 `& $BS --help` 核对本机版本支持的参数名。不同版本的参数可能略有差异，以 `--help` 为准。
   - 系统预设如果因为 `inherits` 链加载失败：在 GUI 里把预设"另存为用户预设"，再用 `%APPDATA%\BambuStudio\user\<用户ID>\` 下导出的完整 JSON。

3. 检查结果：
   - 两个 `.gcode.3mf` 都生成了，命令退出码为 0。
   - 日志里没有 `error`、`out of bed` 或 `empty layer` 这类报错。
   - 把预计时间和耗材用量（在 3mf 的 `Metadata/slice_info.config` 里）汇报给用户。

---

## 4. 备选：GUI 手动切片

命令行跑不通时，告诉用户在 Bambu Studio 里手动操作：

1. 打印机选 X2D 0.4，耗材选对应 PETG，打印板选**纹理 PEI**。
2. 盘 1：拖入 `side_frame_x2.stl`，右键 → 填充/复制 → 共 2 个，按 `A` 排版，按第 2 节的表设参数。
3. 点 `+` 新建盘 2：拖入 `basket_x3.stl`，复制成 3 个，按 `A` 排版，按第 2 节的表设参数。
4. 点"切片所有盘"。

---

## 5. 交还给用户

- 用 Bambu Studio 打开两个 `.gcode.3mf`（`Start-Process $BS -ArgumentList "<文件>"`），让用户在预览里检查。重点看两处：篮子外壁藤编纹清晰，侧框顶层有熨烫。
- **由用户自己点"打印"发送到 X2D**。
- 提醒用户：
  - PETG 容易拉丝，篮子网格底的挂丝用热风枪快速扫一下就掉了。
  - 插销太紧装不进去时，把 `build_cart.py` 里的 `HOLE_D` 从 4.2 改成 4.3，运行 `python build_cart.py` 重新生成后再切（依赖：`pip install manifold3d trimesh numpy scipy`）。

---

## 6. 组装（打印完后）

1. 一片侧框平放，孔朝上。
2. 三个篮子一端的插销插进这片侧框的孔里。
3. 第二片侧框对准另一端的插销，压到底。
4. 立起来就好了。
