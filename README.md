# Mihomo Swift

极简中文原生 macOS Mihomo 客户端。SwiftUI 主窗口与菜单栏，macOS 26+，仅 Apple Silicon。

**当前为 0.1.0 开发版**：可运行 App / DMG，内置 Mihomo v1.19.32。无 Developer ID 证书，未公证；TUN 与系统代理的 Helper 源码已实现，特权入口在开发包中关闭，等待签名后的真实系统验收。

## 已实现

- 本地 YAML 和订阅导入、多 Profile、手动订阅更新与重新加载。
- 原文独立保存，白名单合成，串行事务，Controller 热重载与失败补偿。
- Rule / Global / Direct 回读确认；Off 保留内核用于控制与测速。
- 按 Profile 隔离节点选择，单个 / 批量延迟测试，稳定延迟排序。
- 启动恢复、窗口关闭继续运行、菜单栏退出清理、无特权内核崩溃看护。
- 登录自启注册、手动官方内核更新、SHA-256 与 ARM64 验证、失败回滚。
- 特权 Helper 的认证 XPC、受控内核存储、系统代理快照和条件恢复实现。

## 构建与验证

需要 Swift 6+ 和 macOS 26+ SDK（Xcode 或 Command Line Tools）。

```sh
python3 Scripts/fetch-kernel.py
swift build
swift run --skip-build MihomoChecks --real --updates
python3 Tests/Integration/core_smoke.py
bash Scripts/build-app.sh
bash Scripts/make-dmg.sh
open dist/Mihomo.app
```

下载固定官方版本并核对预先固定的资产摘要。第三方二进制不提交 Git；App 打包时内置内核与许可证。

GitHub Actions 在 macOS 26 ARM64 上构建、运行事务及真实内核测试并生成开发 DMG。正式签名与公证流程见 [发布说明](docs/RELEASE.md)。

- [安装说明](docs/INSTALL.md)
- [配置白名单与事务设计](docs/ARCHITECTURE.md)
- [TV 技术结论与待验证边界](docs/TECHNICAL-VALIDATION.md)
- [AC 验收记录](docs/ACCEPTANCE.md)
- [产品需求文档](docs/PRD.md)

## 许可证

本项目使用 GPL-3.0，详见 LICENSE。Mihomo 为 GPL-3.0，Yams 为 MIT；许可证随 App 分发。固定内核的对应源码见 [MetaCubeX/mihomo v1.19.32](https://github.com/MetaCubeX/mihomo/tree/v1.19.32)，依赖和构建信息以该版本的 go.mod / Makefile 为准。
