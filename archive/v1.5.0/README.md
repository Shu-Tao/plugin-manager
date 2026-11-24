# 插件管理（PluginManager）

独立 App 形式的越狱插件管理器：不内嵌于设置，桌面上就是一个普通 App。列出设备上所有注入型插件，逐项开关，并提供「重启 SpringBoard（注销）」与「重启用户空间」让改动生效。

产物：`dist/com.shutao.pluginmanager___VERSION___iphoneos-arm64.deb`（rootless，arm64，iOS 15.0+）。

---

## 一、它做了什么

| 功能 | 实现 |
| --- | --- |
| 列出所有插件 | 扫描注入目录，收集 `*.dylib` / `*.dylib.disabled`，读同名 Filter plist 拿 Bundle ID；顺带查 dpkg 归属包名 |
| 单项开关 | 把 `Name.dylib` → `Name.dylib.disabled`，`Name.plist` → `Name.plist.disabled`（恢复时反向）。注入器只认 `.dylib` 后缀，改名即全局不加载 |
| 批量开关 | 导航栏「全部」菜单，对当前搜索结果全启用 / 全禁用 |
| 搜索 | 按插件名、Bundle ID、所属包名过滤 |
| 生效 | 「重启 SpringBoard（注销）」走 `sbreload`，回退 `killall -9 SpringBoard`；「重启用户空间」走 `launchctl reboot userspace` |
| 待生效提示 | 状态卡片显示「N 项改动已写盘，重启后生效」 |

**为什么用改名而不是偏好开关**：改名是文件级的、进程无关的、对任何注入器（ElleKit / Substrate / TweakInject）都成立的唯一语义。写偏好开关只能对「自己 hook 了自己配置」的插件生效，对第三方插件无效。

---

## 二、包内结构与权限

```
/var/jb/Applications/PluginManager.app/          755  App 本体（图标 + Info.plist + 主程序）
/var/jb/usr/libexec/pluginmanager/pmhelper       4755 特权助手（setuid root）
```

App 用 `posix_spawn` 调 `pmhelper`，参数进、单行 JSON 出；没有常驻 daemon，没有 launchd 注册，没有 IPC 端口。助手第一件事就是 `geteuid() != 0` 时拒绝执行。

### 助手协议

```jsonc
// pmhelper list
{"ok":true,"dir":"/var/jb/usr/lib/TweakInject","jbroot":"/var/jb","count":12,
 "items":[{"id":"DemoTweak","dylib":"DemoTweak.dylib","plist":"DemoTweak.plist",
           "enabled":true,"filter":["com.apple.springboard"],"execs":[],
           "size":18432,"mtime":1699999999,"package":"com.yg.demotweak"}]}

// pmhelper set --id DemoTweak --state disabled
{"ok":true,"id":"DemoTweak","state":"disabled","moved":["DemoTweak.dylib.disabled","DemoTweak.plist.disabled"]}

// pmhelper respring          -> {"ok":true,"method":"sbreload"}
// pmhelper reboot-userspace  -> {"ok":true,"method":"launchctl"}
// pmhelper version           -> {"ok":true,"version":"1.0.0","uid":501,"euid":0}

// 失败统一 {"ok":false,"error":"E_IO","detail":"..."}
```

错误码：`E_NOT_ROOT` `E_NO_DIR` `E_BAD_ID` `E_BAD_STATE` `E_NOENT` `E_NOSTATE` `E_IO` `E_USAGE`。

### 注入目录探测顺序

1. `/var/jb/usr/lib/TweakInject` ← **A14 / iOS 15 / Dopamine rootless 命中这个**
2. `/var/jb/Library/MobileSubstrate/DynamicLibraries`
3. `/usr/lib/TweakInject`
4. `/Library/MobileSubstrate/DynamicLibraries`（rootful 设备）

取第一个存在者并 `realpath` 去重后使用。

---

## 三、构建

在 Windows 上直接构建，**不需要 WSL、不需要管理员权限**。

```powershell
cd E:\DataBackup\plugin-manager
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-toolchain.ps1   # 首次：拉工具链
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean           # 出包
```

工具链（全部落在 `E:\DataBackup\toolchain`，约 1.3 GB）：

| 组件 | 用途 |
| --- | --- |
| zig 0.17.1（pip wheel） | `zig cc`，做 Apple 目标的编译前端 |
| llvm-mingw 的 `ld.lld` | `-flavor darwin`，做 Mach-O 链接 |
| iPhoneOS16.5.sdk（theos/sdks） | 头文件与 tbd 存根 |
| zsign 1.1.3 | ad-hoc 签名 + 注入 entitlements |

`build.ps1` 的六个阶段：编译 → 链接 → 签名 → 组装 layout → 打 deb → 单测 + 产物自检。任一阶段失败都会直接中断并打印原因。

