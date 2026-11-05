# marketplace-watcher-my

Watch Malaysian second-hand marketplaces for keywords (e.g. `ddr4`, `rtx 3060`, `4tb`) and get a **Discord** and/or **Telegram** message, with photo, price and link, as soon as a new listing appears.

| Source | What it searches | Notes |
|---|---|---|
| Carousell | `carousell.com.my` keyword search, newest first | whole country, no city filter |
| Mudah | `mudah.my` keyword search, by region | `malaysia` (nationwide) or a state such as `sarawak` |
| Facebook Marketplace | keyword search in one city | works logged out, but only the newest ~24 results |
| Lowyat Forum | WTS posts in the PC "Garage Sales" sections | matches keywords in the **title** only |

One PowerShell script, no dependencies to install. Runs on **Windows, macOS and Linux**. Built for personal use on a home PC or small server, not as a service.

> **Platform status: Windows is tested; macOS and Linux are untested.** The macOS and Linux support (PowerShell 7, browser lookup, launchd/cron setup) was written carefully but has **never been run on a real Mac or Linux machine**. It may need small fixes on your system. If something breaks, please open an issue and include your OS, version, browser and the error output.

## Limitations (please read)

- **Malaysia-focused.** The defaults, the sources and the examples are all Malaysian. Carousell's other country sites (`.sg`, `.ph`, ...) may work by changing `carousell_site`, but are not tested. Mudah and Lowyat are Malaysia-only.
- **Needs a Chromium browser** (Edge, Chrome or Chromium). Pages are rendered with the browser in headless mode, because Carousell and Facebook block plain HTTP requests and the pages are built with JavaScript.
- **It scrapes web pages**, not official APIs. Any site can change its layout and break a parser; you will see `No listings parsed for ...` in the output. Scraping may also be against a site's terms of service: keep the interval modest and use it for personal use only.
- **Slow and heavy.** Each page needs a browser start (roughly 5-25 s). A full check of 4 sources and a few keywords takes minutes and uses noticeable CPU. Overlapping runs must be prevented (the scheduler setups below do this), so the real interval is "5 minutes or the run time, whichever is longer".
- **Facebook:** logged-out search returns only about 24 listings per keyword, so a very busy keyword can push a listing off the list between checks. The city is set by `facebook_city` (the slug in `facebook.com/marketplace/<slug>`).
- **Lowyat:** there is no usable keyword search without logging in, so it reads each section and filters titles by your keywords (a RAM post titled "Kingston 16GB 3200" will not match `ddr4`). It only reports `WTS`/untagged posts started in the last 3 days, since bumped old posts rise to the top.
- **Carousell** has no location filter in the search address. **Mudah** can only filter by region (state), not by city.
- **Delivery to East Malaysia is not filtered.** None of these sites let the script filter by "delivers to Sarawak/Sabah"; check with each seller.
- Cloudflare can occasionally block a page load. The script skips that search for that round and tries again next time.
- eBay and Shopee are **not** supported (blocked / bot-protected).
- **macOS and Linux:** supported through PowerShell 7. The Windows setup is the most tested. See "Platform notes" below for what was and was not verified.
- Not affiliated with any of these sites.

## Requirements

| | Windows | macOS | Linux |
|---|---|---|---|
| PowerShell | Windows PowerShell 5.1 (preinstalled) or PowerShell 7 | **PowerShell 7** | **PowerShell 7** |
| Browser | Microsoft Edge (preinstalled) or Chrome | Edge, Chrome or Chromium | Edge, Chrome or Chromium (a normal `.deb`/`.rpm` install, see notes) |
| Scheduler | Task Scheduler | launchd | cron |

You also need a Discord webhook URL and/or a Telegram bot token + chat id.

### Install PowerShell 7 and a browser

- **macOS:** `brew install --cask powershell`, and a browser, e.g. `brew install --cask google-chrome` (or Edge/Chromium). Run scripts with `pwsh`.
- **Debian / Ubuntu:** install PowerShell 7 from Microsoft's package repository (see <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux>), then Chrome or Edge from their official `.deb`. On a server, `sudo apt install chromium` also works (see the snap note below).
- **Fedora / RHEL:** same guide for PowerShell; `sudo dnf install chromium` or Chrome's `.rpm`.
- Check: `pwsh -Version` and `which google-chrome chromium microsoft-edge`.

## Setup (all systems)

1. Download or clone this repo to a folder (Windows `C:\marketplace-watcher-my`, macOS/Linux e.g. `~/marketplace-watcher-my`).
2. Copy `config.example.json` to `config.json` and edit it:

   | Key | Meaning |
   |---|---|
   | `keywords` | search words; every source is searched for every keyword (Lowyat: title filter) |
   | `sources` | any of `carousell`, `mudah`, `facebook`, `lowyat`; remove the ones you don't want |
   | `carousell_site` | Carousell site, default `https://www.carousell.com.my` |
   | `mudah_region` | `malaysia` or a state slug (`sarawak`, `selangor`, ...) |
   | `facebook_city` | Facebook Marketplace city slug (`kualalumpur`, `kuching`, `penang`, ...) |
   | `lowyat_sections` | Lowyat garage-sale sections to read, e.g. `RAMGarageSales` |
   | `discord_webhook` | Discord: channel settings > Integrations > Webhooks > Copy URL. Leave as is to disable |
   | `telegram_token`, `telegram_chat_id` | Telegram: create a bot with @BotFather; send it a message, then open `https://api.telegram.org/bot<token>/getUpdates` to find your chat id. Leave empty to disable |
   | `browser_path` | optional: full path to the browser if it is not found automatically |

   `config.json` is git-ignored. **Never commit it**: the webhook URL and bot token let anyone post as you. On macOS/Linux also run `chmod 600 config.json`.

