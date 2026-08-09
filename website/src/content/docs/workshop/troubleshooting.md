---
title: 创意工坊故障排查
description: 解决创意工坊浏览、登录和下载中的常见问题。
---

## 浏览问题

持续繁忙、超时或加载失败通常是共享 Steam Web API Key 被限流。配置自己的 [Steam Web API Key](/workshop/api-key/)，或在适用网络中切换浏览端点。

## 登录问题

- 二维码失效时点击“刷新二维码”；Steam 挑战变化时会自动换码，30 秒没有更新时 Mirage 也会自动重建登录会话。
- 手机已确认但页面没有立即完成时，先确认网络仍可连接 Steam；正常情况下服务收到 `loggedIn` 状态后会自动进入完成页。
- 手机确认需要在 Steam 手机应用中明确批准。
- 密码登录失败时确认使用的是 Steam 账户名而非昵称。
- 保存会话失效后重新登录，Mirage 会自动替换钥匙串中的令牌。

## 服务不可用

若提示内置 Steam 服务不可用，确认 Mirage App 完整位于可执行的本地磁盘，未单独移动或删除 `Contents/Resources/SteamService`。重新安装完整 App 后再试。

## 下载问题

- 确认 Steam 会话仍有效，账号拥有 Wallpaper Engine。
- 检查磁盘空间和 Steam CDN 网络连接。
- 取消后重试不会污染壁纸库，已校验的暂存分块可被复用。
- 校验失败通常表示现有文件或传输分块损坏，重试会重新请求错误分块。

## 诊断日志

Mirage 的开发日志会对密码、API Key 和令牌字段自动脱敏。反馈问题时请附上系统版本、Mirage 构建号、作品 ID、复现步骤和相关日志。反馈渠道见[社区与反馈](/reference/community/)。

相关位置：[通用设置](/settings/general/)、[Steam 登录](/workshop/login/)、[数据目录](/advanced/data-directories/)。
