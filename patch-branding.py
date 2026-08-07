"""把 .pak 资源里的 “Chrome for Testing” 品牌字样替换为 “Course-Thru 课速通”，
并把关于页版权署名里的 “Google LLC.” 替换为 “IceFire_Icer.”。

构建期脚本，由 build.ps1 在 Chromium 解压后调用。Chrome for Testing 的
品牌字符串（窗口标题模板、新标签页“自定义”按钮、设置“关于”页等）编译在
语言包资源里，CDP 与企业策略都无法修改，只能在构建期替换资源文本。

支持 grit data_pack v5（Chrome 152 实际格式：12 字节头 + 6 字节条目，
offset 为绝对文件偏移，UTF-8/UTF-16 文本资源）。仅在字符串出现变化时重写文件；
无匹配时文件保持不变（幂等，可重复执行）。用法：
    python patch-branding.py path/to/resources.pak [more.pak ...]
"""
import struct
import sys
from pathlib import Path

# 先替换长的，避免把 “Google Chrome for Testing” 里的子串先改掉。
REPLACEMENTS = [
    ("Google Chrome for Testing", "Course-Thru \u8bfe\u901f\u901a"),
    ("Chrome for Testing", "Course-Thru"),
    # 关于页版权署名：只替换带句点的完整公司名并保留句点，
    # 避免误伤其他声明里的裸 “Google LLC”。
    ("Google LLC.", "IceFire_Icer."),
]


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


def patch_pak(data):
    """返回重写后的 pak 字节；无匹配时返回 None。"""
    parsed = parse_pak(data)
    if parsed is None:
        raise ValueError("仅支持 data_pack v5")
    encoding, entries, aliases = parsed
    for _, ofs in entries:
        if ofs > len(data):
            raise ValueError("pak 结构异常（偏移越界）")

    def decode(raw):
        if encoding == 2:
            return raw.decode("utf-16-le")
        return raw.decode("utf-8")

    def encode(text):
        if encoding == 2:
            return text.encode("utf-16-le")
        return text.encode("utf-8")

    bodies = []
    changed = 0
    for i in range(len(entries) - 1):
        _, ofs = entries[i]
        _, next_ofs = entries[i + 1]
        raw = data[ofs:next_ofs]
        new_raw = raw
        try:
            text = decode(raw)
            for old, new in REPLACEMENTS:
                if old in text:
                    text = text.replace(old, new)
            new_raw = encode(text)
        except (UnicodeDecodeError, UnicodeEncodeError):
            # 二进制资源（图片、HTML 等）不做文本替换。
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

    # v5 头部：version u4 + encoding u1 + pad3 + num_res u2 + num_alias u2
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
    for arg in sys.argv[1:]:
        p = Path(arg)
        data = p.read_bytes()
        out = patch_pak(data)
        if out is None:
            print(f"[unchanged] {p}")
            continue
        p.write_bytes(out)
        print(f"[patched] {p} ({len(data)} -> {len(out)} bytes)")


if __name__ == "__main__":
    main()