3. Run it once by hand:

   ```powershell
   pwsh -NoProfile -File ./watch.ps1                                  # macOS / Linux / Windows with PowerShell 7
   powershell -ExecutionPolicy Bypass -File .\watch.ps1               # Windows PowerShell 5.1
   ```

   The first run only **records** what is currently listed and sends nothing. Every keyword/source/location combination is recorded silently the first time it is seen, so adding a keyword later never floods you. After that, only new listings are sent.

4. Run it automatically every 5 minutes, below.

### Windows (Task Scheduler)

Run it as **your own user**, not SYSTEM:

```powershell
schtasks /create /tn "MarketplaceWatcher" /sc MINUTE /mo 5 `
  /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\marketplace-watcher-my\watch.ps1"
```

`schtasks` repeats forever; the PowerShell `New-ScheduledTaskTrigger -RepetitionInterval` form can silently stop after one day. On a laptop, open the task in Task Scheduler and untick "Start the task only if the computer is on AC power". Windows does not start a new run while the previous one is still going.

### macOS (launchd)

Create `~/Library/LaunchAgents/com.example.marketplace-watcher.plist` (change the two paths; `which pwsh` shows yours, usually `/opt/homebrew/bin/pwsh` on Apple Silicon and `/usr/local/bin/pwsh` on Intel):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.marketplace-watcher</string>
  <key>ProgramArguments</key><array>
    <string>/opt/homebrew/bin/pwsh</string><string>-NoProfile</string>
    <string>-File</string><string>/Users/YOU/marketplace-watcher-my/watch.ps1</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/tmp/marketplace-watcher.log</string>
  <key>StandardOutPath</key><string>/tmp/marketplace-watcher.log</string>
</dict></plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.example.marketplace-watcher.plist
# stop it:  launchctl unload ~/Library/LaunchAgents/com.example.marketplace-watcher.plist
```

launchd never starts a second copy of a job that is still running. The Mac must be awake to run it (a laptop that sleeps will simply skip checks).

### Linux (cron)

```bash
crontab -e
```

```cron
*/5 * * * * flock -n /tmp/marketplace-watcher.lock pwsh -NoProfile -File $HOME/marketplace-watcher-my/watch.ps1 >> $HOME/marketplace-watcher.log 2>&1
```

`flock -n` stops a slow run from overlapping the next one. On a machine without a desktop the headless browser still works; no display is needed. A systemd timer works equally well if you prefer it (one `OnUnitActiveSec=5min` timer and a oneshot service running the same command).

## Platform notes

- **Tested:** Windows 11 with Windows PowerShell 5.1 and Edge, against the four live sites. **Not yet tested on real macOS or Linux machines.** The OS-specific parts are small and isolated (browser lookup, how a hung browser is killed, the user-agent string, temp folders), but expect to report an issue if your distro or browser packaging behaves differently.
- **Browser identity:** the script sends a normal desktop browser user agent that matches your OS (the default headless one says "HeadlessChrome" and is blocked).
- **Running as root** (for example inside a container): the script adds `--no-sandbox` automatically because Chrome refuses to start as root otherwise. Inside Docker you may also need a bigger `/dev/shm` (`--shm-size=1g`).
- **Ubuntu snap Chromium** runs in a confined sandbox that can interfere with the throwaway profile folder; prefer Chrome/Edge from their `.deb`, or the `chromium` package from your distro's own repository, and set `browser_path` if needed.
- **A hung browser** is killed after 60 seconds (`taskkill /T` on Windows, `pkill -f` on macOS/Linux, matched by the throwaway profile path) and its profile folder is deleted; leftovers named `mwatch-*` in the temp folder are swept on the next run.

## How it works

- Each (source, keyword) pair is one page fetch through the headless browser (`--dump-dom`, capped at 60 s so a hung page cannot block later runs). Every fetch uses its own empty browser profile, so nothing is shared with your normal browsing and nothing accumulates.
- A small parser per site turns the page into `id, title, price, link, image` items. Ids are remembered in `seen.txt` (next to the script); anything not in there is new.
- New items are posted as a Discord embed (title, price, big photo) and/or a Telegram photo with caption.

To add another site, write a `Parse-<name>` function returning `Item` objects and add a case to the job list near the end of `watch.ps1`.

## Troubleshooting

- `No Edge/Chrome/Chromium found`: install one or set `browser_path`.
- `No listings parsed for mudah/'ddr4'` once in a while: a page load timed out; harmless. Every time: the site changed its layout and the parser needs updating, or the page is being blocked.
- Nothing arrives after the first run: that is expected until a *new* listing appears. To test the delivery, delete one id line from `seen.txt` (not the `seed:` lines) and run again.
- Delete `seen.txt` to forget everything; the next run will silently re-record the current listings.

## Support

This tool is free and maintained in spare time. If it saved you time, you can star the repo, report problems or send a fix, or [buy me a coffee](https://buymeacoffee.com/raizer99). Thank you!

## License

MIT, see [LICENSE](LICENSE).
