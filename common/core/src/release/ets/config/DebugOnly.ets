// Release（core 模块 default target）：环境切换实现与调试能力判断不编译进来，只留一个 false 标记。
// Debug / Staging 的同名文件在 src/staging/ets/config/DebugOnly.ets。

export const ENVIRONMENT_SWITCH_COMPILED: boolean = false;
