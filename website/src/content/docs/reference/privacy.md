---
title: 隐私与数据
description: Mirage 如何处理 Steam 凭据、API Key 与本地数据。
---

Mirage 是本地运行的桌面应用，不运营 Mirage 账户系统，也不会把使用数据上传到 Mirage 的服务器。

## Steam 凭据

- 二维码挑战 URL 由 Steam 返回并在本机生成二维码，不发送给第三方二维码服务。
- 密码只通过标准输入交给随 App 提供的本机辅助进程，不进入命令行参数、不写入日志，也不长期保存。
- 登录成功后的刷新令牌与 GuardData 存入 macOS 钥匙串，账号名存入偏好设置。
- Steam Guard 验证码只用于当前登录。
- 主动退出登录会清除该账号的钥匙串会话数据。

详见 [Steam 登录](/workshop/login/)。

## Steam Web API Key

你填写的 API Key 保存在本地设置中，只用于从本机请求创意工坊浏览数据。App 附带的共享 Key 同样只用于浏览，不参与登录或下载。

## 网络请求

| 用途 | 目标 |
| --- | --- |
| 浏览创意工坊 | Steam Web API 或你选择的镜像端点 |
| 登录与 Steam Guard | Valve Steam 登录服务 |
| 下载创意工坊内容 | Valve Steam 内容 CDN |
| 检查或下载更新 | Mirage 的 GitHub Release 与 appcast |
| 网页壁纸 | 由壁纸自身决定 |

可选的 SteamCF 镜像并非 Steam 官方服务，只代理浏览 API，不加速登录或下载。

## 日志与本地数据

Mirage 会对日志中的密码、API Key、访问令牌和刷新令牌字段自动脱敏。壁纸、下载、缓存和设置都保存在本机，路径见[数据目录](/advanced/data-directories/)。

Mirage 与 Valve、Steam、Wallpaper Engine 没有关联，也未获其官方认可。
