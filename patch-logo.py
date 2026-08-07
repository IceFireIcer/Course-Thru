"""把 Chromium 资源包里的 Chrome 产品 logo 图片替换为 Course-Thru 课速通的 logo。

构建期脚本，由 build.ps1 在 Chromium 解压后调用。Chromium 的浏览器品牌图标
（新标签页 favicon、关于页 logo、窗口/任务栏图标等）编译在
chrome_100_percent.pak、chrome_200_percent.pak、resources.pak 的图片资源里，
CDP 与企业策略无法修改，只能在构建期替换资源。

替换策略：解析 grit data_pack v5，对每个 PNG 图片资源解码后按“四色品牌色占比”
启发式识别 Chrome 产品 logo（Chrome logo 的蓝/红/黄/绿四色都有显著占比，而
普通单色/双色工具图标不会命中），再把同像素尺寸的自有 logo PNG 写入。
幂等：资源字节已等于目标图片时保持不变，可重复执行。用法：
    python patch-logo.py path/to/assets [pak ...]
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image

# Chrome 品牌四色（近似值，容差内匹配即可）。
BRAND_COLORS = {
    "blue": (0x42, 0x85, 0xF4),
    "red": (0xEA, 0x43, 0x35),
    "yellow": (0xFB, 0xBC, 0x05),
    "green": (0x34, 0xA8, 0x53),
}

LOGO_SIZES = {16, 24, 32, 48, 64, 96, 128, 256, 512}

# CfT 产品 logo 的蓝色主色（近似值）：浅蓝环 + 白色内圈，透明底。
CFT_BLUE = (0x42, 0x85, 0xF4)


def parse_pak(data):
    """返回 (encoding, entries, aliases)；非 v5 格式返回 None。"""
    if len(data) < 16:
        return None
    version, = struct.unpack_from("<I", data, 0)
    if version != 5:
        return None
    encoding = data[4]
    num_res, = struct.unpack_from("<H", data, 8)
    num_alias, = struct.unpack_from("<H", data, 10)
    header_len = 12
    entries = [
        struct.unpack_from("<HI", data, header_len + 6 * i)
        for i in range(num_res + 1)
    ]
    aliases = [
        struct.unpack_from("<HH", data, header_len + 6 * (num_res + 1) + 4 * i)
        for i in range(num_alias)
    ]
    return encoding, entries, aliases


def is_chrome_logo(im):
    """判断图片是否是 Chrome 四色产品 logo（而非普通单色/双色图标）。"""
    w, h = im.size
    if w != h or w not in LOGO_SIZES:
        return False
    rgba = im.convert("RGBA")
    px = rgba.load()
    counts = {name: 0 for name in BRAND_COLORS}
    opaque = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 32:
                continue
            opaque += 1
            best = None
            best_dist = 999
            for name, ref in BRAND_COLORS.items():
                d = abs(r - ref[0]) + abs(g - ref[1]) + abs(b - ref[2])
                if d < best_dist:
                    best_dist = d
                    best = name
            if best_dist < 120:
                counts[best] += 1
    if opaque == 0:
        return False
    frac = {name: counts[name] / opaque for name in BRAND_COLORS}
    # Chrome 产品 logo：至少 3 个品牌色占比 ≥5%，且蓝色不过度占优
    # （排除 Google G 之类以蓝色为主的高蓝图标）。
    present = sum(1 for name in BRAND_COLORS if frac[name] >= 0.05)
    return present >= 3 and frac["blue"] < 0.35


def is_cft_blue_logo(im):
    """识别 Chrome for Testing 的浅蓝“C”型产品 logo（四色启发式抓不到它）。

    特征：透明底（不是整块色板）、蓝色占比适中（0.2~0.6，过高的是纯蓝工具图标
    或 Google G）、几乎没有暖色、蓝色像素为浅蓝（b 通道高）。实测命中
    chrome_*.pak 的 14469/14470/14471/14472/14460（含 200% 双倍尺寸）。
    """
    w, h = im.size
    if w != h or w not in LOGO_SIZES:
        return False
    rgba = im.convert("RGBA")
    px = rgba.load()
    blue = warm = opaque = 0
    blue_r = blue_g = blue_b = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 32:
                continue
            opaque += 1
            d = abs(r - CFT_BLUE[0]) + abs(g - CFT_BLUE[1]) + abs(b - CFT_BLUE[2])
            if d < 110:
                blue += 1
                blue_r += r
                blue_g += g
                blue_b += b
            elif r > g + 30 and r > b + 30:
                warm += 1
    if opaque == 0:
        return False
    blue_frac = blue / opaque
    op_frac = opaque / (w * h)
    if not (0.20 <= blue_frac <= 0.60):
        return False
    if warm / opaque >= 0.10:
        return False
    if op_frac >= 0.95:
        return False
    # 蓝色像素应为浅蓝（CfT 的 C 环），排除 #1A73E8 类深蓝工具图标
    return blue_b / blue > 190 and blue_r / blue < 170 and blue_g / blue < 170


def patch_pak(data, logo_map):
    """返回重写后的 pak 字节；无资源变化时返回 None。"""
    parsed = parse_pak(data)
    if parsed is None:
        raise ValueError("仅支持 data_pack v5")
    encoding, entries, aliases = parsed
    for _, ofs in entries:
        if ofs > len(data):
            raise ValueError("pak 结构异常（偏移越界）")

    bodies = []
    changed = 0
    for i in range(len(entries) - 1):
        _, ofs = entries[i]
        _, next_ofs = entries[i + 1]
        raw = data[ofs:next_ofs]
        new_raw = raw
        if raw.startswith(b"\x89PNG\r\n\x1a\n"):
            try:
                im = Image.open(io.BytesIO(raw))
                if is_chrome_logo(im) or is_cft_blue_logo(im):
                    target = logo_map.get(im.size[0])
                    if target is not None and target != raw:
                        new_raw = target
            except Exception:
                # 解码失败的非标准图片资源保持原样。
                pass
        if new_raw != raw:
            changed += 1
        bodies.append(new_raw)

    if changed == 0:
        return None

    offsets = []
    pos = 0
    for b in bodies:
        offsets.append(pos)
        pos += len(b)
    offsets.append(pos)

    num_res = len(entries) - 1
    head = (
        struct.pack("<I", 5)
        + bytes([encoding])
        + b"\x00\x00\x00"
        + struct.pack("<HH", num_res, len(aliases))
    )
    alias_bytes = b"".join(struct.pack("<HH", a, b) for a, b in aliases)
    table_len = 6 * len(entries)
    data_start = len(head) + table_len + len(alias_bytes)
    table = b"".join(
        struct.pack("<HI", rid, data_start + ofs)
        for (rid, _), ofs in zip(entries, offsets)
    )
    return head + table + alias_bytes + b"".join(bodies)


def main():
    assets_dir = Path(sys.argv[1])
    logo_map = {}
    for size in LOGO_SIZES:
        p = assets_dir / f"logo-{size}.png"
        if p.is_file():
            logo_map[size] = p.read_bytes()
    if not logo_map:
        raise SystemExit(f"未在 {assets_dir} 找到 logo-*.png 资源")

    for arg in sys.argv[2:]:
        p = Path(arg)
        data = p.read_bytes()
        out = patch_pak(data, logo_map)
        if out is None:
            print(f"[unchanged] {p}")
            continue
        p.write_bytes(out)
        print(f"[patched] {p} ({len(data)} -> {len(out)} bytes)")


if __name__ == "__main__":
    main()
