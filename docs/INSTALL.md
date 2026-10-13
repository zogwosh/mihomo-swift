# 安装与使用（0.1.0 开发版）

适用 macOS 26+、Apple Silicon ARM64。DMG 内置 Mihomo v1.19.32，无需首次下载。

1. 打开 DMG，将 Mihomo.app 拖入 Applications。
2. 打开 Mihomo。开发版使用临时签名，未公证；若系统阻止，可在“系统设置 → 隐私与安全性”中对该应用选择“仍要打开”。
3. 导入本地 YAML 或订阅 URL。导入不会自动激活；选中 Profile 后点击“激活”。
4. 开发版使用 Off：内核运行，系统网络不被接管，可选节点、测速、切换 Rule / Global / Direct；其他应用可按 Profile 的本地监听端口手动连接。
5. 关闭窗口后继续运行，菜单栏可重新打开窗口。使用菜单栏“退出 Mihomo”停止受管理内核。

TUN 和系统代理需要 Developer ID 签名的 Helper 和 macOS 系统批准。当前无证书开发包明确禁用这两项特权操作，源码和正式签名脚本已经包含相应实现，但尚未完成真实特权验收。不要把开发版视为完成 PRD 全部验收的正式发行。

本地 YAML 导入后保存副本。“重新加载”读取应用数据目录中的副本；外部文件修改不会自动生效。本地文件型 provider 会一并复制配置目录内的相对路径资源。订阅引用本地文件、绝对路径、越界路径、独立 TUN listener 会被拒绝。DNS、规则、节点认证等不会写回原 YAML。

所有配置、订阅地址和节点选择保存在 `~/Library/Application Support/MihomoSwift`，文件限制为当前用户访问。无遥测、无自动订阅或内核更新。延迟测试 URL 为 `https://www.gstatic.com/generate_204`，超时 5 秒，最多并发 4 项。
