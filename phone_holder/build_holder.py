"""重力手机夹 (3D 打印) —— 参数化结构模型，输出 STL。

原理: 手机放上去压住底托 -> 底托下滑 -> 底托上的两根销子在左右夹臂的 45° 斜槽里走
      -> 两个夹臂同步向内收 -> 夹住手机。拿走手机，打印弹簧把底托拉回去，夹臂张开。

零件 (共 5 个打印件 + 4 颗 M3 自攻螺丝，不需要金属弹簧):
  base   底壳: 背板(背面 4 个安装孔) + 围墙 + 底托导轨 + 弹簧挂柱 + 4 根盖板螺丝柱
  foot   底托: 竖直滑块 + 2 根驱动销 + 前面托手机的托盘 + 顶上一体打印的折线弹簧(套在挂柱上)
  arm_l / arm_r  左右夹臂: 水平滑条(带斜槽) + 夹爪
  cover  面板: 手机靠的面 + 背面 3 根导向筋(夹臂在筋之间滑)

坐标 (装配状态): X 向右, Y 向上 (手机竖着的方向), Z 朝向手机 (背板 z=0, 面板正面 z 最大)。
用法:  python3 build_holder.py   -> stl/ 下输出打印件 + 预览
所有尺寸 mm。
"""
import os
import sys
import numpy as np
import trimesh
from manifold3d import Manifold, CrossSection, Mesh, set_circular_segments

set_circular_segments(64)
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "stl")
os.makedirs(OUT, exist_ok=True)

# ======================= 参数 =======================
# --- 背面 4 个安装孔 (尺寸待定，先用占位值) ---
# 孔中心相对于背板中心的坐标 (x, y)。拿到实测尺寸后直接改这里。
MOUNT_HOLES = [(-15.0, -20.0), (15.0, -20.0), (-15.0, 20.0), (15.0, 20.0)]   # 占位: 30 x 40 矩形
MOUNT_HOLE_D = 4.0        # M3 热熔铜螺母用 4.0；直接拧 M3 自攻用 2.6；M4 自攻用 3.4
MOUNT_HOLE_DEPTH = 4.0    # 盲孔深度 (背板厚 6，不会打穿到机构里)

# --- 外壳 ---
W = 54.0                   # 外壳宽 (外壳高 H 由弹簧长度自动算出)
CORNER_R = 5.0
WALL = 2.5                 # 围墙厚
CL = 0.3                   # 滑动间隙 (打印太紧就调到 0.35~0.4)

# --- 分层 (Z) ---
BASE_T = 6.0               # 背板厚
FOOT_T = 4.5               # 底托滑块层厚
ARM_T = 4.5                # 夹臂滑条层厚
COVER_T = 2.5              # 面板厚

# --- 机构 ---
TRAVEL = 14.0              # 底托行程
RATIO = 1.0                # 夹臂单边行程 / 底托行程 (1.0 = 45° 斜槽；改小夹紧力更大但开口变小)
PIN_D = 4.0                # 驱动销直径
SLOT_W = 4.5               # 斜槽宽
PIN_X = 6.0                # 两根驱动销离中线距离
JAW_GAP = 2.0              # 夹爪收到最紧时离外壳侧面的间隙

# --- 手机 ---
PHONE_T = 13.0             # 夹爪能容纳的最大厚度 (手机+壳)
JAW_Y = (16.0, 64.0)       # 夹爪高度范围
JAW_W = 5.0                # 夹爪厚度
LIP = 3.0                  # 夹爪前沿内勾 (45° 斜面，免支撑)

# --- 打印弹簧: 底托顶上的折线(蛇形)拉簧，上端圆环套在底壳挂柱上 ---
SPR_N = 8                  # 折条根数 (越多越软、越不容易疲劳，但更占高度)
SPR_T = 0.8                # 折条厚度 (= 0.4 喷嘴 2 条线；改 1.0 变硬约 2 倍)
SPR_GAP = 0.8              # 折条间隙 (打印状态)
SPR_HALF = 11.0            # 折条半长 (总长 22)
SPR_CONN = 1.5             # 折条两端连接块宽
SPR_PRE = 3.0              # 预拉伸: 装配时把圆环往上拉 3 mm 套到挂柱上，保证夹臂能完全弹开
RING_OD, RING_ID = 6.4, 3.6
PEG_D = 3.0                # 挂柱直径
SPR_E = 2000.0             # 材料弹性模量 MPa (PETG≈2000, PLA≈3000) —— 只用于估算弹力

