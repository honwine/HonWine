# Wine mmap + PROT_EXEC + fd 深度分析

> 更新: 2026-06-12
> 主题: 在 noexec 文件系统上 mmap(MAP_PRIVATE, fd) + mprotect(PROT_EXEC) 失败的根本原因

---

## 一、核心问题

在 HarmonyOS HNP 安装路径 `/data/service/hnp/` 上，文件系统挂载为 **noexec**，导致 Wine 加载 PE DLL 时无法为代码段添加 PROT_EXEC 权限：

```
map_image_into_view failed to set ... protection on ... section .text, noexec filesystem?
```

### 为什么 `mmap(fd) + mprotect(PROT_EXEC)` 会失败？

Linux 内核在 `mprotect` 添加 PROT_EXEC 时会检查：
1. 页面是否是**文件支持的**（file-backed）？
2. 文件所在的文件系统是否禁止可执行映射（`MS_NOEXEC`）？

如果两者都满足，即使 mmap 使用 `MAP_PRIVATE`（写时拷贝），内核也会拒绝添加 PROT_EXEC。

**工作原理**: Wine 先 mmap(fd) 创建文件支持的可写页面，然后试图 mprotect 添加 PROT_EXEC。在 noexec 文件系统上，步骤 2 被内核拒绝。

---

## 二、Wine PE 加载全流程分析

### 2.1 调用链

```
virtual_map_builtin_module() / virtual_map_module()
  → virtual_map_image()
    → map_image_view()                    # 1. 分配匿名内存视图
      → map_view()                        #    创建 VIEW，strip PROT_EXEC (line 2298)
        → map_fixed_area()                #    mmap(MAP_ANON) 分配匿名页
    → map_image_into_view()               # 2. 填充 PE 内容
      → map_pe_header()                   #    2a. 映射 PE 头
      → for each section:                 #    2b. 映射每个段
        → [可执行段] map_file_into_view() #        可能 mmap(fd) 创建文件支持页
        → [共享段] map_file_into_view()   #        mmap(shared_fd) 共享映射
      → set_vprot()                       #    2c. 设置最终保护（含 PROT_EXEC）
        → mprotect_range()
          → mprotect_exec()               #        调用 mprotect 添加 PROT_EXEC ❌ 失败
```

### 2.2 关键函数详解

#### (a) `map_view()` — 视图分配 (line 2260)

```c
unix_prot &= ~PROT_EXEC;  // line 2298: 初始分配永不加 PROT_EXEC
```

- 总是通过 `anon_mmap_alloc()` 或 `map_fixed_area()` 分配**匿名**内存
- 明确 strip PROT_EXEC，后面通过 `mprotect_range` 再加

#### (b) `map_pe_header()` — PE 头映射 (line 2745)

```c
// line 2753: 用 PROT_READ|PROT_WRITE 尝试 mmap(fd)，不加 PROT_EXEC
if (mmap(ptr, map_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, fd, 0) != MAP_FAILED)
    return STATUS_SUCCESS;

// line 2760-2762: EPERM/EACCES 才设置 removable=TRUE
case EPERM:
case EACCES:
    WARN("noexec file system, falling back to read\n");
    break;
// ...
*removable = TRUE;  // 只有 mmap 失败时才设置
```

**关键问题**: 在 noexec 文件系统上，`mmap(PROT_READ|PROT_WRITE)` **成功**（因为没有请求 PROT_EXEC），因此 `removable` 保持 FALSE。Wine 的 removable 检测机制完全绕过 noexec 场景。

#### (c) `map_file_into_view()` — 文件内容映射 (line 2364)

