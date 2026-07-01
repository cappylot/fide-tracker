# FIDE Rating Tracker

A native **SwiftUI** iOS app for searching FIDE players, viewing their monthly rating history, and tracking rating changes — with **zero backend cost** using GitHub Actions to build a local SQLite database.

This is the completely free path: GitHub Actions (unlimited free minutes on public repos) downloads the monthly FIDE list, builds a SQLite database, and publishes it as a Release. The iOS app downloads that SQLite once on first launch, then queries it locally with GRDB. Monthly, it checks for an updated database and pulls the new one if available. No server, no database, no API costs. **Total cost: $0/month forever.**

## How the pieces fit

```
    FIDE (ratings.fide.com)
          ↓
   GitHub Action (daily)
   ├─ First run: backfill 24 months of archived lists
   ├─ Every month: seed from previous release, add the new list
   └─ Upload to Release (if changed)
          ↓
   iOS app (SwiftUI)
   ├─ Download fide.db on first launch
   ├─ Query locally with GRDB
   └─ Check for updates monthly
```

- **GitHub Action** (`.github/workflows/ingest.yml`) runs daily. On the very first run it backfills the last 24 months from FIDE's archived monthly lists (`ingestion/backfill.py`, ~1–2 hours), so rating charts have two years of history from day one. After that, each monthly run seeds the database from the previous release, adds the new month on top, and publishes it as a GitHub Release — so history keeps accumulating. **This is free** — even on private repos, you get 2000 free minutes/month, and a monthly incremental ingest is ~2–3 minutes.
- **The database** is a single SQLite file kept in GitHub Releases. To stay phone-download-sized, backfilled months store only *rating change-points* per player (the newest months are always complete — the app's search/top/delta queries rely on that); storing every player × month would be several GB. Expect roughly 500 MB–1 GB with history.
- **The app** downloads the DB on first launch (happens in the background), stores it in `Documents/`, and queries it locally. Monthly, it checks for an updated version and pulls it if the database hash changed.

## Setup (completely free)

### Backend / GitHub Action

1. **Fork this repo** to your GitHub account (public or private).
2. **No secrets needed.** The Action uses the default `GITHUB_TOKEN` (auto-provided by GitHub).
3. Push to main. The workflow runs daily at 03:00 UTC.
4. On the first run, it creates a Release named `fide-YYYYMMDD` with the SQLite file attached.

### iOS App

1. Open `ios/FideTracker.xcodeproj` in Xcode 15+. GRDB is already configured as a Swift Package dependency; Xcode resolves it automatically on first open.
2. **Set your GitHub repo** in `Services/FIDEDatabase.swift`: change the `repoSlug` constant near the top of the actor to your own `"owner/repo"` (the fork you pushed the workflow to).
3. Build and run.

The project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding or removing source files, run `cd ios && xcodegen generate` (the `.xcodeproj` is committed, so this is only needed when the file list changes).

On first launch, the app downloads `fide.db` from your GitHub Release (~30 seconds on WiFi). After that, all searches/lists/charts run instantly locally.

### Optional: monthly sync

The app checks for updates in the background. Pull-to-refresh on the Tracked tab to force an immediate check.

## Features

- **Search:** By player name or FIDE-ID. Ranks results by rating.
- **Top:** View top-100 by rating type (Standard/Rapid/Blitz), optionally filter by federation.
- **Player detail:** Full profile + monthly history as a Swift Charts line graph + all-time delta.
- **Tracked:** Star players from Search or Top. Shows your favourites + latest month-over-month change.
- **Monthly sync:** New database versions download automatically; no manual step.

## Architecture decisions

- **Local-first:** All queries run on-device. No latency, no rate limits, no API dependency.
- **Static data source:** GitHub Releases (free) instead of a live API (costs scale per request).
- **Scheduled ingestion:** GitHub Actions free tier covers one monthly FIDE download + parse.
- **GRDB:** Industry-standard Swift SQLite library. Fast, small footprint, battle-tested.

## Storage & costs

| Component | Cost |
|---|---|
| GitHub Actions | Free (unlimited on public, 2000 min/month on private) |
| GitHub Releases storage | Free |
| Data transfer (app download) | Uses user's internet, no cost to you |
| SQLite queries (on-device) | Zero cost |
| **Total** | **$0/month** |

**Database size:** ~500 MB for the full FIDE dataset (~1.2M players, including inactive). Download takes ~30 seconds on WiFi, slower on LTE. To shrink it, filter the ingestion (e.g., active players only, or top-100 per federation).

## Troubleshooting

**"Database not found"**  
→ Verify the `repoSlug` constant in `Services/FIDEDatabase.swift` points at your fork (`owner/repo`), and that a release exists under that repo's Releases tab.

**"Download is slow"**  
→ First-time downloads pull ~500 MB. Subsequent months only download if changed.

**"I want just active players"**  
→ Modify `backend/ingestion/ingest.py` to skip inactive players before inserting (see the filter on the `flag` field). Reduces SQLite size and speed.

**"Can I host the database elsewhere?"**  
→ Yes. Change the GitHub API URL in `FIDEDatabase.swift` to point to S3, your website, or any HTTPS server. The Action can upload there too.

## Development

### Build the database locally (for testing)

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Download the real FIDE list and build SQLite:
python -m ingestion.ingest
# → produces fide.db

# Or test with a local XML:
python -m ingestion.ingest --period 2026-06 --file test_list.xml
```

To test the app against a local database:
1. Build the SQLite as above.
2. Copy `backend/fide.db` into Xcode's Derived Data folder, or modify `FIDEDatabase.swift` to read from a test path.

### Modifying the schema

The database models live in `backend/app/models.py`. If you change them, update `backend/ingestion/ingest.py` and re-run a full ingest.

## Legal

Data from FIDE's official monthly download (`ratings.fide.com/download/players_list_xml.zip`). FIDE content is copyrighted; keep usage personal or analytical. Don't republish the raw database without permission.

---

**$0/month, zero servers, fully self-contained. Download the app, it syncs itself. Done.**
