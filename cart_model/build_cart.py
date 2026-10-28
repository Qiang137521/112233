"""三层小推车拼装模型 (总高 200 mm)，生成可 3D 打印的 STL 零件。

用法:  python3 build_cart.py      -> 输出到 ./stl/
所有尺寸单位 mm。改下面的参数即可重新生成。
"""
import os
import numpy as np
import trimesh
from manifold3d import Manifold, CrossSection, OpType, set_circular_segments

set_circular_segments(64)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stl")
os.makedirs(OUT, exist_ok=True)

# ---------------- 参数 ----------------
TOTAL_H = 200.0
W, D, H = 110.0, 72.0, 24.0        # 篮子外形 长/宽/高
CORNER_R = 6.0                     # 篮子圆角
WALL, FLOOR = 2.4, 1.8             # 壁厚 / 底厚
POST_D = 10.0                      # 立柱直径
BOSS_D = 11.5                      # 篮子角上的柱座直径
PX, PY = W / 2 + 1.5, D / 2 + 1.5  # 立柱中心位置
PIN_D = 6.0                        # 插销直径
HOLE_D = 6.2                       # 插孔直径 (配合间隙 0.2，松了就改 6.1，紧了改 6.3)
SOCKET = 9.0                       # 篮子插孔深度 (上下各一个)
CASTER_H = 22.0                    # 地面到底层篮子底面
HANDLE_RISE = 18.0                 # 把手高出顶层篮子的高度
GAP = (TOTAL_H - CASTER_H - 3 * H - HANDLE_RISE) / 2  # 层间立柱长度 (=44)
WHEEL_D, WHEEL_W = 13.0, 5.0
AXLE_HOLE_FORK, AXLE_HOLE_WHEEL = 2.0, 2.4  # 用 1.75 mm 耗材当轮轴


def rrect(w, d, r):
    return CrossSection.square([w - 2 * r, d - 2 * r], center=True).offset(r)


def cyl(h, d, z0=0.0, x=0.0, y=0.0):
    return Manifold.cylinder(h, d / 2, d / 2).translate([x, y, z0])


def chamfer_pin(length, d=PIN_D, c=0.6):
    """竖直插销，两端倒角，底面在 z=0。"""
    body = cyl(length - 2 * c, d, c)
    bot = Manifold.cylinder(c, d / 2 - c, d / 2)
    top = Manifold.cylinder(c, d / 2, d / 2 - c).translate([0, 0, length - c])
    return body + bot + top


def corners():
    return [(sx * PX, sy * PY) for sx in (-1, 1) for sy in (-1, 1)]


# ---------------- 篮子 ----------------
def basket():
    outer = rrect(W, D, CORNER_R)
    body = Manifold.extrude(outer, H)
    inner = Manifold.extrude(rrect(W - 2 * WALL, D - 2 * WALL, CORNER_R - WALL), H).translate([0, 0, FLOOR])
    body = body - inner
    # 外壁竖条纹
    g = 2.0
    grooves = []
    for x in np.arange(-W / 2 + 10, W / 2 - 9, 5.0):
        for sy in (-1, 1):
            grooves.append(Manifold.cube([g, 1.4, H - 7], center=False).translate([x - g / 2, sy * D / 2 - 0.7, 3]))
    for y in np.arange(-D / 2 + 10, D / 2 - 9, 5.0):
        for sx in (-1, 1):
            grooves.append(Manifold.cube([1.4, g, H - 7]).translate([sx * W / 2 - 0.7, y - g / 2, 3]))
    body = body - Manifold.batch_boolean(grooves, OpType.Add)
    # 顶部外翻沿口
    lip = Manifold.extrude(rrect(W + 2.4, D + 2.4, CORNER_R + 1.2), 2.5).translate([0, 0, H - 2.5])
    lip = lip - Manifold.extrude(rrect(W - 2 * WALL, D - 2 * WALL, CORNER_R - WALL), 3).translate([0, 0, H - 2.6])
    body = body + lip
    # 角柱座 + 与篮体的连接
    for x, y in corners():
        ax, ay = np.sign(x) * (W / 2 - CORNER_R), np.sign(y) * (D / 2 - CORNER_R)
        web = CrossSection.batch_hull([CrossSection.circle(BOSS_D / 2).translate([x, y]),
                                 CrossSection.circle(3.0).translate([ax + np.sign(x) * 2, ay + np.sign(y) * 2])])
        body = body + Manifold.extrude(web, H)
        body = body - cyl(SOCKET, HOLE_D, -0.01, x, y) - cyl(SOCKET, HOLE_D, H - SOCKET + 0.01, x, y)
    return body


# ---------------- 层间立柱 (两端带插销) ----------------
def spacer():
    pin_len = SOCKET - 0.5
    return chamfer_pin(pin_len) + cyl(GAP, POST_D, pin_len) + chamfer_pin(pin_len).translate([0, 0, pin_len + GAP])


# ---------------- 独立插销 (脚轮、把手用) ----------------
CASTER_SOCKET = CASTER_H - (WHEEL_D + 1.0) - 1.2   # 脚轮座插孔深 (留 1.2 mm 顶)
HANDLE_SOCKET = 6.5
DOWEL_LEN = SOCKET - 0.5 + min(CASTER_SOCKET, HANDLE_SOCKET) - 0.5


def dowel():
    return chamfer_pin(DOWEL_LEN)


