"""三层小推车儿童玩具模型 (总高 200 mm)，免螺丝插销拼装，生成可 3D 打印的 STL。

结构: 2 片侧框 (立柱 + 弧形把手 + 假轮子一体) + 3 个篮子。
篮子两端各有 2 根小圆柱插销 (代替原物的螺丝)，压进侧框立柱上的孔即可。

用法:  python3 build_cart.py      -> 输出到 ./stl/
所有尺寸单位 mm。改下面的参数即可重新生成。
"""
import os
import numpy as np
import trimesh
from manifold3d import Manifold, CrossSection, OpType, set_circular_segments

set_circular_segments(48)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stl")
os.makedirs(OUT, exist_ok=True)

# ---------------- 参数 ----------------
TOTAL_H = 200.0
L, D, BH = 100.0, 64.0, 26.0       # 篮子外形 长/宽/高
CORNER_R = 10.0                    # 篮子圆角
WALL, FLOOR = 1.6, 2.0             # 壁厚 / 底厚
LEVELS = [28.0, 88.0, 148.0]       # 三个篮子底面离地高度
POST_R = 5.0                       # 立柱半径 (圆管)
POST_T = 8.0                       # 立柱前后削平后的厚度 (= 侧框打印高度)
PY = D / 2 - 5.5                   # 立柱中心 y 位置
PX = L / 2 + POST_T / 2            # 侧框中心 x 位置 (内侧面贴住篮子端面)
HANDLE_R = 12.0                    # 把手转角半径
PEG_D, HOLE_D = 4.0, 4.2           # 插销 / 插孔直径 (紧了把 HOLE_D 调到 4.3，松了调到 4.1)
PEG_LEN = POST_T - 0.5
WHEEL_D, WHEEL_W = 16.0, 7.0       # 假轮子
POST_BOTTOM = 19.0                 # 立柱下端 (下面接轮叉)


def rrect(w, d, r):
    return CrossSection.square([w - 2 * r, d - 2 * r], center=True).offset(r)


def cyl_x(length, d, x0, y, z):
    """沿 x 轴的圆柱, 从 x0 开始。"""
    return Manifold.cylinder(length, d / 2).rotate([0, 90, 0]).translate([x0, y, z])


# ---------------- 篮子 ----------------
def basket():
    inner = rrect(L - 2 * WALL, D - 2 * WALL, CORNER_R - WALL)
    body = Manifold.extrude(rrect(L, D, CORNER_R), BH)
    body = body - Manifold.extrude(inner, BH).translate([0, 0, FLOOR])
    # 顶部卷边
    rim = Manifold.extrude(rrect(L + 1.6, D + 1.6, CORNER_R + 0.8), 2.2).translate([0, 0, BH - 2.2])
    rim = rim - Manifold.extrude(inner, 3).translate([0, 0, BH - 2.5])
    body = body + rim
    # 底部网格 (仿藤编网底)
    holes, pitch, s = [], 4.0, 2.4
    ax, ay = L / 2 - 12, D / 2 - 10
    for x in np.arange(-ax, ax + 0.01, pitch):
        for y in np.arange(-ay, ay + 0.01, pitch):
            holes.append(Manifold.cube([s, s, FLOOR + 1]).translate([x - s / 2, y - s / 2, -0.5]))
    body = body - Manifold.batch_boolean(holes, OpType.Add)
    # 两端插销 (代替螺丝)，末端倒角方便压入
    cavity = Manifold.extrude(inner, BH).translate([0, 0, FLOOR])
    for sx in (-1, 1):
        for sy in (-1, 1):
            # 圆角处补一个小凸台，让端面平贴立柱
            pad = cyl_x(3.0, 8.0, L / 2 - 3.0, sy * PY, BH / 2).scale([sx, 1, 1]) - cavity
            body = body + pad
            peg = Manifold.cylinder(PEG_LEN, PEG_D / 2) + \
                Manifold.cylinder(0.5, PEG_D / 2, PEG_D / 2 - 0.5).translate([0, 0, PEG_LEN])
            peg = peg.translate([0, 0, -0.5])  # 嵌入端墙 0.5 mm
            peg = peg.rotate([0, 90 * sx, 0]).translate([sx * L / 2, sy * PY, BH / 2])
            body = body + peg
    return body