```c
int prot = PROT_READ | PROT_WRITE;  // 不加 PROT_EXEC

// line 2398-2400: 只有 !removable 且地址对齐时才 mmap(fd)
if ((!removable || (flags & MAP_SHARED)) && host_addr == map_addr && host_size == map_size)
{
    if (mmap(host_addr, host_size, prot, flags, fd, offset) != MAP_FAILED)
        return STATUS_SUCCESS;  // ✅ 文件支持页已建立，但后续 PROT_EXEC ❌

    // line 2407-2418: EACCES/EPERM 处理
    case EACCES:
    case EPERM:
        if (vprot & VPROT_WRITE) return STATUS_ACCESS_DENIED;
        break;  // 只读 → fall through 到 pread 方案
}

// line 2432-2433: fallback 路径 — 匿名页 + pread
mprotect(map_addr, map_size, PROT_READ | PROT_WRITE);
pread(fd, map_addr, size, offset);  // 文件内容读到匿名内存 → 后续 PROT_EXEC 可以加
```

**两条路径对比**:

| 路径 | 页面类型 | 后续 mprotect(PROT_EXEC) | 文件系统要求 |
|------|---------|-------------------------|-------------|
| mmap(fd) 成功 | 文件支持 | ❌ 失败 (noexec) | fs 无 noexec |
| pread 回退 | 匿名 | ✅ 成功 | 无限制 |

#### (d) `mprotect_exec()` — 加 PROT_EXEC (line 1938)

```c
static inline int mprotect_exec(void *base, size_t size, int unix_prot)
{
    // force_exec_prot 逻辑（ARM64EC 场景，我们当前不触发）
    if (force_exec_prot && (unix_prot & PROT_READ) && !(unix_prot & PROT_EXEC))
    {
        prctl(0x6a6974, 0, 0);
        if (!mprotect(base, size, unix_prot | PROT_EXEC)) { ... return 0; }
        prctl(0x6a6974, 0, 1);
        ...
    }

    // OHOS fix: 所有 PROT_EXEC mprotect 用 prctl 绕过
    if (unix_prot & PROT_EXEC)
    {
        int ret;
        prctl(0x6a6974, 0, 0);     // 暂时允许 exec
        ret = mprotect(base, size, unix_prot);
        prctl(0x6a6974, 0, 1);     // 恢复 noexec
        return ret;
    }

    return mprotect(base, size, unix_prot);
}
```

**注意**: prctl 绕过对**文件支持页面**无效（内核层面），只能在匿名页面 + prctl 场景下工作。

---

## 三、我们的修复方案

### 3.1 修复位置: `map_image_into_view()` (line 3196-3217)

```c
/* OHOS: for executable sections, use anonymous memory to avoid noexec filesystem */
if (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE)
{
    char *sec_addr = (char *)view->base + sec[i].VirtualAddress;
    size_t sec_offset = sec[i].VirtualAddress & host_page_mask;
    size_t sec_map_size = ROUND_SIZE(sec[i].VirtualAddress, file_size, host_page_mask);

    prctl(0x6a6974, 0, 0);
    if (mmap(sec_addr - sec_offset, sec_map_size + sec_offset,
              PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) == MAP_FAILED)
    {
        prctl(0x6a6974, 0, 1);
        ERR_(module)("Could not map %s section %.8s with anon mmap\n", ...);
        goto done;
    }
    prctl(0x6a6974, 0, 1);
    if (pread(fd, sec_addr, file_size, file_start) != (ssize_t)file_size)
    {
        ERR_(module)("Could not read %s section %.8s\n", ...);
        goto done;
    }
}
else if (map_file_into_view(view, fd, ...) != STATUS_SUCCESS)
{
    // 非可执行段用原始 mmap(fd) 方案（不需要 PROT_EXEC）
}
```

### 3.2 为什么有效

1. **跳过 mmap(fd)**: 不创建文件支持页面，用 `MAP_ANON` 匿名内存替代
2. **pread 填充内容**: 文件数据直接读到匿名页面
3. **后续 set_vprot**: 匿名页 + prctl → mprotect(PROT_EXEC) 成功

### 3.3 修复覆盖范围

| 场景 | 覆盖? | 说明 |
|------|-------|------|
| `map_image_into_view` 可执行段 | ✅ | 匿名 mmap + pread |
| `map_image_into_view` 非可执行段 | N/A | 不需要 PROT_EXEC |
| `map_image_into_view` 共享段 | N/A | MAP_SHARED，不需要 PROT_EXEC |
| PE header 映射 | N/A | VPROT_READ 无 EXEC |
| `virtual_create_builtin_view` | N/A | VPROT_SYSTEM，由 ELF loader 管理 |
| 普通 NtAllocateVirtualMemory + EXEC | ✅ | 匿名 mmap → mprotect_exec 加 EXEC |
| `force_exec_prot` | ⚠️ | 未测试，当前不触发 |

