# Source reports and local source ordering

This package adds an explicit report dialog to the native player's Settings menu
when playback came from a prepared server entry. It uses the server's current
source version, requested language and actual audio-track indices. A manual
library/source URL without a prepared entry does not acquire reporting permission.
The existing Switch Source picker remains available for ordinary files; confirmed combined episode files keep their file-only identity and cannot switch to external releases.

Report-only, history reset, prepare-alternative, play-alternative and undo are
separate actions. A saved report with a failed reset/retry remains an explicit
partial result. Undo deletes that report only; it cannot restore reset history.
An unknown acknowledgement is never automatically replayed. A known unused
replacement is cancelled using the original server, session, profile and client,
including late receipts delivered after viewer cancellation. The client cannot
cancel an unknown replacement ID or prove server cleanup after a lost response.

Both details pages expose the title's local-source preference: inherit, prefer
local, or search first with local fallback. Only the dedicated source-only PUT is
used, after an explicit capability marker. No fallback full-preference update or
DELETE can erase audio/subtitle choices. On supporting servers, ordinary Play
uses server ordering instead of the previous unconditional client-local shortcut.
Versions remains an explicit manual choice. Servers without the capability keep
the best-library fallback; the separate Versions picker remains available.

The original API client refreshes/rebases some ordinary calls. These mutations
and their cleanup use a single captured request with the existing URLSession:
no refresh, automatic PIN adoption, transport rebase or application-level replay.
Changing server/profile/session requires reopening the dialog. Client context is
a stale-result guard, not a server authority or a substitute for current PG/PIN
checks. Requested audio language comes from report options, not the playing track.

## Validation

No Apple compilation, simulator or device tests were run on the Linux authoring
host. It has no Swift on PATH or Xcode. New XCTest cases cover wire fields,
three-state preferences, original request/context binding, explicit actions,
partial/unknown outcomes, cancellation with late delivery and joined cleanup.
Existing test files are preserved.

`.github/workflows/apple-source-actions.yml` runs only on an explicit manual
`workflow_dispatch` or a push to the dedicated `feature/integrated-requirements`
branch. Manual dispatch requires a reviewed immutable commit; a branch push pins
its actual commit. The job records actual tools, requires Swift 6.2+
(the upstream API already uses `@concurrent`), generates the actual Xcode project,
selects an installed available tvOS 18+ Apple TV simulator, runs `StrmrTVTests`, and
compiles `StrmrMobile` for the iOS simulator. It preserves logs and the xcresult.
It does not publish apps, install on real devices, create releases or push source.
The workflow has not been dispatched or pushed by the author.

The public runner image reference reviewed while preparing this workflow is
[GitHub's macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
Its documented default was Xcode 26.6; the workflow records and checks the actual
selected compiler rather than assuming that an older Xcode supports this source.
AetherEngine remains the existing exact 7.47.0 dependency, and Google Cast remains
exact 4.8.6. Future CI resolves those existing dependencies and includes the
tracked Iroh framework; the local sparse source checkout excludes its large blobs.

## Combined episode files

The separate combined-file change decodes the backend's explicit membership and
file-progress marker. It keeps such files in the manual Versions list and excludes
them from automatic best-episode selection. Selecting one asks Play From Beginning
or Cancel before a player or media request is created. After consent, actual
library playback data is re-read under the same client context; changed data or
missing file-progress semantics are denied instead of becoming a single episode.

Playback uses the existing unmatched-library target with movie/file progress keyed
by the actual opaque streamPath. Catalogue IDs, the selected episode, resume point,
following episodes and episode artwork are removed. The full file duration and
position are retained as file progress; no episode offset, duration ratio or
automatic watched update for all members is manufactured. The same coordinator
handles TV and iPhone/iPad. New XCTest cases cover mapping, progress metadata,
malformed descriptors, legacy single-episode compatibility and pre-cancelled
consent; an actual remote-control/device interaction remains to be validated.

## Progress and replacement ownership

Wrong-content reports pause the actual player, permanently stop its progress
admission and await all admitted HTTP writes and their background cleanup before
POST. Reset is refused after an unconfirmed old write. Normal alternative handoff
also drains old writes, including its final write, before presenting the new player.
Alternatives are polled to ready while the old player remains open. The final
readiness/episode check precedes pause and dismissal. Beginning, Current and
Current minus 10 seconds read the engine at the confirmed handoff; wrong-content
alternatives always start at zero. The opening-dialog position is not reused.

The release-retry owner tracks at most 64 original prequeue IDs, including pending
POSTs. A late receipt cannot DELETE a deduplicated ID owned by another dialog or
player. New POSTs wait for any already-started DELETE. Completed records are removed;
unknown DELETEs retain a bounded record and show an explicit cancellation-retry
choice. Retrying cleanup uses the original captured credentials. No timer pretends
an uncertain DELETE succeeded. The record is removed after confirmed cleanup.
This owner coordinates only release-retry resources, not authentication or sessions.

All normal, warm and prefetched prequeue requests use the same capability-bound
`automaticLibrarySelection` builder. Old servers receive no unknown extension
field. Cast progress retains its original viewer and physical-file/catalogue key,
including when the phone changes profile while casting.
