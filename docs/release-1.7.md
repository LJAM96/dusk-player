# Dusk 1.7 Release Notes

Range: `a5f00c1` (merge-base of `origin/release/1.6` and `origin/main`) to
`origin/main` at `2181fd0`. That is 62 non-merge commits plus the
`bd14f5e` merge of `plucky-iguana` (`49888eb`). `MARKETING_VERSION` is 1.7.0
(`c444cde`). The last release is 1.6.2 on `release/1.6`.

Every item below was checked against the code or diff, not only the commit
subject. "Device check pending" items come from agent notes and have not
been seen on real hardware.

## What's New (App Store)

### iPhone and iPad (596 characters)

```text
Dusk now uses all your Plex servers at once.
• Home, Continue Watching and Search combine every server. Choose which copy plays first in Settings › Server Priority.
• MKV files with Dolby Atmos or 5.1 Dolby audio can play with Atmos and spatial audio, through a lossless Plex remux.
• Dolby Vision profile 5 files now play.
• Ask Siri to "play [title] in Dusk".
• On iPad, Home opens with a larger, near full-screen hero.
• Optional Previous and Next Episode buttons in the player.
• A calmer, more native look.
• Three new app icons for subscribers.
• Fixed: TrueHD tracks playing without sound.
```

### Apple TV (597 characters)

```text
• A new full-screen Home with a hero you can swipe through, and text sized for the TV.
• A new play bar: click or hold to skip, swipe to scrub with previews, and one panel for audio, subtitles, quality and speed.
• Next Episode in the play bar.
• Each show now has one page with season tabs.
• Continue Watching and Up Next in the Top Shelf.
• All your Plex servers at once, ordered in Settings › Server Priority.
• Dolby Atmos from MKV files. Dolby Vision profile 5 files now play.
• Back from any tab returns to Home.
• Fixed: the screensaver not starting while paused, and silent TrueHD tracks.
```

Notes on the texts:

- Counts are Unicode characters of the block, without the trailing newline.
- Siri is left out of the tvOS text on purpose. Apple TV Siri is unverified,
  and tvOS builds get no App Shortcut NLU assets (see Risks). If a device check
  passes, swap the "Back from any tab" line for `• Ask Siri to "play [title] in Dusk".`
  That line is 37 characters, so the text stays under 600.
- Not mentioned on purpose: the subscription price change, the new icon unlock
  rules (see Risk 2), and the fixes that shipped in 1.6.1 and 1.6.2.
- Not new in 1.7, so not in the text: the supporter tier and the six classic
  icons, anonymous analytics, library order synced with the Plex account
  (`9cfa6d5`), and the Videos library. All of them are on `release/1.6` already.

## All Changes

### Features

- **Multi-server unification.** Every enabled server connects in parallel in
  the background (`ServerPool`, `ServerProbe`, `ServerConnectionCoordinator`).
  Home, Continue Watching, hubs, Search and recommendations merge across
  servers. Duplicates are merged only on strong keys (plex guid, tmdb, imdb or
  tvdb), and a server name shows only when titles collide. The server picker
  and Settings › "Change Server" are gone (`ServerPickerView` was deleted).
  They are replaced by Settings › Navigation › **Server Priority**, which sets
  the order and has an on/off switch per server (iOS and tvOS). Playback walks
  the copies in priority order with fallback, but a copy that has progress
  plays first. Mark watched/unwatched and "remove from Continue Watching"
  apply to every copy. Library Order now covers every enabled server.
  Downloads and offline sync are keyed per server. Live TV and Seerr use the
  highest-priority server. `49888eb` (merge `bd14f5e`), `12fb471`, `e78b786`,
  `69bf6dc`.
- **Dolby Atmos and spatial audio from MKV files.** These files go through a
  lossless Plex fMP4 HLS remux to AVPlayer. On tvOS this covers E-AC-3 Atmos.
  On iOS it covers E-AC-3 Atmos and any 5.1+ AC-3/E-AC-3. The remux is accepted
  only when Plex copies both video and audio. `RemuxHLSLoader` restores the JOC
  flag. The new "Dolby Atmos" toggle (tvOS) and "Dolby Atmos & Spatial Audio"
  toggle (iOS) under Playback Advanced are on by default. The TrueHD fallback
  now remuxes the audio only and keeps 4K/HDR video. `f206afd`, `aa8bed3`.
- **Dolby Vision profile 5** plays through a relabelled video-copy remux on
  AVPlayer (`dvh1` + `dvcC` patch), where it used to dead-end. `05236c5`.
