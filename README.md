# 🍅 Focus Guard

Focus Guard is a macOS menu bar app that helps you stay focused with Pomodoro sessions, website blocking, and a place to capture distractions for later.

## Features

- **A customizable focus cycle:** 35 minutes of focus, 3 minutes to wrap up, and a 7-minute break by default.
- **Website blocking:** Redirects distracting sites to a local blocked page during focus and wrap-up, including while the timer is paused. The default list includes YouTube, Instagram, LinkedIn, Facebook, X, Twitter, Reddit, and Netflix. You can paste full URLs into the list; only the domain is kept, and lines that aren't recognized as domains are reported. An allow list overrides the block list for specific subdomains; by default it contains `music.youtube.com`, so YouTube Music (including its installed Chrome app) keeps playing during focus.
- **Distraction reminders:** Outside focus and wrap-up, warns you after 10 minutes of tracked use on a listed site, then at further 10-minute intervals. Brief interruptions of up to 3 minutes can count toward the same streak.
- **A “Later” list:** Capture a thought from the menu bar or press `⌥⇧L` from any app. Review your list during wrap-up.
- **Daily planning:** Organize tasks into must-do, nice-to-do, and other tasks, then check them off as you go.
- **Weekly history:** Review daily study time, completed sessions, wrap-up notes, and time spent on distracting sites. Sessions that cross midnight are split between the two days.
- **A deliberate stopping step:** Type a confirmation phrase (configurable) before abandoning a focus session. Spacing and punctuation don't matter.

The app interface and notifications are currently in Korean. The descriptions below use English names for its controls.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel.
- Xcode Command Line Tools (`xcode-select --install`) to build from source.
- A supported browser: Google Chrome, Safari, Arc, Brave, or Microsoft Edge. Firefox is not supported.

## Build and run

```bash
git clone https://github.com/brightree/focus-guard.git
cd focus-guard/app
./build.sh
open FocusGuard.app
```

The script creates `app/FocusGuard.app` for your Mac's architecture. You can move it to `/Applications` if you prefer. Once launched, Focus Guard appears as a 🍅 icon in the menu bar. It shows up in the Dock and ⌘Tab only while one of its windows is open.

### Permissions

| Permission | When it is requested | What it is used for |
| --- | --- | --- |
| Automation | When the app first tries to control a supported browser | Read tab URLs, redirect blocked tabs, and close a tab when you choose that action in a reminder. |
| Notifications | On first launch | Show phase changes, distraction reminders, and storage problems. |
| Launch at login | When you enable it in Settings | Start Focus Guard when you log in. Blocking only works while the app is running. |

If you deny browser automation, the menu bar panel shows a warning with a shortcut to **System Settings → Privacy & Security → Automation → Focus Guard**, where you can enable the relevant browser.

## Everyday use

1. Click the 🍅 menu bar icon to start a session, pause or resume the timer, open the main window, or end the current phase. You can also add an item to your Later list here.
2. Press `⌥⇧L` to capture a thought without opening the main window.
3. Use the main window to review your weekly history, plan today's tasks, or open Settings.
4. In Settings, adjust durations, the blocked-site list, the stopping phrase, the storage folder, and launch at login. Settings can be changed at any time; new durations apply from the next phase. Every numeric setting is kept within a fixed range (for example, focus is 1–180 minutes).

## Privacy, safety, and limitations

### Browser access

[BrowserWatcher.swift](app/Sources/BrowserWatcher.swift) checks the active tab of the foreground browser roughly once per second. At the start of a focus session—and when the app launches with focus or wrap-up still active—it also reads the URLs of all tabs in running supported browsers and redirects matching tabs, including those in background windows.

Browsing statistics contain the matched domain and tracked time, not full URLs or page contents. The original URL is encoded in the blocked page's URL fragment so you can return to it later. Fragments are not sent to the local HTTP server, but the full blocked-page URL may remain in browser history or browser sync.

macOS grants broad browser automation permission. This app uses it to read tab URLs, replace them with the blocked page, and close a tab when you choose “Close this tab” in a reminder.

**Redirecting a tab can discard unsaved work.** Save drafts before starting a focus session. The reminder's close action first re-checks the browser's current tab and closes it only if it is still on the site the reminder was about; if you've switched to another site, it does nothing.

### Local web server

[Server.swift](app/Sources/Server.swift) serves the blocked page at `http://127.0.0.1:47321`. It binds to the IPv4 loopback address, so it is not directly accessible from other devices on your network.

