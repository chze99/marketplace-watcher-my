# marketplace-watcher-my: watch Malaysian second-hand marketplaces for keywords and post new listings to Discord / Telegram.
# Sources: Carousell, Mudah, Facebook Marketplace, Lowyat Forum garage sales.
# Runs on Windows (PowerShell 5.1 or 7), macOS and Linux (PowerShell 7 = pwsh), with Edge, Chrome or Chromium installed.
# Settings live in config.json (copy config.example.json). Run every few minutes from Task Scheduler / launchd / cron (see README).

$cfgPath = Join-Path $PSScriptRoot "config.json"
if (!(Test-Path $cfgPath)) { throw "Missing $cfgPath - copy config.example.json to config.json and edit it." }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$Keywords       = @($cfg.keywords)
$Sources        = @($cfg.sources)               # any of: carousell, mudah, facebook, lowyat
$LowyatSections = @($cfg.lowyat_sections)       # forum.lowyat.net/<name>; any *GarageSales section works
$Site           = $cfg.carousell_site           # e.g. https://www.carousell.com.my
$FbCity         = $cfg.facebook_city            # Facebook Marketplace city slug (facebook.com/marketplace/<slug>)
$MudahRegion    = $cfg.mudah_region             # Mudah region slug (mudah.my/<slug>/all); "malaysia" = nationwide
$DiscordUrl     = $cfg.discord_webhook
$TgToken        = $cfg.telegram_token
$TgChat         = $cfg.telegram_chat_id

# Without a destination, listings would be marked "seen" and lost, so refuse to run.
if (($DiscordUrl -notmatch '^https://') -and !$TgToken) { throw "Set discord_webhook (or telegram_token + telegram_chat_id) in config.json." }
if ($DiscordUrl -notmatch '^https://') { $DiscordUrl = "" }

$SeenFile = Join-Path $PSScriptRoot "seen.txt"

# $IsWindows / $IsMacOS only exist in PowerShell 7; Windows PowerShell 5.1 is always Windows.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$onMac     = (-not $onWindows) -and $IsMacOS

# Any Chromium-based browser works. config.json "browser_path" overrides the search.
$Browser = $cfg.browser_path
if (!$Browser) {
    $candidates = if ($onWindows) {
        @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    } elseif ($onMac) {
        @("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium")
    } else {
        @("microsoft-edge", "microsoft-edge-stable", "google-chrome", "google-chrome-stable", "chromium", "chromium-browser")
    }
    foreach ($c in $candidates) {
        $found = if (Test-Path $c) { $c } else { (Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
        if ($found) { $Browser = $found; break }
    }
}
if (!$Browser) { throw "No Edge/Chrome/Chromium found (needed to fetch the pages). Install one, or set browser_path in config.json." }

# The default headless user agent says "HeadlessChrome" and gets blocked, so present a normal desktop browser that matches this OS.
$platform = if ($onWindows) { "Windows NT 10.0; Win64; x64" } elseif ($onMac) { "Macintosh; Intel Mac OS X 10_15_7" } else { "X11; Linux x86_64" }
$UA = "Mozilla/5.0 ($platform) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
$seen = [Collections.Generic.HashSet[string]]::new([string[]]@(if (Test-Path $SeenFile) { Get-Content $SeenFile }))

# Each page fetch uses its own throwaway browser profile (deleted afterwards). If a browser had to be force-killed the profile can be
# locked and left behind, so sweep leftovers from earlier runs.
$tmpRoot = [IO.Path]::GetTempPath()
Get-ChildItem $tmpRoot -Filter "mwatch-*" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -lt (Get-Date).AddMinutes(-10) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

function Post($url, $obj) {
    $body = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5))
    Invoke-RestMethod $url -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
}

function Send($src, $kw, $title, $price, $link, $img) {
    if ($DiscordUrl) {
        $embed = @{ title = "$title"; url = $link; description = "**$price**"; footer = @{ text = "$src - $kw" } }
        if ($img) { $embed.image = @{ url = $img } }
        Post $DiscordUrl @{ embeds = @($embed) }
    }
    if ($TgToken) {
        $text = "[$src/$kw] $title - $price`n$link"
        if ($img) { Post "https://api.telegram.org/bot$TgToken/sendPhoto" @{ chat_id = $TgChat; photo = $img; caption = $text } }
        else      { Post "https://api.telegram.org/bot$TgToken/sendMessage" @{ chat_id = $TgChat; text = $text } }
    }
}