### 产物自检（每次构建自动跑）

- `ar` 三成员结构、`debian-binary` 版本
- `control` 字段：Package / Architecture / Version
- 所有路径都在 `var/jb/` 下
- `pmhelper` 的 setuid 位（4755）与 root:root 属主
- 两个 Mach-O：cputype=arm64、MH_EXECUTE、minos ≤ 15.0、含 `LC_CODE_SIGNATURE`

### 核心逻辑单测（35 项）

`src/helper/PMFsOps.c` 是不依赖 Foundation 的纯 C 核——开关规划、执行、失败回滚、标识白名单、目录扫描都在这里，助手直接调用它。构建时用宿主机 clang 把它和 `tests/pmfsops_test.c` 编译成本机程序跑一遍：

```
[valid id]  7 项    路径穿越 / 斜杠 / 空格 / 超长 全部拒绝
[scan]      4 项    去重、字典序、忽略无关文件、目录缺失
[switch]   11 项    禁用/启用/幂等/不存在/非法标识
[partial]   4 项    只有 dylib 没有 plist 也能开关
[symlink]   2 项    符号链接一律拒绝（Windows 宿主跳过）
[rollback]  4 项    第二步失败时回滚第一步
[plan]      5 项    规划结果与目录缺失
35 passed, 0 failed
```

---

## 四、安装到设备

前置：Dopamine（或其他 rootless 越狱）、已装 OpenSSH、已装 ElleKit。

### 一键部署

```powershell
.\scripts\deploy.ps1 -Device [DEVICE_IP] -Password [ROOT_PW]
# 端口非 22：-Port 2222
# 不想自动注销：-NoRespring
# 只看命令不执行：-DryRun
```

脚本做：scp 上传 → `dpkg -i` → 校验可执行位与 setuid → 跑 `pmhelper version` / `pmhelper list` → `uicache` → 注销。

### 手动安装

```bash
scp dist/com.shutao.pluginmanager___VERSION___iphoneos-arm64.deb root@[DEVICE_IP]:/tmp/
ssh root@[DEVICE_IP]
dpkg -i /tmp/com.shutao.pluginmanager___VERSION___iphoneos-arm64.deb
chmod 4755 /var/jb/usr/libexec/pluginmanager/pmhelper
uicache -p /var/jb/Applications/PluginManager.app
sbreload        # 或 killall -9 SpringBoard
```

装完桌面出现「插件管理」图标。

---

## 五、使用

1. 打开 App，列表里是设备上所有注入型插件，开关为绿色表示当前启用。
2. 拨动开关 → 弹「已禁用」提示，状态卡片出现「1 项改动已写盘」。
3. 点「重启 SpringBoard（注销）」→ 黑屏 3–8 秒回到桌面 → 重新打开 App，该插件已不在加载列表里。
4. 注销后仍不生效（少见）→ 点「重启用户空间」，断网黑屏 5–20 秒。
5. 长按 / 点行 → 复制插件标识；导航栏「全部」→ 全启用 / 全禁用（对当前搜索结果生效）。

---

## 六、故障排查

| 现象 | 原因与处理 |
| --- | --- |
| App 打开后整页灰、提示「特权助手不可用」 | `pmhelper` 丢了 setuid：`chmod 4755 /var/jb/usr/libexec/pluginmanager/pmhelper` |
| 提示「未检测到插件注入目录」 | 没装 ElleKit，或注入目录不在四个候选路径里；`ls /var/jb/usr/lib/TweakInject` 自查 |
| 开关报 `E_IO` | 目标名已被占用，或该 dylib 是符号链接（助手拒绝处理符号链接） |
| 开关成功但插件还在跑 | 还没注销；已注入到常驻进程的插件必须重启用户空间 |
| 桌面没有图标 | `uicache -a` 或注销一次；确认 `/var/jb/Applications/PluginManager.app` 存在 |
| `dpkg -i` 报依赖错误 | 本包只依赖 `firmware (>= 15.0)`；若 dpkg 版本过老，用 Sileo/Zebra 安装 |

---

## 七、卸载与回滚

`prerm` 会把所有 `*.dylib.disabled` / `*.plist.disabled` 恢复原名，**不会**出现「卸载了管理器但插件还残留禁用态」的情况。

```bash
dpkg -r com.shutao.pluginmanager
uicache -a && sbreload
```

手动回滚某个插件：

```bash
cd /var/jb/usr/lib/TweakInject
mv Name.dylib.disabled Name.dylib
mv Name.plist.disabled Name.plist
sbreload
```

---

## 八、已知边界

