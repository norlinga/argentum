// ---- Theme toggle (initial theme is set inline in <head> to avoid a flash) ----
const currentTheme = () => document.documentElement.dataset.theme ||
  (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');

document.addEventListener('click', (e) => {
  if (!e.target.closest('#theme-toggle')) return;
  const next = currentTheme() === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem('argentum-theme', next); } catch (_) {}
});

// ---- Tag colours — mirrors Tag.hue in models.rb; keep the two in sync ----
const tagHue = (name) => {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)) % 1000003;
  return Math.floor((h * 137.508) % 360);
};

// Motion preview on card hover (delegated so it works for HTMX-loaded cards).
document.addEventListener('mouseover', (e) => {
  const card = e.target.closest('.card[data-preview]');
  if (!card || card._hover) return;
  card._hover = true;
  let v = card.querySelector('video');
  if (!v) {
    v = document.createElement('video');
    v.muted = true; v.loop = true; v.playsInline = true; v.preload = 'auto';
    v.src = card.dataset.preview;
    v.addEventListener('playing', () => v.classList.add('on'));
    card.querySelector('.thumb').appendChild(v);
  }
  v.play().catch(() => {});
});

document.addEventListener('mouseout', (e) => {
  const card = e.target.closest('.card');
  if (!card || card.contains(e.relatedTarget)) return;
  card._hover = false;
  const v = card.querySelector('video');
  if (v) { v.pause(); v.currentTime = 0; v.classList.remove('on'); }
});

// ---- Player: resume position + view counting ----
const getPlayer = () => window.videojs && document.getElementById('player') && videojs.getPlayer('player');

function initPlayer(el) {
  if (!el || !window.videojs || videojs.getPlayer(el)) return;

  const id = el.dataset.id;
  const start = parseFloat(el.dataset.start) || 0;
  const sources = [];
  if (el.dataset.hls === 'true') sources.push({ src: `/hls/${id}/index.m3u8`, type: 'application/x-mpegURL' });
  sources.push({ src: `/media/${id}`, type: el.dataset.extType });

  const player = videojs(el, { playbackRates: [0.5, 1, 1.25, 1.5, 2], sources });

  player.one('loadedmetadata', () => {
    const d = player.duration();
    if (start > 5 && (!isFinite(d) || start < d - 10)) player.currentTime(start);
  });

  const send = (pos) => fetch(`/videos/${id}/progress`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `position=${pos}`,
    keepalive: true,
  });
  let last = 0;
  player.on('timeupdate', () => {
    const t = player.currentTime();
    if (Math.abs(t - last) >= 5) { last = t; send(t); }
  });
  player.on('pause', () => { if (!player.ended()) send(player.currentTime()); });
  player.on('ended', () => send(0));
  window.addEventListener('pagehide', () => { if (!player.ended()) send(player.currentTime()); });
  player.one('play', () => fetch(`/videos/${id}/view`, { method: 'POST', keepalive: true }));
}

// Runs for the initial page and for every HTMX-swapped fragment (e.g. a video
// that finishes processing while you're on its page).
htmx.onLoad((root) => {
  const el = root.id === 'player' ? root : root.querySelector && root.querySelector('video#player');
  if (el) initPlayer(el);
});

// The poster is only on screen until playback starts, so updating it is harmless
// mid-play and immediate otherwise.
const setPoster = (url) => { const p = getPlayer(); if (p && url) p.poster(url); };

// ---- Edit panel ----
// Picking a still previews it as the poster right away (before Save).
document.addEventListener('change', (e) => {
  const radio = e.target.closest('.still input[name="thumb"]');
  if (radio) setPoster(radio.nextElementSibling.src);
});

// After Save / Cancel the info panel comes back: sync poster and page title to what was stored.
document.body.addEventListener('htmx:afterSwap', (e) => {
  if (e.detail.target.id !== 'info') return;
  const row = e.detail.target.querySelector('.title-row');
  if (!row) return;
  setPoster(row.dataset.poster);
  const suffix = document.title.includes(' · ') ? document.title.slice(document.title.lastIndexOf(' · ')) : '';
  document.title = row.dataset.title + suffix;
});

// Live tag pill preview while typing.
document.addEventListener('input', (e) => {
  const input = e.target.closest('[data-tag-input]');
  if (!input) return;
  const preview = input.form.querySelector('[data-tag-preview]');
  const names = [...new Set(input.value.split(',')
    .map((t) => t.toLowerCase().trim().replace(/\s+/g, ' ')).filter(Boolean))];
  preview.replaceChildren(...names.map((n) => {
    const s = document.createElement('span');
    s.className = 'tag';
    s.style.setProperty('--h', tagHue(n));
    s.textContent = n;
    return s;
  }));
});