---

## 四、潜在遗留问题

### 4.1 非页对齐 PE 镜像路径 (line 3093-3111)

```c
if (image_info->image_flags & IMAGE_FLAGS_ImageMappedFlat)
{
    // 整个文件用 map_file_into_view 映射
    map_file_into_view(view, fd, 0, total_size, 0,
                       VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY, removable);

    // 然后整个 VIEW 加 VPROT_EXEC
    set_vprot(view, ptr, total_size,
              VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY | VPROT_EXEC);
}
```

**风险**: 如果 mmap(fd) 成功（noexec 不加 EXEC 时成功），整个视图变成文件支持的，后续 set_vprot(VPROT_EXEC) 会失败。

**影响范围**: `IMAGE_FLAGS_ImageMappedFlat` 是原生子系统二进制（如 `ntdll.dll` 在某些架构上）。这个路径在现代 PE 文件中很少触发，因为 `FileAlignment == SectionAlignment` 通常为 true。

**缓解**: 如果出现此问题，需要对这个路径也做类似匿名 mmap 处理。

### 4.2 `map_pe_header()` 可能创建文件支持页面 (line 2753)

```c
if (mmap(ptr, map_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, fd, 0) != MAP_FAILED)
```

**风险**: PE 头区域变成了文件支持的。如果某个可执行段与 PE 头在同一 host page 内：
- 我们的匿名 mmap 会用 MAP_FIXED 替换这些页面 → ✅ 没问题
- MAP_FIXED 会无条件替换已有的文件支持页面

**影响**: 已验证无问题。匿名 mmap with MAP_FIXED 替换了 PE 头 mmap 创建的文件支持页面。

### 4.3 Wineserver temp 文件 (mapping.c:357)

```c
// server/mapping.c:357 — 检查目录是否支持 exec 映射
ret = mmap(NULL, get_page_size(), PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
```

**行为**: wineserver 在启动时检查当前目录是否支持 exec 映射：
1. 尝试 server_dir → 如果 noexec，失败
2. 尝试 config_dir → 如果 exec，则用该目录
3. 都失败 → 回退到 server_dir

**影响**: temp 文件仅用于共享写入映射（`IMAGE_SCN_MEM_SHARED` 段），不需要 PROT_EXEC，所以即使检测失败也不影响功能。

### 4.4 force_exec_prot 机制 (line 5064)

当 `force_exec_prot` 启用时，**所有** PROT_READ 页面都强制加 PROT_EXEC：
```c
if (force_exec_prot && (unix_prot & PROT_READ) && !(unix_prot & PROT_EXEC))
    mprotect(base, size, unix_prot | PROT_EXEC);
```

**触发条件**: 由 `virtual_set_force_exec(BOOL enable)` 控制，主要在以下场景：
- ARM64EC 代码页管理
- 某些 JIT 场景

**当前状态**: x86_64 on Box64 + ARM64 不触发。如果未来触发，所有文件支持页的 mprotect 都会失败。

---

## 五、mmap + fd 调用完整清单

### ntdll/unix/virtual.c

| 行号 | 函数 | prot | flags | fd | 需要 EXEC? |
|------|------|------|-------|-----|-----------|
| 2400 | `map_file_into_view` | R\|W | PRIVATE/SHARED | PE fd | 后续 mprotect 加 |
| 2753 | `map_pe_header` | R\|W | FIXED\|PRIVATE | PE fd | 不需要 |
| 3203 | `map_image_into_view` (OHOS) | R\|W | FIXED\|ANON\|PRIVATE | -1 | 后续 mprotect 加 |
| 4539 | `virtual_init_user_shared_data` | R | SHARED\|FIXED | USD fd | 不需要 |
| 4570 | `virtual_init_user_shared_data` | R\|W | SHARED | USD fd | 不需要 |

