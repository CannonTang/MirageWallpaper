---
title: Workshop Setup Wizard
description: The three-step first-use setup for the Workshop.
---

## Step 1: Overview

Confirm that downloads require a global Steam account that owns Wallpaper Engine, and review how browsing and downloading use separate Steam services.

## Step 2: Steam sign-in

The wizard shows a QR code by default. Scan and approve it in the Steam mobile app, or switch to account-name and password sign-in. The code redraws whenever Steam updates its challenge; Mirage starts a fresh session if updates stall, and **Refresh QR Code** is also available manually. Email codes, mobile codes, and mobile confirmations are handled on the same page when Steam Guard requires them.

Sign-in is handled by the service embedded in Mirage, with no separate component to install. Refresh tokens are stored in the macOS Keychain and passwords are not stored.

## Step 3: Finish

After successful sign-in, the wizard advances to the completion step automatically. Steam verifies Wallpaper Engine ownership and access to each item on the first download.

Browsing still uses the Steam Web API. Configure a personal [Steam Web API Key](/en/workshop/api-key/) to avoid contention on the shared built-in key.