# --- 盖板螺丝 ---
POST_R = 3.5
SCREW_PILOT = 2.5          # M3 自攻底孔
SCREW_CLEAR = 3.3
SCREW_HEAD = 6.0           # 沉头直径

# ======================= 推导尺寸 =======================
HX = W / 2
IN_X = HX - WALL                     # 围墙内侧 x
ARM_TRAVEL = RATIO * TRAVEL
Z_F0 = BASE_T + CL                   # 底托层
Z_F1 = Z_F0 + FOOT_T
Z_A0 = Z_F1 + CL                     # 夹臂层
Z_A1 = Z_A0 + ARM_T
Z_C0 = Z_A1 + CL                     # 面板
Z_C1 = Z_C0 + COVER_T
Z_LIP = Z_C1 + PHONE_T               # 夹爪/托盘前沿
Z_FRONT = Z_LIP + 2.0

# 夹臂滑条带宽 = 斜槽竖向跨度 + 槽宽 + 两边各留 2.5
BAND = TRAVEL + SLOT_W + 5.0
RIB = 4.0
RIB_CL = 0.4
MID = 41.0                 # 夹臂布局中心高度
R_BAND = (MID - RIB / 2 - RIB_CL - BAND - 1.0, MID - RIB / 2 - RIB_CL - 1.0)   # 右臂滑条 y
L_BAND = (R_BAND[1] + 2 * RIB_CL + RIB, R_BAND[1] + 2 * RIB_CL + RIB + BAND)       # 左臂滑条 y
# 驱动销 (底托上, 张开状态) 在各自滑条上部
PIN_L = (-PIN_X, L_BAND[1] - SLOT_W / 2 - 2.5)
PIN_R = (PIN_X, R_BAND[1] - SLOT_W / 2 - 2.5)

FOOT_X = PIN_X + 6.0                  # 底托滑块半宽
FOOT_Y = (PIN_R[1] - 4.75, PIN_L[1] + 4.75)
STEM_X = 5.0                          # 底托下伸杆半宽
TRAY_X = 20.0
TRAY_Y = (-8.0, -4.0)                 # 托盘 (张开状态)，顶面 y=-4 是手机底边落点
SEAT_FLAT = 8.0                       # 托盘平面段深度，之后 45° 斜坡把手机推向面板
JAW_OPEN = HX + JAW_GAP + ARM_TRAVEL  # 张开时夹爪内表面 |x|

# 打印弹簧 (底托坐标系, 张开状态)
SPR_Y0 = FOOT_Y[1] + 1.5                             # 第一根折条底面
RING_X = -SPR_HALF + RING_OD / 2


def ring_y(stretch):
    top = SPR_Y0 + SPR_N * SPR_T + (SPR_N - 1) * SPR_GAP + stretch * (SPR_N - 1) / SPR_N
    return top + 1.0 + stretch / SPR_N + RING_OD / 2


PEG_Y = ring_y(SPR_PRE)                              # 挂柱位置 (固定在底壳上)
H = PEG_Y + RING_OD / 2 + 0.6 + WALL                 # 外壳高

POSTS = [(sx * (HX - 8.0), y) for sx in (-1, 1) for y in (6.5, H - 6.5)]


# ======================= 工具函数 =======================
def box(x0, x1, y0, y1, z0, z1):
    return Manifold.cube([x1 - x0, y1 - y0, z1 - z0]).translate([x0, y0, z0])


def cyl(x, y, z0, z1, d):
    return Manifold.cylinder(z1 - z0, d / 2).translate([x, y, z0])


def rrect(w, h, r, cx=0.0, cy=0.0):
    return CrossSection.square([w - 2 * r, h - 2 * r], center=True).offset(r).translate([cx, cy])


def slot2d(p0, p1, w):
    return CrossSection.batch_hull([CrossSection.circle(w / 2).translate(list(p0)),
                                    CrossSection.circle(w / 2).translate(list(p1))])


