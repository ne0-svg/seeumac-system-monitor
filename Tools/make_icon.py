#!/usr/bin/env python3
"""
Regenerate the app icon.

Design language: Braun (geometry only, colour carries meaning),
Sony (one focal point), Apple (rounded container, legible at 16px).

  Background  #1E1E20  deep graphite
  Bars        #F4F2ED  warm off-white
  Peak bar    #E64E16  Braun orange - marks the highest reading

Outputs:
  Resources/AppIcon.icns   bundled by build.sh
  docs/icon.png            README image

Usage:  python3 Tools/make_icon.py
"""
from PIL import Image, ImageDraw
import os, subprocess, shutil

S = 1024
SS = 8                     # 8 倍超采样，边缘更干净
R = S * 0.2237

# ---- 几何（S 的比例）----
BAR_W   = 0.175        # 加粗：16px 下约 2.8px，能立住
GAP     = 0.075
HEIGHTS = [0.220, 0.335, 0.455]
BASE_Y  = 0.745        # 基线略降，图形占位更大
RATIO_R = 0.12         # 近直角：博朗读数面板的硬边

# ---- 色板 ----
DEEP   = (30, 30, 32, 255)      # #1E1E20
CREAM  = (244, 242, 237, 255)   # #F4F2ED
ORANGE = (230, 78, 22, 255)     # #E64E16


def master():
    """绘制 8192×8192 母版，降采样到 1024"""
    W = S * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, W - 1, W - 1], radius=R * SS, fill=DEEP)

    total = BAR_W * 3 + GAP * 2
    x = (1 - total) / 2
    colors = [CREAM, CREAM, ORANGE]
    for h, c in zip(HEIGHTS, colors):
        w_px = BAR_W * W
        h_px = h * W
        bx0 = x * W
        by1 = BASE_Y * W
        by0 = by1 - h_px
        rr = min(w_px * RATIO_R, h_px / 2)
        d.rounded_rectangle([bx0, by0, bx0 + w_px, by1], radius=rr, fill=c)
        x += BAR_W + GAP

    return img.resize((S, S), Image.LANCZOS)


def main():
    os.makedirs("Resources", exist_ok=True)
    icon = master()
    icon.save("docs/icon.png")

    # ---- 生成 iconset ----
    setdir = "build/SeeUMac.iconset"
    if os.path.exists(setdir):
        shutil.rmtree(setdir)
    os.makedirs(setdir)

    # Apple 要求：16/32/128/256/512 + 各自 @2x
    pairs = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for size, name in pairs:
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(setdir, name))
        print(f"  {name:24s} {size}×{size}")

    # ---- 转 icns ----
    subprocess.run(["iconutil", "-c", "icns", setdir,
                    "-o", "Resources/AppIcon.icns"], check=True)
    sz = os.path.getsize("Resources/AppIcon.icns")
    print(f"\n  Resources/AppIcon.icns  {sz/1024:.1f} KB")


if __name__ == "__main__":
    main()