### server/mapping.c

| 行号 | 函数 | prot | flags | fd | 需要 EXEC? |
|------|------|------|-------|-----|-----------|
| 357 | `check_current_dir_for_exec` | R\|X | PRIVATE | temp fd | **直接 mmap 带 EXEC** |

---

## 六、修复前后对比

### 修复前（PE DLL .text 段加载流程）

```
map_view → 匿名页 (no PROT_EXEC)
  → map_pe_header → mmap(fd, PROT_READ|PROT_WRITE) → 成功，文件支持页
  → map_file_into_view → mmap(fd, PROT_READ|PROT_WRITE) → 成功，文件支持页
  → set_vprot(VPROT_EXEC)
    → mprotect_range
      → mprotect_exec → prctl + mprotect(PROT_EXEC) → ❌ 内核拒绝
```

### 修复后

```
map_view → 匿名页 (no PROT_EXEC)
  → map_pe_header → mmap(fd, PROT_READ|PROT_WRITE) → 成功，文件支持页（仅 header）
  → [可执行段] 匿名 mmap + pread → 匿名页，内容已填充
  → [非可执行段] map_file_into_view → mmap(fd) → 文件支持页（不需要 PROT_EXEC）
  → set_vprot(VPROT_EXEC)
    → mprotect_range
      → mprotect_exec → prctl + mprotect(PROT_EXEC) → ✅ 匿名页成功
```

---

## 七、架构决策记录

### 为什么用匿名 mmap + pread 而不是其他方案？

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **匿名 mmap + pread** | 不依赖文件系统 exec 支持 | 代码改动 | ✅ 当前方案 |
| mprotect_exec prctl 绕过 | 最小改动 | 对文件支持页无效 | ❌ 不足（已验证） |
| memfd_create | 内核支持 | Box64 模拟环境可能不支持 | 🔄 备选 |
| HNP 安装到无 noexec 目录 | 零代码改动 | 需要系统级修改 | ❌ 不可行 |
| 强制 removable=TRUE | 利用现有 read 回退 | 可能影响其他逻辑 | 🔄 备选 |

### 为什么 prctl 在 mprotect_exec 中不够？

prctl(0x6a6974) 允许当前进程暂时突破 noexec 限制，但：
- 对**文件支持**页面（有 backing store），内核仍然拒绝 PROT_EXEC
- 对**匿名**页面有效 ✅
- 所以必须先让页面匿名化，再 prctl

---

## 八、相关源码位置索引

| 文件 | 行号 | 功能 |
|------|------|------|
| `dlls/ntdll/unix/virtual.c` | 134-143 | VPROT_* 定义 |
| `dlls/ntdll/unix/virtual.c` | 242 | force_exec_prot 声明 |
| `dlls/ntdll/unix/virtual.c` | 265-282 | anon_mmap_fixed / anon_mmap_alloc |
| `dlls/ntdll/unix/virtual.c` | 1360-1374 | get_unix_prot (VPROT_EXEC → PROT_EXEC) |
| `dlls/ntdll/unix/virtual.c` | 1938-1963 | mprotect_exec (OHOS fix) |
| `dlls/ntdll/unix/virtual.c` | 2001-2015 | set_vprot |
| `dlls/ntdll/unix/virtual.c` | 1971-1992 | mprotect_range |
| `dlls/ntdll/unix/virtual.c` | 2260-2355 | map_view |
| `dlls/ntdll/unix/virtual.c` | 2364-2435 | map_file_into_view |
| `dlls/ntdll/unix/virtual.c` | 2745-2776 | map_pe_header |
| `dlls/ntdll/unix/virtual.c` | 3045-3313 | map_image_into_view (主要修复) |
| `dlls/ntdll/unix/virtual.c` | 3196-3217 | OHOS 匿名 mmap fix |
| `dlls/ntdll/unix/virtual.c` | 3381-3433 | map_image_view |
| `dlls/ntdll/unix/virtual.c` | 3441-3515 | virtual_map_image |
| `dlls/ntdll/unix/virtual.c` | 3918-3971 | virtual_create_builtin_view |
| `dlls/ntdll/unix/virtual.c` | 5184-5303 | allocate_virtual_memory |
| `dlls/ntdll/unix/virtual.c` | 5064-5083 | virtual_set_force_exec |
| `dlls/ntdll/unix/virtual.c` | 4671-4728 | virtual_handle_fault (SIGSEGV handler) |
| `dlls/ntdll/unix/virtual.c` | 4534-4546 | user_shared_data file-backed mmap |
| `server/mapping.c` | 347-363 | check_current_dir_for_exec |
| `server/mapping.c` | 366-408 | create_temp_file |
| `server/mapping.c` | 631-657 | build_shared_mapping (共享 PE 段) |

