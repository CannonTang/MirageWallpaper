---
title: Web Wallpaper Safety
description: Understand the security risks of web wallpapers and Mirage's trust confirmation mechanism.
---

A web wallpaper is essentially an HTML page that can run JavaScript. This enables rich interaction and animation, but it also means it can execute arbitrary script code. That's why Mirage has a dedicated trust confirmation for web wallpapers.

## Why confirmation is needed

- **Scene** and **video** wallpapers are resources and media; they don't execute arbitrary code.
- **Web** wallpapers run in a WKWebView and execute JavaScript, which can access the network, load remote resources, and more.

A web wallpaper from an unknown source could, in theory, contain scripts you don't want to run. So when you apply a web wallpaper that is **not yet trusted**, Mirage shows a safety prompt first.

## The trust mechanism

- The first time you apply a given web wallpaper, if it's not on the trust list, Mirage shows a prompt.
- **Trust and Continue** adds the wallpaper to the trust list, which remains effective across future launches.
- **Continue This Time** is valid only for the current Mirage session and asks again after the next launch.

Persistent trust is recorded **per wallpaper**, applying only to the specific web wallpaper for which you chose **Trust and Continue**, and won't let through any other unconfirmed web wallpapers.

## Recommendations

- Only trust web wallpapers from reliable sources, such as ones you made yourself, or ones from trusted authors and high-reputation Workshop works.
- Stay cautious with web wallpapers of unknown origin or suspicious behavior.
- Scene and video wallpapers don't involve this confirmation. If you value safety more, you can prefer these two types.

## Related

- For the differences between wallpaper types, see [Wallpaper types](/en/formats/wallpaper-types/).
- Web wallpapers are rendered by a separate WebWallpaper process, running in isolation. See [Render architecture](/en/advanced/architecture/).
