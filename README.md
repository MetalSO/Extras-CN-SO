# MetalSO 的个人 Scoop Bucket

个人维护的 [Scoop](https://github.com/ScoopInstaller/Scoop) bucket，**只存放我自己测试与日常使用的软件清单**，不追求与任何上游仓库同步。

> 这是个人自用的 bucket。清单按需增删，不保证长期兼容。

## 使用

```powershell
scoop bucket add extras-cn-so https://github.com/MetalSO/Extras-CN-SO
scoop install artex
```

（bucket 的本地名字可以随意取，上面的 `extras-cn-so` 只是示例。）

## 当前收录

| 清单 | 说明 |
| --- | --- |
| `AF-Media-Bar` | Windows 10/11 任务栏媒体控制与轻度美化工具 |
| `artex` | AI 自主渗透测试系统 |

## 自动更新

仓库使用 GitHub Actions 的 **Excavator**（[`.github/workflows/schedule.yml`](.github/workflows/schedule.yml)）每 12 小时检查一次上游新版本，发现更新后自动改写清单并提交。也可在 Actions 页手动触发。

工作流显式声明了 `permissions: contents: write`，以便自动提交能推送到本仓库。

## 安装 Scoop

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex
```

## 许可

本仓库基于 **BSD-2-Clause** 许可发布，详见 [LICENSE](LICENSE)。
