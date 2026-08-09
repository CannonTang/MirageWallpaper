---
title: Workshop Overview
description: Learn how Mirage integrates with the Steam Workshop and what you need before using it.
---

Mirage includes browsing and downloading for Wallpaper Engine Workshop content (App ID `431960`).

![Browsing the Steam Workshop with the Nature filter in Mirage](/images/docs/workshop-nature.webp)

## How it works

- The **Steam Web API** handles browsing, search, and item metadata. Configure a personal [Steam Web API Key](/en/workshop/api-key/) for the most reliable browsing.
- Mirage's **embedded Steam service** directly depends on [SteamKit2 3.4.0](https://github.com/SteamRE/SteamKit) and handles QR or password sign-in, Steam Guard, manifest resolution, and CDN downloads. Its downloader design is informed by [DepotDownloader](https://github.com/SteamRE/DepotDownloader), but Mirage neither bundles nor launches the DepotDownloader executable, and no separate installation is required.

## Before you start

The first-use wizard has three steps:

1. Review the Workshop and ownership notice.
2. Sign in with a global Steam account that owns Wallpaper Engine. QR sign-in is the default, with password sign-in available as a fallback.
3. Finish setup.

After sign-in, the refresh token and Steam Guard device data are stored in the macOS Keychain. See the [Setup Wizard](/en/workshop/setup-wizard/) and [Steam Sign-In](/en/workshop/login/).

## Browsing and downloading

You can filter by trend, release time, subscriptions, rating, tags, and content rating. Mirage downloads up to three items concurrently and reports live received bytes, speed, progress, and ETA. Cancelling one task does not interrupt the others.

See [Browse the Workshop](/en/workshop/browse/) and [Download and Manage](/en/workshop/download/).

:::caution[Respect the terms]
Workshop content belongs to its respective authors. Follow the license and terms of use set by Steam and the authors. Mirage is not affiliated with or endorsed by Valve, Steam, or Wallpaper Engine.
:::
