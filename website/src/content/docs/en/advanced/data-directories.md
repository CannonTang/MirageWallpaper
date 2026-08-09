---
title: Data Directories
description: Where Mirage stores wallpaper sources, Workshop downloads, caches, and settings.
---

## Wallpaper sources

| Source | Default location |
| --- | --- |
| Mirage Workshop downloads | `~/Library/Application Support/Mirage/Workshop/content/431960/` |
| Mirage local imports | `~/Library/Application Support/Mirage/Wallpapers/` |
| System Steam Workshop | `~/Library/Application Support/Steam/steamapps/workshop/content/431960/` |

General Settings lets you choose custom locations for the system Steam Workshop directory and the import directory. Mirage manages its own Workshop download directory.

## Download staging

In-progress items are stored under:

```text
~/Library/Application Support/Mirage/Workshop/content/431960/.staging/<item ID>/
```

After every chunk validates and a root `project.json` is present, the staging directory is atomically moved to the sibling `<item ID>/` path. Failed or cancelled staging does not appear in the wallpaper library and can be reused on retry.

## Credentials and settings

- Steam refresh tokens and GuardData are stored in the macOS Keychain.
- The Steam account name, global settings, web-wallpaper trust records, and per-wallpaper runtime values are stored in `UserDefaults`.
- Passwords and Steam Guard codes are not persisted.

## Cache and screen saver

| Data | Default location |
| --- | --- |
| Workshop preview cache | `~/Library/Caches/Mirage/WorkshopCache/` |
| Live screen saver | `~/Library/Screen Savers/MirageScreenSaver.saver` |
| Screen saver configuration | `~/Library/Application Support/Mirage/screensaver.json` |

:::caution[Clean up with care]
Deleting an item directory removes that wallpaper. Deleting `.staging` discards reusable unfinished chunks but does not affect installed items. Signing out removes that account's session data from Keychain.
:::
