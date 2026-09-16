# Git 工作流

本项目采用 `master` 主分支 + 短期工作分支 + Pull Request（PR）的流程。
这是适合个人练习的团队协作约定；规则是否强制执行取决于后续 GitHub 配置。
初次导入在 `master` 上建立基线；后续改动从工作分支提交。

## 日常操作

以下命令以已配置 GitHub 远端 `origin` 为前提；尚未同步时跳过 pull/push。

```bash
git switch master
git pull --ff-only origin master
git switch -c feat/course-filter

# 完成一个有明确目的的改动，执行适用验证后检查差异。
git status --short
git diff
git add <本次改动的文件>
git diff --cached
git commit -m "feat: add course filtering"
git push -u origin feat/course-filter
```

然后在 GitHub 创建 PR，目标分支为 `master`，填写目的、改动、验证和风险。
审查后处理问题，完成检查，再使用 Squash and merge 合并，保持主分支历史清晰。
合并后切回 `master` 并执行 `git pull --ff-only origin master`。
确认改动已经进入主分支后再清理工作分支；Squash 合并可能使 `git branch -d`
提示分支尚未合并，遇到此提示应先核对 PR 和差异，避免盲目强制删除。

分支示例：`feat/course-filter`、`fix/login-timeout`、`refactor/service-layer`、
`docs/setup-guide`、`chore/dependencies`。提交信息采用 `类型: 简要说明`，
类型可用 `feat`、`fix`、`refactor`、`docs`、`test`、`chore`。
一个提交聚焦一个逻辑改动，避免将重构、功能和格式调整混在一起。

## Review 与合并

个人开发时也应在 PR 中完整自查 diff，记录验证结果，并可请同伴或 AI 协助审查。
最终由仓库维护者判断是否合并。GitHub 不允许 PR 作者批准自己的 PR；
自查或使用自己账号提交的 AI 审查意见不能充当另一位 reviewer 的批准。
如果只有一位维护者，不要启用必须由另一人批准的门槛，除非已经有可参与的协作者。
团队协作时，再按实际人员和权限设置独立 reviewer 与必需批准数。

后续在 GitHub 按账号套餐和仓库支持情况设置主分支规则：通过 PR 合并、
要求实际存在且可靠的 CI 检查通过、处理审查讨论、禁止强推和删除主分支。
当前只完成本地初始化，尚未配置远端规则、CI 或 Git hooks。
参考：[GitHub PR 审查说明](https://docs.github.com/en/pull-requests/reference/pull-request-reviews)。

## 当前基线与验证

初始提交保存当前源码、项目文档和可共享配置；忽略虚拟环境、打包产物、缓存、
本地备份及常见凭证文件。被忽略的文件仍保留在本机。
`.gitignore` 不会自动发现源码中的密钥，提交前仍需检查 diff。

初始化时，README 引用的 `test_rollcall_service.py` 和根目录的
`rollcall_capturer.py` 实际不存在。README 中的 unittest 命令目前不能作为
通过的验证记录；后续应通过单独 PR 修正文档并按需补齐测试。
语法检查只能发现语法错误，不能替代业务测试或真实登录验证。

## 回退

已共享或已合并的提交优先使用 `git revert <提交号>`，通过新的 PR 回退，
保留审计记录。不要在共享的 `master` 上使用 `reset --hard` 或强制推送改写历史。