The server requires the exact `Host` header `127.0.0.1:47321`. When an `Origin` header is present, it must match `http://127.0.0.1:47321`. These checks help restrict requests from other websites; they do not authenticate local applications. Malformed requests (missing, invalid, or duplicate `Content-Length`) are rejected, request bodies are limited to 64 KB, and connections are closed after 5 seconds.

Other programs running on your Mac can read the current phase, remaining time, and session task title, or add items to the Later list through this server.

If the server cannot start—for example, because another process is using the port—the app still redirects tabs to that address. The blocked page may fail to load; if another service is listening there, its response may appear instead. When the blocked page can't reach the app, it says so rather than claiming the session has ended.

### Storage and backups

By default, records are stored only on your Mac:

```text
~/Library/Application Support/FocusGuard/data.json
```

You can check the active location or choose another folder in Settings. If the selected folder already contains `data.json`, the app loads that file instead of merging it with the current records. The folder only changes if the current records were saved first and the new location can be read (or written, if it's empty); otherwise the app keeps the old location and tells you why.

The file contains tasks, Later items, timer state, session history, wrap-up notes, and distraction statistics. It is **unencrypted JSON**. Anyone with access to the file or its synced folder can read it.

The app creates a dated backup on the first successful save each day and keeps the 14 most recent backups in a `backups/` subfolder. These are local copies beside the data file, not independent backups.

How the app protects an existing file:

- **The file exists but can't be read** (for example, a cloud file that hasn't downloaded): the app stops saving so it can't overwrite it, and shows a warning.
- **The file can be read but is damaged:** the app copies it to `data.unreadable-<timestamp>-<id>.json`, checks that the copy matches the original byte for byte, and only then starts with empty records. If the copy can't be made, it stops saving instead.
- **A save fails** (for example, the folder is read-only or disconnected): the menu bar panel shows the error, and the app retries every 30 seconds.

While saving is stopped or failing, the Later inputs refuse new items instead of pretending to save them.

There is no conflict resolution for multiple Macs sharing one folder. A later save can overwrite another Mac's changes.

### Network and system changes

Focus Guard has no analytics, tracking, automatic updates, or direct outbound network requests. **If you choose a folder synced by a cloud service (for example, Google Drive or iCloud Drive), that service uploads your records.**

The app does not require administrator privileges or change `/etc/hosts`, network settings, or other system files.

### Performance and blocking limits

The app uses a single one-second timer for session updates and browser monitoring. Regular polling runs AppleScript only when a supported browser is in the foreground. The all-tab sweep runs at most two scripts per running browser: one to list tabs and one to redirect every matching tab at once. Closed windows and the menu bar panel are released from memory, so they don't keep redrawing in the background.

Time on distracting sites is collected in memory and written to the data file at most every 30 seconds (and on quit). If the app crashes, up to 30 seconds of distraction time can be lost; other changes are saved within about a second.

Browser scripts run synchronously on the main thread with a two-second timeout per script. An unresponsive browser can briefly freeze the interface.

Focus Guard is a self-management aid. Quitting or force-quitting the app, denying automation permission, or using an unsupported browser bypasses blocking.

Builds are ad-hoc signed, without a Developer ID signature or notarization. macOS may ask for automation permission again after a rebuild, and Gatekeeper may prevent a copied build from opening on another Mac. Building from source on each Mac avoids distributing a prebuilt app.

## Uninstall

**Settings → Delete Focus Guard…** turns off launch at login, moves the app to the Trash, and quits. Check the box to move your records folder to the Trash as well. Items in the Trash can still be restored until you empty it.

To uninstall by hand:

1. Disable launch at login in Settings if you enabled it.
2. Open the main window from the menu bar and choose Quit.
3. Delete `FocusGuard.app`.
4. To remove your records, delete the active storage folder shown in Settings, including its `backups/` subfolder and any `data.unreadable-*.json` copies. If you changed locations, check previous folders for retained copies as well. Deleting files in a synced folder may also remove them from other devices.
5. Optionally disable Focus Guard's browser permissions under **System Settings → Privacy & Security → Automation**.

## Project structure

```text
app/
  build.sh                 Builds the app with swiftc; no Xcode project required
  MakeIcon.swift           Draws the 🍅 app icon at build time
  Sources/
    main.swift             Menu bar, windows, global shortcut, and app startup
    Store.swift            Timer, statistics, and JSON persistence
    Models.swift           Data models and setting ranges
    BrowserWatcher.swift   Browser monitoring and redirects through AppleScript
    Server.swift           Loopback HTTP server for the blocked page
    BlockedPage.swift      Blocked-page HTML, CSS, and JavaScript
    Views.swift            SwiftUI views
```

## License

[MIT](LICENSE)
