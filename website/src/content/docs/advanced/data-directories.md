---
title: 数据目录
description: Mirage 的壁纸来源、创意工坊下载、缓存和设置存放位置。
---

## 壁纸来源

| 来源 | 默认位置 |
| --- | --- |
| Mirage 创意工坊下载 | `~/Library/Application Support/Mirage/Workshop/content/431960/` |
| Mirage 本地导入 | `~/Library/Application Support/Mirage/Wallpapers/` |
| 系统 Steam 创意工坊 | `~/Library/Application Support/Steam/steamapps/workshop/content/431960/` |

在通用设置中可以为系统 Steam 创意工坊目录和导入目录选择自定义位置。Mirage 自己的创意工坊下载目录由应用管理。

## 下载暂存

进行中的作品位于：

```text
~/Library/Application Support/Mirage/Workshop/content/431960/.staging/<作品 ID>/
```

校验完成并确认存在 `project.json` 后，暂存目录会原子移动为同级的 `<作品 ID>/`。失败或取消的暂存内容不会出现在壁纸库中，并可在重试时复用。

## 凭据与设置

- Steam 刷新令牌和 GuardData 存放在 macOS 钥匙串。
- Steam 账号名、全局设置、网页壁纸信任记录和单壁纸运行参数存放在 `UserDefaults`。
- 密码和 Steam Guard 验证码不持久化。

## 缓存与屏保

| 数据 | 默认位置 |
| --- | --- |
| 创意工坊预览缓存 | `~/Library/Caches/Mirage/WorkshopCache/` |
| 动态屏保组件 | `~/Library/Screen Savers/MirageScreenSaver.saver` |
| 动态屏保配置 | `~/Library/Application Support/Mirage/screensaver.json` |

:::caution[谨慎清理]
删除作品目录会移除对应壁纸。删除 `.staging` 会放弃可复用的未完成分块，但不会影响已经安装的作品。退出 Steam 后，Mirage 会从钥匙串删除该账号的会话数据。
:::