def poly_yz(pts, x0, x1):
    """(y,z) 多边形沿 X 拉伸"""
    cs = CrossSection([[list(p) for p in pts]])
    # 拉伸方向 Z -> 旋转到 X:  (a,b,c) 拉伸体 -> 先绕 Y 转 90
    m = cs.extrude(x1 - x0)                 # 局部: x=y坐标, y=z坐标, z=拉伸
    m = m.transform(np.array([[0, 0, 1, x0], [1, 0, 0, 0], [0, 1, 0, 0]], dtype=float))
    return m


def poly_xz(pts, y0, y1):
    """(x,z) 多边形沿 Y 拉伸"""
    cs = CrossSection([[list(p) for p in pts]])
    m = cs.extrude(y1 - y0)                 # 局部: x, y=z坐标, z=拉伸
    m = m.transform(np.array([[1, 0, 0, 0], [0, 0, 1, y0], [0, 1, 0, 0]], dtype=float))
    return m


# ======================= 零件 =======================
def make_base():
    outer = rrect(W, H, CORNER_R, 0, H / 2)
    inner = rrect(W - 2 * WALL, H - 2 * WALL, CORNER_R - WALL, 0, H / 2)
    m = outer.extrude(BASE_T) + (outer - inner).extrude(Z_C0 - BASE_T).translate([0, 0, BASE_T])

    # 盖板螺丝柱
    for (x, y) in POSTS:
        m += cyl(x, y, BASE_T, Z_C0, 2 * POST_R)
    # 底托两侧导轨 (只在底托层高度)
    for s in (-1, 1):
        x_in, x_out = FOOT_X + CL, IN_X + 0.5
        m += box(min(s * x_in, s * x_out), max(s * x_in, s * x_out), 10.5, FOOT_Y[1], BASE_T, Z_F1)
    # 底托伸出口 (底墙开口)
    m -= box(-STEM_X - CL - 0.1, STEM_X + CL + 0.1, -1, WALL + 1, BASE_T, Z_A0)
    # 夹臂穿墙口: 左墙开在左臂滑条高度，右墙开在右臂滑条高度
    m -= box(-HX - 1, -IN_X + 0.1, L_BAND[0] - RIB_CL, L_BAND[1] + RIB_CL, Z_F1 + 0.1, Z_C0 + 1)
    m -= box(IN_X - 0.1, HX + 1, R_BAND[0] - RIB_CL, R_BAND[1] + RIB_CL, Z_F1 + 0.1, Z_C0 + 1)
    # 弹簧挂柱 (一直伸到面板下面，圆环脱不出来)
    m += cyl(RING_X, PEG_Y, BASE_T - 0.1, Z_C0 - CL, PEG_D)
    # 螺丝底孔
    for (x, y) in POSTS:
        m -= cyl(x, y, BASE_T + 1.0, Z_C0 + 1, SCREW_PILOT)
    # 背面安装孔 (从背面开的盲孔)
    for (hx, hy) in MOUNT_HOLES:
        m -= cyl(hx, H / 2 + hy, -1, MOUNT_HOLE_DEPTH, MOUNT_HOLE_D)
    return m


def make_cover():
    plate = rrect(W, H, CORNER_R, 0, H / 2).extrude(COVER_T).translate([0, 0, Z_C0])
    m = plate
    # 导向筋: 右臂滑条下方 / 两条滑条之间 / 左臂滑条上方
    rib_ys = [(R_BAND[0] - RIB_CL - RIB, R_BAND[0] - RIB_CL),
              (R_BAND[1] + RIB_CL, L_BAND[0] - RIB_CL),
              (L_BAND[1] + RIB_CL, L_BAND[1] + RIB_CL + RIB)]
    for (y0, y1) in rib_ys:
        m += box(-IN_X + CL, IN_X - CL, y0, y1, Z_A0, Z_C0 + 0.01)
    for (x, y) in POSTS:   # 筋避开螺丝柱
        m -= cyl(x, y, Z_A0 - 1, Z_C0, 2 * POST_R + 2 * CL)
    # 沉头螺丝孔
    for (x, y) in POSTS:
        m -= cyl(x, y, Z_C0 - 1, Z_C1 + 1, SCREW_CLEAR)
        m -= Manifold.cylinder(SCREW_HEAD / 2 - SCREW_CLEAR / 2 + 0.01, SCREW_CLEAR / 2, SCREW_HEAD / 2) \
            .translate([x, y, Z_C1 - (SCREW_HEAD / 2 - SCREW_CLEAR / 2)])
    # 正面贴防滑垫的浅槽 (0.6 深)
    m -= rrect(W - 14, H - 24, 4, 0, H / 2).extrude(1.0).translate([0, 0, Z_C1 - 0.6])
    return m


