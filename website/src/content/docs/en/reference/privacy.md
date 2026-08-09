---
title: Privacy & Data
description: How Mirage handles Steam credentials, API Keys, and local data.
---

Mirage is a locally running desktop app. It does not operate a Mirage account system or upload usage data to Mirage servers.

## Steam credentials

- Steam returns the QR challenge URL and Mirage renders it locally without using a third-party QR service.
- Passwords are passed over standard input to the helper bundled with the app. They are not put in process arguments, written to logs, or stored long-term.
- Refresh tokens and GuardData are stored in the macOS Keychain after sign-in; the account name is stored in preferences.
- Steam Guard codes are used only for the current attempt.
- Signing out removes that account's session data from Keychain.

See [Steam Sign-In](/en/workshop/login/).

## Steam Web API Key

The API Key you enter is stored in local settings and is used only for Workshop browsing requests from your Mac. The shared key included with the app is also for browsing only and is not involved in sign-in or downloads.

## Network requests

| Purpose | Target |
| --- | --- |
| Browse the Workshop | Steam Web API or a mirror you choose |
| Sign-in and Steam Guard | Valve Steam authentication services |
| Download Workshop content | Valve Steam content CDN |
| Check or download updates | Mirage GitHub Releases and appcast |
| Web wallpapers | Determined by the wallpaper itself |

The optional SteamCF mirror is not an official Steam service. It only proxies the browsing API and does not accelerate sign-in or downloads.

## Logs and local data

Mirage automatically redacts password, API Key, access-token, and refresh-token fields in logs. Wallpapers, downloads, caches, and settings remain on your Mac; see [Data Directories](/en/advanced/data-directories/).

Mirage is not affiliated with or endorsed by Valve, Steam, or Wallpaper Engine.
