# Torrent Match

Torrent Match is a SwiftUI app for finding and ranking movie and television torrents, then sending selected downloads to Transmission.

## Repository layout

- `Torrent Match/App`: app entry point and top-level navigation
- `Torrent Match/Features`: movie search and television subscription workflows
- `Torrent Match/Core`: torrent models, parsing, ranking, providers, search, catalog, and Transmission client code
- `Torrent Match/Services`: app-facing platform and Transmission state services
- `Torrent Match/SupportingFiles`: assets, plist, and entitlements
- `Torrent MatchTests`: unit and integration tests grouped by feature
- `Torrent MatchUITests`: launch and UI tests
- `scripts`: repository maintenance tools

The core implementation is compiled directly into the app target. There is no separate local Swift package.

## Refreshing the movie catalog

The bundled IMDb-derived autocomplete database can be regenerated from the repository root:

```bash
/usr/bin/python3 scripts/update_movie_catalog.py
```

The script downloads IMDb title and ratings datasets, filters low-signal entries, and replaces `Torrent Match/Core/Resources/MovieCatalog.sqlite`.