- **Siri, via App Intents only.** "Play/Watch/Resume/Continue *title* in Dusk"
  works through `PlayTitleIntent` and a catalog of 300 titles. "Play something
  in Dusk" and the free-form term go through `PlayInDuskIntent`
  (`PlayVideoIntent`). Titles are fuzzy-matched across all servers, and a show
  plays its On Deck episode. There is no entitlement and no extension.
  Phrases are English only. `541e5df`.
- **Previous/Next Episode in the player.** On iOS it is opt-in (Settings ›
  Episode Buttons, off by default). On tvOS it is always on: Next only, at the
  end of the action row, with a "Next: S2 · E8" tooltip. Skipping marks the
  episode watched only past the credits marker or 90 %. `cd5ddef` (closes #8).
- **Supporter changes.** There is again a single "Dusk Supporter"
  subscription on the 1.6 product IDs, now $2.99/month and $24.99/year (1.6
  charged $1.99/$14.99). There are three new subscriber-only icons: Velvet,
  Emerald and Gilded, for nine alternates in total. Every icon the
  subscription unlocks works only while it is active, and the app reverts to
  the default icon after a lapse. Generous, Legendary and Patron tips keep the
  six classic icons. The Coffee tip unlocks nothing. The prompt now follows a
  repeating schedule (7 days, then 60/120/180-day gaps) instead of the ladder,
  and it still never appears on tvOS. The Supporter page layout was polished
  on iOS and tvOS. `1696ee2`, `bda4e14` + `7b545a4` (icons), `b1b269d`,
  `f4f2814`, `0b1ab6f`, `2181fd0`. The Director's Cut and Front Row tiers
  (`bf0fb5a`) were built and then removed in `1696ee2`, so they never shipped.
  The code and `Dusk.storekit` have no `directorscut` references left.

### Improvements

- Home and library shelves show about 1.5x more items before "Show All": 15
  on iPhone and tvOS (was 10) and 22 on iPad (was 15). `708c1dd`
- **Native look instead of orange.** The global tint is neutral, and
  `AccentColorTV` is gone. Coral was removed from shared components, from every
  screen outside the Supporter page and App Icon picker, from the
  show/season/episode pages and from Up Next. Watched is now a small
  checkmark, and partially watched episodes get a neutral progress bar.
  Settings toggles use the system switch. STYLE.md was rewritten. `4893c3b`,
  `2c4aa44`, `c6741ba`, `3a8f886`, `58fe923`, `6493d02`.
- Home holds its first paint up to 3 s until the multi-server merge settles,
  so the hero no longer jumps in a beat later. `e78b786`
- Pull-to-refresh no longer publishes half-merged results and keeps a
  server's last rows when a request fails. `12fb471`

### Fixes

- TrueHD tracks played silent on VLCKit 3.7.3 because `trhd` was missing from
  the undecodable fourccs. Pre-selection now skips TrueHD/MLP. `96a3204`
- Episodes with an undecodable Plex stream (for example one missing `id`)
  failed completely. That stream is now dropped and logged. Customer report on
  1.6.x. `0603e63`
- The Up Next overlay overflowed the screen on iPhone and iPad (the backdrop
  sized the ZStack). `abc966e`
- tvOS: the screensaver could not start while paused or after playback ended.
  `5b210dd`

### tvOS-specific

- **DuskFont type scale.** It fixes text that was 2–2.7x too large on tvOS,
  and iOS stays byte-identical. The **full-screen Home hero** was added in the
  same change. `a9832ec`
- **Home hero navigation.** Pages are native focus moves with a Play button on
  each page. Down lands on row 1, card 1. A Select hold no longer drops focus
  onto a card. Wrap-around and 7 s rotation are back, and the remote responds
  faster. The "More" hint is centred. `a1b55cb`, `c14bb18`, `e67407d`,
  `037277e`, `e805126`, `5aff1ad`, `b1d43c9`, `5cdc575`, `0ea5d3f`, `35c8427`,
  `f3b2cea`, `b0b7bb7`, `0d06eab`, `73d46c4`, `58fe923`. Many of these
  supersede each other. The current design is `b0b7bb7` + `0d06eab` +
  `73d46c4`, with the `0ea5d3f` Select-hold guard.
- **Native-style play bar.** One remote-input owner and a HUD state machine.
  Click or hold to seek with acceleration, and swipe to scrub with a thumbnail
  preview. The action row sits on the bar. A tabbed info panel (Info,
  Chapters, Audio, Subtitles, Quality, Channel, Speed) replaces the gear menu.
  **Playback speed is new on tvOS.** Swipe scrubbing was slowed down, and the
  marker ticks and the SharePlay button were removed: an Apple TV now only
  joins SharePlay sessions started elsewhere. `afe0d5c`, `f99d8d4`, `2e69906`,
  `cfb9bbc`.
- The Skip Intro chip and the Up Next card and screen were restyled after AVKit
  (white platter, system glass, no coral). The Up Next card no longer
  stretches. `140b156`, `3a8f886`
- **One series page.** The show, season and episode routes all open
  `SeriesDetailView`, with season pills. The per-episode "Download Subtitles"
  button is gone on tvOS (the player still has it). `606474d`
- **Back button.** Back at a tab root goes to Home, and Back on a scrolled
  Home goes to the hero. `4433046`, `372b2cc`
- **Top Shelf** (`DuskTopShelf` appex, App Group `group.com.dusk-player.app`).
  It shows Continue Watching and Up Next as 16:9 tiles with progress and
  `dusk://` deep links, and it is cleared on sign-out and Home switch. The
  extension never talks to Plex. `8bafd87`, `c96c336` (arm64 in the appex
  plist), `f96e20e` (write to `Library/Caches`, the only writable part of the
  App Group container on Apple TV).
- The app icon background is lightened, then darkened halfway back
  (`#18181C` to `#121216`). `f31e7b7`, `3339d8c`

### iOS/iPadOS-specific

- iPad (regular width) gets a near-full-screen cinematic Home hero
  (`HomeCinematicHeroLayout.iPad`), with portrait capped at a square. iPhone
  and compact layouts are unchanged. `58db017`
- Episode buttons are opt-in on iOS (see Features). The Up Next overflow fix
  is listed under Fixes.

### Under the hood

- `scripts/testflight.sh` replaces Xcode Cloud: manual signing, upload and a
  wait for processing, with iOS and tvOS built in parallel. There is an mmux
  TestFlight process. `2d01156`, `bdcf7aa`
- New `DuskTests` and `DuskTests-tvOS` unit-test bundles: supporter
  entitlements and StoreKitTest, the prompt schedule, Siri matching, the idle
  timer and stream decoding. They are wired into the schemes' Test actions.
- Icon generators: `scripts/generate_directors_cut_icons.py` (name left over
  from the dropped tier) and `scripts/generate_tv_icon_background.py`.
- Docs: new `siri.md`. Large updates to `playback.md`, `ui-features.md`,
  `data-and-plex.md`, `supporter.md` and `codebase-map.md`.
- Version bump to 1.7.0. `c444cde`

### Already shipped in 1.6.x (not new in 1.7)

| main | release/1.6 | Shipped in | Change |
| --- | --- | --- | --- |
| `4169bc2` | `a0c24e8` | 1.6.1 | Subtitle size had no effect on VLCKit playback |
| `243d53c` | `33fa2bf` | 1.6.2 | tvOS 27: settings pickers opened a blank screen |

`git cherry` reports both as not patch-equivalent only because the release
commits also bump the version. The subjects and the code changes match.
`release/1.6` has no other commits beyond the merge-base.

## Open / Risky Before Release

Ranked by severity. I fixed nothing, and the only file I changed is this one.

### High

1. **App Store Connect subscription setup is not finished** (`docs/supporter.md` §
   App Store Connect). The sandbox on 2026-10-13 still showed $1.99/$14.99, and
   earlier it had the "Front Row" names at level 2. Before release:
   - Rename both products and set them to level 1.
   - Set $2.99/$24.99 and choose **"Keep current price for existing
     subscribers"**. The increases are +50.3 % and +66.7 %, so otherwise every
     subscriber must consent or is cancelled.
   - Add the DE localizations.
   - Delete or remove from sale `directorscut.*`.
   - Update the subscription review notes, and add review notes for the
     Generous, Legendary and Patron tips.
   - Flatten the IAP review screenshot to JPEG.

   Prices in the app come from StoreKit, so a wrong ASC price shows up as-is.
2. **Icon perks shrink for existing 1.6 supporters.** In 1.6 any supporter
   (`isSupporter`, including a single Coffee tip or a lapsed subscriber)
   unlocked every alternate icon, and the copy said "Supporting unlocks every
   alternate app icon". In 1.7 the first entitlement read reverts the icon to
   the default (`SupporterEntitlements.shouldRevertIcon`) for anyone with no
   active subscription and no Generous-or-higher tip. With no cached
   expiration this happens right away, with iOS's "icon changed" alert. There
   is no grandfathering, which was a deliberate scope decision ("no migration
   logic"). Still, decide on purpose: accept it, grandfather 1.6 supporters
   from the cached `supporterIsSupporter` flag, or mention it. Also note that
   App Review may object to tips (consumables) unlocking permanent icons. The
   documented fallback is a non-consumable, or dropping the perk from tips.
3. **The single-server to multi-server upgrade path has never run on a
   device.** Every 1.6 user goes through it. Pending: a cold-launch restore
   after the update, existing downloads and pending offline watch sync being
   re-keyed to their server, `includeGuids=1` being honoured on `/hubs` and
   continue watching, probe load with many shared servers, a Plex Home profile
   switch mid-connect, a changed network at cold launch, the Plex Web sidebar
   staying intact after reordering with 2+ servers, and the tvOS Server
   Priority screen with a real remote.
4. **The tvOS Home hero is the main screen and went through 15 iterations.**
   The latest design (`b0b7bb7`, `0d06eab`, `73d46c4`) has only been checked
   in a simulator replica. Pending on device: swipes page and never drop
   focus down, down lands smoothly on row 1 card 1, up from the shelves
   returns to the visible page, wrap and rotation, the Select-hold guard,
   Live TV and outage-note first rows, an HDR seam at the hero bottom, and
   hint legibility on bright art.
5. **The tvOS Top Shelf has never worked on a device.** Build 368 showed
   nothing. The fix (`f96e20e`) is not confirmed on hardware, so test it
   with a TestFlight build first. Check that the App Group capability is on
   both App IDs (`com.dusk-player.app`, `com.dusk-player.app.topshelf`) and
   in their App Store profiles. Only the tvOS app uses
   `Dusk-tvOS.entitlements`, which carries `group-session` plus the App
   Group, and iOS signing is unchanged.

### Medium

6. **tvOS play bar.** Its feel constants (`PlayerTVHUDLayout`) are
   simulator guesses, with one round of device tuning in `f99d8d4`. Known
   gaps: **VoiceOver cannot reach the HUD**, an accessibility regression
   against 1.6. Playback speed resets on a quality switch. A horizontal flick
   may also fire an arrow step. Chapters only covers intro and credits.
7. **tvOS can no longer start SharePlay** from the player (`cfb9bbc`), only
   join a session. This is intentional, but it removes a 1.6 capability.
   Release notes don't mention it.
8. **Siri:**
   - Real speech on iPhone has not been tested, for catalog titles or
     non-catalog titles.
   - Signed-in playback picking the right episode has not been tested.
   - Apple TV Siri is entirely unverified, and tvOS builds have no `nlu/`
     assets.
   - Whether a bare "Play X in Dusk" reaches `PlayVideoIntent` is unverified.
   - Phrases are English only.
   - No usage description or entitlement is needed (App Intents only). That
     is confirmed: the Info.plists have no Siri keys.
9. **The Atmos/spatial remux is on by default** and changes the path for many
   MKV files. Atmos output (HDMI receiver, AirPods) needs real hardware. For
   DV5, it is unverified whether real PMS versions keep the RPU NAL units or
   already write `dvcC`. A bitmap subtitle picked mid-session drops to VLCKit.
10. **Privacy label.** Analytics shipped in 1.6 (`814ac6c`) and 1.7 adds no
    events (`AnalyticsEvent.swift` changed only a comment). Confirm the App
    Store Connect label was already moved to Usage Data › Product Interaction
    (Not Linked, Not Tracking). It was owed as of 2026-08-17. The Siri catalog
    (UserDefaults) and the Top Shelf snapshot (App Group caches) stay on the
    device.
11. **The tvOS series page** has only been checked by compiling. Pending:
    focus moving from the hero to the pills to the row, the row scrolling to
    the episode, season swaps without layout jumps, and the Seerr pill. The
    lost tvOS "Download Subtitles" button is intended.
12. **Other device checks pending:**
    - Back from the Search keyboard and from Settings subpages (subpages must
      pop, not jump to Home).
    - The Home first-paint gate: does it feel fast enough, and does the first
      launch after the update still jump?
    - Episode buttons: a mid-episode skip, sessions with downloads only,
      tooltip legibility.
    - Skip chip and Up Next positions with long titles and HDR.
    - The tvOS 27 picker fix on hardware.

### Low

13. **The iPad hero** has only been checked by compiling. Pending: the
    landscape peek amount, the portrait crop, light-mode text, and toolbar
    legibility.
14. **Native-look pass.** Simulator screenshots only. On tvOS, check that
    focused `.glass` buttons are not white-on-white on a real TV.
15. **Dropped undecodable streams.** Closed-caption tracks may disappear from
    the pickers on the server-transcode path. The customer's JSON was never
    obtained.
16. **Alternate icons** have never been applied on a real iPhone or iPad,
    including the three new ones.
17. **The website** says supporter tips unlock the icons
    (`website/index.html` FAQ), but the Coffee tip no longer does. Nothing
    on the site states prices.
18. **Localization.** The app is English only (no `.xcstrings` or `.lproj`).
    `Dusk.storekit` has DE subscription names that must also be entered in
    App Store Connect. Siri phrases are English only.
19. **Code-hygiene grep across the range:**
    - TODO/FIXME/HACK/XXX: none added. The only match is a `mktemp
      ...-XXXXXX` template in `scripts/testflight.sh`.
    - No `print`, `NSLog`, `#if DEBUG` or env-var hooks added.
    - The new `Logger`s mark only server names and error descriptions as
      `.public`.
    - The StoreKit config is attached only to the Run actions, so Release
      builds are unaffected.
    - "Force AVPlayer/VLCKit" in Playback Advanced already existed in 1.6.

## App Store screenshot headlines

Rendered by the private screenshot tooling (see `docs/screenshots.md`); copy
changes happen there and need a re-render. Upload the folders in this order.

### iPhone 6.9" (`screenshots/1.7/iphone-6.9/`, 1320×2868)

iPhone and iPad carry the same six panels in the same order; Apple TV differs
only in panel 4 (no downloads on tvOS).

| File | Raw capture | Headline | Subline |
|---|---|---|---|
| `01-home.png` | `01-home.png` | Your Plex, made native. | Free. No ads, no tracking. |
| `02-library.png` | `02-library-grid.png` | Your whole library. | Every server, one place. |
| `03-formats.png` | `03-formats.png` (audio picker open) | Direct Play. Even Atmos. | Dolby Vision, DTS, TrueHD, no transcoding. |
| `04-downloads.png` | `04-downloads.png` (9 finished downloads) | Take it offline. | Download movies or whole seasons. |
| `05-search.png` | `05-search.png` (query "dragon", Seerr results) | Missing something? Request it. | Seerr results right in Search. |
| `06-up-next.png` | `06-up-next.png` (full-screen Up Next) | The next episode, already playing. | Skip intros, roll into Up Next. |

### iPad 13" (`screenshots/1.7/ipad-13/`, 2752×2064 landscape)

| File | Raw capture | Headline | Subline |
|---|---|---|---|
| `01-home.png` | `01-home-landscape.png` | Your Plex, made native. | Free. No ads, no tracking. |
| `02-library.png` | `02-library-grid-landscape.png` | Your whole library. | Every server, one place. |
| `03-formats.png` | `03-formats-landscape.png` (audio picker open) | Direct Play. Even Atmos. | Dolby Vision, DTS, TrueHD, no transcoding. |
| `04-downloads.png` | `04-downloads-landscape.png` (30 finished downloads, three full rows) | Take it offline. | Download movies or whole seasons. |
| `05-search.png` | `05-search-landscape.png` | Missing something? Request it. | Seerr results right in Search. |
| `06-up-next.png` | `06-up-next-landscape.png` | The next episode, already playing. | Skip intros, roll into Up Next. |

### Apple TV (`screenshots/1.7/appletv/`, 3840×2160)

| File | Raw capture | Headline | Subline |
|---|---|---|---|
| `01-home.png` | `01-home.png` | Your Plex, made native. | Free. No ads, no tracking. |
| `02-library.png` | `02-library-grid.png` | Your whole library. | Every server, one place. |
| `03-formats.png` | `03-formats.png` (Audio tab open) | Direct Play. Even Atmos. | Dolby Vision, DTS, TrueHD, no transcoding. |
| `04-play-bar.png` | `04-scrub.png` (scrubbing with preview) | Click to skip. Hold to scrub. | A play bar that feels like Apple TV. |
| `05-search.png` | `05-search.png` | Missing something? Request it. | Seerr results right in Search. |
| `06-up-next.png` | `06-up-next.png` | The next episode, already playing. | Skip intros, roll into Up Next. |