- dpkg 重装某插件会把文件恢复成原名 → 该插件自动变回启用态，需要在 App 里重新关一次。
- 插件的 `.dylib` 与 `.plist` 必须同名（Theos 默认约定）。不满足的插件会显示但开关只动 dylib。
- 助手不做通配删除、不改宿主文件权限、不动其他包的内容。

---

## 九、工程结构

```
plugin-manager/
  VERSION                版本号（构建时注入 control）
  src/app/               App（ObjC + ARC + UIKit，无 Storyboard）
    main.m PMAppDelegate  入口与窗口
    PMListViewController  列表 / 搜索 / 批量 / 两个生效按钮
    PMStore               与助手通讯 + 待生效计数
    PMPluginItem          模型
    PMSwitchCell          插件行（色块图标 + 开关）
    PMStatusCell          状态卡片
    PMHelperClient        posix_spawn 调助手，JSON 解析，超时与错误翻译
    PMToast PMTheme       提示与配色
  src/helper/            特权助手
    pmhelper.m            命令分发：list / set / respring / reboot-userspace / version
    PMFsOps.c/.h          纯 C 核：规划、执行、回滚、扫描（被单测覆盖）
    PMPaths.m             注入目录探测、JB 根前缀
    PMScanner.m           插件条目组装、Filter plist 解析、dpkg 归属查询
  tests/                  宿主机单测（Windows/Linux 均可跑）
  resources/              Info.plist、entitlements、control、maintainer scripts
  scripts/                bootstrap / build / deploy / mkdeb / verify-deb / gen-icon
  layout/                 设备侧目录树（构建产物，可删）
  dist/                   .deb 产物
```

---

## 十、二次开发提示

- 加新助手命令：`pmhelper.m` 里加分支 + 在 `PMHelperClient` 里加封装，两侧都返回/解析同一份 JSON。
- 改最低系统：`build.ps1 -MinIOS 14.0`（rootless 需 15+，rootful 用 `-MinIOS 14.0` 并改探测路径已在代码里兼容）。
- 发布到软件源：把 `dist/*.deb` 放进 repo 目录，跑 `dpkg-scanpackages` 生成 `Packages`。
## 十一、1.2.0 新增：文件管理

### 11.1 底部操作面板

点插件行 → 从底部升起面板（圆角 22、grabber、下滑关闭）。按钮网格 3 列：

| 按钮 | 行为 |
| --- | --- |
| 分享 | 把该插件的 dylib + plist 交给系统分享面板 |
| 提取 dylib | 复制到 `Documents/PluginManager/`，可再分享或上传 |
| 包信息 | 弹窗显示 dylib/plist 文件名、dpkg 归属、大小 |
| 备份 | 打包成 `<id>-<时间戳>.zip` 存到 `Library/PluginManager/` |
| 改名 | 同步改 dylib 与 plist 文件名，失败自动回滚 |
| 停用 / 启用 | 与行内开关等价 |

### 11.2 文件管理页

右上角 `⋯` → 「文件管理」。列出：

- `Documents/PluginManager/` —— 提取出来的 dylib/plist、解包产物
- `Library/PluginManager/` —— 备份 zip

点 `.deb` 或解包目录同样升起操作面板（解压 / 提取 dylib / 包信息 / 分享 / 删除副本）。

### 11.3 libarchive 运行时加载

`PMArchiveOps.c` 用 `dlopen` + `dlsym` 解析 `libarchive.2.dylib`，**不在链接期硬依赖**。

原因：设备若缺该库，硬链接会让 `pmhelper` 整体加载失败，连带把已经能用的插件开关一起废掉。运行时加载则最坏只是文件管理不可用。

`pmhelper capabilities` 返回 `{"archive":true/false}`，App 据此显隐相关按钮。

已验证 `llvm-nm -u build/pmhelper` 只含 `_dlopen`/`_dlsym`，没有 `archive_` 符号——确实没有硬依赖。

### 11.4 安全边界

- 输出目录白名单：`Documents/PluginManager/`、`Library/PluginManager/`
- 条目路径含 `..` 或绝对路径 → 跳过并计入 skipped
- 单文件 64 MB、单包总量 256 MB 上限
- 解出的文件统一 0644/0755，不写 setuid
- **不提供删除原始插件**，只删本 App 生成的副本

### 11.5 行布局调整

```
[34 色块] 12 [标题 ………………………] [开关 51]
               [用途 · 最多两个宿主] [▾ 14]
               └ 展开区（完整详情）
```

- 箭头从 18pt 缩到 **14pt**，且不再单独占一列（原来会把标题挤窄）
- 位置移到**副标题行右端、与开关右边缘对齐**，视觉落在右下角
- 折叠态副标题只写「大概功能」：最多两个宿主中文名，不带 bundle id / 包名 / 大小
- 展开后才显示完整 Bundle 清单、进程、文件、dpkg 包、大小、修改时间
