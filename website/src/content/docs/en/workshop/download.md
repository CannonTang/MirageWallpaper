---
title: Download and Manage
description: Download Workshop wallpapers concurrently, view live speed, cancel tasks, and manage installed content.
---

## Starting a download

Start from an item card or detail view. Mirage uses the authenticated Steam session to resolve the item manifest and downloads it into Mirage's own wallpaper directory. The Steam account must own Wallpaper Engine. A Steam Web API Key is not required for downloads.

The embedded service calls SteamKit2 manifest and CDN APIs directly. Its server selection, chunk scheduling, validation, and resumable-reuse design is informed by DepotDownloader, while the actual tasks run in Mirage's own service without the DepotDownloader command-line application.

## Live progress

The download manager shows:

- Received bytes and total compressed size
- Completion percentage
- Smoothed live speed over the last few seconds
- Estimated time remaining
- Resolving, downloading, validating, and completed states

Speed comes from bytes actually received from Steam CDN HTTP response streams, not disk writes or the size advertised on the item page.

## Concurrency and cancellation

Mirage handles up to three items at once. Each item can use up to four chunk requests, with a global limit of eight requests so one item cannot monopolize the connection. Each item has its own cancellation token; cancelling one does not terminate the Steam session or another download.

## Validation and installation

Files are written under `Workshop/content/431960/.staging` first. Mirage validates every manifest chunk and requires a root `project.json`, then atomically replaces the final item directory on the same volume. Failed or cancelled work never enters the wallpaper library, while reusable staged chunks remain available for a retry.

## Updating an item

When an installed item is downloaded again, Mirage validates the existing files and requests only missing or changed chunks. The wallpaper library refreshes automatically after installation.

## Presets and dependencies

A preset depends on a base wallpaper. When the dependency is missing, Mirage asks for confirmation, queues the base item, and applies the preset after the dependency is ready. See [Presets and Dependencies](/en/workshop/presets/).

See [Data Directories](/en/advanced/data-directories/) for the on-disk paths.
