# Dusk UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Dusk. Read this with `docs/codebase-map.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `DuskApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, `SeerrService`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`. There is no
  root `.tint`: the global `AccentColor` asset is the label colour, so system
  controls, navigation buttons and the tab bar selection are neutral and adapt
  over both artwork and light content backgrounds.
- `ContentView` is the account-bootstrap root gate: unauthenticated users see
  `SignInView`; signed-in Plex Home accounts are checked and, when needed, show
  `HomeUserPickerView`; an active Home identity enters `MainTabView`. **There is
  no server step in onboarding.**
- Connecting is not a gate. `ServerConnectionCoordinator` (injected into the
  environment by `ContentView`) connects every enabled server in parallel while
  the shell is already on screen; each server's content appears as it answers.
  Keep connection logic there — do not spread `connectAllServers()` calls into
  feature screens; call the coordinator's `refresh()` for a retry instead.
- A connect pass runs on first mount, on a profile switch, on return to the
  foreground, and on a network-path change. Passes are deduplicated and a fresh
  one is skipped for a minute unless the pool has nothing usable.
- Home selection precedes connecting because each Home identity can expose a
  different resource list. A successful switch reconstructs the main shell so
  navigation paths and feature view models cannot retain the previous user's data.
- Server trouble is never a modal or a full-screen blocker. All servers off is a
  distinct empty state; nothing reachable is an inline error with Retry and a way
  into Server Priority; a partial outage is an unobtrusive inline note. Downloads
  stay reachable in every case. A pool that never got as far as producing server
  states (discovery itself failed: no internet, fresh install) shows the same
  inline error once the coordinator's first pass has finished — `unknown` is only
  a spinner while a pass is actually running.
- `MainTabView` owns one `NavigationPath` per tab so tab stacks stay independent.
- Re-selecting the active tab pops that tab to root.
- Available tabs are data-driven: every present and user-visible library type
  (Movies, TV Shows, Videos) plus Live TV when discovered gets its own tab in
  the user's preferred order, and
  Downloads appears only when visible and populated. Library-tab visibility and
  order are local `UserPreferences`; missing preferences preserve the original
  all-visible Movies / TV Shows / Videos / Live TV order.
- Videos ("Other Videos" / clip sections, `PlexLibraryType.video`) only counts as
  present once a section is known to hold items: `LibrariesViewModel` counts each
  video section (`getLibraryItemCount`) and keeps empty or not-yet-counted ones out
  of `libraries`, so an empty section never shows a Videos tab. A failed count shows
  the section; a cancelled one is retried on the next load. Settings › Navigation
  Tabs hides any destination, Videos included.
- iOS/iPadOS use the modern native `Tab` API with SF Symbols and open Search
  from a circular trailing toolbar action on Home and immediately before Browse
  on each library root, leaving Search out of the tab bar. iPadOS keeps every
  remaining destination flat. On iPhone, Home plus the first three visible
  content destinations stay flat and overflow content, Downloads, and Settings
  move into `MoreView` so the tab bar stays at five items. tvOS remains flat
  with a Search tab and no Downloads tab.
- If a preference or availability change crosses the iPhone five-tab limit,
  keep the currently selected flat destination or `MoreView` mounted until the
  user selects another tab. Replacing the active container immediately tears
  down its `NavigationStack` mid-push; defer the new flat/folded layout and clear
  the retired path when leaving it.
- The tvOS tab shell forces monochrome symbols and a label-color tab bar tint
  (`Color.duskTVTabBarTint`: `TextPrimary` in Dark mode, black in Light mode).
  tvOS draws the selected, unfocused item's icon and title in the bar's tint, so
  a dark tint in Dark mode reads as black-on-black; the focused item's contrast
  against the focus plate is handled by the system, not by the tint.
- That tint is pinned on the real `UITabBar`, at launch through the appearance
  proxy and again from the shell on every update (`DuskTVTabBarTintPin`), and a
  zero-size sentinel subview inside the bar re-pins on every `tintColorDidChange`
  UIKit reports. SwiftUI's `.tint` on a tvOS `TabView` is not sticky: a bar that
  falls back to the inherited window tint picks up the global accent color
  after returning from a detail screen or the player. That accent
  (`AccentColor`) is the same label colour, so a fallback looks identical. The
  shell clears the bar's tint off the tab content (`.tint(nil)`): an inherited
  explicit tint makes tvOS system glass buttons go white-on-white on focus.
- tvOS Back (Siri Remote Menu) at a tab root goes to Home, and on Home
  scrolled down it returns focus to the hero; only Home at its top leaves the
  app. `MainTabView.rootBackAction` decides, `DuskTVRootBackInterceptor` (a
  Menu-only tap recognizer on the `UITabBarController`'s view) catches the
  press with focus in the content or on the tab bar. The recognizer refuses
  the press whenever the selected tab has a pushed screen, checked on the real
  `UINavigationController` because Settings rows push with
  `NavigationLink(destination:)`, outside the tab's `NavigationPath`.
  `onExitCommand` cannot do this: it never sees Back with focus on the tab bar.
- `AppNavigationRoute` is the shared route enum. Add new top-level destinations there
  only when multiple features need to navigate to them.
- Use `NavigationLink(value:)` with `AppNavigationRoute` for media/person/library flows.
- Attach `.duskAppNavigationDestinations()` inside each tab `NavigationStack`; it maps
  routes to concrete destination views with environment services.
- Detail routing enters through `MediaDetailDestinationView`, which dispatches by
  `PlexMediaType` and passes download/offline context through.
- Playback presentation is centralized in `MainTabView` through
  `PlaybackCoordinator.showPlayer` and `PlayerView`; feature screens should call
  `playback.play(...)` or `playback.playVersion(...)`, not present the player.

## Shared UI Primitives

- Prefer shared primitives before adding feature-local copies.
- Loading, empty, and retry states belong to `FeatureLoadingView`,
  `FeatureEmptyStateView`, and `FeatureErrorView`.
- `FeatureErrorView` shows Retry for ordinary failures. Messages that mean the
  Plex account session is dead (`PlexServiceError.unauthorized` /
  `.notAuthenticated`) replace Retry with Sign In, which calls `signOut()` so
  `ContentView` presents `SignInView`. Do not add a local retry button for those
  errors. Successful re-auth is a new session; it does not resume the failed
  screen or playback.
- Poster UI is layered: `PosterArtwork`, `PosterCardText`, `PosterCard`,
  `PosterNavigationCard`, and `PosterActionCard`.
- Fully watched items (e.g. fully watched seasons) pass `isWatched` to the poster
  card to add a small checkmark to the subtitle line, in the subtitle's own colour
  (never a colour — a fully watched row must not become a wall of badges);
  suppress the progress bar in that case (pass `progress: nil`) so completion
  reads as the checkmark, not a full bar. A partially watched season passes
  `unwatchedCount` instead: `UnwatchedCountBadge` draws the count as the system
  `N.circle.fill` symbol in the checkmark's slot, at its size and colour (iOS
  season cards and tvOS season pills). Partial progress still renders the bar
  (`DuskPosterMetrics.posterProgressBarHeight`), white on a dark track like the
  TV app, everywhere.
- Use `PlexItemPosterCarouselSection` for horizontal shelves and
  `PlexItemPosterGrid` for grids. They already handle image sizing, context menus,
  progress, and route creation. Both take `imageAspectRatio` (default 2:3); pass
  `16.0/9.0` for clip content so the requested transcode size matches the display
  aspect — a 2:3 request would be cropped server-side.
- Clip rendering is item-driven: `PlexItem.isClip` (item `subtype == "clip"`) and
  the `Collection.isAllClips` helper decide when a row/grid renders 16:9 with
  `DuskPosterMetrics.videoCarouselWidth`/`videoGridPreferredWidth`. Clip card
  subtitles show the full localized upload date and compact duration via the
  clip-aware `standardPosterSubtitle`; uploads from the last week also prefix
  relative context (for example, `2 days ago · 17 Jul 2026 · 12 min`).
