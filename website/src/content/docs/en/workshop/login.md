---
title: Steam Sign-In
description: Mirage's QR, password, and Steam Guard flows, and how credentials are stored.
---

Downloading Workshop content requires a global Steam account that owns Wallpaper Engine. Mirage's embedded SteamKit2 service connects directly to Valve for sign-in.

## QR sign-in

QR is the default path:

1. Mirage requests a short-lived challenge URL from Steam and renders the QR code locally.
2. Scan it in the Steam mobile app and approve the request.
3. Steam returns a refresh token and Mirage establishes a long-lived session.

The QR image is never uploaded to another service. When Steam refreshes the challenge URL, the wizard redraws the code immediately. If no new challenge arrives within 30 seconds, Mirage automatically starts a fresh QR sign-in session. You can also select **Refresh QR Code** at any time. After mobile approval and successful Steam sign-in, the wizard advances to the completion step automatically.

## Password and Steam Guard

If scanning is unavailable, switch to account-name and password sign-in. The password is sent only over standard input between the app and its local helper. It is not placed in process arguments, written to logs, or stored long-term.

For Steam Guard accounts, the wizard shows email code, mobile code, or mobile confirmation state. Codes are used only for the current attempt.

## Persisted session

After sign-in, Mirage stores the refresh token and GuardData in the macOS Keychain and keeps only the account name in preferences. The next launch restores the session directly. If a token is rejected, Mirage removes it and asks you to sign in again.

Signing out from the Workshop ends the current session and removes its refresh token and GuardData from Keychain.

:::note
Mirage is not an official Steam client and does not bypass Wallpaper Engine ownership or Workshop access controls.
:::