# ---------------- 脚轮 (轮子单独打印) ----------------
def caster():
    hub_z0 = WHEEL_D + 1.0
    hub = cyl(CASTER_H - hub_z0, POST_D + 1, hub_z0)
    hub = hub - cyl(CASTER_SOCKET + 0.01, HOLE_D, CASTER_H - CASTER_SOCKET)
    axle_z = WHEEL_D / 2
    inner = WHEEL_W / 2 + 1.0
    t = 1.8
    plate_2d = CrossSection.batch_hull([CrossSection.circle(3.5).translate([0, axle_z]),
                                  CrossSection.square([9, 1.5]).translate([-4.5, hub_z0])])
    plate = Manifold.extrude(plate_2d, t).rotate([90, 0, 0])  # 在 xz 平面, y 方向厚度
    fork = plate.translate([0, inner + t, 0]) + plate.translate([0, -inner, 0])
    axle = Manifold.cylinder(30, AXLE_HOLE_FORK / 2).rotate([90, 0, 0]).translate([0, 15, axle_z])
    return hub + fork - axle


def wheel():
    w = cyl(WHEEL_W, WHEEL_D)
    w = w - cyl(WHEEL_W + 1, AXLE_HOLE_WHEEL, -0.5)
    # 两侧轮毂凹槽
    for z in (-0.01, WHEEL_W - 0.8):
        w = w - (cyl(0.81, WHEEL_D - 3.0, z) - cyl(0.81, 5.0, z))
    return w


# ---------------- 把手 (弧形，平放打印) ----------------
def handle():
    a = PY            # 半跨度
    leg = 4.0
    h = HANDLE_RISE - POST_D / 2 - leg
    p = 4.0
    ts = np.linspace(-1, 1, 81)
    pts = [(a * np.sign(t) * abs(t), leg + h * (1 - abs(t) ** p) ** (1 / p)) for t in ts]
    r = POST_D / 2
    segs = [Manifold.sphere(r).translate([0, y, z]) for y, z in pts]
    parts = [Manifold.batch_hull([segs[i], segs[i + 1]]) for i in range(len(segs) - 1)]
    arch = Manifold.batch_boolean(parts, OpType.Add)
    for sy in (-1, 1):
        arch = arch + cyl(leg + 0.01, POST_D, 0, 0, sy * a)
    arch = arch.trim_by_plane([0, 0, 1], 0.0)                    # 切平腿底
    arch = arch.trim_by_plane([1, 0, 0], -(r - 1.0))             # 削一个 1 mm 平面便于平放打印
    for sy in (-1, 1):
        arch = arch - cyl(HANDLE_SOCKET, HOLE_D, -0.01, 0, sy * a)
    return arch


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
    parts = {
        "basket": basket(),
        "spacer": spacer(),
        "caster": caster(),
        "wheel": wheel(),
        "handle": handle(),
        "dowel": dowel(),
    }
    qty = {"basket": 3, "spacer": 8, "caster": 4, "wheel": 4, "handle": 2, "dowel": 8}
    # 打印朝向
    print_orient = {
        "basket": parts["basket"],
        "spacer": parts["spacer"],
        "caster": parts["caster"].rotate([180, 0, 0]),   # 倒过来，插孔面贴床
        "wheel": parts["wheel"],
        "handle": parts["handle"].rotate([0, -90, 0]),   # 平面贴床
        "dowel": parts["dowel"],
    }
    for name, m in print_orient.items():
        assert m.status().name == "NoError", name
        t = to_tm(place_on_bed(m))
        t.export(os.path.join(OUT, f"{name}_x{qty[name]}.stl"))
        ext = t.bounds[1] - t.bounds[0]
        print(f"{name:7s} x{qty[name]}  {ext[0]:6.1f} x {ext[1]:6.1f} x {ext[2]:6.1f} mm  "
              f"vol {t.volume/1000:6.1f} cm3  watertight={t.is_watertight}")

    # 组装预览
    cream, mint = [238, 228, 200, 255], [178, 214, 196, 255]
    scene = []
    z = CASTER_H
    pin_len = SOCKET - 0.5
    for i in range(3):
        scene.append(to_tm(parts["basket"].translate([0, 0, z]), cream))
        if i < 2:
            for x, y in corners():
                scene.append(to_tm(parts["spacer"].translate([x, y, z + H - pin_len]), cream))
            z += H + GAP
    top = z + H
    for x, y in corners():
        c = parts["caster"].translate([x, y, 0])
        scene.append(to_tm(c, mint))
        scene.append(to_tm(parts["wheel"].rotate([90, 0, 0]).translate([x, y + WHEEL_W / 2, WHEEL_D / 2]), [90, 90, 90, 255]))
    for sx in (-1, 1):
        scene.append(to_tm(parts["handle"].translate([sx * PX, 0, top]), cream))
    asm = trimesh.util.concatenate(scene)
    asm.export(os.path.join(OUT, "assembly_preview.stl"))
    asm.export(os.path.join(OUT, "assembly_preview.glb"))
    print("assembly height:", round(asm.bounds[1][2] - asm.bounds[0][2], 2), "mm, footprint:",
          np.round(asm.bounds[1][:2] - asm.bounds[0][:2], 1))
    print("GAP =", GAP, " dowel length =", DOWEL_LEN)


if __name__ == "__main__":
    main()