- Context menus for partially watched playable items should expose both watch-state
  endpoints: mark watched and mark unwatched. Do not collapse partial progress into
  a single toggle action.
- Use `MediaCarousel` for generic horizontal sections. It renders only the section
  title; it has no header accessory slot, so do not reintroduce buttons beside the
  title. Its horizontal padding can be overridden when a page needs its shelves to
  share the system navigation title's leading edge.
- A shelf's "Show all" destination is `ShowAllCarouselTile`, rendered by
  `PlexItemPosterCarouselSection` / `PlexItemActionCarouselSection` as the **last
  card** of the shelf on **every** platform — a dashed card sized like the shelf's
  artwork (`imageAspectRatio` aware), so the destination reads as content instead of
  a cramped header button. Pass `showAllRoute` only when the shelf is actually
  truncated; a nil route simply omits the tile.
- Use `AdaptivePosterGridLayout.make(...)` for responsive poster grids. Do not hand-roll
  column math in feature files.
- Use `DuskPosterMetrics` for platform-sensitive poster widths, grid spacing,
  horizontal padding, and detail padding. Its `titleFont` / `subtitleFont` are thin
  forwards to `DuskFont.cardTitle` / `DuskFont.cardSubtitle`, so card text is styled
  by the type scale, not by the metrics struct.
- Use `DuskFont` (`Shared/DuskTypography.swift`) for **all** type. tvOS views go
  through `DuskFont` and never use raw semantic text styles (`.headline`, `.title3`,
  `.caption`, …), which resolve 2.1–2.7× larger on tvOS than on iOS. Each token takes
  the call site's current iOS style — `DuskFont.sectionHeader(ios: .title3.bold())` —
  and returns it unchanged off tvOS, so iOS rendering never moves. tvOS-only paths use
  `DuskFont.TV.<token>`; layout structs that store point sizes use
  `DuskFont.TV.Size.<token>`; sites where iOS deliberately applies no font use
  `.duskFont(tvOnly:)`. The full token table lives in `STYLE.md` §3.1.
- Use `MediaTextFormatter` for duration, season/episode labels, counts, progress,
  media type icons, air dates, and playback version labels.
- Use `PlexItemPresentation` helpers for standard poster subtitles, continue-watching
  labels, poster progress, and image URL selection.
- Use `DuskAsyncImage` for Plex artwork. It integrates app image caching and can route
  Plex image requests through `PlexService` when needed.
- Use `DetailHeroBackdrop` with `DuskHeroBackdropOverlay` for full-bleed hero artwork,
  and always apply `duskHeroBackdropBottomFade()` to the backdrop + overlay stack.
  The overlay owns the shared top and leading scrims; the bottom fade into the page
  is platform-split: on iOS the overlay paints a `Color.duskBackground` gradient and
  cap, on tvOS the modifier instead masks the hero to fully transparent so the page
  background underneath is the only fill at the hero boundary. The modifier's style
  picks the tvOS mask curve: `.standard` (the default) for detail heroes, `.compact`
  for a shorter, lighter fade that reveals more of the backdrop, and `.fullBleed` for
  a hero that owns the whole display — it holds full strength to ~86% and only
  vignettes across the last stretch. Every case must still reach, and hold, zero
  alpha before the hero's bottom edge; that is what makes the HDR seam impossible.
  On iOS the overlay's own scrim strength is selectable via its `style`: the iPhone home
  hero keeps the default `.standard`, the regular-width iPad home hero uses `.cinematic`
  (short top band for the status bar/toolbar, nearly clear middle, darkening and the
  `duskBackground` fade held to the lower third), while the movie/show/season/episode detail heroes pass
  `.soft` to hold the darkening and bottom fade off until the lower third so more of the
  backdrop reads through behind the title block. `.standard` and `.soft` differ on iOS
  only — on tvOS both render the long-standing full-strength vertical scrim. The one
  overlay style that changes tvOS is `.cinematic` (0.10 → 0.20@55% → 0.62@82% →
  0.88), used **only** by the home hero (full-screen on tvOS, near-full-screen on iPad) so the artwork stays nearly
  unscrimmed above the title block; the shared leading ramp is unchanged. Do not
  repoint the detail heroes at it.
  Never paint `Color.duskBackground` (gradient or solid) inside a hero subtree on
  tvOS: real Apple TV HDR output resolves hero-subtree fills and the plain page
  background through different color pipelines, so two stacked fills of the same
  color still meet with a visible seam and gray mismatch on hardware even though
  every simulator renders them identically. Fading the hero to zero alpha is the
  only seam-proof topology.
  When a detail hero swaps artwork from focus changes, opt into retaining the previous
  backdrop while the next one loads instead of clearing the image.
- When the iOS Home cinematic hero is visible, keep the tab bar color scheme dark.
  The floating iPad tab bar can sit over hero artwork, so its selected label must
  resolve against the tab bar material instead of the page's light appearance.
- On tvOS, poster, episode, and cast artwork controls should use
  `duskSuppressTVOSButtonChrome()` plus `duskTVOSFocusEffectShape`. Avoid SwiftUI's
  `.plain`, `.borderless`, `.glass`, and `.card` button styles directly here because
  real Apple TV hardware can draw gray/white system focus plates. When a poster card
  has labels below the artwork, keep the artwork as the actual control but apply
  `duskTVOSFocusedScale` to the outer card so the full poster container grows with
  a tight neutral white glow and without gaining a button background.
- Use platform helpers in `View+Platform.swift` instead of scattering `#if os(tvOS)`:
  `duskNavigationTitle`, title display modes, list background/separator suppression,
  status-bar helpers, tvOS button chrome suppression, and tvOS focus effect shape.

## Home

- `HomeView` is the tab root. It owns `HomeViewModel`, handles loading/error state,
  refreshes on appear, scene activation, and player dismissal, then delegates layout to
  `HomeIOSView` or `HomeTVView`.
- The cinematic hero always resets to its first item after player dismissal, app
  activation, Home-tab re-entry, or a change to the hero item order. Keep the explicit
  reset revision flowing from `HomeView` through both platform shells so a Plex refresh
  cannot preserve a stale selection after Continue Watching reorders.
- `HomeViewModel` owns ordinary Plex Home calls. The separate shared
  `LiveTVViewModel` owns the optional, non-blocking Live TV Home shelf.
- `HomeView` keys its load context by the active Plex Home profile and the server
  set it is showing (`serverPriority.revision` plus the connected servers),
  and installs a fresh `HomeViewModel` whenever that context task starts. Keep the
  profile in this identity: Home users commonly share a server ID, and retaining
  the outgoing model can let its in-flight load suppress the incoming user's load.
- Home data combines global hubs from `getHubs()`, continue watching from
  `getContinueWatching()`, and personalized shelves from `HomeRecommendationEngine`.
- Settings › Home › Personalized shelves is a device-local switch, on by default.
  `HomeView` passes it into `HomeViewModel` and applies changes immediately: off
  clears generated shelves, cancels their task and skips recommendation loading
  on subsequent refreshes; on reloads them. Cancellation and a publication guard
  prevent an old request from restoring shelves after they were disabled. Plex
  hubs, Continue Watching, and library-tab recommendations are unaffected.
- `HomeHubArrangement` places library rows in Library Order even when PMS omits
  the hub's section ID: it uses the paging URL, numeric identifier suffix, or
  consistent item section IDs from the representative server. Unscoped Recently
  Added rows can also use the only matching library type on that server. Ambiguous
  rows remain global; mixed/global rows such as Continue Watching keep their place.
- `LiveTVHomeShelf` adds currently airing channels when Live TV is available and
  `UserPreferences.showsLiveTVOnHome` (Settings › Home › Show Live TV, off by
  default) is on. When off, Home neither renders the shelf nor requests the
  now-playing lineup; the Live TV navigation tab is unaffected. Its
  discovery/load failure must not replace or delay normal Home content.
- Home publishes the base hub and continue-watching payload first, then expands
  Recently Added hubs and loads personalized shelves through cancellable follow-up
  tasks. Keep this two-phase behavior so expensive recommendation work does not block
  the first visible home content.
