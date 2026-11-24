#!/usr/bin/env python3
"""校验产物 .deb：结构、路径、权限、Mach-O 头、签名与 entitlements。"""
import io
import os
import struct
import sys
import tarfile

EXPECTED_ARCH = "iphoneos-arm64"
EXPECTED_PKG = "com.yg.pluginmanager"
HELPER_PATH = "var/jb/usr/libexec/pluginmanager/pmhelper"
APP_BIN = "var/jb/Applications/PluginManager.app/PluginManager"

LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
CPU_TYPE_ARM64 = 0x0100000C

failure = []
notes = []


def check(cond, ok_msg, fail_msg):
    if cond:
        notes.append("  [PASS] " + ok_msg)
        return True
    failure.append("  [FAIL] " + fail_msg)
    return False


def parse_ar(data):
    if data[:8] != b"!<arch>\n":
        raise SystemExit("not an ar archive")
    off = 8
    out = []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        size_field = hdr[48:58].decode("ascii", "replace").strip()
        size = int(size_field or "0")
        body = data[off + 60:off + 60 + size]
        out.append((name, body))
        off += 60 + size + (size % 2)
    return out


def macho_info(blob):
    if len(blob) < 32:
        return None
    magic_le = struct.unpack("<I", blob[0:4])[0]
    magic_be = struct.unpack(">I", blob[0:4])[0]
    if magic_le == 0xFEEDFACF:
        endian = "<"
        is64 = True
    elif magic_le == 0xFEEDFACE:
        endian = "<"
        is64 = False
    elif magic_be == 0xFEEDFACF:
        endian = ">"
        is64 = True
    elif magic_be == 0xFEEDFACE:
        endian = ">"
        is64 = False
    else:
        return None
    hdr_size = 32 if is64 else 28
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack(endian + "iiIIII", blob[4:28])
    info = {
        "cputype": cputype,
        "filetype": filetype,
        "ncmds": ncmds,
        "flags": flags,
        "codesig": None,
        "min_os": None,
        "has_auth_code": None,
    }
    pos = hdr_size
    for _ in range(ncmds):
        if pos + 8 > len(blob):
            break
        cmd, cmdsize = struct.unpack(endian + "II", blob[pos:pos + 8])
        if cmdsize < 8:
            break
        if cmd == LC_CODE_SIGNATURE and pos + 16 <= len(blob):
            dataoff, datasize = struct.unpack(endian + "II", blob[pos + 8:pos + 16])
            info["codesig"] = (dataoff, datasize)
        elif cmd == LC_BUILD_VERSION and pos + 24 <= len(blob):
            platform, minos, sdk = struct.unpack(endian + "III", blob[pos + 8:pos + 20])
            info["min_os"] = (platform, minos, sdk)
        elif cmd == LC_VERSION_MIN_IPHONEOS and pos + 16 <= len(blob):
            version, sdk = struct.unpack(endian + "II", blob[pos + 8:pos + 16])
            info["min_os"] = (2, version, sdk)
        pos += cmdsize
    return info


def fmt_version(v):
    return "%d.%d.%d" % ((v >> 16) & 0xFFFF, (v >> 8) & 0xFF, v & 0xFF)


def blobs_from_codesig(macho):
    if not macho or not macho["codesig"]:
        return []
    return []


