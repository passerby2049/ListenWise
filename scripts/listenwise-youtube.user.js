// ==UserScript==
// @name         Open in ListenWise
// @namespace    com.listenwise.userscript
// @version      0.1.0
// @description  Add a button to YouTube video pages that opens the current video in ListenWise.
// @match        https://www.youtube.com/*
// @match        https://m.youtube.com/*
// @run-at       document-idle
// @grant        none
// ==/UserScript==

(function () {
  'use strict';

  const BTN_ID = 'listenwise-open-btn';

  function currentVideoURL() {
    const u = new URL(location.href);
    if (u.pathname === '/watch' && u.searchParams.get('v')) {
      return `https://www.youtube.com/watch?v=${u.searchParams.get('v')}`;
    }
    const m = u.pathname.match(/^\/shorts\/([^/?#]+)/);
    if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
    return null;
  }

  function buildDeepLink(ytURL) {
    return `listenwise://import?url=${encodeURIComponent(ytURL)}`;
  }

  function makeButton(ytURL) {
    const a = document.createElement('a');
    a.id = BTN_ID;
    a.href = buildDeepLink(ytURL);
    a.textContent = 'Open in ListenWise';
    a.title = 'Import this video into ListenWise';
    a.style.cssText = [
      'display:inline-flex',
      'align-items:center',
      'height:36px',
      'padding:0 14px',
      'margin-left:8px',
      'border-radius:18px',
      'background:oklch(74% 0.13 75)',
      'color:#1a1308',
      'font:500 13px/1 "Geist Sans", system-ui, -apple-system, sans-serif',
      'text-decoration:none',
      'cursor:pointer',
      'white-space:nowrap',
    ].join(';');
    return a;
  }

  function inject() {
    const ytURL = currentVideoURL();
    const existing = document.getElementById(BTN_ID);
    if (!ytURL) { existing?.remove(); return; }

    const actions =
      document.querySelector('#actions.ytd-watch-metadata') ||
      document.querySelector('#top-level-buttons-computed') ||
      document.querySelector('ytd-watch-metadata #actions');
    if (!actions) return;

    if (existing) {
      existing.href = buildDeepLink(ytURL);
      return;
    }
    actions.appendChild(makeButton(ytURL));
  }

  const mo = new MutationObserver(() => inject());
  mo.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('yt-navigate-finish', inject);
  inject();
})();