- Continue-watching items drive `HomeCinematicHero` (iOS) and the featured hero
  (tvOS, see "tvOS featured hero" below). **iOS only:** Settings › Home Advanced ›
  Compact Continue Watching (`UserPreferences.compactHomeContinueWatching`, off by
  default) swaps the hero for `HomeContinueWatchingShelf`, the library pages'
  `PlexItemActionCarouselSection` row, as the first shelf, and `HomeIOSView` takes
  its no-hero path (large "Home" title), so nothing is shown twice. tvOS has no such
  setting: its hero already is a row of cards.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated. That rule lives in
  `HomeHubFilter` (`HomeHubFilter.swift`).
- Home's arrangement is fixed and identical on both platforms: the cinematic hero,
  the Live TV shelf (when enabled), the Plex hubs, then the personalized shelves. `HomeIOSView` and
  `HomeTVView` each render that sequence directly. There is no user-editable Home
  layout; do not reintroduce one.
- Home is **merged across every connected server**. `HomeViewModel.load()` fans
  `/hubs` and `/hubs/continueWatching` out to all of them. **The first paint is gated
  by `HomeFirstPaintGate`** (`HomeFirstPaintGate.swift`): painting the first server's
  answer at once made Home jump when a later server brought Continue Watching, and so
  the cinematic hero, along with it. Once there is content, the loading view stays up for a short
  grace (`settleGrace`, 500 ms) so the other servers, including ones the pool is still
  connecting, and the library order can catch up. Only while a server that had
  hero items the last time Home settled (`HomeContinueWatchingMemory`, per profile in
  UserDefaults) is still missing *and* nothing in hand has any does it wait longer.
  Nothing is held past `patience` (3 s from when Home started waiting; the gate
  survives a load superseded by a server connecting). After the first paint, late
  servers fold in as they answer. The memory is a hint: it is rewritten on every
  settled merge, so a server that stops answering stops being waited for. No skeleton
  is shown, on purpose. **Once there is content on screen (a tab return, a
  pull-to-refresh, another server connecting) the merge is published in one go
  instead.** A merge missing the servers that have not answered yet is a *smaller*
  screen than the one already there, and swapping between the two is what made
  pull-to-refresh look like content jumping between servers. The merge (`HubMerge`, `ContinueWatchingMerge`) is a
  pure function of the per-server answers in priority order, so each publish refines the
  same list. With one server both merges return their input verbatim. Every merge
  registers its findings in `plexService.alternates` for playback fallback.
- Initial load, tab return, scene activation, player dismissal and pull-to-refresh all
  go through the **same** `load()`. It bumps `loadGeneration`, supersedes the previous
  load, and runs the work in an unstructured task the view model owns, awaiting only its
  value. That last part is load-bearing: `.refreshable` runs its action in a task SwiftUI
  cancels freely, and a load cut off half way would leave Home on the merge of whichever
  servers answered first — and skip the library-order pass, the Recently Added expansion
  and the personalized shelves. `LibraryRecommendationsViewModel.load()` is built the
  same way for the same reason.
- A server that *fails* a Home request is not a server that answered with nothing.
  `HomeServerPayload` carries `nil` for a failed request and the view model keeps that
  server's previous answer (`lastPayloads`, dropped when the server leaves the pool or
  the Plex Home profile changes), so a timeout during a refresh cannot make one server's
  rows blink out and back.
- Home reloads on `plexService.serverContentRevision` (`.task(id:)`), never on a single
  server identifier: the tab shell mounts before anything is connected.
- Home never labels a row with the server it came from — with every server merged into
  one screen that is noise. The only server wording is `ServerOutageNote`, a quiet line
  naming enabled servers that are currently offline. The old server-name subtitle
  (iPhone) and tvOS header subtitle are gone.
- Within the hubs, `HomeHubArrangement.arrange(hubs:libraryOrder:)` regroups the rows
  so each library's hubs appear in the order the account gives that library.
  `libraryOrder` is a list of **`PlexLibrary.id`** (`"<serverID>|<key>"`), and a row is
  placed by `PlexHub.representativeLibraryID` — its own server, or the highest-priority
  source of a merged row. Never key this on the bare section key: two servers' "3"
  sections would share a block. It is a pure permutation — global rows first, then one
  block per library in library order, then rows whose section is unknown. `libraryOrder`
  must be built from *every* section, including music and photo, or the blocks drift.
- Recently Added hubs are expanded through `PlexService.mergedHubItems(for:size:)`,
  which pages **each contributing server's** hub key and re-merges, so shelf limits are
  intentional and "Show all" (`.hub`) shows the whole merged row rather than the
  primary server's share of it. `PlexHub.isPageable` / `hasMoreOnAnySource` /
  `totalSourceSize` are the merged-row equivalents of `key` / `more` / `size`.
- TV Recently Added rows hold seasons and episodes, not just shows: a new episode in an
  old show arrives as that season (or episode). Poster cards (`PlexItemPosterCarouselSection`,
  `PlexItemPosterGrid`) title them by their show (`PlexItem.posterCardTitle`) with the
  numbering underneath (`hubPosterSubtitle` on Home: "Season 6", "S6 · E3"), and a
  season whose own poster fails to load falls back to the show's (`fallbackPosterPath`
  → `DuskAsyncImage(fallbackURL:)`): Plex can send a season poster path even when the
  season has none (unconfirmed against a real PMS; the show poster also covers any other failure). Home keeps one card per show in Recently Added (`oneCardPerShow`).
- `HomeCinematicHero` (iOS only since the tvOS featured hero; its tvOS paging code is
  no longer reached) owns hero rotation, drag navigation on iOS, image preloading, title-logo fallback, pager state, and motion
  reduction. iOS enables automatic rotation (`autoRotates: true`): the hero advances
  every 7s and the pager pills animate a fill that tracks the timer. The hero pauses
  rotation while `PlaybackCoordinator.showPlayer` is true and restarts it fresh on
  return, so opening the player no longer advances the hero in the background.
  Rotation also respects Reduce Motion, scene phase, and drag interaction.
  The hero is Home's only Continue Watching surface (iOS shows every item, tvOS
  caps at 10), so the pager is a `UIPageControl`-style sliding window
  (`HomeHeroPagerWindow`): at most `pagerMaxVisibleItems` pills (iPhone 7,
  iPad 9, tvOS 10), the current one centred, the outer two shrunk on a side with
  more items beyond. On iOS it is one adjustable accessibility element. The
  pager is an `.overlay` of the hero so it can never size it: as a `ZStack`
  sibling, one pill per item once widened the hero past the screen.
  On iOS discrete hero moves use the two-slot slide
  model: mount the incoming slide at its off-screen offset before advancing
  animation progress, and queue overlapping moves behind the in-flight slide.
  Backdrops are decoded off the main thread (`byPreparingForDisplay`) during
  prefetch so the first frame of a page never stalls on a JPEG decode. Publish
  prefetched artwork as each request completes; waiting for the entire batch lets
  one slow image make other pages pop in late. Extend it carefully; it is stateful
  and timing-sensitive.
- On iPad (regular width) the home hero uses `HomeCinematicHeroLayout.iPad`: it fills
  the scroll viewport down to the bottom inset (`heroHeightFactor: 1`), so at rest only
  the first shelf's header and poster tops peek in below it — that peek is iPad's
  scroll affordance. Portrait is capped at a square (`maxHeightToWidthRatio: 1`) so a
  16:9 backdrop isn't cropped to a sliver. iPhone and compact-width iPad multitasking
  keep `.ios`. `HomeIOSView.heroLayout` makes the choice.
