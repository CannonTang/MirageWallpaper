---
title: Workshop Troubleshooting
description: Resolve common Workshop browsing, sign-in, and download problems.
---

## Browsing problems

Persistent busy errors, timeouts, or failed loads usually mean the shared Steam Web API Key is rate-limited. Configure a personal [Steam Web API Key](/en/workshop/api-key/) or switch browsing endpoints where appropriate.

## Sign-in problems

- If a QR code expires, select **Refresh QR Code**. The wizard redraws Steam challenge updates automatically and starts a fresh sign-in session when no update arrives for 30 seconds.
- If mobile approval succeeds but the page does not complete immediately, confirm that Steam connectivity is still available. Under normal operation the wizard advances as soon as the service receives `loggedIn`.
- Mobile confirmation requires explicit approval in the Steam mobile app.
- For password sign-in, use the Steam account name rather than the profile display name.
- When a persisted session expires, sign in again; Mirage replaces the rejected Keychain token automatically.

## Embedded service unavailable

If Mirage reports that the embedded Steam service is unavailable, make sure the complete app is on an executable local volume and that `Contents/Resources/SteamService` was not moved or deleted. Reinstall the complete app and retry.

## Download problems

- Confirm the Steam session is valid and the account owns Wallpaper Engine.
- Check free disk space and connectivity to Steam content servers.
- Cancelling and retrying does not pollute the library; validated staged chunks can be reused.
- A validation failure usually means an existing file or transferred chunk is corrupt. Retrying requests the invalid chunks again.

## Diagnostic logs

Mirage redacts password, API Key, and token fields in developer logs. When reporting a problem, include the macOS version, Mirage build, item ID, reproduction steps, and relevant logs. See [Community and Feedback](/en/reference/community/).

Related pages: [General Settings](/en/settings/general/), [Steam Sign-In](/en/workshop/login/), and [Data Directories](/en/advanced/data-directories/).