# Cloudflare 403s plain HTTP requests (and these are JS-rendered), so use a headless browser.
function Get-Page($url) {
    $base = Join-Path $tmpRoot ("mwatch-" + [guid]::NewGuid().ToString("N"))   # profile dir; $base.out / $base.err hold the output
    $flags = "--headless=new --disable-gpu --no-first-run --user-data-dir=`"$base`" --virtual-time-budget=15000 `"--user-agent=$UA`" --dump-dom `"$url`""
    if (-not $onWindows -and (& id -u) -eq '0') { $flags = "--no-sandbox " + $flags }   # Chrome refuses to start as root otherwise
    $sp = @{ FilePath = $Browser; ArgumentList = $flags; RedirectStandardOutput = "$base.out"; RedirectStandardError = "$base.err"; PassThru = $true }
    if ($onWindows) { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    # A browser occasionally hangs forever on a page, so cap it at 60s or it blocks every later run (and kill its child processes too).
    if (!$p.WaitForExit(60000)) {
        if ($onWindows) { taskkill /T /F /PID $p.Id | Out-Null } else { & pkill -f -- "--user-data-dir=$base"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    $html = Get-Content "$base.out" -Raw -Encoding UTF8
    Remove-Item "$base.out", "$base.err", $base -Recurse -Force -ErrorAction SilentlyContinue   # may stay locked if the browser was force-killed; swept later
    $html
}

function Item($id, $title, $price, $link, $img) { [pscustomobject]@{ id = $id; title = $title; price = $price; link = $link; img = $img } }

# Each parser returns Item objects; ids of new sources carry a prefix so they can't collide. Carousell keeps bare ids (existing seen.txt).
function Parse-Carousell($html) {
    foreach ($c in ($html -split 'data-testid="listing-card-(?=\d)' | Select-Object -Skip 1)) {
        $id = [regex]::Match($c, '^\d+').Value
        if (!$id) { continue }
        Item $id ([Net.WebUtility]::HtmlDecode([regex]::Match($c, '--max-line:\s*2;?">([^<]*)<').Groups[1].Value)) `
            ([regex]::Match($c, 'title="([A-Z]*\$[^"]*|RM[^"]*|P[\d,][^"]*)"').Groups[1].Value) `
            ($Site + [regex]::Match($c, 'href="(/p/[^"?]+)').Groups[1].Value) `
            ([regex]::Match($c, 'src="(https://media\.karousell\.com/media/photos/products/[^"]+)"').Groups[1].Value -replace '_thumbnail(?=\.jpg)', '')
    }
}

function Parse-Mudah($html) {
    # Organic results are the listing-ad-item cards; the page's embedded JSON also holds unrelated gallery ads (cars, bikes).
    foreach ($c in ($html -split 'data-testid="listing-ad-item-(?=\d)' | Select-Object -Skip 1)) {
        $id = [regex]::Match($c, '^\d+').Value
        if (!$id) { continue }
        $price = [regex]::Match($c, '>(RM\s?[\d,]+)\s*<').Groups[1].Value
        Item "mudah:$id" ([Net.WebUtility]::HtmlDecode([regex]::Match($c, '<h2>([^<]*)</h2>').Groups[1].Value)) $(if ($price) { $price } else { "no price" }) `
            ([regex]::Match($c, 'href="(https://www\.mudah\.my/[^"]+\.htm)').Groups[1].Value) `
            ([regex]::Match($c, 'src="(https://img\.rnudah\.com/[^"]+)').Groups[1].Value -replace '/grids/', '/images/')
    }
}

function Parse-Facebook($html) {
    # Logged-out search works but is capped to ~24 cards. Card text is: [Just listed] | price | title | location.
    foreach ($c in ($html -split '<a [^>]*href="/marketplace/item/(?=\d)' | Select-Object -Skip 1)) {
        $c = $c.Substring(0, [Math]::Min(8000, $c.Length))
        $id = [regex]::Match($c, '^\d+').Value
        $t = @([regex]::Matches($c, '<span[^>]*dir="auto"[^>]*>(?:<span[^>]*>)*([^<]+)<') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } | Where-Object { $_ -ne 'Just listed' })
        if (!$id -or $t.Count -lt 2) { continue }
        $pi = [Array]::FindIndex($t, [Predicate[string]]{ param($x) $x -match '^(MYR|RM)\s?[\d,]+|^Free$' })
        if ($pi -lt 0 -or $pi + 1 -ge $t.Count) { continue }
        Item "fb:$id" $t[$pi + 1] ($t[$pi] -replace '^MYR\s?', 'RM ') "https://www.facebook.com/marketplace/item/$id/" `
            ([Net.WebUtility]::HtmlDecode([regex]::Match($c, 'src="(https://scontent[^"]+)').Groups[1].Value))
    }
}

# Lowyat has no usable keyword search without a login, so we read each section's topic list and filter titles by $Keywords.
function Parse-Lowyat($html) {
    foreach ($c in ($html -split '<!-- Begin Topic Entry (?=\d)' | Select-Object -Skip 1)) {
        $m = [regex]::Match($c, '<a href="(/topic/(\d+))" title="This topic was started: ([^"]+)">\s*(?:<span class="topic-prefix label (\w+)">[^<]*</span>)?\s*([^<]*)</a>')
        if (!$m.Success -or ($m.Groups[4].Value -and $m.Groups[4].Value -ne 'WTS')) { continue }   # skip tagged want-to-buy / trade posts; untagged ones are kept
        $started = [datetime]::MinValue
        [void][datetime]::TryParseExact($m.Groups[3].Value, 'MMM d yyyy, h:mm tt', [cultureinfo]::InvariantCulture, 'None', [ref]$started)
        Item "ly:$($m.Groups[2].Value)" ([Net.WebUtility]::HtmlDecode($m.Groups[5].Value.Trim())) "Posted $($m.Groups[3].Value)" "https://forum.lowyat.net$($m.Groups[1].Value)" `
            ([Net.WebUtility]::HtmlDecode([regex]::Match($c, 'id="forum_topic_thumb"><img src="(https?://[^"]+)"').Groups[1].Value)) |
            Add-Member started $started -PassThru
    }
}

# A job is one page to fetch: a keyword search (carousell/mudah/facebook) or a whole section (lowyat). Seed keys keep their old format.
$jobs = foreach ($src in $Sources) {
    if ($src -eq "lowyat") {
        foreach ($sec in $LowyatSections) { [pscustomobject]@{ src = $src; label = $sec; url = "https://forum.lowyat.net/$sec"; seed = "seed:lowyat/$sec" } }
        continue
    }
    foreach ($kw in $Keywords) {
        $q = [uri]::EscapeDataString($kw)
        switch ($src) {
            "carousell" { $url = "$Site/search/$q`?sort_by=3";                                                               $seed = "seed:$Site/$kw" }
            "mudah"     { $url = "https://www.mudah.my/$MudahRegion/all?q=$q";                                               $seed = "seed:mudah/$MudahRegion/$kw" }   # changing location re-seeds
            "facebook"  { $url = "https://www.facebook.com/marketplace/$FbCity/search?query=$q&sortBy=creation_time_descend"; $seed = "seed:facebook/$FbCity/$kw" }
        }
        [pscustomobject]@{ src = $src; label = $kw; url = $url; seed = $seed }
    }
}
$kwRegex = ($Keywords | ForEach-Object { [regex]::Escape($_) }) -join '|'

foreach ($j in $jobs) {
    $items = @(& "Parse-$($j.src)" (Get-Page $j.url))
    if (!$items) { Write-Warning "No listings parsed for $($j.src)/'$($j.label)' (blocked, layout changed, or nothing recent)"; continue }
    # Done after the "nothing parsed" check, so a quiet section still seeds. Topics are ordered by last reply, so bumped old posts
    # rise to the top: only alert on ones started in the last 3 days.
    if ($j.src -eq "lowyat") { $items = @($items | Where-Object { $_.title -match $kwRegex -and $_.started -ge (Get-Date).AddDays(-3) }) }

    # New keyword/source: record current listings silently instead of spamming them.
    $seeding = $seen.Add($j.seed)
    if ($seeding) { Add-Content $SeenFile $j.seed }

    foreach ($i in $items) {
        if (!$seen.Add($i.id)) { continue }
        Add-Content $SeenFile $i.id
        if ($seeding) { continue }
        try { Send $j.src $j.label $i.title $i.price $i.link $i.img } catch { Write-Warning "Send failed: $_" }
        Start-Sleep -Milliseconds 500   # stay under Discord's webhook rate limit
    }
}