- **tvOS featured hero** (`TVFeaturedHeroPage`, `Shared/TVFeaturedHero.swift`), shared
  by Home (Continue Watching, `HomeViewModel.heroItems()`, capped at 10) and the
  Movies / TV Shows Recommended pages (their Continue Watching minus clips, capped at
  10, which then drops the page's own Continue Watching row; the Videos page keeps its
  row and has no hero). It works like the Apple TV app: the artwork fills the display,
  the title (clear logo, else text), metadata and a three-line summary sit on the left,
  and a row of small 16:9 cards below holds the items. **Focus on a card cross-fades
  the artwork and text to it** (0.4s); selecting a card plays it (the page's own `play`,
  the same resume behaviour the old Play button had). There is no Play button, no
  rotation, no "More" hint.
  - The card row is an ordinary row of focusable cards (`.focused` on each card's
    button by `storageKey`, system card focus effect). Every move in and out of the
    hero is the focus engine's own geometric move between rows, like between any two
    shelves; nothing overrules, fences or lands focus. **No `.focusSection()` on the
    hero or the shelves stack**: a move into a section is steered towards its middle,
    and from the card row that landed on the fourth shelf (simulator). Only the
    accessory row (the library pages' Browse / Library Order buttons, top left under the
    tab bar) is a full-width focus section, so up from any card reaches it.
  - The page has two stops: the full hero, or the first shelf at the top of the display.
    `TVFeaturedHeroFoldSnapping` bends the engine's reveal scroll there (Apple's
    fold-snapping pattern): from the hero any real scroll goes to the fold; from below,
    a target that would show a good part of the hero (< 85% of the fold) goes to the
    top, anything else stays at the fold. **Never add a programmatic scroll on a focus
    change the engine made**: the two stack (that threw the old hero's down-press rows
    past the first shelf). A settle check 200ms after the page stops (card focused →
    top; otherwise never on a sliver of hero) is a safety net only.
  - The hero is full-bleed: the scroll view ignores the top safe area while there is a
    hero, so content y = scroll offset; the hero is offset by the leading safe-area
    inset and sized from the screen bounds. Text is pinned to the dark scheme (the
    scrim is dark in both appearances); the artwork uses `DuskHeroBackdropOverlay(.cinematic)`
    plus `duskHeroBackdropBottomFade(.fullBleed)` and standard dynamic range against
    the HDR seam.
  - Every item's backdrop (screen size, `byPreparingForDisplay`) and clear logo are
    prefetched up front, the selected one first. The artwork on screen trails the
    selection until the new one has decoded, so a cross-fade never passes through an
    empty frame; an item without artwork fades to the plain page.
  - Home claims focus for the selected card once, on first appearance; library pages
    leave it to the tab bar (down from the tab bar lands on the nearest card).
    `selectionResetRevision` (playback over, app active, Home reselected) goes back to
    the first item; `focusRequestRevision` (Home's Back press while scrolled down)
    focuses the selected card and the engine scrolls the page up.
  - The shelves stack is a plain `VStack` on tvOS (Home and library pages): the first
    shelf starts right at the fold and must exist when down is pressed. Its top padding
    (`max(safeAreaTop, 60) + 24`) keeps the first header clear of the tab bar at the fold.
- On iOS the home hero play button uses `homeHeroNativeButtonStyle()` (prominent,
  `Color.primary`-tinted Liquid Glass that contrasts the artwork) with
  `HomeHeroActionButtonLabel(fillsWidth: true)`, sized as a wide, short pill
  (≈240pt iPhone / ≈300pt iPad). Keep it consistent with the detail primary button
  (`STYLE.md` §3.3); never a coloured fill.
- `HomeIOSView` and `HomeTVView` should stay composition shells. Keep Plex data rules in
  `HomeViewModel`, not in platform views.
- Use `HomeItemContextMenu` for hero context actions. It already exposes mark watched,
  details, season, and show routes when available (on tvOS `contextMenuSeasonRoute` /
  `contextMenuShowRoute` are nil, because the details route already opens the one
  show page). Its optional
  `onRemoveFromContinueWatching` adds Plex's "Remove from Continue Watching" action
  (server `PUT /actions/removeFromContinueWatching`); the hero supplies it because its
  items are always the Continue Watching hub. `HomeViewModel.removeFromContinueWatching`
  drops the item optimistically, then reloads to reconcile.
- `HomeHubItemsView` is the full "show all" grid for hub contents. It has its own small
  view model and uses the shared poster grid; all-clip hubs render it 16:9.

### Server Priority

- `Settings › Navigation › Server Priority` opens `ServerPrioritySettingsView` on
  every platform. It answers two questions and nothing else: in which order the
  servers rank, and which of them Dusk uses at all.
- Each row shows the server name, its ownership ("Your server" / "Shared by X"),
  and its live status from `pool.state(for:)` — Local, Remote, Relay, Connecting…,
  Offline, Not authorized, Disabled. The words come from `ServerStatusText` so the
  rest of the app says the same thing.
- Every edit is written immediately through `ServerPriorityStore`; there is no
  save step and nothing to lose by leaving. Enabling a server reconnects it
  straight away (the row reads "Connecting…" until it resolves); disabling calls
  `pool.markDisabled`, which drops the session so the rest of the app forgets that
  server. Both bump `serverPriority.revision`, which Home, Libraries, and Search
  observe to reload.
- "Check Again" re-runs the whole connect pass through
  `ServerConnectionCoordinator.refresh()` — use it after bringing a server online
  or accepting a new share.
- Disabling the last enabled server is allowed but never silent: the screen shows
  what it costs ("Dusk has nothing to show; downloads still play"). Do not replace
  this with a blocking alert — the user may be deliberately going offline-only.
- A single-server account sees a plain one-row screen: no reorder affordances, no
  talk of priority. Ordering language only appears once there are two servers.
- iOS/iPadOS use `EditButton` + `onMove` plus a per-row toggle; tvOS gives each
  server its own section with a position menu and a "Use This Server" toggle. The
  same tvOS rule as Library Order applies: **no focus-driven drag**.
- The visible rows are not the stored list — a server that has gone missing keeps
  its slot in `ServerPriorityStore`. Reordering therefore goes through
  `reorder(visible:)`, which re-applies the new order to the visible slots only.

### Library Order

- `LibraryOrderSettingsView` (route `.libraryOrder`) is reached from the library tabs,
  not Settings: iOS has an `arrow.up.arrow.down` toolbar button on each tab's landing
  screen and the library list; tvOS has a "Library Order" glass button in the browse
  row (recommendations), the chip row (All landing) and atop the library list. It
  edits the order of *your* libraries across every enabled server, and which of them
  are hidden (`pinnedSources[].isHidden`; hidden ones drop out of `LibrariesViewModel`,
  not Home). Both are an
  account-level Plex setting rather than a Dusk preference: the same order drives the
  Plex Web sidebar and the other Plex apps signed in as this user.
- A row carries its server name only when another library of the same type has the
  same title. The server name disambiguates; it is never decoration.
- The screen lists **every** section, music included, even
  though Dusk cannot browse it. They occupy slots in the account's order, so
  omitting them would silently move them when the list is written back.
- iOS/iPadOS use native list editing (`EditButton` + `onMove`). tvOS uses a position
  menu per row (`TVSettingsMenuRow`), the same pattern as Navigation Tabs, with
  formatted ordinal labels so the list is not capped at a handful of names.
  **The previous focus-driven pick-up (the old Home layout editor) was removed and
  must not come back.** It was unusable on a real remote: directional commands only
  reach an `onMoveCommand` handler when the focus engine finds no candidate, and the
  tvOS tab bar sits above this screen, so a row moved down but not up.
- Writes are debounced 1s and coalesced, so walking a library through six slots is one
  account write, not six. `onDisappear` flushes a debounce that is still counting down.
- A failed write reverts the list to `PlexService.libraryOrder.orderedSections` and
  shows an inline message; showing the rejected order would lie about what the other
  Plex apps will do. A failed load shows `FeatureErrorView` with Retry.
- The order is read and written through `PlexService`; the view model never talks to
  plex.tv itself. Entries for disabled servers, cloud providers, and servers whose
  sections failed to load are carried through untouched — never write an order for a
  server Dusk could not read. Storage format and traps: `docs/data-and-plex.md`.
- Clips never enter the cinematic hero rotation (`HomeViewModel.heroItems()` filters
  `isClip` — frame grabs read poorly full-bleed). They stay visible in hub rows, where
  an all-clip hub (`isVideoHub`) renders as a 16:9 carousel.

## tvOS Top Shelf

- The `DuskTopShelf` app extension (tvOS only, bundle id
  `com.dusk-player.app.topshelf`) shows Continue Watching in the Top Shelf when
  Dusk sits in the Home Screen's top row: sectioned content, 16:9 tiles, one
  "Continue Watching" section that is Home's merged list as-is (started items
  with progress and next episodes mixed, `ContinueWatchingMerge` order), at
  most 10 items. No separate "Up Next" section; the app never splits them.
