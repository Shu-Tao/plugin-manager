#!/usr/bin/env python3
"""把 layout/ 目录打成 Debian 包（ar + control.tar.xz + data.tar.xz）。

不依赖 dpkg/fakeroot，可直接在 Windows 上跑。
用法： python mkdeb.py <layout_dir> <control_file> <out_deb> [version]
"""
import io
import os
import sys
import tarfile
import hashlib
import time

SETUID_PATHS = {"var/jb/usr/libexec/pluginmanager/pmhelper"}
EXEC_PATHS = {
    "var/jb/usr/libexec/pluginmanager/pmhelper",
    "var/jb/Applications/PluginManager.app/PluginManager",
}


def norm(path):
    return path.replace(os.sep, "/").lstrip("./")


def add_bytes(tar, name, data, mode, mtime):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = mtime
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar, name, mtime):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = mtime
    tar.addfile(info)


def build_data_tar(layout_dir):
    mtime = int(time.time())
    dirs = []
    files = []
    for root, dirnames, filenames in os.walk(layout_dir):
        dirnames.sort()
        for d in dirnames:
            dirs.append(norm(os.path.relpath(os.path.join(root, d), layout_dir)))
        for f in sorted(filenames):
            files.append(norm(os.path.relpath(os.path.join(root, f), layout_dir)))

    all_dirs = set()
    for rel in dirs + files:
        parts = rel.split("/")
        for i in range(1, len(parts)):
            all_dirs.add("/".join(parts[:i]))
    all_dirs.add("var")

    buf = io.BytesIO()
    md5map = {}
    total_bytes = 0
    with tarfile.open(fileobj=buf, mode="w:xz", preset=6) as tar:
        for rel in sorted(all_dirs):
            add_dir(tar, "./" + rel, mtime)
        for rel in sorted(files):
            with open(os.path.join(layout_dir, rel.replace("/", os.sep)), "rb") as fh:
                data = fh.read()
            if rel in SETUID_PATHS:
                mode = 0o4755
            elif rel in EXEC_PATHS or rel.endswith(".dylib"):
                mode = 0o755
            else:
                mode = 0o644
            add_bytes(tar, "./" + rel, data, mode, mtime)
            md5map[rel] = hashlib.md5(data).hexdigest()
            total_bytes += len(data)
    return buf.getvalue(), md5map, total_bytes


def build_control_tar(control_path, md5map, version=None, installed_kb=None):
    mtime = int(time.time())
    with open(control_path, "rb") as fh:
        control_data = fh.read()
    text = control_data.decode("utf-8-sig")
    if version:
        text = text.replace("__VERSION__", version)
    # Installed-Size 必须是解压后的实际 KB 数
    if installed_kb is not None:
        text = text.replace("__INSTALLED_SIZE__", str(installed_kb))
    control_data = text.encode("utf-8")
    if not control_data.endswith(b"\n"):
        control_data += b"\n"

    md5_lines = "".join("%s  %s\n" % (md5map[rel], rel) for rel in sorted(md5map))

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:xz", preset=6) as tar:
        add_dir(tar, "./", mtime)
        add_bytes(tar, "./control", control_data, 0o644, mtime)
        add_bytes(tar, "./md5sums", md5_lines.encode(), 0o644, mtime)
        scripts_dir = os.path.dirname(os.path.abspath(control_path))
        for name in ("preinst", "postinst", "prerm", "postrm"):
            path = os.path.join(scripts_dir, name)
            if not os.path.exists(path):
                continue
            with open(path, "rb") as fh:
                add_bytes(tar, "./" + name, fh.read(), 0o755, mtime)
    return buf.getvalue()


def ar_header(name, size, mtime):
    fields = [
        name.ljust(16),
        str(mtime).ljust(12),
        "0".ljust(6),
        "0".ljust(6),
        "100644".ljust(8),
        str(size).ljust(10),
        chr(96) + chr(10),
    ]
    header = "".join(fields)
    assert len(header) == 60, (len(header), header)
    return header.encode("ascii")


def ar_write(out_path, members):
    mtime = int(time.time())
    with open(out_path, "wb") as fh:
        fh.write(b"!<arch>\n")
        for name, data in members:
            fh.write(ar_header(name, len(data), mtime))
            fh.write(data)
            if len(data) % 2 == 1:
                fh.write(b"\n")


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    layout_dir, control_path, out_deb = sys.argv[1:4]
    version = sys.argv[4] if len(sys.argv) > 4 else None

    data_tar, md5map, total_bytes = build_data_tar(layout_dir)
    installed_kb = max(1, total_bytes // 1024)
    control_tar = build_control_tar(control_path, md5map, version, installed_kb)
    ar_write(out_deb, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.xz", control_tar),
        ("data.tar.xz", data_tar),
    ])
    print("built %s" % out_deb)
    print("  data.tar.xz    %d bytes, %d files, Installed-Size %d KB" % (len(data_tar), len(md5map), installed_kb))
    print("  control.tar.xz %d bytes" % len(control_tar))
    return 0


if __name__ == "__main__":
    sys.exit(main())