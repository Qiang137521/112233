import sys, numpy as np, trimesh, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
def render(path, out, elev=18, azim=-55, size=(7,9)):
    s = trimesh.load(path, force="mesh", process=False)
    tri = s.vertices[s.faces]
    try: col = s.visual.face_colors[:, :3] / 255.0
    except Exception: col = np.tile([0.85,0.83,0.75], (len(tri),1))
    n = s.face_normals; L = np.array([0.4,-0.6,0.7]); L/=np.linalg.norm(L)
    shade = 0.45 + 0.55*np.clip(n@L, 0, 1)
    fig = plt.figure(figsize=size); ax = fig.add_subplot(111, projection="3d")
    ax.add_collection3d(Poly3DCollection(tri, facecolors=col*shade[:,None], edgecolor="none"))
    lo, hi = s.bounds; c=(lo+hi)/2; r=(hi-lo).max()/2
    ax.set_xlim(c[0]-r,c[0]+r); ax.set_ylim(c[1]-r,c[1]+r); ax.set_zlim(c[2]-r,c[2]+r)
    ax.set_box_aspect((1,1,1)); ax.view_init(elev, azim); ax.axis("off")
    plt.tight_layout(); plt.savefig(out, dpi=110); plt.close()
render(sys.argv[1], sys.argv[2], *map(float, sys.argv[3:5])) if len(sys.argv)>3 else render(sys.argv[1], sys.argv[2])
