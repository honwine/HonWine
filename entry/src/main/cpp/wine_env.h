#ifndef WINE_ENV_H
#define WINE_ENV_H
/**
 * wine_env.h — 共享 Wine/Box64 环境变量设置
 *
 * napi_init.cpp (PC fork/exec) 和 wine_child.cpp (Pad NCP)
 * 都需要设置这些变量。集中定义避免重复。
 */
#include <cstdlib>

// Box64 性能调优参数 (对标 Winlator Performance 预设)
// x86_64 下 Box64 为 passthrough 脚本, 这些参数无实际作用, 但设置无害
static inline void SetBox64PerfEnv() {
    setenv("BOX64_LOG", "0", 1);
    setenv("BOX64_NOBANNER", "1", 1);
    setenv("BOX64_SHOWSEGV", "1", 1);
    setenv("BOX64_DYNAREC_SAFEFLAGS", "0", 1);
    setenv("BOX64_DYNAREC_BIGBLOCK", "3", 1);
    setenv("BOX64_DYNAREC_CALLRET", "2", 1);
    setenv("BOX64_DYNAREC_FORWARD", "1024", 1);
    setenv("BOX64_DYNAREC_WEAKBARRIER", "2", 1);
    setenv("BOX64_AVX", "0", 1);
}

// 返回 Box64 性能参数的 "KEY=VALUE" 字符串列表
// 用于 napi_init.cpp 构建 fork/exec 的 envp
inline void AppendBox64PerfStrings(std::vector<std::string>& env) {
    env.push_back("BOX64_LOG=0");
    env.push_back("BOX64_NOBANNER=1");
    env.push_back("BOX64_SHOWSEGV=1");
    env.push_back("BOX64_DYNAREC_SAFEFLAGS=0");
    env.push_back("BOX64_DYNAREC_BIGBLOCK=3");
    env.push_back("BOX64_DYNAREC_CALLRET=2");
    env.push_back("BOX64_DYNAREC_FORWARD=1024");
    env.push_back("BOX64_DYNAREC_WEAKBARRIER=2");
    env.push_back("BOX64_AVX=0");
}

#endif // WINE_ENV_H