- **The extension never talks to Plex.** `TopShelfPublisher`
  (`Dusk/Sources/TopShelf/`) is called from `HomeViewModel.publish` on every
  Continue Watching publish; it caches each tile's artwork with the app's own
  session and writes `TopShelfSnapshot` (titles, artwork file names, deep links)
  into the App Group `group.com.dusk-player.app`, then calls
  `TVTopShelfContentProvider.topShelfContentDidChange()`. The extension only
  reads that snapshot (`TopShelfSnapshot.swift` is compiled into both). No
  snapshot → the static Top Shelf image.
- `PlexService.tearDownServerSessions` clears the snapshot (sign-out, Plex Home
  switch): the shelf must never show another identity's items.
- Deep links: `dusk://play?server=…&item=…&type=…[&clip=1]` resumes,
  `dusk://open?…` opens the detail page on Home. `DuskApp` hands the URL to
  `TopShelfLinkRouter`; `MainTabView` acts on it once the item's server is
  connected (a cold launch delivers it first) and drops it after 30 s. Play
  re-reads the server's `viewOffset` instead of trusting the snapshot.
- iOS is untouched: everything is `#if os(tvOS)`, the URL scheme is only in
  `Info-tvOS.plist`, and only the tvOS app uses `Dusk-tvOS.entitlements` (App
  Group added); iOS keeps `Dusk.entitlements`.

## Libraries

- `LibrariesViewModel` groups Plex libraries by `PlexLibraryType`. Its `libraries`
  reads through `PlexService.libraryOrder.orderedSections`, which now spans **every
  connected server** in the account's cross-server order, not raw `/library/sections`
  order. Libraries are never merged into virtual ones: two servers' "Movies" sections
  hold different files and page independently, so they stay two rows.
- A library shows its server name **only** when another library of the same type has
  the same title (`ServerLabeling`, shared with the Library Order settings screen). A
  single-server account never sees one.
- `MainTabView` reuses a single `LibrariesViewModel` to decide tabs and feed library
  screens, and reloads it on `plexService.serverContentRevision` because the available
  tabs derive from the merged library list. Avoid each tab independently discovering
  libraries.
- `LibrariesView` is the direct Movies/Shows/Videos/Photos tab wrapper (Photos: see
  "Photos" below). Where the tab lands
  is Settings › Navigation › **Libraries Open To** (`UserPreferences.libraryLandingPage`,
  device-local):
  - **Recommended** (default): `LibraryRecommendationsView` for **all** libraries of
    that type. Browse reaches every library's grid in one step: on tvOS a leading row
    of glass buttons ("All Movies", one per library, then "Libraries" when there are
    several, then "Library Order") sits under the tab bar, at the top of the featured
    hero when there is one (one press up from its cards) and first in the page otherwise;
    on iOS a toolbar link with one library, or a Browse menu (each library's grid, then
    "Libraries") with several. "Libraries" opens `LibraryTypeListView` for
    per-library recommendations. The menu pushes by appending to the tab's
    `NavigationPath`, never via `navigationDestination(item:/isPresented:)`: a
    screen pushed outside the path is dropped when anything on it appends to the
    path, so a poster tapped in the grid bounced straight back to the grid.
  - **All (A–Z)**: one library opens straight on its `LibraryItemsView` grid, with a
    "Recommended" link (iOS toolbar, tvOS last chip) back to its recommendations;
    several open on `LibraryTypeListView`, whose rows then open grids.
  The list's rows follow the same setting. (The old combined `LibrariesHubView` tab
  is retired; every type gets its own tab.)
- `LibraryRecommendationsViewModel` takes `libraries: [PlexLibrary]` and is the
  library-scoped home equivalent: `getLibraryHubs(...)` per library (fanned out, each
  routed to its own server), `HubMerge` across them, continue-watching hub extraction,
  recently-added expansion, and personalized shelves from `LibraryRecommendationEngine`
  merged per genre (`LibraryRecommendationLoadResult.merging`). A merged personalized
  row has no "Show All" because no single library list is behind it.
- **Large libraries (tens of thousands of titles).** On a big PMS every section query
  (`/all` with a sort or filter, counts, `/hubs/sections`) costs the server a walk of the
  whole section however small the page, and the database is the bottleneck. So the
  screen is two-phase: the hub rows (Continue Watching, Recently Added, …) paint as
  soon as `/hubs/sections` answers, and only *then* do the personalized shelves start
  (genre counts, candidate pages, history); they are animated in below when ready.
  Never fold the shelves back into the first paint — that is what kept a 60k-title
  library on a spinner for minutes. Inside the engine, taste-signal metadata and the
  genre pools load concurrently, libraries of a type tab load three at a time, and
  Recently Added is only re-fetched when the hub came back shorter than the row. The
  last rows per profile + library set are kept in memory
  (`LibraryRecommendationsSnapshot`), so a rebuilt screen paints at once and refreshes
  underneath. Reproduce with a mock PMS that synthesizes the library and charges a
  per-row scan cost per section query (see `docs/development-workflow.md`).
- A failing server never blanks the others: the sections load commits per server and
  only throws when every server failed.
- `.video` libraries never run the genre engine. Their shelves come from
  `LibraryVideoShelfLoader`: per-channel rows (first ~6 collections via
  `getLibraryCollections`, items sorted by release date) and a day-seeded
  "Rediscover" row of unwatched items. Row order: Continue Watching, prioritized
  hubs, secondary hubs, channel rows, Rediscover — all 16:9.
- `LibraryItemsView` is the browse grid for a concrete library, genre, or collection
  route; `.video` libraries use the 16:9 grid metrics.
- `LibraryItemsViewModel` handles pagination, sort, genre selection, local genre
  matching as a last resort, and optional collection scoping (`LibraryCollectionItemsView`
  delegates to it). Paging is server-side (`X-Plex-Container-Start/Size`, sort and
  filters as query parameters): a 50-item first page, then 100-item pages prefetched
  half a page before the end. Without a preselected genre the first page does not wait
  for the genre list. A genre handed in from a recommendation row is resolved to the
  server's own filter value (`LibraryGenreSupport.serverOption`, by value or title);
  only a genre the server has no filter for is matched locally, on the listing's tags,
  scanning at most 10 × 200 titles per grid page from a resumable offset — never the
  whole library, never per-item metadata requests. Sort options are per-kind via `LibrarySortOption.options(for:)`;
  video libraries default to Release Date (newest).
- Use `LibraryGenreSupport` for Plex genre filter discovery, normalization, URL
  parameter extraction, and fallback matching. Do not compare genre strings ad hoc.
- The grid's sort is remembered per library (`LibrarySortStore`, keyed on
  `PlexLibrary.id`; a sort the type no longer offers falls back to its default).
- The grid's **Unwatched** chip (between Genre and Sort) is a one-tap filter, remembered
  per library (`LibraryUnwatchedFilterStore`, keyed on `PlexLibrary.id`) and applied to
  that library's genre and collection grids too. `LibraryUnwatchedFilter` sends
  `unwatched=1` for movie/video sections (in-progress titles stay) and
  `unwatchedLeaves=1` for shows (listed while any episode is unwatched). Active = inverted
  `TextPrimary` fill with a filled checkmark (STYLE.md selected treatment).
- `LibraryItemsViewModel` uses a `queryGeneration` guard so stale async page loads do
  not mutate current results. Preserve this pattern when adding filters.
