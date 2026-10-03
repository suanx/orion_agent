# vendor/proot —— 预编译 proot 全套（arm64-v8a）

来源：https://github.com/jieapi/aicode（`app/src/_armJniLibs/arm64-v8a/`，GPL-3.0），
其上游为 https://github.com/termux/proot（GPL-2.0+）。

## 为什么用它而不用 Termux 官方 deb 的二进制

Termux 官方 proot 的 DT_NEEDED 是 `libtalloc.so.2`（带版本后缀），
而打包时极易把库改名为 `libtalloc.so` 造成链接失败（我们踩过）。
aicode 的构建把 DT_NEEDED 定为 `libtalloc.so`，与文件名一一对应，
且这是在真实 Android 设备（含国产 ROM）上跑通的产品级组合。

| 文件 | 用途 |
|---|---|
| libproot.so | proot 主程序（动态链接 libtalloc.so / libandroid-shmem.so） |
| libproot-loader.so | ptrace 辅助二进制（PROOT_LOADER 指向它） |
| libproot-loader32.so | 32 位客户程序的辅助 loader（PROOT_LOADER_32） |
| libtalloc.so | talloc 库 |
| libandroid-shmem.so | Android shm 封装 |

## 部署方式（关键，踩过两次坑）

以 `lib*.so` 命名放进 **jniLibs/arm64-v8a**，并在 gradle 设
`packaging.jniLibs.useLegacyPackaging = true`，安装后由系统解压到
`applicationInfo.nativeLibraryDir`——该目录由系统管理，W^X 限制不拦 exec，
也无需 chmod。运行时通过 MethodChannel `orion_agent/system`/`nativeLibDir`
取路径。**不要**放 assets 手工复制（需 chmod 且受 exec 限制），
也**不要**改回「不落盘」的默认打包（nativeLibraryDir 会是空目录）。