def make_spring(stretch):
    """底托顶上的折线拉簧 (底托坐标系)。stretch=0 是打印状态；装配预览里按拉伸量把间距均匀拉开 (近似)。"""
    p = SPR_T + SPR_GAP + stretch / SPR_N
    z0, z1 = Z_F0, Z_F1
    m = box(-SPR_HALF, -SPR_HALF + SPR_CONN, FOOT_Y[1] - 1.0, SPR_Y0 + 0.01, z0, z1)       # 底部连接到底托
    for i in range(SPR_N):
        y = SPR_Y0 + i * p
        m += box(-SPR_HALF, SPR_HALF, y, y + SPR_T, z0, z1)
        if i < SPR_N - 1:                                                                   # 两端交替连接
            x0 = SPR_HALF - SPR_CONN if i % 2 == 0 else -SPR_HALF
            m += box(x0, x0 + SPR_CONN, y, y + p + 0.01, z0, z1)
    y_top = SPR_Y0 + (SPR_N - 1) * p + SPR_T
    ry = ring_y(stretch)
    x0 = -SPR_HALF if (SPR_N - 1) % 2 == 1 else SPR_HALF - SPR_CONN
    m += box(x0, x0 + SPR_CONN, y_top - 0.01, ry, z0, z1)
    m += box(RING_X - 1.0, RING_X + 1.0, y_top - 0.01, ry, z0, z1)
    m += cyl(RING_X, ry, z0, z1, RING_OD)
    m -= cyl(RING_X, ry, z0 - 1, z1 + 1, RING_ID)
    return m


def make_foot(stretch=0.0):
    """张开状态 (d=0) 的底托；stretch = 弹簧拉伸量"""
    m = rrect(2 * FOOT_X, FOOT_Y[1] - FOOT_Y[0], 2.0, 0, (FOOT_Y[0] + FOOT_Y[1]) / 2).extrude(FOOT_T).translate([0, 0, Z_F0])
    m += box(-STEM_X, STEM_X, TRAY_Y[0] + 1, FOOT_Y[0] + 2, Z_F0, Z_F1)
    # 驱动销 (向前伸进夹臂斜槽)
    for (x, y) in (PIN_L, PIN_R):
        m += cyl(x, y, Z_F1 - 0.5, Z_A1 - 0.3, PIN_D)
    # 托盘: 平面段 + 45° 斜坡前沿 (斜坡把手机底边推向面板，打印免支撑)
    y_top = TRAY_Y[1]
    z_slope = Z_C1 + SEAT_FLAT
    lip_h = Z_FRONT - z_slope - 2.0
    prof = [(TRAY_Y[0], Z_F0), (y_top, Z_F0), (y_top, z_slope),
            (y_top + lip_h, z_slope + lip_h), (y_top + lip_h, Z_FRONT), (TRAY_Y[0], Z_FRONT)]
    tray = poly_yz(prof, -TRAY_X, TRAY_X)
    # 托盘左右前角倒圆 (俯视 XZ 平面)
    corner = CrossSection.square([2 * TRAY_X, Z_FRONT - Z_F0 + 4]).translate([-TRAY_X, Z_F0 - 4]).offset(-4).offset(4)
    tray ^= poly_xz(corner.to_polygons()[0].tolist(), TRAY_Y[0] - 1, y_top + lip_h + 1)
    m += tray
    m += make_spring(stretch)
    return m


