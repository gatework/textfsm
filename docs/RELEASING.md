# 可信发布

RubyGems Trusted Publisher 配置为 GitHub owner `gatework`、本仓库名称、workflow `release.yml`、environment `release`。
不配置长期 RubyGems API key。发布任务仅在完整 CI 通过后获得 OIDC 临时凭据。

1. 更新版本常量和 CHANGELOG；完成仓库规定的本地测试、lint 与包验证。
2. 提交并推送，确认同一提交的远端 CI 通过。
3. 推送与版本一致的 `vX.Y.Z` 标签。`release.yml` 重跑完整矩阵，并下载该次 CI 的 gem。
4. 发布脚本核对包身份、元数据、文件列表与源文件内容，验证该包后上传到 RubyGems。
5. RubyGems 下载、GitHub Release gem 和 `SHA256SUMS` 必须匹配同一产物。

恢复失败时先核实注册表版本和校验和；同版本不同包禁止覆盖。手动重跑使用对应标签 ref。
