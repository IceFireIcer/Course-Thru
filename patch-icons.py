"""构建期把 PE 可执行文件的应用图标替换为 Course-Thru 新 logo。

Chrome 的主图标组是命名资源（chrome.exe 的 IDR_MAINFRAME、chrome.dll 的
数值组 101），rcedit 只会新增一个未命名组、无法替换它，因此这里直接重建
资源段：把旧资源树完整拷贝一份，替换目标图标组的 PNG 图像与组描述，然后
把新资源段作为新节追加到文件末尾并重指资源目录（不修改原 .rsrc 节，
避免 297MB 级全文件重写）。

用法：
    python patch-icons.py <exe/dll> --logo logo/logo.png --groups IDR_MAINFRAME,IDR_X001_APP_LIST
    python patch-icons.py <exe/dll> --logo logo/logo.png --groups 101
    python patch-icons.py <exe/dll> --logo logo/logo.png --add-main-icon   # 无资源段的启动器

需要 Pillow。幂等：目标组已被替换为相同字节时直接退出（退出码 0）。
"""
import argparse
import io
import struct
import sys
from pathlib import Path

from PIL import Image

IMAGE_DIRECTORY_ENTRY_RESOURCE = 2
RT_ICON = 3
RT_GROUP_ICON = 14


def align(v, a):
    """把 v 向上对齐到 a 的整数倍（PE 节/文件对齐用）。"""
    return (v + a - 1) & ~(a - 1)


def _sort_key(item):
    """命名条目在前（保持原顺序），数值条目按 id 升序。"""
    key, _ = item
    if isinstance(key, str):
        return (0, 0, key)
    return (1, key, 0)


# ---------------- 资源树解析 ----------------


class ResTree:
    """三层资源树：type -> name -> lang -> blob。key 为 int 或 str。"""

    def __init__(self):
        self.types = {}  # type_key -> {name_key -> {lang_key -> bytes}}

    def add(self, type_key, name_key, lang_key, blob):
        self.types.setdefault(type_key, {}).setdefault(name_key, {})[lang_key] = blob

    def get(self, type_key, name_key):
        return self.types.get(type_key, {}).get(name_key)


def parse_resource_tree(raw, pe):
    """解析 PE 资源段为 ResTree（type -> name -> lang -> blob）。

    pe = (sections, rsrc_rva)。资源目录按三层嵌套（类型/名称/语言）遍历，
    叶子数据项通过节表把 RVA 换算为文件偏移后读取原始字节。
    """
    rva = pe[1]
    if not rva:
        return None

    def read_name(offdata):
        name_rva = rva + (offdata & 0x7FFFFFFF)
        off = rva_to_off(pe[0], name_rva)
        length = struct.unpack_from("<H", raw, off)[0]
        return raw[off + 2 : off + 2 + 2 * length].decode("utf-16-le")

    def dir_entries(dir_rva):
        off = rva_to_off(pe[0], dir_rva)
        nname, nid = struct.unpack_from("<HH", raw, off + 12)
        out = []
        for i in range(nname + nid):
            eo = off + 16 + 8 * i
            nameid, offdata = struct.unpack_from("<II", raw, eo)
            out.append((nameid, offdata))
        return out

    def key(nameid):
        if nameid >> 31:
            return read_name(nameid)
        return nameid

    tree = ResTree()
    for type_raw, off1 in dir_entries(rva):
        tkey = key(type_raw)
        for name_raw, off2 in dir_entries(rva + (off1 & 0x7FFFFFFF)):
            nkey = key(name_raw)
            for lang_raw, off3 in dir_entries(rva + (off2 & 0x7FFFFFFF)):
                lkey = key(lang_raw)
                doff = rva_to_off(pe[0], rva + (off3 & 0x7FFFFFFF))
                blob_rva, size = struct.unpack_from("<II", raw, doff)
                blob = get_data(raw, pe[0], blob_rva, size) if size else b""
                tree.add(tkey, nkey, lkey, blob)
    return tree


def pe_sections(raw):
    """解析 PE 头返回节表信息 (sections, rsrc_rva, rsrc_size)。

    sections 为 [(name, 虚拟地址, 虚拟大小, 文件偏移, 文件大小), ...]；
    rsrc_rva 是资源目录在内存中的 RVA（第三数据目录项）。
    """
    e_lfanew = struct.unpack_from("<I", raw, 0x3C)[0]
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", raw, coff + 2)[0]
    opt_size = struct.unpack_from("<H", raw, coff + 16)[0]
    opt = coff + 20
    sec_table = opt + opt_size
    sections = []
    for i in range(nsec):
        off = sec_table + 40 * i
        name = raw[off : off + 8]
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", raw, off + 8)
        sections.append((name, vaddr, vsize, rawptr, rawsize))
    rsrc_rva, rsrc_size = struct.unpack_from("<II", raw, opt + 112 + 8 * 2)
    return sections, rsrc_rva, rsrc_size