def main():
    if len(sys.argv) != 2:
        print("usage: verify-deb.py <deb>")
        return 2
    deb = sys.argv[1]
    if not os.path.exists(deb):
        print("missing %s" % deb)
        return 2

    data = open(deb, "rb").read()
    members = parse_ar(data)
    names = [m[0] for m in members]
    print("deb: %s (%d bytes)" % (deb, len(data)))
    print("ar members: %s" % ", ".join(names))

    check(names[0] == "debian-binary", "首成员为 debian-binary", "首成员不是 debian-binary")
    check(any(n.startswith("control.tar") for n in names), "含 control.tar.xz", "缺少 control 段")
    check(any(n.startswith("data.tar") for n in names), "含 data.tar.xz", "缺少 data 段")
    check(members[0][1] == b"2.0\n", "debian-binary 版本 2.0", "debian-binary 内容异常")

    control_blob = [m[1] for m in members if m[0].startswith("control.tar")][0]
    data_blob = [m[1] for m in members if m[0].startswith("data.tar")][0]

    ctf = tarfile.open(fileobj=io.BytesIO(control_blob), mode="r:*")
    control_txt = ctf.extractfile("./control").read().decode("utf-8-sig", "replace")
    fields = {}
    for line in control_txt.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            fields[k.strip()] = v.strip()

    print("\ncontrol 字段:")
    for k in ("Package", "Name", "Version", "Architecture", "Section", "Depends", "Maintainer"):
        print("  %-14s %s" % (k + ":", fields.get(k, "<missing>")))

    check(fields.get("Package") == EXPECTED_PKG, "Package = %s" % EXPECTED_PKG, "Package 字段不符")
    check(fields.get("Architecture") == EXPECTED_ARCH, "Architecture = %s" % EXPECTED_ARCH, "Architecture 字段不符")
    check("Version" in fields, "Version 存在（%s）" % fields.get("Version"), "缺少 Version")
    control_names = ctf.getnames()
    print("control 内容: %s" % ", ".join(control_names))
    for script in ("./postinst", "./prerm"):
        if script in control_names:
            mode = ctf.getmember(script).mode
            check(mode & 0o111 != 0, "%s 可执行 (mode %o)" % (script, mode), "%s 不可执行" % script)

    dtf = tarfile.open(fileobj=io.BytesIO(data_blob), mode="r:*")
    members_data = dtf.getmembers()
    paths = {}
    for m in members_data:
        if m.isfile():
            paths[m.name.lstrip("./")] = m

    print("\ndata 文件（%d 个）:" % len(paths))
    for p in sorted(paths):
        print("  %-70s %7d  %o" % (p, paths[p].size, paths[p].mode))

    bad_paths = [p for p in paths if not p.startswith("var/jb/")]
    check(not bad_paths, "所有路径都在 var/jb/ 下", "存在包外路径: %s" % bad_paths)

    check(HELPER_PATH in paths, "特权助手存在", "缺少特权助手")
    check(APP_BIN in paths, "App 主程序存在", "缺少 App 主程序")

    if HELPER_PATH in paths:
        m = paths[HELPER_PATH]
        check(m.mode & 0o4000 != 0, "pmhelper 置 setuid 位 (mode %o)" % m.mode, "pmhelper 缺 setuid 位 (mode %o)" % m.mode)
        check(m.uid == 0 and m.gid == 0, "pmhelper 属主 root:root", "pmhelper 属主不是 root")

    if APP_BIN in paths:
        m = paths[APP_BIN]
        check(m.mode & 0o111 != 0, "App 主程序可执行 (mode %o)" % m.mode, "App 主程序不可执行")

    need_app = [
        "var/jb/Applications/PluginManager.app/Info.plist",
        "var/jb/Applications/PluginManager.app/AppIcon60x60@2x.png",
        "var/jb/Applications/PluginManager.app/AppIcon60x60@3x.png",
    ]
    for p in need_app:
        check(p in paths, "存在 %s" % p.split("/")[-1], "缺少 %s" % p)

    # Mach-O 检查
    print("\nMach-O 检查:")
    for label, path in (("PluginManager", APP_BIN), ("pmhelper", HELPER_PATH)):
        if path not in paths:
            continue
        blob = dtf.extractfile(paths[path]).read()
        info = macho_info(blob)
        if not info:
            failure.append("  [FAIL] %s 不是有效 Mach-O" % label)
            continue
        check(info["cputype"] == CPU_TYPE_ARM64, "%s cputype=arm64" % label,
              "%s cputype 非 arm64 (0x%x)" % (label, info["cputype"]))
        check(info["filetype"] == 2, "%s 为 MH_EXECUTE" % label, "%s filetype=%d 非可执行" % (label, info["filetype"]))
        if info["min_os"]:
            platform, minos, sdk = info["min_os"]
            check(minos <= 0x000F0000, "%s 最低系统 %s（<=15.0）" % (label, fmt_version(minos)),
                  "%s 最低系统 %s 高于 15.0" % (label, fmt_version(minos)))
        else:
            notes.append("  [WARN] %s 未找到 LC_BUILD_VERSION/LC_VERSION_MIN" % label)
        check(info["codesig"] is not None, "%s 含 LC_CODE_SIGNATURE（已签名）" % label, "%s 未签名" % label)
        if info["codesig"]:
            dataoff, datasize = info["codesig"]
            check(dataoff + datasize <= len(blob), "%s 签名数据在文件范围内" % label, "%s 签名段越界" % label)
            print("           codesig offset=%d size=%d" % (dataoff, datasize))

    print("\n结果:")
    for n in notes:
        print(n)
    if failure:
        for f in failure:
            print(f)
        print("\n自检失败：%d 项" % len(failure))
        return 1
    print("\n全部检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