---

## 九、替代方案

### 方案清单

| # | 方案 | 改动量 | 优雅度 | 性能 | 鲁棒性 | 推荐 |
|---|------|--------|--------|------|--------|------|
| 1 | 当前: 匿名 mmap+pread (可执行段) | 中 | ⭐⭐⭐ | 中 | ⭐⭐⭐ | 已实施 |
| 2 | fstatfs 检测 + 强制 removable | **小** | ⭐⭐⭐⭐ | 中 | ⭐⭐⭐⭐ | **首选** |
| 3 | virtual_map_image 层 memfd 替换 | 中 | ⭐⭐⭐⭐⭐ | 好 | ⭐⭐⭐⭐⭐ | 中期 |
| 4 | 复制 DLL 到 /data/local/tmp | 小 | ⭐⭐ | 差 | ⭐⭐ | 不推荐 |
| 5 | SIGSEGV handler 懒修复 | **大** | ⭐ | 好 | ⭐ | 不推荐 |
| 6 | map_pe_header 改用匿名 mmap | 小 | ⭐⭐⭐ | 好 | ⭐⭐⭐ | 备选 |

### HarmonyOS SDK API 可用性检查

> 基于 `/apps/harmony/sdk/default/openharmony/native/sysroot/` (OHOS SDK 15.0.4)
> 目标架构: `x86_64-linux-ohos`

| API | 可用? | 头文件 | 备注 |
|-----|-------|--------|------|
| `fstatfs` | ✅ | `<sys/statfs.h>` | `struct statfs` 有 `f_flags` 字段 |
| `fstatvfs` | ✅ | `<sys/statvfs.h>` | 备选，用 `f_flag` + `ST_NOEXEC=8` |
| `ST_NOEXEC` / `MS_NOEXEC` | ✅ | `<sys/statvfs.h>` / `<sys/mount.h>` | 两者值都是 8。`statfs.h` 内部已 include `<sys/statvfs.h>` |
| `memfd_create` | ✅ | `<sys/mman.h>` | 函数声明存在，`__NR_memfd_create=279` |
| `MFD_CLOEXEC` | ✅ | `<sys/mman.h>` | 值 `0x0001U` |
| `MFD_ALLOW_SEALING` | ✅ | `<sys/mman.h>` | 值 `0x0002U` |
| `MFD_EXEC` | ⚠️ | `<linux/memfd.h>` | **内核 6.6 有，5.10 无**。SDK 头文件缺失。见下方内核版本分析 |
| `MFD_NOEXEC_SEAL` | ⚠️ | `<linux/memfd.h>` | 同 MFD_EXEC，6.6 有，5.10 无 |
| `shm_open` / `shm_unlink` | ✅ | `<sys/mman.h>` | POSIX，方案 3 的 memfd fallback |
| `copy_file_range` | ✅ | `<unistd.h>` | syscall 285 |
| `prctl` | ✅ | `<sys/prctl.h>` | 已验证可用 |

### `MFD_EXEC` 内核版本分析

> 源码: `/src/ohos/kernel/linux/linux-5.10` 和 `/src/ohos/kernel/linux/linux-6.6`

