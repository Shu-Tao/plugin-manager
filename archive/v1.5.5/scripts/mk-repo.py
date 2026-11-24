#!/usr/bin/env python3
"""为 dist/ 里的 .deb 生成 apt 源索引（repo/Packages + Release）。"""
import bz2
import gzip
import hashlib
import io
import lzma
import os
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 从 Release 取全部 deb（与 build.ps1 输出目录一致）
DIST = os.path.join(ROOT, "Release")
if not os.path.isdir(DIST):
    DIST = os.path.join(ROOT, "build", "dist")
# 与 serve-sileo.ps1 读取目录一致
REPO = os.path.join(ROOT, "repo")
ORDER = ["Package", "Name", "Version", "Architecture", "Description",
         "Depends", "Section", "Priority", "Maintainer", "Author"]


def ar_members(blob):
    off = 8
    out = {}
    while off + 60 <= len(blob):
        hdr = blob[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        size = int(hdr[48:58].decode("ascii", "replace").strip() or "0")
        out[name] = blob[off + 60:off + 60 + size]
        off += 60 + size + (size % 2)
    return out


def parse_deb(path):
    blob = open(path, "rb").read()
    members = ar_members(blob)
    ctrl = tarfile.open(fileobj=io.BytesIO(members["control.tar.xz"]))
    text = ctrl.extractfile("./control").read().decode("utf-8-sig")
    fields = {}
    for line in text.splitlines():
        if line.startswith(" ") or line.startswith("\t"):
            continue
        if ": " in line:
            k, v = line.split(": ", 1)
            fields[k.strip()] = v.strip()
    data = tarfile.open(fileobj=io.BytesIO(members["data.tar.xz"]))
    installed = sum(i.size for i in data.getmembers() if i.isfile())
    return blob, fields, installed


def stanza(path):
    blob, fields, installed = parse_deb(path)
    name = os.path.basename(path)
    lines = []
    for k in ORDER:
        if k in fields:
            lines.append("%s: %s" % (k, fields[k]))
    lines.append("Installed-Size: %d" % max(1, installed // 1024))
    lines.append("Filename: ./%s" % name)
    lines.append("Size: %d" % len(blob))
    lines.append("SHA256: %s" % hashlib.sha256(blob).hexdigest())
    lines.append("SHA1: %s" % hashlib.sha1(blob).hexdigest())
    lines.append("MD5sum: %s" % hashlib.md5(blob).hexdigest())
    return "\n".join(lines) + "\n"


def version_key(v):
    parts = []
    for chunk in v.replace("-", ".").replace("_", ".").split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return parts


def stanza_fields(path):
    blob, fields, _ = parse_deb(path)
    return fields


def main():
    os.makedirs(REPO, exist_ok=True)
    debs = sorted(f for f in os.listdir(DIST) if f.endswith(".deb"))
    if not debs:
        print("dist/ 里没有 .deb")
        return 1

    # 同一个包只保留最高版本，否则 Sileo 会列出十几个重复条目
    best = {}
    for name in debs:
        src = os.path.join(DIST, name)
        fields = stanza_fields(src)
        pkg = fields.get("Package", "")
        if not pkg:
            continue
        ver = fields.get("Version", "0")
        key = version_key(ver)
        if pkg not in best or key > best[pkg][0]:
            best[pkg] = (key, name, src)

    stanzas = []
    for pkg, (_, name, src) in sorted(best.items()):
        dst = os.path.join(REPO, name)
        if not (os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src)):
            open(dst, "wb").write(open(src, "rb").read())
        stanzas.append(stanza(src))

    entries = "\n".join(stanzas)
    raw = entries.encode("utf-8")
    open(os.path.join(REPO, "Packages"), "wb").write(raw)
    open(os.path.join(REPO, "Packages.gz"), "wb").write(gzip.compress(raw))
    open(os.path.join(REPO, "Packages.bz2"), "wb").write(bz2.compress(raw))
    open(os.path.join(REPO, "Packages.xz"), "wb").write(lzma.compress(raw))
    release = ("Origin: YG Local\nLabel: YG Local\nSuite: stable\n"
               "Version: 1.0\nCodename: ios\nArchitectures: iphoneos-arm64\n"
               "Components: main\nDescription: YG 本地插件源\n")
    open(os.path.join(REPO, "Release"), "wb").write(release.encode("utf-8"))

    print("repo: %s" % REPO)
    print("packages: %d" % len(debs))
    print("files: %s" % ", ".join(sorted(os.listdir(REPO))))
    print()
    print(entries)
    return 0


if __name__ == "__main__":
    sys.exit(main())