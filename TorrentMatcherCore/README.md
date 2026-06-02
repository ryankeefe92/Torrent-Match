# TorrentMatcherCore

Swift files for the torrent matcher app core logic.

## What's included

- Release filename parser
- Apple TV calibrated ranker
- Generic regex-based HTML provider adapter framework
- Config tester for provider regexes
- Result deduping
- Dead-result filtering: ignore 0 seeders + fewer than 2 leechers
- Seeder tie-breaker only
- Transmission RPC client
- Sample provider config templates with empty URLs

## Main files

- `ReleaseParser.swift` parses release names.
- `TorrentRanker.swift` scores and ranks results.
- `ProviderConfig.swift` defines configurable providers.
- `RegexHTMLProvider.swift` fetches/parses HTML providers.
- `TorrentSearchService.swift` searches all providers and ranks results.
- `MovieCatalog.swift` loads the bundled movie title catalog used for local autocomplete.
- `ProviderConfigTester.swift` tests regex configs against pasted sample HTML.
- `TransmissionClient.swift` sends a magnet to Transmission RPC.

## Refreshing the bundled movie catalog

The app can autocomplete against a bundled IMDb-derived movie database with release years.

Regenerate it with:

```bash
/usr/bin/python3 scripts/update_movie_catalog.py
```

That script downloads IMDb `title.basics.tsv.gz` and `title.ratings.tsv.gz`, filters out low-signal titles, and writes `Sources/TorrentMatcherCore/Resources/MovieCatalog.sqlite`.

## Current final calibrated weights

Source:
- REMUX 90
- BluRay 68
- WEB-DL 42
- WEBRip 22
- Unknown 0

Resolution:
- 2160p 100
- 1080p 92
- 720p 50
- SD/480p 30
- Unknown 10

Dynamic range:
- Dolby Vision 30
- HDR10+ 27
- HDR10 24
- HDR 20
- Unknown 12
- SDR -5

Audio codec:
- TrueHD 42
- DTS-HD MA 36
- DDP/E-AC-3 32
- DD/AC3 18
- AAC 6
- Unknown 0

Channels:
- 7.1 32
- 5.1 24
- 2.0/unknown 0

Atmos:
- DDP Atmos +6
- TrueHD Atmos +0

Video codec:
- HEVC/H.265 20
- AVC/H.264 10
- AV1 excluded entirely
- Unknown 0

Seeders:
- No score bonus.
- Used only as tie-breaker when score is equal.

## Provider config flow

Create a `ProviderConfig`:

```swift
let config = ProviderConfig(
    id: "my-provider",
    name: "My Provider",
    enabled: true,
    searchURLTemplate: "", // add your own URL with {{query}}
    resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
    titlePattern: #"<a[^>]+href=[\"'][^\"']+[\"'][^>]*>([^<]+)</a>"#,
    detailURLPattern: #"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>[^<]+</a>"#,
    magnetPattern: #"href=[\"'](magnet:\?[^\"']+)[\"']"#,
    seedersPattern: #"(?:seeders|seeds|se)[^>]*>\s*(\d+)\s*<"#,
    leechersPattern: #"(?:leechers|leeches|le)[^>]*>\s*(\d+)\s*<"#,
    detailBaseURL: ""
)
```

Then:

```swift
let service = TorrentSearchService(configs: [config])
let ranked = await service.searchAndRank("your search")
```

## Testing provider regexes

Use:

```swift
let test = ProviderConfigTester.test(config: config, sampleHTML: htmlString)
print(test.resultBlockCount)
print(test.sampleResults)
print(test.warnings)
```

This lets you paste saved HTML and tune regexes before live searching.

## Transmission

```swift
let client = TransmissionClient(
    config: TransmissionConfig(
        rpcURL: URL(string: "http://YOUR_TAILSCALE_IP:9091/transmission/rpc")!,
        username: "your-user",
        password: "your-password"
    )
)
try await client.add(magnet: magnet)
```

Your Mac must be awake, Transmission remote access must be enabled, and the iPhone/Mac must be network-reachable, e.g. with Tailscale.

In the app UI you can now save both:

- a `Home RPC URL` for your LAN address
- a `Tailscale RPC URL` for your tailnet IP or MagicDNS hostname

When both are configured, Torrent Match will try them in order and can prefer the Tailscale endpoint first.
