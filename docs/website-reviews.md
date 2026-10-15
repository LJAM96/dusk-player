# Website App Store reviews

The "Loved on the App Store." section on `website/index.html` (right before
Open Source) is rendered by `website/js/main.js` from **`website/js/reviews.js`**.
Updating the reviews means editing only that file.

## Format

`reviews.js` assigns a JSON array to `window.DUSK_REVIEWS`, in the shape App
Store Connect's customer reviews export uses:

```js
window.DUSK_REVIEWS = [
  {"id":"…","rating":5,"title":"…","body":"…","reviewerNickname":"…","createdDate":"2026-10-12T20:16:14-07:00","territory":"USA"}
];
```

- Shown: `title`, `body`, `reviewerNickname`. `rating` must be `5` (anything
  else is skipped). Cards appear in array order, so put the strongest first.
  `id`, `createdDate` and `territory` are ignored.
- The grid is four per row on desktop, 2×2 on tablet, a swipe row on phones,
  so four (or eight) reviews fill it cleanly.
- Paste texts verbatim: no typo fixes, no invented surnames or extra data.
  `\n` in `body` is kept as a line break; long bodies are clamped to six lines.
- It's a plain `<script>`, not a fetched `.json`, so the site needs no build
  step and works from `file://`. Keep it valid JSON inside the brackets.
- An empty array hides the whole section.

## Deploy

Push to `main`. Coolify (homelab host `coolify`) builds `website/Dockerfile`
(`nginx:alpine` serving `website/`) and redeploys getdusk.app behind
Cloudflare, within seconds of the push. There's no GitHub Actions workflow.