def make_arm(side):
    """side=-1 左臂, +1 右臂；张开状态"""
    band = L_BAND if side < 0 else R_BAND
    pin = PIN_L if side < 0 else PIN_R
    xj = side * JAW_OPEN                       # 夹爪内表面
    x_inner = pin[0] - side * (SLOT_W / 2 + 2.5)   # 滑条内端 (靠中线一端)
    x_outer = xj + side * JAW_W
    bar = box(min(x_inner, x_outer), max(x_inner, x_outer), band[0], band[1], Z_A0, Z_A1)
    # 斜槽: 相对夹臂，销子从 pin 走到 pin + (-side*ARM_TRAVEL, -TRAVEL)
    p1 = (pin[0] + side * ARM_TRAVEL, pin[1] - TRAVEL)
    slot = slot2d(pin, p1, SLOT_W).extrude(ARM_T + 2).translate([0, 0, Z_A0 - 1])
    bar -= slot
    # 夹爪 (XZ 截面沿 Y 拉伸)，内侧前沿 45° 内勾
    zl = Z_FRONT - 2.0
    prof = [(x_outer, Z_A0), (xj, Z_A0), (xj, zl - LIP), (xj - side * LIP, zl), (xj - side * LIP, Z_FRONT), (x_outer, Z_FRONT)]
    if side > 0:
        prof = prof[::-1]
    jaw = poly_xz(prof, JAW_Y[0], JAW_Y[1])
    return bar + jaw


def foot_at(d):
    return make_foot(SPR_PRE + d).translate([0, -d, 0])


def arm_at(side, d):
    return make_arm(side).translate([-side * RATIO * d, 0, 0])


# ======================= 检查 =======================
def check():
    ok = True
    base, cover = make_base(), make_cover()
    for d in np.linspace(0, TRAVEL, 8):
        parts = {"base": base, "cover": cover, "foot": foot_at(d),
                 "arm_l": arm_at(-1, d), "arm_r": arm_at(1, d)}
        names = list(parts)
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                v = (parts[names[i]] ^ parts[names[j]]).volume()
                if v > 1e-3:
                    print(f"  干涉! d={d:.1f}  {names[i]} x {names[j]}  {v:.3f} mm3")
                    ok = False
    # 安装孔不能碰到弹簧槽 / 外形
    for (hx, hy) in MOUNT_HOLES:
        if abs(hx) + MOUNT_HOLE_D / 2 > HX - 1.5 or not (1.5 < H / 2 + hy - MOUNT_HOLE_D / 2 and H / 2 + hy + MOUNT_HOLE_D / 2 < H - 1.5):
            print(f"  警告: 安装孔 ({hx},{hy}) 太靠边/超出背板")
            ok = False
    print("干涉检查:", "通过 (全行程 0 干涉)" if ok else "有问题")
    print(f"可夹手机宽度: {2 * (JAW_OPEN - ARM_TRAVEL):.0f} ~ {2 * JAW_OPEN:.0f} mm  (含壳)")
    print(f"可夹厚度: <= {PHONE_T:.0f} mm,  底托行程 {TRAVEL:.0f} mm,  夹紧力 ≈ {1 / (2 * RATIO):.2f} × 手机重量 (每侧, 不计摩擦/弹簧)")
    L = 2 * SPR_HALF - SPR_CONN
    k = SPR_E * FOOT_T * SPR_T ** 3 / L ** 3 / SPR_N           # 每根折条按两端导向梁计
    s_max = SPR_PRE + TRAVEL
    strain = 3 * SPR_T * (s_max / SPR_N) / L ** 2
    d75 = (JAW_OPEN - 37.5) / RATIO
    print(f"外壳: {W:.0f} x {H:.1f} mm")
    print(f"打印弹簧: 刚度≈{k:.3f} N/mm, 张开时预紧≈{k * SPR_PRE * 102:.0f} gf, 夹 75mm 手机时≈{k * (SPR_PRE + d75) * 102:.0f} gf, "
          f"最紧≈{k * s_max * 102:.0f} gf;  最大应变≈{strain * 100:.2f}% (PETG 建议 < 1.5%)")
    if strain > 0.015:
        print("  警告: 弹簧应变偏大，增加 SPR_N 或减小 SPR_T")
        ok = False
    return ok


