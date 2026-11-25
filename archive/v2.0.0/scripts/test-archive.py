#!/usr/bin/env python3
"""用真实 deb 验证 PMArchiveOps 的解析逻辑（镜像 libarchive 的 ar+tar+xz 行为）。

这里不调 C 代码，而是用 Python 复刻同一套两步解析流程，
验证：ar 成员枚举、control 提取、data 段文件计数、dylib-only 过滤、
路径穿越拒绝。用来交叉验证 C 实现的预期结果。
"""
import io
import lzma
import os
import sys
import tarfile


def parse_ar(path):
    data = open(path, "rb").read()
    if data[:8] != b"!<arch>\n":
        raise SystemExit("not ar: " + path)
    off = 8
    members = {}
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        size = int(hdr[48:58].decode("ascii", "replace").strip() or "0")
        members[name] = data[off + 60:off + 60 + size]
        off += 60 + size + (size % 2)
    return members


def main():
    if len(sys.argv) < 2:
        print("usage: test-archive.py <deb>")
        return 2
    deb = sys.argv[1]
    members = parse_ar(deb)
    print("ar members:", ", ".join(sorted(members)))
    assert "debian-binary" in members, "缺 debian-binary"
    assert any(n.startswith("control.tar") for n in members), "缺 control.tar"
    assert any(n.startswith("data.tar") for n in members), "缺 data.tar"

    ctrl_name = [n for n in members if n.startswith("control.tar")][0]
    data_name = [n for n in members if n.startswith("data.tar")][0]

    # control 提取
    ctrl_tar = tarfile.open(fileobj=io.BytesIO(members[ctrl_name]), mode="r:*")
    control = ctrl_tar.extractfile("./control").read().decode("utf-8-sig")
    fields = {}
    for line in control.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            fields[k.strip()] = v.strip()
    print("control package:", fields.get("Package"))
    assert fields.get("Package"), "control 没有 Package 字段"

    # data 段文件统计 + dylib-only 过滤
    data_tar = tarfile.open(fileobj=io.BytesIO(members[data_name]), mode="r:*")
    files = [m for m in data_tar.getmembers() if m.isfile()]
    print("data files:", len(files))

    plugin_like = [m for m in files
                   if m.name.endswith((".dylib", ".plist"))
                   or "DynamicLibraries/" in m.name
                   or "TweakInject/" in m.name]
    print("plugin-like files:", len(plugin_like))
    for m in plugin_like[:5]:
        print("   ", m.name, m.size)

    # 路径穿越检测：确认包内没有可疑条目
    bad = [m.name for m in data_tar.getmembers()
           if m.name.startswith("/") or ".." in m.name]
    print("suspicious paths:", bad if bad else "none")
    assert not bad, "包内存在可疑路径: %s" % bad

    # 权限检查
    for m in files:
        if m.name.endswith("pmhelper"):
            print("pmhelper mode: %o" % m.mode)

    print("OK: %s 解析通过" % os.path.basename(deb))
    return 0


if __name__ == "__main__":
    sys.exit(main())
