# Source reports and local source ordering

This package adds an explicit report dialog to the native player's Settings menu
when playback came from a prepared server entry. It uses the server's current
source version, requested language and actual audio-track indices. A manual
library/source URL without a prepared entry does not acquire reporting permission.
The existing Switch Source picker remains available for those files.

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