# ======================= 输出 =======================
def to_tri(m):
    mesh = m.to_mesh()
    return trimesh.Trimesh(vertices=np.asarray(mesh.vert_properties)[:, :3], faces=np.asarray(mesh.tri_verts), process=False)


ROT_FLIP = np.array([[1, 0, 0, 0], [0, -1, 0, 0], [0, 0, -1, 0]], dtype=float)  # 绕 X 转 180


def print_parts():
    """打印朝向: 全部平放，免支撑"""
    def on_bed(m):
        lo = m.bounding_box()[2]
        return m.translate([0, 0, -lo])
    base = on_bed(make_base())                                   # 背面贴床
    cover = on_bed(make_cover().transform(ROT_FLIP))             # 正面贴床，筋朝上
    foot = on_bed(make_foot())                                   # 背面贴床，销子朝上，弹簧平躺
    arm_l = on_bed(make_arm(-1))                                 # 滑条底面贴床，夹爪朝上
    arm_r = on_bed(make_arm(1))
    return {"base": base, "cover": cover, "foot": foot, "arm_l": arm_l, "arm_r": arm_r}


# 预览: 装配坐标 (x, y, z) -> 渲染坐标 (x, -z, y)，竖起来，正面朝 -Y
TO_VIEW = np.array([[1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0], [0, 0, 0, 1]], dtype=float)
COLORS = {"base": (235, 232, 225), "cover": (245, 243, 238), "foot": (120, 220, 140),
          "arm_l": (90, 205, 120), "arm_r": (90, 205, 120), "phone": (40, 42, 50)}


def scene_at(d, phone_w=None, explode=0.0, cover=True):
    sc = trimesh.Scene()
    off = {"base": 0, "foot": 1, "arm_l": 2, "arm_r": 2, "cover": 3}
    parts = {"base": make_base(), "cover": make_cover(), "foot": foot_at(d),
             "arm_l": arm_at(-1, d), "arm_r": arm_at(1, d)}
    if not cover:
        del parts["cover"]
    for name, m in parts.items():
        t = to_tri(m.translate([0, 0, off[name] * explode]))
        t.apply_transform(TO_VIEW)
        t.apply_translation([0, 0, 30])
        mat = trimesh.visual.material.PBRMaterial(baseColorFactor=list(COLORS[name]) + [255], roughnessFactor=0.7)
        t.visual = trimesh.visual.TextureVisuals(material=mat)
        sc.add_geometry(t, geom_name=name)
    if phone_w:
        ph = box(-phone_w / 2, phone_w / 2, TRAY_Y[1] - d, TRAY_Y[1] - d + 150, Z_C1, Z_C1 + 8.5)
        t = to_tri(ph)
        t.apply_transform(TO_VIEW)
        t.apply_translation([0, 0, 30])
        t.visual = trimesh.visual.TextureVisuals(material=trimesh.visual.material.PBRMaterial(
            baseColorFactor=list(COLORS["phone"]) + [255], roughnessFactor=0.4))
        sc.add_geometry(t, geom_name="phone")
    return sc


def main():
    ok = check()
    for name, m in print_parts().items():
        t = to_tri(m)
        assert t.is_watertight, name
        bb = t.bounds
        print(f"  {name:6s} {bb[1][0] - bb[0][0]:5.1f} x {bb[1][1] - bb[0][1]:5.1f} x {bb[1][2] - bb[0][2]:5.1f} mm")
        t.export(os.path.join(OUT, f"{name}.stl"))
    scene_at(0).export(os.path.join(OUT, "preview_open.glb"))
    # 75 mm 宽手机: 夹臂收进 (JAW_OPEN - 37.5)
    d75 = (JAW_OPEN - 75 / 2) / RATIO
    scene_at(d75, phone_w=75).export(os.path.join(OUT, "preview_phone75.glb"))
    scene_at(0, cover=False).export(os.path.join(OUT, "preview_mech_open.glb"))       # 去掉面板看机构
    scene_at(TRAVEL, cover=False).export(os.path.join(OUT, "preview_mech_closed.glb"))
    # 装配预览 STL (只看不打)
    sc = scene_at(0)
    trimesh.util.concatenate(list(sc.geometry.values())).export(os.path.join(OUT, "assembly_preview.stl"))
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
