# 许可范围（为什么 Photons 可以调用本仓库）

本仓库：**GPL-3.0-or-later**（`LICENSE`）。Photons：**MIT**。
两者共存的方式是 **两个独立进程 + JSON over pipes**，不是链接。

## 判定依据（GPLv3 §5 末段、§6；GNU GPL FAQ #MereAggregation）

> "A compilation of a covered work with other separate and independent works,
> which are not by their nature extensions of the covered work, and which are
> not combined with it such as to form a larger program … is called an
> 'aggregate' … Inclusion of a covered work in an aggregate does not cause this
> License to apply to the other parts of the aggregate."

> "If the modules are included in the same executable file, they are definitely
> combined in one program. If modules are designed to run linked together in a
> shared address space, that almost surely means combining them into one program.
> By contrast, pipes, sockets and command-line arguments are communication
> mechanisms normally used between two separate programs."

## 本仓库遵守的边界

| 事实 | 状态 |
|---|---|
| `hdrmerge-swift` 是独立可执行文件（`otool -L` 只依赖系统 dylib，无自定义 dylib） | ✅ |
| Photons 用 `Process` 启动它，参数是路径，结果是 JSON | ✅ 聚合 |
| 不 `dlopen`、不链接 `libHDRMergeCore.dylib`、不把源码拷进 Photons target | ✅ |
| `Host/Photons/HDRMergeClient.swift` 是 **MIT**（只做进程/JSON 胶水，不含本仓库任何算法实现） | ✅ 可进 Photons |
| 分发时随包提供 `hdrmerge-swift` 的对应源码（本仓库 tag + 补丁） | 分发方义务（GPLv3 §6(d)） |
| 不得给 GPL 组件加额外限制（EULA/DRM/App Store） | 分发方义务 |

只要保持「独立进程 + 路径参数 + JSON/文件交换」，Photons 保持 MIT，本仓库保持 GPLv3，这是许可允许的聚合。

若将来出现「把合并算法编译进 Photons 进程」的需求，那就不再是聚合——要么整包转 GPLv3，要么重新实现算法（本仓库的 `PORTING.md` 已写明与上游 HDRMerge 的差异，重实现时可据此避开 GPL 表达）。