| | Linux 5.10 | Linux 6.6 |
|---|---|---|
| `MFD_EXEC` 宏 | ❌ 不存在 | ✅ `0x0010U` |
| `MFD_NOEXEC_SEAL` | ❌ 不存在 | ✅ `0x0008U` |
| `MFD_ALL_FLAGS` | `CLOEXEC \| ALLOW_SEALING \| HUGETLB` | `CLOEXEC \| ALLOW_SEALING \| HUGETLB \| NOEXEC_SEAL \| EXEC` |
| memfd 默认 exec | **默认可执行** | 6.3+ 默认不可执行，需 `MFD_EXEC` |
| 传 `0x0010` 行为 | ❌ **EINVAL** (不在 MFD_ALL_FLAGS 中) | ✅ 正常 |
| 不传任何 exec flag | ✅ 可执行 | ⚠️ kernel warning，回退到 MFD_EXEC |

**关键**: 5.10 内核中 `memfd_create("x", MFD_CLOEXEC)` 创建的 fd **天然可执行**，不需要也不接受 `MFD_EXEC`。6.6 内核中需要显式传 `MFD_EXEC` 才是最佳实践。

**运行时兼容方案**: 先尝试带 `MFD_EXEC`，若 `errno == EINVAL` 则回退到不带：

```c
// 兼容 5.10 和 6.6 内核的 memfd_create
// 6.6 优先使用 MFD_EXEC，5.10 回退到无 MFD_EXEC (默认即 exec)
#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif

static int create_exec_memfd(const char *name)
{
    int fd;

    /* 6.6+: 显式请求 MFD_EXEC */
    fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_EXEC);
    if (fd >= 0) return fd;

    /* 5.10: MFD_EXEC 会返回 EINVAL，回退到不传 */
    if (errno == EINVAL)
    {
        fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
        if (fd >= 0) return fd;
    }

    /* memfd 不可用，fallback 到 shm_open */
    return -1;
}
```

---

### 方案 2: `fstatfs` 检测 noexec + 强制 `removable=TRUE` ⭐推荐

**核心思路**: 在 `map_pe_header()` 中用 `fstatfs(fd)` 检测文件系统是否挂载为 noexec。若是，设置 `*removable = TRUE`，后续所有 `map_file_into_view()` 调用自动跳过 mmap(fd)，走 pread 回退路径。

**为什么有效**: `removable=TRUE` → `map_file_into_view` line 2398 条件 `!removable` 为 false → 跳过 mmap(fd) → 执行 line 2432-2433 的 pread 分支 → 页面保持匿名 → 后续 `mprotect_exec` + prctl 成功加 PROT_EXEC。

**改动点**: `map_pe_header()` line 2751，在 mmap 尝试前添加：

```c
// 文件: dlls/ntdll/unix/virtual.c
// 函数: map_pe_header() line 2745
// 位置: line 2751 "if (!*removable && map_size)" 之前

#include <sys/vfs.h>  // statfs

if (!*removable)
{
    struct statfs sfs;
    if (fstatfs(fd, &sfs) == 0 && (sfs.f_flags & ST_NOEXEC))
    {
        WARN("noexec filesystem detected, using read fallback\n");
        *removable = TRUE;
    }
}
```

**覆盖范围**:

| 场景 | 原路径 | 方案 2 后 | 效果 |
|------|--------|-----------|------|
| `map_pe_header` | mmap(fd) | pread | header 匿名页 |
| `map_file_into_view` 所有段 | mmap(fd) | pread | 全部匿名页 |
| `set_vprot(VPROT_EXEC)` | mprotect_exec | mprotect_exec+prctl | ✅ 成功 |
| `IMAGE_FLAGS_ImageMappedFlat` 路径 | mmap(fd) 全文件 | pread 全文件 | ✅ 自动覆盖 |

**优点**:
- 改动约 10 行，利用 Wine 已有的 pread 回退路径
- 自动覆盖所有 PE 段和特殊路径
- 可替代当前方案 1（删除 `map_image_into_view` 中的匿名 mmap 特殊处理，代码更干净）

**缺点**:
- 所有文件 I/O 走 pread（非 mmap），大文件加载稍慢
- `fstatfs` + `ST_NOEXEC` 是 Linux 特有，需要 `#ifdef __linux__`

