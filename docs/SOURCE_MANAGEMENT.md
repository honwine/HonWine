# Wine 源码管理

> 更新: 2026-06-12

## 策略

Wine 源码 (`thirdparty/wine`) 通过 submodule 跟踪上游 `wine-mirror/wine.git`，当前基线为 master 分支。

我们的修改以 **git patch 文件** 形式维护在 `patches/` 目录。构建时用 `git am` 应用，不需要维护 fork 或长期分支。Wine 上游更新时只需重新 apply，有冲突就手动解决后重新生成 patch。

## Patch 列表

| Patch | 行数 | 文件 | 内容 |
|-------|------|------|------|
| `0001-ohos-Box64-compatibility-noexec-filesystem-support.patch` | 235 | 3 | virtual.c, musl_compat.c, .gitignore |

## 日常操作

### 构建前：应用补丁

```bash
cd thirdparty/wine
git am ../../patches/*.patch
git log --oneline -3          # 确认 ohos 提交在顶部
```

### 新增修改后：更新 patch

```bash
cd thirdparty/wine

# (1) 确保当前在 ohos 提交之上
git log --oneline -3

# (2) 修改源码，提交
git add <modified-files>
git commit -m "ohos: <description>"

# (3) 重新生成 patch
# 单 patch（推荐：改动少时一个文件够了）
git format-patch <first-ohos-commit>~1 --stdout > ../../patches/ohos.patch

# 多 patch（改动多时便于管理独立变更）
git format-patch <first-ohos-commit>~1 -o ../../patches/ --force
```

### 更新 Wine 上游

```bash
cd thirdparty/wine

# 回到上游
git reset --hard HEAD~N       # N = ohos 提交数量
git checkout master
git pull origin master

# 重新应用补丁
git am ../../patches/*.patch

# 如有冲突:
#   手动解决 → git add <file> → git am --continue
#   全部解决后 → 重新生成 patch
```

### 临时切换干净上游

```bash
cd thirdparty/wine
git checkout master            # 回到上游，丢弃 ohos 提交
# 需要 patch 时: git am ../../patches/*.patch
```

### 恢复之前应用的补丁

```bash
cd thirdparty/wine
git am --abort                 # 中止未完成的 am
git checkout master            # 回到干净状态
```