def rva_to_off(sections, rva):
    """把内存 RVA 换算为文件偏移；找不到所属节时返回 None。

    范围用 max(vsize, rawsize) 判断：节在文件中的实际数据可能比虚拟大小
    大或小（SectionAlignment 与 FileAlignment 不一致所致），取较大者兜底。
    """
    for _, vaddr, vsize, rawptr, rawsize in sections:
        if vaddr <= rva < vaddr + max(vsize, rawsize):
            return rawptr + (rva - vaddr)
    return None


def get_data(raw, sections, rva, size):
    """按 (RVA, size) 读取资源数据的原始字节；映射失败时返回空串。"""
    off = rva_to_off(sections, rva)
    if off is None:
        return b""
    return raw[off : off + size]


# ---------------- 资源树序列化 ----------------


def serialize_tree(tree):
    """序列化资源段，返回 (bytes, [(data_entry_pos, blob_off), ...])。

    数据项里的 OffsetToData 暂填 0，由调用方在知道节基址后统一修正。
    布局：根目录必须在段首（资源基址处），名称字符串放在目录与数据项之后。
    """
    leaves = []  # (tkey, nkey, lkey, blob) 稳定顺序
    for tkey, names_map in sorted(tree.types.items(), key=_sort_key):
        for nkey, langs in sorted(names_map.items(), key=_sort_key):
            for lkey, blob in sorted(langs.items(), key=_sort_key):
                leaves.append((tkey, nkey, lkey, blob))

    # 分组：type -> [name -> [lang...]]
    types = []  # [(tkey, [(nkey, [lkey...])])]
    type_pos, name_pos = {}, {}
    for leaf in leaves:
        tkey, nkey, lkey, _ = leaf
        if tkey not in type_pos:
            type_pos[tkey] = len(types)
            types.append([tkey, []])
        ti = type_pos[tkey]
        pair = (tkey, nkey)
        if pair not in name_pos:
            name_pos[pair] = len(types[ti][1])
            types[ti][1].append([nkey, []])
        types[ti][1][name_pos[pair]][1].append(lkey)
    # leaf 索引（数据项按 leaves 顺序排列）
    leaf_idx = {}
    for i, leaf in enumerate(leaves):
        leaf_idx[(leaf[0], leaf[1], leaf[2])] = i

    # 用到的名称字符串（放在目录与数据项之后）
    used_names = []
    for tkey, names_map in sorted(tree.types.items(), key=_sort_key):
        for nkey in names_map:
            for key in (tkey, nkey):
                if isinstance(key, str) and key not in used_names:
                    used_names.append(key)
    names_size = 0
    name_off = {}
    for key in used_names:
        name_off[key] = names_size
        names_size += 2 + 2 * len(key)
        names_size = align(names_size, 4)

    # 布局：level1 -> level2 -> level3 -> 数据项 -> 名称字符串 -> 数据块
    off = 0
    off_l1 = off
    off += 16 + 8 * len(types)
    l2_off = []
    for ti, (_, names) in enumerate(types):
        l2_off.append(off)
        off += 16 + 8 * len(names)
    l3_off = {}
    for ti, (tkey, names) in enumerate(types):
        for ni, (nkey, langs) in enumerate(names):
            l3_off[(ti, ni)] = off
            off += 16 + 8 * len(langs)
    off_data = off
    off_names = off_data + 16 * len(leaves)
    off_blobs = off_names + names_size
    blob_off = {}
    for i, leaf in enumerate(leaves):
        blob_off[(leaf[0], leaf[1], leaf[2])] = off_blobs
        off_blobs += len(leaf[3])
        while off_blobs % 4:
            off_blobs += 1

    def name_field(key):
        if isinstance(key, str):
            return 0x80000000 | (off_names + name_off[key])
        return key

    buf = bytearray()

    def dir_header(keys):
        named = sum(1 for k in keys if isinstance(k, str))
        return struct.pack("<IIHH", 0, 0, 0, 0) + struct.pack("<HH", named, len(keys) - named)

    # level1（16 字节目录头 + 条目）
    buf += dir_header([tkey for tkey, _ in types])
    for ti, (tkey, _) in enumerate(types):
        buf += struct.pack("<II", name_field(tkey), 0x80000000 | l2_off[ti])
    # level2
    for ti, (tkey, names) in enumerate(types):
        buf += dir_header([nkey for nkey, _ in names])
        for ni, (nkey, _) in enumerate(names):
            buf += struct.pack("<II", name_field(nkey), 0x80000000 | l3_off[(ti, ni)])
    # level3
    for ti, (tkey, names) in enumerate(types):
        for ni, (nkey, langs) in enumerate(names):
            buf += dir_header(langs)
            for lkey in langs:
                i = leaf_idx[(tkey, nkey, lkey)]
                buf += struct.pack(
                    "<II", name_field(lkey), off_data + 16 * i
                )
    # 数据项（OffsetToData 占位 0，调用方按节基址修正；codepage=1252 与常见工具一致）
    fixups = []
    for i, leaf in enumerate(leaves):
        pos = off_data + 16 * i
        buf += struct.pack("<IIII", 0, len(leaf[3]), 0x4E4, 0)
        fixups.append((pos, blob_off[(leaf[0], leaf[1], leaf[2])]))
    # 名称字符串
    assert len(buf) == off_names
    for key in used_names:
        buf += struct.pack("<H", len(key)) + key.encode("utf-16-le")
        while len(buf) % 4:
            buf.append(0)
    # 数据块
    for leaf in leaves:
        buf += leaf[3]
        while len(buf) % 4:
            buf.append(0)

    assert len(buf) == off_blobs, (len(buf), off_blobs)
    return bytes(buf), fixups


