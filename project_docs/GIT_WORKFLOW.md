# Git 工作流

先练熟一条简单流程：**开分支 → 本地提交 → 提 PR → 自己审查 → 合并同步**。
`master` 保存合并后的版本，每次独立改动使用一个工作分支。

## 1. 开始改动

以下以 `docs/update-guide` 为例，实际操作时换成描述本次改动的分支名。
尚未连接 GitHub 时，跳过 `pull`、`push` 和网页操作，先练习本地提交。

```bash
git switch master
git pull --ff-only origin master
git switch -c docs/update-guide
```

## 2. 平时在本地提交

完成一小项改动后，检查并提交；同一个工作分支可以多次提交。

```bash
git status --short
git diff
git add 文件路径
git diff --cached
git commit -m "docs: 简化工作流说明"
```

将 `文件路径` 换成要提交的文件，可填写多个。提交说明写清做了什么，
先记住三个前缀即可：`feat:` 新功能、`fix:` 修复、`docs:` 文档。

## 3. 上传并自己审查

```bash
git push -u origin docs/update-guide
```

在 GitHub 创建 PR，目标分支选 `master`，写明：**改了什么、为什么改、怎么验证**。
然后自己扮演 reviewer，打开文件差异逐项检查：

- 有没有无关改动、密码或其他不该提交的文件？
- 改动是否达到目的，有没有明显问题？
- 是否做过相应验证，未验证的地方有没有说明？

发现问题就留下评论，回到同一分支修改、提交，再运行 `git push`，原 PR 会更新。
自己可以评论和合并，但不能批准自己的 PR；目前不设置必须由另一人批准的要求。

## 4. 合并后同步

检查完成后，在 GitHub 合并 PR，再回到本地：

```bash
git switch master
git pull --ff-only origin master
```

下一次改动重新开分支，重复这个流程即可。