---

### 方案 3: `virtual_map_image` 层 memfd 替换

**核心思路**: 在 `virtual_map_image()` 中 `server_get_unix_fd()` 之后、`map_image_into_view()` 之前，检测文件系统 noexec，若是则把 PE 内容拷贝到 memfd（或 shm），后续所有 mmap 操作都用匿名 fd —— Wine 原有的 mmap(fd) 路径完全不用改。

**为什么有效**: memfd 是匿名 fd，内核允许 PROT_EXEC。与方案 2 不同，方案 3 **保留 mmap(fd) 路径**（零磁盘 I/O），只是把 fd 从磁盘文件替换为匿名内存。

**改动点**: `virtual_map_image()` line 3456-3484，在 fd 获取后：

```c
// 文件: dlls/ntdll/unix/virtual.c
// 函数: virtual_map_image() line 3441

if ((status = server_get_unix_fd(mapping, 0, &unix_fd, &needs_close, NULL, NULL)))
    return status;

// OHOS: 检测 noexec，用 memfd 替代磁盘 fd
{
    struct statfs sfs;
    if (fstatfs(unix_fd, &sfs) == 0 && (sfs.f_flags & MS_NOEXEC))
    {
        int exec_fd = create_exec_memfd("wine-pe");
        if (exec_fd == -1)
            exec_fd = create_exec_shm("wine-pe", pe_size);

        if (exec_fd != -1)
        {
            // 拷贝 PE 内容到匿名 fd
            off_t size = lseek(unix_fd, 0, SEEK_END);
            lseek(unix_fd, 0, SEEK_SET);
            if (copy_file_range_all(exec_fd, unix_fd, size))
            {
                if (needs_close) close(unix_fd);
                unix_fd = exec_fd;
                needs_close = TRUE;
            }
            else close(exec_fd);
        }
        // 如果 memfd/shm 都失败 → 继续用原始 fd，依赖 mprotect_exec+prctl
    }
}
```

**`create_exec_memfd` — 兼容 5.10 和 6.6 内核**:

```c
// OHOS: 创建可用于 PROT_EXEC mmap 的 memfd
// 6.6 内核: 需要 MFD_EXEC；5.10 内核: MFD_EXEC 会导致 EINVAL
#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif

static int create_exec_memfd(const char *name)
{
    int fd;

    /* 6.6+ 内核：显式请求 MFD_EXEC */
    fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_EXEC);
    if (fd >= 0) return fd;

    /* 5.10 内核：MFD_EXEC 返回 EINVAL，回退。默认即 exec */
    if (errno == EINVAL)
        return memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);

    return -1;
}

/* shm_open fallback — memfd 不可用时 (POSIX，SDK 完全支持) */
static int create_exec_shm(const char *name, off_t size)
{
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd == -1) return -1;
    shm_unlink(name);  // 立即删除，fd 仍可用
    if (ftruncate(fd, size) == 0) return fd;
    close(fd);
    return -1;
}

/* 跨文件系统安全的 copy_file_range 封装 */
static BOOL copy_file_range_all(int dst_fd, int src_fd, off_t size)
{
    off_t remaining = size;
    while (remaining > 0)
    {
        off_t n = copy_file_range(src_fd, NULL, dst_fd, NULL, remaining, 0);
        if (n <= 0) return FALSE;
        remaining -= n;
    }
    return TRUE;
}
```

**优点**:
- 最优雅的解法：根因消除，mmap(fd) 路径不变
- memfd 在内存中，mmap 零磁盘 I/O，性能最好
- 兼容 5.10 和 6.6 内核，自动探测 MFD_EXEC 支持
- shm_open fallback 确保 POSIX 兼容性

**缺点**:
- 改动约 60 行（含 helper 函数）
- `copy_file_range` 在内核 5.3+ 才支持跨文件系统
- 设备必须有可用的 memfd 或 shm

---

### 方案 4: 复制 PE DLL 到非 noexec 目录