# ---------------- 图标组处理 ----------------


def group_entries(blob):
    """解析 GRPICONDIR 图标组数据，返回各图标条目字典列表。

    每个条目含宽/高（0 表示 256）、位深、数据大小及对应 RT_ICON 的资源 id。
    """
    count = struct.unpack_from("<H", blob, 4)[0]
    out = []
    for i in range(count):
        off = 6 + 14 * i
        w, h, _, _, _, bitcount, size, rid = struct.unpack_from("<BBBBHHIH", blob, off)
        out.append(
            {"w": w or 256, "h": h or 256, "bitcount": bitcount, "size": size, "id": rid}
        )
    return out


def build_group_blob(entries):
    """把图标条目字典列表序列化回 GRPICONDIR 二进制（256px 的宽高写 0）。"""
    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    for e in entries:
        out += struct.pack(
            "<BBBBHHIH",
            e["w"] if e["w"] < 256 else 0,
            e["h"] if e["h"] < 256 else 0,
            0,
            0,
            1,
            32,
            e["size"],
            e["id"],
        )
    return bytes(out)


def make_icon_png(logo, w, h):
    """把源 logo 缩放到 (w, h) 并编码为优化的 PNG 字节（作为 RT_ICON 资源）。"""
    img = logo.resize((w, h), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def replace_group(logo, tree, type_key, name_key):
    """替换一个图标组（组描述 + 对应 RT_ICON 图像），返回是否发生变化。"""
    groups = tree.get(type_key, name_key)
    if not groups:
        return False
    changed = False
    for lang, blob in list(groups.items()):
        entries = group_entries(blob)
        new_entries = []
        for e in entries:
            png = make_icon_png(logo, e["w"], e["h"])
            e["size"] = len(png)
            e["bitcount"] = 32
            new_entries.append(e)
            icons = tree.get(RT_ICON, e["id"])
            if icons:
                for ilang, old in list(icons.items()):
                    if old != png:
                        tree.types[RT_ICON][e["id"]][ilang] = png
                        changed = True
        new_blob = build_group_blob(new_entries)
        if new_blob != blob:
            groups[lang] = new_blob
            changed = True
    return changed


# ---------------- PE 节追加 ----------------


def append_section(raw, section_data, fixups, section_name):
    """追加新节并重指资源目录，返回新文件字节。"""
    e_lfanew = struct.unpack_from("<I", raw, 0x3C)[0]
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", raw, coff + 2)[0]
    opt_size = struct.unpack_from("<H", raw, coff + 16)[0]
    opt = coff + 20
    sec_table = opt + opt_size
    section_alignment = struct.unpack_from("<I", raw, opt + 32)[0]
    file_alignment = struct.unpack_from("<I", raw, opt + 36)[0]
    size_of_headers = struct.unpack_from("<I", raw, opt + 60)[0]

    last = sec_table + 40 * (nsec - 1)
    last_vaddr = struct.unpack_from("<I", raw, last + 12)[0]
    last_vsize = struct.unpack_from("<I", raw, last + 8)[0]
    last_rawsize = struct.unpack_from("<I", raw, last + 16)[0]
    new_va = align(last_vaddr + max(last_vsize, last_rawsize), section_alignment)

    headers_end = sec_table + 40 * (nsec + 1)
    if headers_end > size_of_headers:
        raise RuntimeError(
            f"节表放不下新节头（需要到 0x{headers_end:X}，SizeOfHeaders=0x{size_of_headers:X}）"
        )

    raw_off = align(len(raw), file_alignment)
    raw_size = align(len(section_data), file_alignment)

    out = bytearray(raw)
    sec = bytearray(section_data)
    # 修正数据项 OffsetToData（真实 RVA，写入新节数据内）
    for pos, blob_off in fixups:
        struct.pack_into("<I", sec, pos, new_va + blob_off)
    # 头部补丁
    struct.pack_into("<H", out, coff + 2, nsec + 1)
    struct.pack_into("<I", out, opt + 56, new_va + align(len(section_data), section_alignment))
    data_dir = opt + 112
    struct.pack_into(
        "<II",
        out,
        data_dir + 8 * IMAGE_DIRECTORY_ENTRY_RESOURCE,
        new_va,
        len(section_data),
    )
    hdr = bytearray(40)
    hdr[0:8] = section_name.encode("ascii").ljust(8, b"\0")[:8]
    struct.pack_into(
        "<IIIIII", hdr, 8, len(section_data), new_va, raw_size, raw_off, 0, 0
    )
    struct.pack_into("<HH", hdr, 32, 0, 0)
    struct.pack_into("<I", hdr, 36, 0x40000040)  # INITIALIZED_DATA | READ
    out[sec_table + 40 * nsec : sec_table + 40 * (nsec + 1)] = hdr
    # 追加数据
    out.extend(b"\0" * (raw_off - len(out)))
    out.extend(sec)
    out.extend(b"\0" * (raw_size - len(section_data)))
    return bytes(out)


# ---------------- 入口 ----------------


def patch_file(path, logo, groups=None, add_main=False):
    """对单个 PE 文件执行图标替换；返回是否有改动。

    - add_main=True：为无资源段的文件（Go 编译产物）新建主图标组（.rsrc）；
      已有主图标组则跳过（幂等）。
    - 否则：替换指定组（groups，如 IDR_MAINFRAME/101/1）的图标组描述与图像。
    """
    raw = Path(path).read_bytes()
    tree = parse_resource_tree(raw, pe_sections(raw))

    if add_main:
        if tree is not None and tree.get(RT_GROUP_ICON, 1):
            print(f"[icons] {path}: 已存在主图标组，跳过 --add-main-icon")
            return False
        if tree is None:
            tree = ResTree()
        sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
        entries = []
        for i, (w, h) in enumerate(sizes):
            rid = 101 + i
            png = make_icon_png(logo, w, h)
            tree.add(RT_ICON, rid, 0, png)
            entries.append({"w": w, "h": h, "bitcount": 32, "size": len(png), "id": rid})
        tree.add(RT_GROUP_ICON, 1, 0, build_group_blob(entries))
    else:
        changed = False
        for g in groups or []:
            gkey = int(g) if str(g).isdigit() else g
            if replace_group(logo, tree, RT_GROUP_ICON, gkey):
                changed = True
        if not changed:
            print(f"[icons] {path}: 目标图标组已是新 logo，无需修改")
            return False

    section, fixups = serialize_tree(tree)
    section_name = ".rsrc" if add_main else ".rsrc2"
    new_raw = append_section(raw, section, fixups, section_name)
    Path(path).write_bytes(new_raw)
    print(f"[icons] 已替换图标: {path}（{len(raw)} -> {len(new_raw)} bytes）")
    return True


def main():
    """命令行入口：解析参数后调用 patch_file 处理目标 PE 文件。"""
    ap = argparse.ArgumentParser()
    ap.add_argument("pe_path")
    ap.add_argument("--logo", required=True)
    ap.add_argument("--groups", default="")
    ap.add_argument("--add-main-icon", action="store_true")
    args = ap.parse_args()
    groups = [g.strip() for g in args.groups.split(",") if g.strip()]
    if not groups and not args.add_main_icon:
        ap.error("需要 --groups 或 --add-main-icon")
    logo = Image.open(args.logo).convert("RGBA")
    patch_file(args.pe_path, logo, groups, args.add_main_icon)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
