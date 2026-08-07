"""从 logo\\logo.png 生成构建所需的全部衍生 logo 资源到 assets\\。

用法：python generate-assets.py

生成的资源：
- assets\\logo-{16,24,32,48,64,128,256}.png   —— 替换 Chromium pak 产品 logo 用
- assets\\app.ico                             —— chrome.exe/chrome.dll/启动器/安装包图标
- assets\\wizard-image.bmp / wizard-small.bmp —— Inno Setup 安装向导图片
- assets\\scriptcat\\logo*.png                —— ScriptCat 扩展图标（含灰度变体）
"""
import os
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "logo" / "logo.png"
OUT = ROOT / "assets"

PRODUCT_SIZES = (16, 24, 32, 48, 64, 96, 128, 256, 512)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
SCRIPT_CAT_ICONS = (
    ("logo.png", 128, False),
    ("logo-32.png", 32, False),
    ("logo-gray.png", 128, True),
    ("logo-gray-32.png", 32, True),
)


def gray(png):
    """ScriptCat 的停用/暗色态图标：转为中灰渐变保留透明通道。"""
    g = png.convert("L")
    return ImageOps.colorize(g, black=(90, 90, 90), white=(255, 255, 255)).convert("RGBA")


def make_wizard_bmp(path, w, h, logo_size):
    canvas = Image.new("RGB", (w, h), (255, 255, 255))
    logo = im.resize((logo_size, logo_size), Image.LANCZOS)
    canvas.paste(logo, ((w - logo_size) // 2, (h - logo_size) // 2), logo)
    canvas.save(path, format="BMP")


def main():
    global im
    if not SRC.is_file():
        raise SystemExit(f"缺少源 logo：{SRC}")
    im = Image.open(SRC).convert("RGBA")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "scriptcat").mkdir(exist_ok=True)

    for s in PRODUCT_SIZES:
        im.resize((s, s), Image.LANCZOS).save(OUT / f"logo-{s}.png")

    # PIL 通过 sizes 参数自行缩放生成多尺寸帧；append_images 方式实测只写入首帧。
    im.save(OUT / "app.ico", format="ICO", sizes=[(s, s) for s in ICO_SIZES])

    make_wizard_bmp(OUT / "wizard-image.bmp", 164, 314, 110)
    make_wizard_bmp(OUT / "wizard-small-image.bmp", 55, 58, 36)

    for name, size, use_gray in SCRIPT_CAT_ICONS:
        base = gray(im) if use_gray else im
        base.resize((size, size), Image.LANCZOS).save(OUT / "scriptcat" / name)

    print(f"已生成全部 logo 资源到 {OUT}")


if __name__ == "__main__":
    main()
