# FIDE Tracker — Free Setup (5 minutes)

**Total cost: $0/month forever.** No backend, no server, no API key.

## Step 1: Fork the repo (1 min)

1. Go to [github.com/YOU/fide-tracker](https://github.com/fide-tracker) (or wherever you forked it)
2. That's it — GitHub Actions are enabled by default

## Step 2: Trigger the first run (optional, but recommended)

1. Click **Actions** tab
2. Select **"FIDE monthly ingestion (build SQLite)"**
3. Click **"Run workflow"** → **"Run workflow"**
4. Wait for it to finish — the **first run backfills the last 24 months** of
   FIDE archives so charts have history from day one (~1–2 hours). Every
   later run reuses the previous release and takes ~5 minutes.
5. Click **Releases** tab — you'll see `fide-YYYY-MM` with `fide.db` attached

(Or just wait until tomorrow at 03:00 UTC for the scheduled run.)

## Step 3: Set up the iOS app (3 min)

1. Open `ios/FideTracker.xcodeproj` in Xcode 15+ (GRDB is already set up as a package dependency)
2. **Set your GitHub repo:**
   - Open `ios/FideTracker/Services/FIDEDatabase.swift`
   - Near the top of the `FIDEDatabase` actor, change the `repoSlug` constant
     to your own `"owner/repo"`
3. **Build & run** on the Simulator or a device

On first launch, the app will download `fide.db` (~500 MB, ~30 sec on WiFi). After that, search/top/charts are instant.

## How it works

- **GitHub Action** (runs daily at 03:00 UTC)
  - First run only: backfills the last 24 months from FIDE's archived
    monthly lists, storing each player's rating change-points so the
    database stays phone-sized
  - Downloads the latest FIDE rating list from `ratings.fide.com`
  - Seeds from the previous release and adds the new month (history
    accumulates month over month)
  - Only publishes when FIDE releases a new monthly list
  - Publishes to GitHub Releases (free storage, free bandwidth)

- **iOS app** (downloads on first launch, then monthly)
  - Fetches `fide.db` from GitHub Releases
  - Stores locally in Documents/
  - Queries with GRDB (instant)
  - Checks for updates monthly (pull-to-refresh)

## Costs

| Item | Cost |
|---|---|
| GitHub Actions | FREE (unlimited on public, 2000 min/month on private) |
| GitHub Releases | FREE |
| GRDB | FREE (open source) |
| Data transfer | Uses user's internet |
| **Total** | **$0/month** |

## What you get

- **Search** by name or FIDE-ID
- **Top 100** rankings (filter by Standard/Rapid/Blitz + federation)
- **Player profile** with monthly history chart
- **Tracked players** with month-over-month rating change
- **Monthly auto-sync** (new database downloads if changed)

## Troubleshooting

**"Database not found when I open the app"**
- Make sure the `repoSlug` constant in `FIDEDatabase.swift` points at your fork (`owner/repo`)
- Check that a release exists under that repo's Releases tab

**"Download is taking forever"**
- First download is ~500 MB (~30 sec on WiFi, slower on cellular)
- Subsequent months only download if the database actually changed

**"I only want active players (smaller download)"**
- Edit `backend/ingestion/ingest.py`
- In the `_upsert` loop, add: `if p.get("flag") and "i" in p["flag"].lower(): continue`
- Run `python -m ingestion.ingest` locally to rebuild
- Upload the smaller `fide.db` to your Release manually (or wait for the next automatic run to rebuild it)

**"Can I move the database to my own server?"**
- Yes! Change the GitHub API URL in `FIDEDatabase.swift` to point to S3, a CDN, your website, etc.
- You can also modify the workflow to upload there

---

**That's it.** The Action runs automatically every day. The app syncs itself. Zero maintenance, zero cost. Enjoy!
