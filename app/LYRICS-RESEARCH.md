# Lyrics source investigation

Checked 19–20 October 2026.

Spotify's local AppleScript dictionary exposes playback metadata and controls,
but no lyrics field. The documented [Web API track object](https://developer.spotify.com/documentation/web-api/reference/get-track)
also has no lyrics field. Futnyl does not use private Spotify lyrics endpoints,
cookies, or embedded third-party credentials.

[LRCLIB](https://lrclib.net/docs) provides an anonymous API without an API key.
Its exact lookup uses song, artist, album and duration, with a two-second duration
tolerance. Its search endpoint provides candidate recordings. Community entries
can be incomplete or incorrectly timed, so an HTTP success alone is insufficient.

[Musixmatch's official developer overview](https://www.postman.com/musixmatch-dev)
requires choosing a plan and obtaining an API key. Its [official API specification](https://github.com/musixmatch/musixmatch-sdk/blob/master/swagger/swagger.json)
defines authenticated lyrics/subtitle endpoints. This research did not establish
an unrestricted free synchronized-lyrics replacement suitable for this app.

## Public fixture checks

The real Swift client successfully fetched usable timed lyrics for these public
test recordings. No current Spotify playback metadata was used in this test.

| Recording | Requested seconds | Timed lines returned |
| --- | ---: | ---: |
| Never Gonna Give You Up — Rick Astley | 213 | 59 |
| Blinding Lights — The Weeknd, After Hours | 200 | 40 |
| Bohemian Rhapsody — Queen | 354 | 56 |
| Not Like Us — Kendrick Lamar | 274 | 105 |

The first song's exact result contained only a single timestamp at zero. The
previous client accepted this as synchronized lyrics. The revised client rejects
it, searches candidates, and selects a timed recording only when its full title,
artist, album (if supplied), and duration match. It preserves version words such
as live/remix instead of stripping them to force a match.

The parser requires at least two nonempty lines at distinct timestamps, and
rejects timestamps beyond the recording's duration plus two seconds. Playback
uses Spotify's observed position, extrapolated only while playing. Pause and seek
tests cover the lyric clock, and clicking a line seeks only if the current track
still matches.

## Decision and limits

Keep LRCLIB first, followed by the [AMLL community database](https://github.com/amll-dev/amll-ttml-db), with explicit unavailable
states. Do not display plain text or a guessed alternate recording as synchronized
lyrics. The interface identifies the source that supplied the current document.

These checks verify recording metadata, timestamp structure and playback-clock
behavior. They do not prove every lyric's transcription or audible alignment.
Community lyrics can still contain errors, and strict matching intentionally
reduces coverage. There is no guarantee of correct lyrics for every Spotify song.

## Ordered fallback investigation

AMLL documents a generated `.lrc` index under `spotify-lyrics/<Spotify ID>.lrc`.
This allows a bounded request for an exact recording without fuzzy cross-service
search or a commercial-service cookie. Its README asks downstream users to link
to the project; Futnyl provides both in-app attribution and a README link. The
repository distinguishes contributor-authored material from external data and
notes that cross-platform mapping and older submissions can contain errors.

A live test of its public Never Gonna Give You Up Spotify-ID entry returned 60
usable timed lines. Automated tests verify LRCLIB wins when available, AMLL can
recover from missing/untimed results and primary outages, cancellation stops
fallback, and malformed IDs or unusable timestamps cannot supply synced lyrics.
AMLL's exact ID index improves recording selection but cannot guarantee that
community timestamps are audibly perfect.

Open-source aggregators such as [syncedlyrics](https://github.com/moehmeni/syncedlyrics)
and [Lyrica](https://github.com/Wilooper/Lyrica) also wrap commercial/private
services or scrape pages. Their open-source code alone does not establish a
stable, unrestricted service or correct recording match, so they were not added
as automatic providers.

Google is discovery only. A search result pointing at Spotify or Musixmatch does
not supply recording-specific LRC timestamps or public API access. Futnyl offers
a user-clicked search link after timed lookup fails, without fetching snippets,
extracting browser credentials, generating timing from text, or replacing the
synchronized display. The title and artist are sent to Google only on that click.
