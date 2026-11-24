//
//  PMProcOps.h — 进程表操作（纯 C，无 Foundation，可宿主机单测）
//
//  用途：注销 SpringBoard 时不再依赖 sbreload / killall 等外部程序，
//  直接通过内核进程表定位目标进程并发信号。
//

#ifndef PM_PROC_OPS_H
#define PM_PROC_OPS_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 按进程名精确匹配，返回第一个 pid；未找到返回 -1。
int pm_find_pid_by_name(const char *name);

/// 按名字统计进程数；出错返回 0。
int pm_count_by_name(const char *name);

/// 向所有同名进程发信号，返回实际命中的进程数。
/// sig 非法或 name 为空时返回 -1。
int pm_kill_by_name(const char *name, int sig);

/// 给指定 pid 发信号；pid <= 1 一律拒绝（保护 PID 1 / init）。
int pm_kill_pid(int pid, int sig);

/// 进程名白名单校验：只允许调用方声明的固定目标，防止助手变成通用杀进程工具。
/// allowed 是 NULL 结尾的字符串数组。
int pm_name_allowed(const char *name, const char *const *allowed);

#ifdef __cplusplus
}
#endif

#endif