- Infinite scroll is triggered from `PlexItemPosterGrid.onItemAppear`; keep pagination
  logic in the view model.

### Photos

- Plex `photo` sections are `PlexLibraryType.photo` (Photos tab, hideable/reorderable
  in Navigation Tabs like the others). Like "Other Videos", a photo section stays out
  of `LibrariesViewModel.libraries` until `getLibraryItemCount` says it holds
  something, so an empty one never adds a tab. Permissions need nothing extra: the
  sections come through the same per-server, per-profile session as every library,
  so a managed user only sees the photo libraries shared with them.
- No recommendations: one photo library opens straight on `PhotoBrowserView`, several
  on `LibraryTypeListView` (rows always open the grid, whatever Libraries Open To says).
  `.library(photoLibrary)` and `.photoAlbum(PhotoAlbumRoute)` both land on
  `PhotoBrowserView`.
- `PhotoBrowserViewModel` walks a list of paged queries (`PlexPhotoQuery`): a library
  root in **Albums** mode lists its root albums and then its loose photos, an album
  its sub-albums then its photos and clips, and **Timeline** (root only, remembered per
  library) is every photo and clip, newest first. 60 rows first, then 150 per page as
  the grid (or the viewer) nears the end. Nothing walks the whole library.
- Grid: album cards (composite artwork, title) above a tight square grid of photos;
  clips carry a play glyph and duration and play straight away through
  `PlaybackCoordinator.play` (they are ordinary Plex `clip` items).
- `PhotoViewerView` is a full-screen cover over the grid's loaded `media`:
  - iOS/iPadOS: horizontal paging `ScrollView` (`scrollPosition(id:)`), each photo in a
    `UIScrollView` (`PhotoZoomScrollView`) for pinch / double-tap zoom; paging is off
    while zoomed. Tap toggles the chrome (close, "n of m", date / place / camera).
    Left/right arrow keys page, Escape closes.
  - tvOS: left/right on the remote steps with a cross-fade, Select toggles the info,
    Play/Pause toggles a 5 s slideshow (clips skipped, idle timer off while it runs).
    The grid has a glass **Slideshow** button, and Play/Pause on a focused photo starts
    the slideshow from it.
  - A clip page shows its frame with a play button. Playing it closes the viewer and
    the grid starts playback in the cover's `onDismiss`, because the player is itself
    a full-screen cover of the tab shell and cannot present over another cover.
- Images: grid tiles use the item's `thumb` through `imageURL` (square, `minSize=1`
  crop). The viewer shows that cached thumbnail first, then
  `photoDisplayURL(for:width:height:)`: the original **Part** through
  `/photo/:/transcode` fitted inside the screen's long edge (no `minSize`, so portrait
  photos are not oversized), which also applies EXIF rotation and converts HEIC. Clips
  have no transcodable original and keep their thumb. Neighbours are prefetched.
- Reproduce with `scripts/mock_large_plex.py --photos 5000` (see
  `docs/development-workflow.md`); screenshot hooks: `-DuskScreenshotScreen photos`,
  `-DuskScreenshotPhotoAlbum <ratingKey>:<title>`, `-DuskScreenshotPhotoViewer <n>`,
  `-DuskScreenshotPhotoSlideshow YES`.

## Detail Screens

- Detail entry is split by domain: movie, show, season, episode, video (clip), and
  actor detail views each have their own `@Observable` model. tvOS is the exception
  for TV content: it has no separate show/season/episode screens. `MediaDetailDestinationView`
  sends all three routes to `SeriesDetailView`, and `ShowDetailView`, `SeasonDetailView`,
  `EpisodeDetailView` (+ its model) are compiled out of tvOS (`#if !os(tvOS)`).
- Clips route to `VideoDetailView` via `.video`/`.downloadedVideo` routes
  (`AppNavigationRoute.destination(for:)` branches on `item.isClip`) — never to
  `MovieDetailView`. It is a trimmed movie page: hero metadata line is
  "channel · upload date · duration", no cast/ratings sections, plus a
  "More from {channel}" 16:9 row resolved from the item's first Collection tag.
- Detail views own screen layout; detail view models own Plex fetches, offline fallback,
  watch-state mutations, image URL selection, and computed display state.
- Shared detail UI lives in `DetailSharedViews.swift` only when reused across detail
  screens.