**核心思路**: 安装/启动时把 PE DLL 从 noexec 的 HNP 目录复制到非 noexec 的可写目录。

**改动点**: 部署脚本，非源码。

**缺点**:
- 每次启动需要复制 615 个 DLL（~200MB），启动慢
- 需要管理两份文件，占用双倍空间
- /data/local/tmp 可能被系统清理
- 不符合 HNP 的沙箱设计原则

---

### 方案 5: SIGSEGV handler 懒修复（on-demand）

**核心思路**: 在 `virtual_handle_fault()` 中处理 `EXCEPTION_EXECUTE_FAULT`。当执行到文件支持页触发 SIGSEGV 时，在信号处理器中把该页替换为匿名内存。

**改动点**: `virtual_handle_fault()` line 4671。

```c
// 新增: 处理执行错误
if (err == EXCEPTION_EXECUTE_FAULT)  // 值 = 8, 当前未处理
{
    // 1. 检查该页是否是文件支持的
    // 2. 分配匿名页，pread 文件内容
    // 3. mprotect_exec 加 PROT_EXEC
    // 4. 返回 STATUS_SUCCESS 让 CPU 重新执行
}
```

**缺点**:
- 信号处理器中能安全调用的函数非常有限（async-signal-safe）
- `mmap`、`pread`、`mprotect` 在信号处理器中**不是安全的**
- 每次首次执行新页都触发 SIGSEGV → 性能抖动
- 复杂度高，容易产生难以调试的竞态条件
- Wine upstream 也不会接受这种写法

---

### 方案 6: `map_pe_header` 直接用匿名 mmap + pread

**核心思路**: 与方案 1 类似，把 `map_pe_header()` line 2753 的 mmap(fd) 改成匿名 mmap + pread。

**改动点**: `map_pe_header()` line 2751-2757。

```c
// 替换:
if (!*removable && map_size)
{
    // 不再: mmap(ptr, map_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE, fd, 0)
    // 改为:
    if (mmap(ptr, map_size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) != MAP_FAILED)
    {
        if (size > map_size) pread(fd, (char *)ptr + map_size, size - map_size, map_size);
        return STATUS_SUCCESS;
    }
    // ... EPERM/EACCES 处理保持不变
}
```

**与方案 2 对比**: 方案 2 更简单且覆盖更广。方案 6 可以视为方案 2 的手动版本。

---

## 十、推荐实施路径

```
阶段 1 (立即可做): 方案 2 — fstatfs + MS_NOEXEC 检测 + 强制 removable
  ├─ 改动: ~10 行，map_pe_header() 中加 fstatfs 检测
  ├─ 原理: 利用 Wine 已有 pread 回退路径
  ├─ 内核兼容: 无版本依赖（fstatfs 在任何内核都可用）
  └─ 成功后 → 可删除方案 1 的逐段匿名 mmap 代码

阶段 2 (中期): 方案 3 — memfd/shm 替换 fd，保留 mmap(fd) 路径
  ├─ 改动: ~60 行，virtual_map_image() 中替换 fd
  ├─ 内核兼容: 自动探测 MFD_EXEC (6.6) / fallback (5.10) / shm_open
  ├─ 优势: mmap 零磁盘 I/O，性能最优
  └─ 注意: 需要 copy_file_range 跨文件系统支持 (5.3+)

阶段 3 (远期): 跟踪 OpenHarmony 内核升级
  ├─ 当 5.10 不再支持时，移除 memfd MFD_EXEC 回退逻辑
  └─ 统一使用 MFD_EXEC 显式声明（向后兼容警告无人理睬的 6.6 行为）
```

**当前推荐**: 先实施方案 2，改动最小、最安全、无内核兼容问题。验证功能正确后，再根据性能需求决定是否升级到方案 3。
```

**方案 2 是最佳下一步**: 改动最小，利用 Wine 现有 pread 回退机制，自动覆盖所有受影响的路径（包括方案 1 未覆盖的 `IMAGE_FLAGS_ImageMappedFlat` 和 header 页）。验证后可以删除方案 1 的逐段匿名 mmap 代码，代码更整洁。
