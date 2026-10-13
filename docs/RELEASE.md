# 构建与发布

开发包：`bash Scripts/build-app.sh`，随后 `bash Scripts/make-dmg.sh`。产物位于 dist，采用 ad-hoc 签名，未公证。必须使用 development 文件名和 prerelease 标记，不能称作已完成 Gatekeeper 验收的正式发行。

正式发行需要 Developer ID Application 证书，以及完整 Xcode 提供的 notarytool / stapler。凭据只存入本机钥匙串或受保护 CI secrets，不提交仓库。

```sh
export SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='mihomo-notary'
bash Scripts/notarize.sh
```

该脚本从内核到 Helper 到 App 依次签名，启用 hardened runtime、时间戳；提交 App 公证、装订、检查签名和 Gatekeeper；生成 DMG，再签名、公证与装订 DMG。任一步失败会终止。

正式发布前必须按 ACCEPTANCE.md 完成干净 macOS 26 ARM64 机器上的 Helper 授权、全部网络模式、代理快照恢复、强制退出和更新失败注入。当前未签名环境不具备此验收条件。

发行时提供 DMG、SHA-256、安装说明、GPL 许可证和对应 Mihomo 版本源码访问。下载内核需遵循官方仓库版本来源，更新只保存在应用数据目录，不改写已签名 App。
