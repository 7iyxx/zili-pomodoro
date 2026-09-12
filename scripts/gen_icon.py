# -*- coding: utf-8 -*-
"""
「自力」App 图标生成脚本（绿色简约风）
=============================================================================
设计：绿色渐变圆角方块 + 白色圆环 + 白色对勾（寓意：自律 · 完成 · 循环）
产出：
  1. mipmap-*/ic_launcher.png            —— 传统图标（Android 8.0 以下使用）
  2. mipmap-*/ic_launcher_foreground.png —— 自适应图标前景层（Android 8.0+）
  3. drawable-*/ic_stat_notify.png       —— 通知栏小图标（纯白剪影）
  4. preview/icon_preview.png            —— 512px 预览图（仅供查看效果）
依赖：Pillow（已安装）；所有绘制按 108 单位设计稿 + 4 倍超采样，保证边缘平滑。
"""
import os
from PIL import Image, ImageDraw

RES = r"D:\codex\projects\pomodoro_app\android\app\src\main\res"
PREVIEW_DIR = r"D:\codex\projects\pomodoro_app\preview"
SS = 4  # 超采样倍数（先画大图再缩小 = 抗锯齿）

# 主题绿（iOS 系绿色调：上浅下深渐变）
GREEN_TOP = (62, 207, 107)     # #3ECF6B
GREEN_BOTTOM = (31, 157, 77)   # #1F9D4D
WHITE = (255, 255, 255, 255)


def rounded_gradient(size: int, radius_ratio: float = 0.225) -> Image.Image:
    """生成「圆角矩形 + 垂直渐变」的绿色底图（RGBA）"""
    grad = Image.new("RGBA", (size, size))
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(
            int(GREEN_TOP[i] + (GREEN_BOTTOM[i] - GREEN_TOP[i]) * t) for i in range(3)
        ) + (255,)
        grad.paste(color, (0, y, size, y + 1))
    # 用圆角矩形做遮罩，切出圆角
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=255
    )
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def draw_glyph(img: Image.Image, size: int) -> Image.Image:
    """绘制主图形：白色圆环 + 对勾（坐标体系：108 单位设计稿，按 size 等比缩放）"""
    k = size / 108.0
    d = ImageDraw.Draw(img)
    cx = cy = 54 * k
    # 圆环（外半径 29、线宽 6；位于自适应图标安全区半径 33 之内）
    r = 29 * k
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=max(1, round(6 * k)))
    # 对勾：三点折线 + 圆头
    pts = [(cx - 11.5 * k, cy + 0.5 * k), (cx - 3.5 * k, cy + 8.5 * k), (cx + 12 * k, cy - 9.5 * k)]
    w = max(1, round(6.5 * k))
    d.line(pts, fill=WHITE, width=w, joint="curve")
    for p in (pts[0], pts[2]):  # 两端补圆点，模拟圆头线帽
        rr = w / 2
        d.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=WHITE)
    return img


def draw_check_only(img: Image.Image, size: int) -> Image.Image:
    """通知小图标专用：只画一个加粗的对勾（24px 下依然清晰可辨）"""
    k = size / 108.0
    d = ImageDraw.Draw(img)
    cx = cy = 54 * k
    pts = [(cx - 15 * k, cy + 1 * k), (cx - 4 * k, cy + 12 * k), (cx + 16 * k, cy - 12 * k)]
    w = max(2, round(11 * k))
    d.line(pts, fill=WHITE, width=w, joint="curve")
    for p in (pts[0], pts[2]):
        rr = w / 2
        d.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=WHITE)
    return img


def export_legacy(size: int, path: str) -> None:
    """传统图标：绿底 + 图形（圆角已烘焙）"""
    big = rounded_gradient(size * SS)
    draw_glyph(big, size * SS)
    big.resize((size, size), Image.LANCZOS).save(path)
    print("legacy  ->", path)


def export_foreground(size: int, path: str) -> None:
    """自适应图标前景层：透明底 + 图形（系统负责裁剪与背景）"""
    big = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    draw_glyph(big, size * SS)
    big.resize((size, size), Image.LANCZOS).save(path)
    print("fg      ->", path)


def export_notify(size: int, path: str) -> None:
    """通知小图标：透明底 + 白色对勾剪影"""
    big = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    draw_check_only(big, size * SS)
    big.resize((size, size), Image.LANCZOS).save(path)
    print("notify  ->", path)


def main() -> None:
    legacy = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
    fg = [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]
    notify = [("mdpi", 24), ("hdpi", 36), ("xhdpi", 48), ("xxhdpi", 72), ("xxxhdpi", 96)]

    for dpi, size in legacy:
        export_legacy(size, os.path.join(RES, f"mipmap-{dpi}", "ic_launcher.png"))
    for dpi, size in fg:
        export_foreground(size, os.path.join(RES, f"mipmap-{dpi}", "ic_launcher_foreground.png"))
    for dpi, size in notify:
        folder = os.path.join(RES, f"drawable-{dpi}")
        os.makedirs(folder, exist_ok=True)
        export_notify(size, os.path.join(folder, "ic_stat_notify.png"))

    # 预览图（512px，用于查看效果）
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    export_legacy(512, os.path.join(PREVIEW_DIR, "icon_preview.png"))
    print("DONE")


if __name__ == "__main__":
    main()
