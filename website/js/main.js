/* ============================================
   Dusk Marketing Website — main.js
   ============================================ */

(function () {
  'use strict';

  // --- Theme Toggle ---
  var THEME_KEY = 'dusk-theme';
  var html = document.documentElement;
  var toggle = document.getElementById('theme-switch');

  function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function applyTheme(theme) {
    html.setAttribute('data-theme', theme);
    toggle.setAttribute('aria-checked', theme === 'dark' ? 'true' : 'false');
  }

  // Init: check saved preference, fall back to system
  var saved = localStorage.getItem(THEME_KEY);
  applyTheme(saved || getSystemTheme());

  // Click handler — toggle between themes
  toggle.addEventListener('click', function () {
    var current = html.getAttribute('data-theme');
    var next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem(THEME_KEY, next);
    applyTheme(next);
  });

  // Keyboard handler for accessibility
  toggle.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      toggle.click();
    }
  });

  // Listen for system theme changes (only if no saved preference)
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function (e) {
    if (!localStorage.getItem(THEME_KEY)) {
      applyTheme(e.matches ? 'dark' : 'light');
    }
  });

  // --- Footer Year ---
  document.getElementById('year').textContent = new Date().getFullYear();

  // --- App Store Reviews (data lives in js/reviews.js) ---
  var STAR_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.5l2.94 5.96 6.56.95-4.75 4.63 1.12 6.54L12 17.5l-5.87 3.08 1.12-6.54L2.5 9.41l6.56-.95L12 2.5z"/></svg>';
  var AVATAR_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="9" r="3.5"/><path d="M5.5 19.5a6.5 6.5 0 0 1 13 0"/></svg>';
  var APPLE_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11Z"/></svg>';

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function renderReviews() {
    var section = document.getElementById('reviews');
    var list = document.getElementById('reviews-list');
    var reviews = (window.DUSK_REVIEWS || [])
      .filter(function (r) { return r.rating === 5 && r.body; });
    if (!section || !list || !reviews.length) return;

    reviews.forEach(function (r) {
      var card = el('article', 'review-card fade-in');

      var stars = el('div', 'review-stars');
      stars.setAttribute('role', 'img');
      stars.setAttribute('aria-label', '5 out of 5 stars');
      stars.innerHTML = new Array(6).join(STAR_SVG);

      var author = el('div', 'review-author');
      var avatar = el('span', 'review-avatar');
      avatar.innerHTML = AVATAR_SVG;
      author.appendChild(avatar);
      author.appendChild(el('span', 'review-name', r.reviewerNickname));

      var source = el('span', 'review-source');
      source.innerHTML = APPLE_SVG;
      source.appendChild(document.createTextNode('App Store'));

      var footer = el('div', 'review-footer');
      footer.appendChild(author);
      footer.appendChild(source);

      card.appendChild(stars);
      if (r.title) card.appendChild(el('h3', 'review-title', r.title));
      card.appendChild(el('p', 'review-body', r.body));
      card.appendChild(footer);
      list.appendChild(card);
    });

    section.hidden = false;
  }

  renderReviews();

  // --- Scroll Animations ---
  var faders = document.querySelectorAll('.fade-in');

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      // Stagger whatever enters together in document order, so a batch of
      // cards always cascades top-left to bottom-right and a lone card that
      // scrolls in later shows up right away.
      var revealed = entries
        .filter(function (entry) { return entry.isIntersecting; })
        .map(function (entry) { return entry.target; })
        .sort(function (a, b) {
          return a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
        });

      revealed.forEach(function (el, i) {
        observer.unobserve(el);
        if (i > 0) {
          el.style.transitionDelay = (i * 0.08) + 's';
          // Drop the delay once revealed so hover effects aren't held back.
          el.addEventListener('transitionend', function () {
            el.style.transitionDelay = '';
          }, { once: true });
        }
        el.classList.add('visible');
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

    faders.forEach(function (el) { observer.observe(el); });
  } else {
    // Fallback: just show everything
    faders.forEach(function (el) { el.classList.add('visible'); });
  }
})();
