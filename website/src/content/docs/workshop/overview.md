---
title: 创意工坊概览
description: 了解 Mirage 如何对接 Steam 创意工坊，以及使用前需要准备什么。
---

Mirage 内置 Steam 创意工坊的浏览与下载能力，直接对应 Wallpaper Engine（App ID `431960`）的创意工坊内容。

![Mirage 中按自然标签浏览的 Steam 创意工坊](/images/docs/workshop-nature.webp)

## 工作方式

- **Steam Web API**用于浏览、搜索和读取作品信息。建议配置自己的 [Steam Web API Key](/workshop/api-key/)。
- **内置 Steam 服务**直接依赖 [SteamKit2 3.4.0](https://github.com/SteamRE/SteamKit)，负责二维码或密码登录、Steam Guard、作品清单解析和 CDN 下载。下载器的整体设计参考 [DepotDownloader](https://github.com/SteamRE/DepotDownloader)，但 Mirage 不捆绑或启动 DepotDownloader 可执行程序，也无需安装额外工具。

## 使用前的准备

首次使用时，Mirage 会显示三步向导：

1. 阅读创意工坊和所有权说明。
2. 登录一个拥有 Wallpaper Engine 的全球 Steam 账号。二维码登录为默认方式，也可改用账户密码。
3. 完成设置。

登录后，刷新令牌和 Steam Guard 设备数据保存在 macOS 钥匙串中。详见[设置向导](/workshop/setup-wizard/)和[Steam 登录](/workshop/login/)。

## 浏览与下载

你可以按趋势、发布时间、订阅数、评分、标签和分级筛选作品。Mirage 最多同时下载三个作品，并显示实时接收字节、速度、进度和预计剩余时间。每个任务可独立取消，不会中断其他下载。

详见[浏览创意工坊](/workshop/browse/)和[下载与管理](/workshop/download/)。

:::caution[遵守条款]
创意工坊内容归各自作者所有。请遵守 Steam 与作者的许可与使用条款。Mirage 与 Valve、Steam 或 Wallpaper Engine 没有关联，也未获其官方认可。
:::
