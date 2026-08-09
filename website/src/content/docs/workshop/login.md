---
title: Steam 登录
description: Mirage 的二维码、密码与 Steam Guard 登录流程，以及凭据如何保存。
---

下载创意工坊内容需要登录一个拥有 Wallpaper Engine 的全球 Steam 账号。登录由 Mirage 内置的 SteamKit2 服务直接连接 Valve。

## 二维码登录

二维码是默认方式：

1. Mirage 从 Steam 获取短期挑战 URL，并在本机生成二维码。
2. 使用 Steam 手机应用扫码并确认。
3. Steam 返回刷新令牌，Mirage 建立长驻会话。

二维码图片不会上传到其他服务。Steam 刷新挑战 URL 时，向导会立即重绘二维码；如果 30 秒内没有收到新的挑战，Mirage 会自动重建二维码登录会话。也可以点击“刷新二维码”立即换码。手机确认并完成 Steam 登录后，向导会自动进入完成页。

## 密码与 Steam Guard

无法扫码时可以改用账户名和密码。密码只通过应用与本机辅助进程之间的标准输入发送，不进入命令行参数、不写入日志，也不会长期保存。

若账号启用了 Steam Guard，向导会显示邮箱验证码、手机验证码或手机确认状态。验证码只用于当前登录。

## 会话保存

登录成功后，Mirage 将刷新令牌和 GuardData 存入 macOS 钥匙串，并只在偏好设置中保存账号名。下次启动会直接尝试恢复会话。令牌失效时，Mirage 会清除它并要求重新登录。

在创意工坊页面退出登录会终止当前会话，并删除钥匙串中的刷新令牌和 GuardData。

:::note
Mirage 并非 Steam 官方客户端，也不会绕过 Wallpaper Engine 所有权或创意工坊访问权限。
:::
