// app.js — live SSE updates, command palette, action requests, animations.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  // ---- Toast notifications ------------------------------------------------
  const toastBox = $('#toast');
  function toast(msg, kind = 'ok') {
    if (!toastBox) return alert(msg);
    const el = document.createElement('div');
    el.className = 'toast ' + kind;
    el.textContent = msg;
    toastBox.appendChild(el);
    setTimeout(() => { el.style.opacity = 0; setTimeout(() => el.remove(), 300); }, 2400);
  }

  // ---- Command palette (Ctrl/Cmd + K) -------------------------------------
  const palette = $('#palette');
  const paletteInput = $('#palette-input');
  const paletteList = $('#palette-list');
  let paletteApps = [];
  let paletteIdx = 0;

  function openPalette() {
    if (!palette) return;
    palette.classList.remove('hidden');
    paletteInput.value = '';
    renderPalette('');
    paletteInput.focus();
  }
  function closePalette() { palette && palette.classList.add('hidden'); }

  function renderPalette(q) {
    if (!paletteList) return;
    const items = [];
    if (q.startsWith('>')) {
      const rest = q.slice(1).trim().toLowerCase();
      const cmds = ['Go to Apps:/', 'Open Console:/console'];
      for (const it of cmds) {
        const [label, href] = it.split(':');
        if (!rest || label.toLowerCase().includes(rest)) items.push({label, href});
      }
    } else {
      const ql = q.toLowerCase();
      for (const a of paletteApps) {
        if (!ql || a.name.toLowerCase().includes(ql) || (a.tenant||'').toLowerCase().includes(ql)) {
          items.push({label: a.name + '  ·  ' + a.role + ' / ' + (a.state||'?'), href: '/apps/' + a.name});
        }
      }
    }
    paletteIdx = 0;
    paletteList.innerHTML = items.slice(0, 50).map((it, i) =>
      `<li data-href="${it.href}" class="px-4 py-2 cursor-pointer ${i===0?'bg-zinc-800/60':''}">${it.label}</li>`
    ).join('') || '<li class="px-4 py-3 text-zinc-500">no matches</li>';
    paletteList.querySelectorAll('li[data-href]').forEach((li, i) => {
      li.addEventListener('mouseenter', () => { paletteIdx = i; highlightPalette(); });
      li.addEventListener('click', () => { location.href = li.dataset.href; });
    });
  }
  function highlightPalette() {
    paletteList.querySelectorAll('li').forEach((li, i) =>
      li.classList.toggle('bg-zinc-800/60', i === paletteIdx));
  }

  document.addEventListener('keydown', (ev) => {
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 'k') {
      ev.preventDefault();
      openPalette();
    } else if (ev.key === 'Escape') {
      closePalette();
    }
  });
  $('#palette-btn')?.addEventListener('click', openPalette);
  paletteInput?.addEventListener('input', (e) => renderPalette(e.target.value));
  paletteInput?.addEventListener('keydown', (e) => {
    const items = paletteList.querySelectorAll('li[data-href]');
    if (!items.length) return;
    if (e.key === 'ArrowDown') { paletteIdx = (paletteIdx + 1) % items.length; highlightPalette(); e.preventDefault(); }
    else if (e.key === 'ArrowUp') { paletteIdx = (paletteIdx - 1 + items.length) % items.length; highlightPalette(); e.preventDefault(); }
    else if (e.key === 'Enter') { location.href = items[paletteIdx].dataset.href; }
  });
  palette?.addEventListener('click', (e) => { if (e.target === palette) closePalette(); });

  // ---- Apps grid (live via SSE) ------------------------------------------
  const grid = $('#grid');
  const filter = $('#filter');
  const tpl = $('#card-tpl');
  const pulse = $('#pulse');
  const dokkuPill = $('#dokku-pill');
  const m = { total: $('#m-total'), running: $('#m-running'), degraded: $('#m-degraded'), down: $('#m-down') };
  const cards = new Map(); // name -> {el, last:state}

  function setMetric(node, val) {
    if (!node || node.textContent === String(val)) return;
    node.textContent = val;
  }

  function applyState(card, state) {
    const dot = card.querySelector('.js-dot');
    const ping = card.querySelector('.js-ping');
    const badge = card.querySelector('.js-state');
    badge.textContent = state;
    badge.className = 'js-state text-[10px] uppercase tracking-widest px-2 py-0.5 rounded ring-1 state-' + state;
    dot.className = 'js-dot relative inline-flex h-3 w-3 rounded-full dot-' + state;
    ping.className = 'js-ping absolute inline-flex h-full w-full rounded-full opacity-60 animate-ping dot-' + state;
    ping.style.display = state === 'running' ? '' : 'none';
  }

  function buildCard(a) {
    const node = tpl.content.firstElementChild.cloneNode(true);
    node.href = '/apps/' + a.name;
    node.dataset.name = a.name;
    node.querySelector('.js-name').textContent = a.name;
    node.querySelector('.js-role').textContent = a.role;
    node.querySelector('.js-tenant').textContent = a.tenant;
    node.querySelectorAll('.act').forEach(b => {
      b.addEventListener('click', (ev) => {
        ev.preventDefault(); ev.stopPropagation();
        runAction(a.name, b.dataset.act, node);
      });
    });
    return node;
  }

  function paintCard(node, a) {
    node.querySelector('.js-image').textContent = a.image || '—';
    node.querySelector('.js-image').title = a.image || '';
    node.querySelector('.js-http').textContent = a.http || '000';
    node.querySelector('.js-port').textContent = a.int_port || '—';
    node.querySelector('.js-domains').textContent = (a.domains || '').split(',').filter(Boolean).join(' ') || '—';
    const openLink = node.querySelector('.js-open');
    if (openLink) {
      if (a.state === 'running' && a.domains) {
        const domain = a.domains.split(',')[0]?.trim();
        openLink.href = 'http://' + domain;
        openLink.classList.remove('hidden');
      } else {
        openLink.classList.add('hidden');
      }
    }
  }

  function applyFilter() {
    const q = (filter?.value || '').toLowerCase();
    cards.forEach(({el}, name) => {
      el.style.display = !q || name.toLowerCase().includes(q) ? '' : 'none';
    });
  }
  filter?.addEventListener('input', applyFilter);

  async function runAction(name, verb, card) {
    if ((verb === 'stop' || verb === 'restart' || verb === 'rebuild') &&
        !confirm(verb + ' ' + name + '?')) return;
    card.classList.add('flash-ok');
    setTimeout(() => card.classList.remove('flash-ok'), 900);
    try {
      const res = await fetch('/apps/' + name + '/' + verb, { method: 'POST' });
      const txt = await res.text();
      toast((res.ok ? '✓ ' : '✖ ') + verb + ' ' + name, res.ok ? 'ok' : 'err');
      if (!res.ok) console.warn(txt);
    } catch (e) {
      toast('✖ ' + verb + ' ' + name + ': ' + e.message, 'err');
    }
  }

  function applySnapshot(snap) {
    paletteApps = snap.apps || [];
    let total=0, running=0, degraded=0, down=0;
    const seen = new Set();
    for (const a of snap.apps || []) {
      seen.add(a.name);
      total++;
      switch (a.state) {
        case 'running': running++; break;
        case 'restarting': case 'mixed': case 'created': degraded++; break;
        case 'stopped': case 'exited': case 'dead': case 'paused': down++; break;
      }
      let entry = cards.get(a.name);
      if (!entry) {
        const el = buildCard(a);
        grid.appendChild(el);
        entry = { el, last: '' };
        cards.set(a.name, entry);
      }
      paintCard(entry.el, a);
      if (entry.last !== a.state) {
        applyState(entry.el, a.state);
        if (entry.last) {
          const cls = a.state === 'running' ? 'flash-ok' : 'flash-warn';
          entry.el.classList.add(cls);
          setTimeout(() => entry.el.classList.remove(cls), 900);
        }
        entry.last = a.state;
      }
    }
    // remove gone apps
    for (const [name, {el}] of cards) {
      if (!seen.has(name)) { el.remove(); cards.delete(name); }
    }
    // first render: drop skeletons
    grid.querySelectorAll('.skel').forEach(s => s.remove());

    setMetric(m.total, total);
    setMetric(m.running, running);
    setMetric(m.degraded, degraded);
    setMetric(m.down, down);

    if (dokkuPill) {
      dokkuPill.innerHTML = 'Dokku <b class="ml-1">' + (snap.healthy ? 'healthy' : 'down') + '</b>';
      dokkuPill.style.color = snap.healthy ? '#6ee7b7' : '#fda4af';
    }
    pulse?.classList.add('opacity-100');
    setTimeout(() => pulse?.classList.remove('opacity-100'), 400);
    applyFilter();
  }

  if (grid) {
    const es = new EventSource('/events');
    es.addEventListener('snapshot', (ev) => {
      try { applySnapshot(JSON.parse(ev.data)); } catch (e) { console.error(e); }
    });
    es.onerror = () => { /* browser auto-reconnects */ };
  }
})();
