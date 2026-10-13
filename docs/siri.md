# Siri

"Hey Siri, play Brooklyn Nine-Nine in Dusk" plays the movie, or the next
episode of the show, from the user's Plex libraries. Everything lives in
`Dusk/Sources/Siri/`. It uses App Intents only, so there is no Siri
entitlement, no Intents extension and no permission prompt.

## Routes

| Route | What Siri hears | How the title is resolved |
| --- | --- | --- |
| `PlayTitleIntent` (App Shortcut) | "Play/Watch/Resume/Continue *title* in/on Dusk" | Siri matches *title* against the titles Dusk registered beforehand (`SiriTitleCatalog`) and hands over a `PlexTitleEntity`. |
| `PlayInDuskIntent` (`PlayVideoIntent`, a system intent) | Siri's own "play *video* in *app*" | Siri passes the spoken text as `term`; Dusk searches Plex. |
| `PlayInDuskIntent` (App Shortcut) | "Play/Watch something in/on Dusk", "Find something to watch in Dusk" | Siri asks "What would you like to watch?" and Dusk searches the free-form answer. |

App Shortcut phrases only match parameter values that were registered in
advance (`suggestedEntities()` → `updateAppShortcutParameters()`). A title that
is not in the catalog goes through the free-form routes. Whether Siri sends a
bare "Play X in Dusk" to `PlayVideoIntent` for an unregistered title is up to
Siri and has not been verified on a device.

Both intents run in the app and open it first (`openAppWhenRun` on iOS 18+,
`supportedModes = .foreground(.immediate)` on tvOS 26+). Only the foreground app
connects its servers (`ServerConnectionCoordinator`), so a background intent
would have nothing to search.

## Flow

`SiriPlaybackService` (registered with `AppDependencyManager` in `DuskApp.init`):

1. Waits up to 15s for the session and the pool. It gives other servers 1.5s
   once the first one answers. Signed out, profile picker, every server off and
   unreachable each get their own spoken reply.
2. `SiriTitleQuery` strips "the movie/show" and a trailing year. Plex search
   runs for the spoken text, the text with digits spelled out ("brooklyn 99" →
   "brooklyn nine nine"; Plex matches words), and the longest word. It runs on
   every connected server and is merged with `SearchMerge`, which registers
   alternates for playback fallback. Catalog titles are added as candidates too.
3. `SiriTitleMatcher` scores and resolves:
   - Folding: case, accents and punctuation are ignored; number words and
     sequel numerals become digits; a leading "the" and "(US)"-style
     qualifiers are dropped.
   - Scoring: an exact match beats a title the query starts, which beats a
     title containing all of its words, which beats an edit-distance near-miss.
   - Ties (within 0.04) are broken by the year hint, then by in-progress, then
     by any watch history. Whatever is still tied is `.ambiguous`, and on iOS
     and tvOS 26+ Siri asks "Which one did you mean?" via `requestChoice`.
4. A movie resumes from its offset. A show plays `SiriNextEpisodePicker`'s
   episode from `/allLeaves`, using Plex's On Deck rule: the episode in progress,
   else the one after the last watched, else the first unwatched, else start
   over; specials are skipped. Playback starts through
   `PlaybackCoordinator.play` without awaiting it, so the player cover and its
   error UI take over and Siri replies straight away.

## Catalog

`SiriTitleCatalog` holds up to 300 movies/shows: recently watched (each
library's `lastViewedAt:desc`) first, then recently added. It is refreshed from
`MainTabView` 5s after servers connect or the app becomes active, at most every
30 minutes. It is stored in UserDefaults and cleared in
`tearDownServerSessions` (sign-out, Plex Home switch), like the Top Shelf.
Entities carry synonyms ("Brooklyn 99", "The Office" for "The Office (US)").

## Traps

- The App Shortcut "Play" tile is hidden in the Shortcuts app until the catalog
  has titles. That is expected when signed out.
- tvOS builds get the App Shortcut definitions but no flexible-matching NLU
  assets (`Metadata.appintents` has no `nlu/`). Expect exact phrases only on
  Apple TV, if tvOS Siri runs App Shortcuts at all. Device check pending.
- `requestChoice` options are not Sendable: `choose(among:)` must stay off the
  main actor.

## Verification

- Unit tests: `DuskTests/SiriTitleMatchingTests.swift` (query parsing,
  folding, resolution, next-episode rule) on iOS and tvOS.
- iOS simulator: Shortcuts app → Dusk → "Play by Name" runs the intent end to
  end (prompt, app opens, spoken reply). There is no way to trigger intents
  programmatically on the tvOS simulator.
- Device only: real Siri speech on iPhone and Apple TV, signed-in playback.