# ---------------- 侧框 (立柱 + 把手 + 假轮子 一体) ----------------
def tube_along(points, r):
    balls = [Manifold.sphere(r).translate(p) for p in points]
    segs = [Manifold.batch_hull([balls[i], balls[i + 1]]) for i in range(len(balls) - 1)]
    return Manifold.batch_boolean(segs, OpType.Add)


def side_frame():
    top = TOTAL_H - POST_R
    pts = [(0, -PY, POST_BOTTOM), (0, -PY, top - HANDLE_R)]
    for a in np.linspace(np.pi, np.pi / 2, 10)[1:]:
        pts.append((0, -PY + HANDLE_R + HANDLE_R * np.cos(a), top - HANDLE_R + HANDLE_R * np.sin(a)))
    for a in np.linspace(np.pi / 2, 0, 10)[1:]:
        pts.append((0, PY - HANDLE_R + HANDLE_R * np.cos(a), top - HANDLE_R + HANDLE_R * np.sin(a)))
    pts.append((0, PY, POST_BOTTOM))
    frame = tube_along(pts, POST_R)

    for sy in (-1, 1):
        y = sy * PY
        # 轮叉: 在 yz 平面画轮廓，沿 x 拉伸 POST_T
        fork2d = CrossSection.batch_hull([
            CrossSection.circle(POST_R).translate([y, POST_BOTTOM]),
            CrossSection.square([12, 1]).translate([y - 6, WHEEL_D / 2 + 1.5]),
        ])
        frame = frame + Manifold.extrude(fork2d, POST_T).rotate([90, 0, 90]).translate([-POST_T / 2, 0, 0])
        # 假轮子 (轴向 x) + 轮毂
        frame = frame + cyl_x(WHEEL_W, WHEEL_D, -WHEEL_W / 2, y, WHEEL_D / 2)
        for x0 in (-WHEEL_W / 2 - 0.01, WHEEL_W / 2 - 0.6):
            frame = frame - (cyl_x(0.61, WHEEL_D - 4, x0, y, WHEEL_D / 2) - cyl_x(0.61, 6, x0, y, WHEEL_D / 2))
        frame = frame + cyl_x(POST_T, 4.5, -POST_T / 2, y, WHEEL_D / 2)

    # 前后削平 -> 平放打印
    frame = frame.trim_by_plane([1, 0, 0], -POST_T / 2).trim_by_plane([-1, 0, 0], -POST_T / 2)
    # 插孔 (贯穿)
    for lv in LEVELS:
        for sy in (-1, 1):
            frame = frame - cyl_x(POST_T + 2, HOLE_D, -POST_T / 2 - 1, sy * PY, lv + BH / 2)
    return frame


# ---------------- 导出 ----------------
def to_tm(m, color=None):
    mesh = m.to_mesh()
    t = trimesh.Trimesh(vertices=mesh.vert_properties[:, :3], faces=mesh.tri_verts, process=False)
    if color is not None:
        t.visual.face_colors = color
    return t


def place_on_bed(m):
    b = m.bounding_box()
    return m.translate([-(b[0] + b[3]) / 2, -(b[1] + b[4]) / 2, -b[2]])


def main():
    parts = {"basket": basket(), "side_frame": side_frame()}
    qty = {"basket": 3, "side_frame": 2}
    print_orient = {
        "basket": parts["basket"],
        "side_frame": parts["side_frame"].rotate([0, 90, 0]),   # 平放
    }
    for name, m in print_orient.items():
        assert m.status().name == "NoError", name
        t = to_tm(place_on_bed(m))
        t.export(os.path.join(OUT, f"{name}_x{qty[name]}.stl"))
        ext = t.bounds[1] - t.bounds[0]
        print(f"{name:10s} x{qty[name]}  {ext[0]:6.1f} x {ext[1]:6.1f} x {ext[2]:6.1f} mm  "
              f"vol {t.volume/1000:6.1f} cm3  watertight={t.is_watertight}")

    # 组装预览
    cream = [236, 226, 178, 255]
    scene = [to_tm(parts["basket"].translate([0, 0, lv]), cream) for lv in LEVELS]
    scene += [to_tm(parts["side_frame"].translate([sx * PX, 0, 0]), cream) for sx in (-1, 1)]
    asm = trimesh.util.concatenate(scene)
    asm.export(os.path.join(OUT, "assembly_preview.stl"))
    asm.export(os.path.join(OUT, "assembly_preview.glb"))
    print("assembly:", np.round(asm.bounds[1] - asm.bounds[0], 1), "mm")


if __name__ == "__main__":
    main()
