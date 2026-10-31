# DataWheel 截图裁剪：多显示器感知，按 CG 窗口坐标从全屏截图裁出窗口
# 用法: cropshot.py <winid> <out.png>
import subprocess, sys
from PIL import Image

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def wininfo():
    wins = {}
    for line in run(["swift", "build/winhelper.swift", "list"]).splitlines():
        d = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
        if "id" in d:
            wins[int(d["id"])] = {k: (int(v) if k in ("x", "y", "w", "h", "layer") else v)
                                  for k, v in d.items()}
    return wins

def displays():
    ds = []
    for line in run(["swift", "build/winhelper.swift", "displays"]).splitlines():
        d = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
        ds.append({k: int(v) for k, v in d.items()})
    return ds

wid = int(sys.argv[1]); out = sys.argv[2]
w = wininfo().get(wid)
if not w:
    print("window not found"); sys.exit(1)

# 找到包含窗口的显示器
disp = None
for d in displays():
    if d["x"] <= w["x"] < d["x"] + d["w"] and d["y"] <= w["y"] < d["y"] + d["h"]:
        disp = d; break
if disp is None:
    disp = displays()[0]

# 截取该显示器
shot = "/tmp/dw_shot_tmp.png"
if disp["x"] != 0 or disp["y"] != 0:
    subprocess.run(["screencapture", "-x", "-R", f'{disp["x"]},{disp["y"]},{disp["w"]},{disp["h"]}', shot], check=True)
else:
    subprocess.run(["screencapture", "-x", shot], check=True)
img = Image.open(shot)

scale = img.width / disp["w"]  # 显示器逻辑宽 → 像素缩放
# 窗口在显示器内的相对位置（全局坐标 - 显示器原点）
lx = w["x"] - disp["x"]; ly = w["y"] - disp["y"]
box = (int(lx*scale), int(ly*scale), int((lx+w["w"])*scale), int((ly+w["h"])*scale))
img.crop(box).save(out)
print(out, img.crop(box).size, "scale", round(scale, 2))