- Use `DetailHeroSection` for cinematic detail headers. It owns the backdrop
  gradient/scrim, title artwork, supertitle/subtitle/action slots, an optional
  `descriptionText`, and safe-area offset. There is **no poster on any platform**:
  iPhone centers one column (title, metadata, actions); iPad uses two columns
  (left: title + actions, right: marker/metadata + `descriptionText`); tvOS is a
  left-aligned column with the action row beneath. Use
  `detailHeroContentAlignment(for:)` / `detailHeroTextAlignment(for:)` to center
  hero text on iPhone, and `detailShowsSynopsisBelowHero(for:)` to drop the
  below-hero synopsis section on iPad (the hero's right column shows it there).
- Detail hero actions share one button system across all platforms (see
  `STYLE.md` §3.3). The primary uses `detailHeroNativePrimaryButtonStyle()` —
  prominent, `Color.primary`-tinted Liquid Glass for contrast (dark-on-light /
  light-on-dark) with a `Color.duskPrimaryActionLabel` label; on Show/Season it
  reads just "Play" / "Resume" (`playButtonShortLabel`), never the target episode.
  Secondary actions (download, watched, go-to-show/season) are **icon-only**
  everywhere via `DetailHeroSecondaryIconLabel` + `detailHeroNativeSecondaryButtonStyle()`
  with an `.accessibilityLabel` (capsule pills on iOS, circles on tvOS). On iOS wrap
  the action block in `detailHeroActionStackFrame(isCompactPhone:)` (iPhone ≈60%
  centered, iPad fills the hero's left column); tvOS lays the icons out to the right
  of the primary. Movie/Show/Season/Episode all expose a watched toggle; Show/Season
  toggle the whole show/season. Never fill or tint primary actions with a colour.
- On tvOS, keep focusable detail rows in separate `.focusSection()` groups. Hero
  actions, expandable summaries, season/episode grids, and cast shelves should move
  vertically to the next visible row instead of letting the focus engine skip to a
  lower but more horizontally aligned item.
- Detail screens use hidden inline navigation bars over hero artwork. Keep
  `.toolbarColorScheme(.dark, for: .navigationBar)` and hidden toolbar backgrounds unless
  the screen is no longer hero-led.
- Detail screens refresh after player dismissal and scene activation to pick up watch
  progress.
- `MovieDetailViewModel` handles movie metadata, media info, resume position, watched
  state, and offline movie metadata banners.
- `ShowDetailViewModel` loads show details, seasons, next-episode metadata, season
  availability badges, and show-level offline messaging.
- `SeasonDetailViewModel` loads season details and episodes, computes the next episode,
  sorts offline-available episodes first when appropriate, and records offline watch
  mutations.
- `SeriesDetailView` (tvOS only) is the one page per show. `SeriesDetailViewModel`
  composes a `ShowDetailViewModel` (seasons, Seerr gaps, show watch state) with a
  `SeasonDetailViewModel` for the season on screen; it does not re-implement either.
  The route decides where it opens: a show opens on its first regular season with
  something unwatched (Specials only when nothing else exists), a season on itself,
  and an episode on its season with that episode in the banner and the row scrolled
  to it. For season/episode routes the season paints first and the show (pills)
  loads after it; the pills share a fixed-height slot with the plain "Episodes"
  header so the row never jumps. Season pills sit above the horizontal episode row
  (only when there are 2+ seasons); picking one loads that season and swaps it in
  only once loaded (the row dims meanwhile), so the page never blanks. A Seerr-only
  season pill opens its request page. Hero buttons and season pills are system
  `.glass` with no tint (the selected season is
  bold and full-opacity, the rest dimmed, so it never looks focused), and
  progress bars are neutral. Each episode card shows the title with a
  "Season X · Episode N" subtitle plus a quiet watched checkmark
  (`PosterCardText`); the
  hero's clear-logo title, focused-episode name/metadata/summary, backdrop, and the
  "Episode Cast" row follow the focused card inside stable-height regions, with the
  focus commit debounced so rapid remote navigation does not shift the scroll
  position. Selecting a card, or the hero Play/Resume, plays the focused episode;
  the eye button toggles the season on screen. The row is only scrolled
  programmatically when the season changes — never on focus or next-up changes.
- `SeasonDetailView` (iOS/iPadOS) keeps the vertical episode list with per-episode
  detail navigation.
- `EpisodeDetailViewModel` (iOS/iPadOS) handles single-episode metadata, parent
  show/season links, watch toggles, and offline availability.
- `ActorDetailViewModel` loads a person plus filmography by searching Plex for exact role
  matches. Keep this search behavior local to actor detail unless Plex gets a stronger
  people endpoint.
- Use `PlayVersionContextMenu` for alternate media versions; it filters out unplayable
  versions with no parts.
- "Download Subtitles" (Plex-proxied OpenSubtitles) is a secondary action on movie,
  episode (iOS/iPadOS only — tvOS has no episode page; the player covers it), and
  video detail. iOS/iPadOS put it in the Play button's `.contextMenu`
  next to Play Version; tvOS gets a `captions.bubble` icon button in the hero action
  row, because context menus are awkward there. It is gated on
  `<Model>.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)` (owner of
  *that item's* server,
  non-restricted Home user; anything else would 403) plus a real playable part and
  no cached/offline metadata. The detail models own the flow
  (`makeSubtitleSearchViewModel(preferredLanguageCode:)`), so the views never touch
  `PlexService`; a successful install re-reads the item so the new stream shows up in
  media info, and the next playback session mounts it. Presentation goes through
  `detailSubtitleSearchPresentation(isPresented:viewModel:)` (sheet on iOS, full-screen
  cover on tvOS).
- Use `DownloadActionButton` and `DownloadContextMenuContent` from the downloads
  feature for download actions. Do not duplicate download state UI in detail screens.
- Offline-capable detail models may show cached metadata before network refresh. Preserve
  `isUsingCachedData`, offline-fallback state, `offlineStateVersion`, and
  `OfflinePlaybackSyncManager` checks when changing watched/progress behavior.
- Some show/season loading is intentionally sequential to avoid async-let runtime aborts
  during transient context-menu navigation lifetimes. Do not "optimize" it back to
  `async let` without reproducing that scenario.

## Live TV

- `MainTabView` owns one shared `LiveTVViewModel` for availability, the tab,
  `MoreView`, and the Home shelf. Do not discover providers independently per
  surface.
- `LiveTVView` offers yesterday through seven days ahead, channel/program
  artwork, current-program progress, schedule details, and Watch actions only
  for currently airing programs. Past entries remain inspectable but are not
  presented as recordings.
- The player gear menu exposes channel switching on iOS/iPadOS and tvOS. The
  live seek bar shows LIVE or the time behind live and provides Go Live; all
  forward movement is clamped to the HLS edge.

## Search And Settings

- `SearchView` is a thin tab-root wrapper (`NavigationStack` + destinations) around
  `SearchRootContent`, which owns the view model, searchable field, and results; the
  split lets iPhone/iPad toolbar actions push Search without a nested stack.
  Settings and Downloads follow the same wrapper/`*RootContent` pattern.
  All-clip result groups render 16:9.
- Search is debounced in the view model with a cancellable `Task`; views only bind the
  query and render grouped results.
- Search is **fanned out to every connected server** (`PlexService.streamSearch`) and the
  merged groups are republished as each server answers (`SearchMerge`), so results stream
  in instead of waiting for the slowest server. Groups are matched on their type, items
  deduplicated by content key and round-robin interleaved in priority order, and the
  copies registered in `plexService.alternates`. It is an error **only** when every
  server failed and there is nothing to show; one unreachable server shows
  `ServerOutageNote` above the results. A server connecting or dropping re-runs the
  current query (`.task(id: serverContentRevision)`).
- `SearchMediaResult.id` carries the server (`PlexItemID.storageKey`): merged results can
  hold the same rating key twice, and duplicate `ForEach` ids drop rows.
- When Seerr is connected, search also performs an additive Seerr discovery
  request. Plex groups publish first; external movies/shows are deduplicated and
  appended with request-state badges. A Seerr failure stays silent and never
  breaks Plex search.
- Presentation is platform-adaptive so search feels native everywhere. tvOS and iPad
  (`userInterfaceIdiom == .pad`) render each result group as a
  `PlexItemPosterCarouselSection` (the same poster carousels Home uses for hubs); iPhone
  renders each group as a titled `PlexItemPosterGrid` section (matching the library grid).
  Plex `/hubs/search` returns one hub per media type, which maps cleanly onto a carousel
  row or a grid section.
- All platforms reuse the shared `FeatureStateViews` for empty/loading/error/no-result
  states through one `searchResults(_:content:)` wrapper, so state reporting stays uniform.
- Search results route through `AppNavigationRoute.destination(for:)` so people, movies,
  shows, seasons, and episodes stay consistent with the rest of the app.
- Seerr cards instead use dedicated request-only routes. Never put them through
  Plex detail routes, playback, downloads, or watch-state actions.
- `SettingsView` selects the platform shell. Shared sheet/navigation chrome is in
  `SettingsContainer`.
- The Integrations section links to `SeerrSettingsView`. Both platforms accept
  only a server URL and connect using the active Plex identity; tvOS uses native
  keyboard/Remote input rather than a browser login.
- `SettingsViewModel` is for transient settings UI state: Home-user picker
  presentation, image cache status, and app version. Server state belongs to
  `ServerPrioritySettingsViewModel`.
- Persistent settings live in `UserPreferences`, not `SettingsViewModel`.
- Settings → Navigation holds three ordering screens, deliberately different in
  scope. Navigation Tabs controls the visibility and order of Movies, TV Shows,
  Videos, and Live TV; it is device-local `UserPreferences`. Library Order controls
  the order of your individual libraries across servers; it is stored on the Plex
  account (see "Library Order"). Server Priority controls which servers Dusk uses
  at all and which one wins for a title that exists on several; it is device-local
  (see "Server Priority"). All three use native list editing on iOS/iPadOS and
  position menus on tvOS.
- For Navigation Tabs, hidden types stay in the saved order so restoring one puts it
  back where the user placed it.
- `UserPreferences` is `@Observable`, environment-injected, and backed by `UserDefaults`.
  Add new device-local user-facing preferences there with a key, default loading, and
  persistence. A setting Plex already models for the account belongs in `PlexService`
  instead, like library order.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in `UserPreferences`; do not
  bypass those setters.
- `videoEnhancementMode` is a persisted playback preference with Auto, On, and
  Off settings. It affects local rendering only, must not request Plex
  transcoding, and must not alter startup quality. Its per-platform default
  lives in `VideoEnhancementMode.defaultForPlatform` — Auto on Apple TV, Off on
  battery-powered devices.
- Playback Defaults › Audio & Subtitles (`AudioSubtitleSettingsView`, a pushed
  page on both platforms) holds every track-language setting: Audio › Language
  (`defaultAudioLanguage`, "" = Original), Subtitles › Show Subtitles
  (`subtitleMode`: Off/Auto/Always), Language (`defaultSubtitleLanguage`, never
  "None" any more) and Size, and Advanced › Forced Subtitles
  (`forcedSubtitlesEnabled`). The rules live in `SubtitleSelectionPolicy`
  (`playback.md` → Automatic Track Languages). The 1.8 page replaced the old
  Subtitles/Forced Only/Subtitle Size/Audio rows;
  `UserPreferences.storedSubtitleSettings` maps the legacy keys
  (`subtitleForcedOnly` stays readable for that only).
- Values the viewer never set in Dusk follow the Plex account's language
  settings (`PlexService.fetchAccountLanguageDefaults`, `profile` of
  `/api/v2/user`, fetched in `MainTabView` per profile). They are cached under
  `plexAccount*` keys and applied through
  `UserPreferences.applyPlexAccountLanguageDefaults`, which never writes the
  viewer's own keys, so the account keeps steering until the viewer picks.
- `subtitleFontSize` (Audio & Subtitles › Size, Extra Small/Small/
  Medium/Large, Medium = the previous fixed size) scales locally rendered
  subtitles on both engines. It is also editable from the in-player gear menu
  (a `PlayerSelectionSheet` on iOS/iPadOS, a nested `Menu` on tvOS); the player
  writes the same `UserPreferences` value, so it is one preference and not a
  per-session override. It is disabled for AirPlay sessions, whose subtitles are
  burned in by Plex. See `playback.md` for how each engine applies it.
- Playback Info exposes Video Enhancement state and detail rows so AVPlayer and
  VLCKit sessions can explain whether enhancement is active, waiting for a
  frame, disabled by preference, or unavailable for a stream/runtime reason.
- `SettingsSupport` owns shared settings copy, URLs, language options, and bindings.
  Subtitle and audio pickers share `CommonLanguage` (plus the device language and a
  Plex-account language outside the list); adding an ISO 639-1 case there
  is enough for both platforms. Playback matching then canonicalizes Plex/VLCKit
  ISO 639-2 codes (`rum`/`ron` → `ro`) in `PlayerViewModel.normalizedLanguageCode`.
- Both settings pages lead with a supporter row (thank-you state for supporters),
  followed by Plex Home when applicable. There is no "Plex Server" section and no
  server picker: servers are managed in Navigation › Server Priority. Everyday playback
  and appearance settings follow, while engine overrides, storage, About, and
  Account stay lower on the page. AI Upscaling is a normal Playback Default;
  Playback Advanced is reserved for forced engine selection. The iOS Appearance
  section has an App Icon row opening `AppIconPickerView`. The supporter tier
  itself (StoreKit products, status rules, the iOS/iPadOS prompt schedule, alternate
  icons) is documented in `supporter.md`; tvOS only exposes supporter purchases
  through Settings.
- Player Quality lives in the in-player gear menu, not global Settings. It is a
  per-session manual action and must not create a persisted default that starts
  future sessions transcoded.
- "Download Subtitles" also lives in the in-player gear menu (iOS item below
  Subtitle Size, tvOS button beside the Subtitles menu), behind
  `PlayerControlsContext.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)`
  and not Live TV. It opens `SubtitleSearchView` (sheet on iOS with
  `[.medium, .large]` detents, full-screen cover on tvOS) via
  `PlayerViewModel.showSubtitleSearch`, which must stay in both controls auto-hide
  suppression lists (`PlayerView`'s keyboard bridge and
  `PlayerViewModel.canAutoHideControls`) like the other player sheets. The flow
  defaults to `UserPreferences.defaultSubtitleLanguage`, then the device language
  when it is a `CommonLanguage`, then English, and auto-searches on appear and on
  every language / Hearing Impaired change. A successful install calls
  `PlaybackCoordinator.refreshSubtitleStreamsAfterDownload()` and then dismisses,
  so the track is mounted and selected without restarting the session by hand
  (see `playback.md`).
- iOS settings use `List`, `Section`, `Picker`, `Toggle`, `Link`, Safari sheet, and
  confirmation dialogs.
- tvOS settings use `ScrollView` plus `TVSettingsSection`, `TVSettingsMenuRow`,
  `TVSettingsToggleRow`, and action/link row components. The page leads with a
  `.title` "Settings" header (tvOS has no nav-bar title). Shared spacing lives in
  `TVSettingsMetrics` (`contentInset`, `cardVerticalPadding`, `sectionSpacing`) so
  the header, section labels, card content, and footers stay aligned. Keep tvOS
  rows focus-friendly and avoid iOS list-only affordances there. Each focusable row
  shows focus with `tvSettingsRowFocusHighlight(_:)` — a neutral background band
  driven by a per-row `@FocusState` (rows can't use the scale+glow effect because
  they sit inside a shared card). Any new tvOS settings row must carry that band, or
  it will be invisible when focused (`.duskSuppressTVOSButtonChrome()` strips the
  system focus effect, leaving no indicator on its own).
- `TVSettingsMenuRow` pushes its own option list (`TVSettingsOptionList`) through a
  plain `NavigationLink`. Do not switch it back to `Picker` with
  `.pickerStyle(.navigationLink)`: on tvOS 27 that style pushes an empty list with
  nothing focusable, so focus drops to the tab bar and Back exits the app with a
  black screen left over Settings (1.6.2 fix).
- When the signed-in account has multiple Plex Home members, both settings
  platforms show a Plex Home section with the current user, `Switch User`, and
  `Automatically Sign In`. The switch action reuses the startup picker as a
  sheet on iOS and a full-screen flow on tvOS. The toggle is device-local:
  turning it off removes the persisted active-session token but keeps the
  current in-memory session until the app ends.

## Platform Differences

- Prefer separate platform composition files for large differences:
  `HomeIOSView`/`HomeTVView`, `SettingsIOSView`/`SettingsTVView`.
- Prefer shared modifiers/helpers for small differences.
- tvOS often needs larger poster metrics, explicit focus sections, `scrollClipDisabled`,
  explicit page backgrounds, plain/custom poster focus, glass button styles for primary
  actions, and default focus restoration.
- For tvOS detail pages, use focus sections as vertical row boundaries when a row's first
  focusable item may be horizontally offset from the current control.
- iOS often needs navigation title display modes, searchable placement tuning, status bar
  behavior, refreshable lists, Safari sheets, and compact action stacks.
- tvOS should not rely on iOS-only `List` styling, context menu behavior, or touch drag
  gestures without a remote/focus alternative.
- When a view measures full-bleed hero artwork on tvOS, account for safe-area leading and
  trailing insets so backdrops span the visual screen.

## Design And Style Rules

- `STYLE.md` is authoritative: native vibes, not orange. Use `Color.duskBackground`,
  `duskSurface`, `duskTextPrimary`, and `duskTextSecondary`; `duskAccent` is brand
  only (Supporter page, App Icon picker).
- Root feature screens should paint `Color.duskBackground.ignoresSafeArea()`.
- Elevated rows/cards use `Color.duskSurface` and subtle 1pt strokes.
- Primary action buttons use neutral contrasting Liquid Glass (`Color.primary`-tinted
  prominent glass on iOS, untinted `.glass` on tvOS). Progress, ratings, active
  states, selection, links and loading are neutral too. Do not introduce ad-hoc colors.
- Posters use 16pt corners. Sheets/cards use the larger rounded style already present in
  settings and library rows.
- Prefer system materials for overlays and hero controls where existing UI does.
- Use SF Symbols for iconography and keep labels concise.
- Keep content-first layouts: artwork leads, text supports, chrome recedes.
- Preserve progress indicators on posters and rows where watch state exists.
- Do not duplicate formatting logic in views. Add to `MediaTextFormatter` or an existing
  presentation helper.
- Do not make views call `PlexService` directly unless the file is already a small bridge
  around image URL construction. Feature data loading belongs in `@Observable` view models.

## Safe Change Checklist

- Read the relevant view, view model, shared primitive, and route code before editing.
- Confirm whether the change belongs in a platform shell, shared primitive, view model,
  route enum, or settings preference.
- Keep edits scoped; other agents may be working in nearby files.
- Reuse `AppNavigationRoute` and `.duskAppNavigationDestinations()` for navigation.
- Reuse shared poster/grid/carousel/state/formatting helpers before adding new UI.
- Keep Plex API calls in view models or `PlexService`, not view bodies.
- Preserve refresh-on-player-dismiss behavior on screens showing watch state.
- Preserve offline fallback paths and pending sync recording on downloaded media flows.
- Check tvOS focus and iOS compact layout when touching shared view code.
- If adding/removing/renaming source files under `Dusk/Sources`, run `xcodegen generate`.
- After code changes, run the compile-only `xcodebuild` command from `AGENTS.md`.
- Documentation-only changes do not require an Xcode build.
