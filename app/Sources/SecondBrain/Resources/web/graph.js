// Knowledge graph view (CONTRACT §12.2 + §12.7). Canvas + d3-force so it stays smooth with thousands of nodes.
// Swift calls SB.render(payload), SB.focus(id), SB.setTheme("light"|"dark"), SB.toggleSearch().
// Swift is told things through navigations it cancels: sbgraph://open/<path>, sbgraph://hint-dismissed.
(function () {
  'use strict';

  // ---------- Constants ----------

  // Fixed project palette (one per project, in creation order). Readable on light and dark backgrounds.
  const PALETTE = ['#6e56cf', '#12a594', '#f76b15', '#d6409f', '#0090ff', '#30a46c', '#e5484d', '#05a2c2', '#ad7f58', '#8e4ec6'];
  const KIND_COLORS = {
    project: '#5b5bd6', meeting: '#6e56cf', email: '#0090ff', document: '#f76b15', note: '#ad7f58', url: '#05a2c2',
    person: '#8b8e99', topic: '#30a46c', decision: '#d6409f', question: '#e2a336', task: '#12a594', page: '#5d6577',
  };
  const KIND_ORDER = ['meeting', 'email', 'document', 'note', 'url', 'topic', 'decision', 'question', 'task', 'person', 'page', 'project'];
  // Same icons as the rest of the app (SF Symbols waveform, envelope, person, checkmark.seal, lightbulb,
  // questionmark.bubble, doc.text …), drawn as small inline SVGs.
  const GLYPH_PATHS = {
    meeting: 'M4 10v4M8 7v10M12 4v16M16 8v8M20 10v4',
    email: 'M3.5 6h17v12h-17zM3.5 7l8.5 6 8.5-6',
    person: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4.5 20c1.4-3.6 4.2-5.5 7.5-5.5s6.1 1.9 7.5 5.5',
    decision: 'M12 2.5l2.3 1.9 3-.2.8 2.9 2.6 1.5-1.1 2.8 1.1 2.8-2.6 1.5-.8 2.9-3-.2L12 21.5l-2.3-1.9-3 .2-.8-2.9-2.6-1.5 1.1-2.8-1.1-2.8 2.6-1.5.8-2.9 3 .2zM8.6 12.1l2.3 2.3 4.6-4.7',
    topic: 'M9.5 18h5M10.5 21h3M12 3a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.3 1.1 2.2h5c0-.9.4-1.6 1.1-2.2A6 6 0 0 0 12 3z',
    question: 'M4 4.5h16v11.5H9.5L5 20v-4H4zM9.8 8.6a2.3 2.3 0 1 1 3.1 2.1c-.6.3-.9.8-.9 1.4M12 14.3v.2',
    document: 'M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6',
    note: 'M5.5 4h13v16h-13zM8.5 8h7M8.5 12h7M8.5 16h4',
    url: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    task: 'M4 6l1.5 1.5L8 5M4 12l1.5 1.5L8 11M4 18l1.5 1.5L8 17M11 6h9M11 12h9M11 18h9',
    page: 'M6 3h8l4 4v14H6zM14 3v4h4',
    project: 'M3 6.5h6l2 2h10V19H3z',
    search: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM15.5 15.5L20 20',
    fit: 'M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5',
    calendar: 'M4 6h16v14H4zM4 10h16M8 3.5v4M16 3.5v4',
    links: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  };
  const FILLED = { play: 'M7 4.5l12.5 7.5L7 19.5z', pause: 'M6.5 4.5h4v15h-4zM13.5 4.5h4v15h-4z' };

  function glyph(name) {
    if (FILLED[name]) return `<svg class="g" viewBox="0 0 24 24"><path d="${FILLED[name]}"/></svg>`;
    return `<svg class="g" viewBox="0 0 24 24"><path d="${GLYPH_PATHS[name] || GLYPH_PATHS.page}"/></svg>`;
  }

  // ---------- State ----------

  const S = {
    payload: null, nodes: [], links: [], byId: new Map(), adj: new Map(), sim: null,
    transform: d3.zoomIdentity, width: 0, height: 0, dpr: 1,
    colorBy: 'project', projects: new Map(), labels: {},
    focus: null, focusSet: null, hover: null, hiddenKinds: new Set(),
    searchOpen: false, query: '', matches: null,
    time: Infinity, timeMin: 0, timeMax: 0, playing: null,
    theme: {}, drawQueued: false, scopeKey: null, positions: new Map(), lastToggle: 0,
    textWidths: new Map(),
  };

  let canvas, ctx, zoom;
  const $ = (id) => document.getElementById(id);

  // ---------- Helpers ----------

  function L(key, n) {
    const s = S.labels[key] || key;
    return n === undefined ? s : s.replace(/%(ld|d|@)/, String(n));
  }
  function kindLabel(kind) { return (S.labels.kinds && S.labels.kinds[kind]) || kind; }
  function kindPlural(kind) { return (S.labels.kindsPlural && S.labels.kindsPlural[kind]) || kindLabel(kind); }
  function locale() { return S.labels.lang === 'en' ? 'en-US' : 'es-MX'; }
  function fmtDate(ms, long) {
    const opts = long ? { day: 'numeric', month: 'long', year: 'numeric' } : { day: 'numeric', month: 'short' };
    try { return new Intl.DateTimeFormat(locale(), opts).format(new Date(ms)); } catch (e) { return new Date(ms).toDateString(); }
  }
  function fold(s) { return (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase(); }
  function esc(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
  function navigate(url) {
    // Navigations are cancelled by Swift; a fresh anchor click is the most reliable way to send several in a row.
    const a = document.createElement('a');
    a.href = url;
    a.click();
  }

  function readTheme() {
    const cs = getComputedStyle(document.documentElement);
    const v = (n) => cs.getPropertyValue(n).trim();
    S.theme = {
      bg: v('--bg'), text: v('--text'), muted: v('--muted'), edge: v('--edge'), edgeStrong: v('--edge-strong'),
      person: v('--person'), personRing: v('--person-ring'), haloAlpha: parseFloat(v('--halo-alpha')) || 0.1,
      labelHalo: v('--label-halo'), accent: v('--accent'),
      dark: document.documentElement.dataset.theme === 'dark' ||
        (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches),
    };
    for (const n of S.nodes) n.color = colorOf(n);
    for (const p of S.projects.values()) p.labelColor = labelColor(p.color);
    S.textWidths.clear();
  }

  function labelColor(hex) {
    const c = d3.hsl(hex);
    if (S.theme.dark) { c.l = Math.max(c.l, 0.72); } else { c.l = Math.min(c.l, 0.36); }
    return c.formatHex();
  }

  function colorOf(n) {
    if (n.kind === 'person') return S.theme.person || '#c9cbd3';
    if (S.colorBy === 'project') {
      const p = n.project && S.projects.get(n.project);
      if (p) return p.color;
      return KIND_COLORS.page;
    }
    if (n.kind === 'project') {
      const p = S.projects.get(n.project);
      return p ? p.color : KIND_COLORS.project;
    }
    return KIND_COLORS[n.kind] || KIND_COLORS.page;
  }

  function shortTitle(n) {
    const p = n.project && S.projects.get(n.project);
    if (p && n.kind === 'page') {
      for (const sep of [' — ', ' - ', ': ']) {
        if (n.title.startsWith(p.name + sep)) {
          const rest = n.title.slice(p.name.length + sep.length);
          return rest.charAt(0).toUpperCase() + rest.slice(1);
        }
      }
    }
    return n.title;
  }

  // The project's overview page: the one structural page worth a label ("📋 Resumen").
  function isOverview(n) { return n.kind === 'page' && /\/wiki\/overview\.md$/.test(n.id); }

  function radiusOf(n) {
    const base = 2.6 + 2.2 * Math.pow(Math.log2(1 + n.links), 1.25);
    if (n.kind === 'project') return Math.max(14, Math.min(base, 30));
    // Index, pendientes, línea de tiempo… link to everything: at full size they'd be the biggest, unlabeled shapes.
    if (n.kind === 'page' && !isOverview(n)) return Math.min(base, 8);
    return Math.min(base, 28);
  }

  // ---------- Render (payload from Swift) ----------

  function render(payload) {
    const first = !S.payload;
    S.payload = payload;
    S.labels = payload.labels || {};
    S.colorBy = payload.colorBy || 'project';
    document.documentElement.lang = S.labels.lang || 'es';
    if (payload.theme) document.documentElement.dataset.theme = payload.theme;

    stopPlay();
    const scopeKey = payload.scopeKey || '';
    const sameScope = !first && scopeKey === S.scopeKey;
    if (scopeKey !== S.scopeKey) { S.positions.clear(); S.hiddenKinds.clear(); S.focus = null; }
    else for (const n of S.nodes) S.positions.set(n.id, { x: n.x, y: n.y });
    S.scopeKey = scopeKey;

    S.projects = new Map();
    (payload.projects || []).forEach((p, i) => {
      S.projects.set(p.slug, { ...p, color: p.color || PALETTE[i % PALETTE.length] });
    });

    S.nodes = payload.nodes.map((n) => ({
      id: n.id, title: shortTitle(n), fullTitle: n.title, kind: n.kind, project: n.project || null, date: n.date || null,
      links: n.links || 0, alpha: 1, appear: 1, fold: fold(n.title),
    }));
    S.byId = new Map(S.nodes.map((n) => [n.id, n]));
    S.links = payload.edges
      .filter((e) => S.byId.has(e.source) && S.byId.has(e.target))
      .map((e) => ({ source: e.source, target: e.target, weight: e.weight || 1 }));
    S.adj = new Map(S.nodes.map((n) => [n.id, new Set()]));
    for (const e of S.links) { S.adj.get(e.source).add(e.target); S.adj.get(e.target).add(e.source); }
    for (const n of S.nodes) n.r = radiusOf(n);

    readTheme();
    buildChips();
    buildTimebar();
    layout(first);
    applySearch();

    if (S.focus && !S.byId.has(S.focus)) S.focus = null;
    const focus = payload.focus && S.byId.has(payload.focus) ? payload.focus : null;

    if (payload.snapshot) {
      document.documentElement.classList.add('snapshot');
      S.sim.stop();
      for (let i = 0; i < 260; i++) S.sim.tick();
      fit(null, false);
      if (focus) setFocus(focus, false);
      if (payload.hint) showHint();
      for (const n of S.nodes) n.alpha = targetAlpha(n);
      frame(performance.now());
      return;
    }

    // The vault changed under an open graph (Claude finished a page): keep the view where it is.
    if (sameScope && !focus) {
      if (S.focus) { S.focusSet = neighbourhood(S.focus, 2); showPeek(S.byId.get(S.focus)); }
      requestDraw();
      return;
    }
    if (focus) {
      setFocus(focus, false);
    } else {
      fit(null, false);
    }
    if (payload.replay && !focus && hasDates()) {
      startPlay(4200, true);
    } else if (payload.hint) {
      showHint();
    }
    requestDraw();
  }

  // ---------- Layout ----------

  function anchors() {
    const slugs = [...S.projects.keys()].filter((s) => S.nodes.some((n) => n.project === s));
    const map = new Map();
    if (S.colorBy !== 'project' || slugs.length < 2) { slugs.forEach((s) => map.set(s, { x: 0, y: 0 })); return map; }
    const R = Math.max(150, Math.sqrt(S.nodes.length) * 17);
    slugs.forEach((s, i) => {
      const a = -Math.PI / 2 + (i * 2 * Math.PI) / slugs.length;
      map.set(s, { x: Math.cos(a) * R * 1.25, y: Math.sin(a) * R });
    });
    return map;
  }

  function layout() {
    if (S.sim) S.sim.stop();
    const N = S.nodes.length;
    const anchor = anchors();
    S.anchor = anchor;
    const rand = d3.randomLcg(0.42);
    let known = 0;
    for (const n of S.nodes) {
      const p = S.positions.get(n.id);
      if (p) { n.x = p.x; n.y = p.y; known++; continue; }
      const a = (n.project && anchor.get(n.project)) || { x: 0, y: 0 };
      const spread = 40 + Math.sqrt(N) * 6;
      n.x = a.x + (rand() - 0.5) * spread;
      n.y = a.y + (rand() - 0.5) * spread;
    }
    const global = S.colorBy === 'project' && anchor.size > 1;
    const charge = -(36 + 190 / Math.sqrt(Math.max(1, N / 60)));
    S.sim = d3.forceSimulation(S.nodes)
      .randomSource(d3.randomLcg(0.7))
      .alphaDecay(N > 800 ? 0.045 : 0.03)
      .velocityDecay(0.42)
      .force('link', d3.forceLink(S.links).id((d) => d.id)
        .distance((l) => {
          const k = (n) => (n.kind === 'project' ? 26 : n.kind === 'person' ? 22 : 0);
          return (N < 150 ? 46 : 30) + k(l.source) + k(l.target) + Math.min(l.source.r, 14) + Math.min(l.target.r, 14);
        }))
      .force('charge', d3.forceManyBody().strength((d) => (d.kind === 'project' ? charge * 3 : charge)).theta(0.9).distanceMax(520))
      .force('collide', d3.forceCollide((d) => d.r + 3).iterations(1))
      .force('x', d3.forceX((d) => (global && d.project && anchor.get(d.project) ? anchor.get(d.project).x : 0))
        .strength((d) => (d.kind === 'project' ? 0.35 : global ? (d.kind === 'person' ? 0.012 : 0.07) : 0.018)))
      .force('y', d3.forceY((d) => (global && d.project && anchor.get(d.project) ? anchor.get(d.project).y : 0))
        .strength((d) => (d.kind === 'project' ? 0.35 : global ? (d.kind === 'person' ? 0.012 : 0.07) : 0.045)))
      .on('tick', requestDraw)
      .stop();
    // Warm up offscreen so the first frame is already a readable shape; the rest settles live.
    const restart = known > N * 0.8;
    if (restart) S.sim.alpha(0.25);
    const warm = restart ? 40 : N < 300 ? 200 : N < 1000 ? 110 : 60;
    for (let i = 0; i < warm; i++) S.sim.tick();
    S.sim.restart();
  }

  // ---------- Visibility, focus, search ----------

  function visible(n) {
    if (S.hiddenKinds.has(n.kind)) return false;
    if (n.date && n.date > S.time) return false;
    return true;
  }

  function neighbourhood(id, hops) {
    const set = new Set([id]);
    let frontier = [id];
    for (let h = 0; h < hops; h++) {
      const next = [];
      for (const v of frontier) for (const w of S.adj.get(v) || []) {
        const n = S.byId.get(w);
        if (!set.has(w) && visible(n)) {
          // Don't walk through hubs (projects, people, overview/tasks/timeline): through them 2 hops = everything.
          set.add(w);
          if (!isHub(n)) next.push(w);
        }
      }
      frontier = next;
    }
    return set;
  }

  function isHub(n) { return n.kind === 'project' || n.kind === 'person' || n.kind === 'page'; }

  function setFocus(id, animate = true) {
    const n = S.byId.get(id);
    if (!n) return;
    S.focus = id;
    S.focusSet = neighbourhood(id, 2);
    $('showAll').hidden = false;
    showPeek(n);
    fit([...S.focusSet].map((i) => S.byId.get(i)), animate);
    requestDraw();
  }

  function clearFocus(animate = true) {
    const had = !!S.focus;
    S.focus = null;
    S.focusSet = null;
    $('showAll').hidden = true;
    $('peek').hidden = true;
    if (had) fit(null, animate);
    requestDraw();
  }

  function applySearch() {
    const q = fold(S.query.trim());
    if (!S.searchOpen || !q) { S.matches = null; $('searchCount').textContent = ''; requestDraw(); return; }
    S.matches = new Set(S.nodes.filter((n) => visible(n) && n.fold.includes(q)).map((n) => n.id));
    $('searchCount').textContent = S.matches.size ? L('matches', S.matches.size) : L('noMatches');
    requestDraw();
  }

  function toggleSearch(force) {
    const now = Date.now();
    if (force === undefined && now - S.lastToggle < 250) return;   // ⌘F can arrive from both Swift and the page
    S.lastToggle = now;
    S.searchOpen = force === undefined ? !S.searchOpen : force;
    $('searchBox').hidden = !S.searchOpen;
    $('searchBtn').classList.toggle('on', S.searchOpen);
    if (S.searchOpen) { const i = $('searchInput'); i.focus(); i.select(); } else { $('searchInput').blur(); }
    applySearch();
  }

  // ---------- Peek card ----------

  function showPeek(n) {
    const color = n.kind === 'person' ? S.theme.personRing : n.color;
    const badge = $('peekBadge');
    badge.style.setProperty('--c', color);
    badge.innerHTML = n.kind === 'project' ? `<span style="font-size:14px">${esc(projectEmoji(n))}</span>` : glyph(n.kind);
    $('peekKind').textContent = kindLabel(n.kind);
    $('peekTitle').textContent = n.kind === 'project' ? projectName(n) : n.title;
    const meta = [];
    if (n.date) meta.push(`<span>${glyph('calendar')}${esc(fmtDate(n.date, true))}</span>`);
    meta.push(`<span>${glyph('links')}${esc(L('links', degreeVisible(n)))}</span>`);
    if (S.colorBy === 'project' && n.project && n.kind !== 'project') {
      const p = S.projects.get(n.project);
      if (p) meta.push(`<span style="color:${p.labelColor}">${esc(p.emoji + ' ' + p.name)}</span>`);
    }
    $('peekMeta').innerHTML = meta.join('');
    const open = $('peekOpen');
    open.textContent = n.kind === 'project' ? L('openOverview') : L('open');
    open.onclick = () => openNode(n);
    const neighbours = [...(S.adj.get(n.id) || [])].map((id) => S.byId.get(id)).filter(visible)
      .sort((a, b) => b.links - a.links).slice(0, 8);
    $('peekNeighboursTitle').textContent = neighbours.length ? L('connected') : '';
    const ul = $('peekNeighbours');
    ul.innerHTML = '';
    for (const m of neighbours) {
      const li = document.createElement('li');
      li.style.setProperty('--c', m.kind === 'person' ? S.theme.personRing : m.color);
      li.innerHTML = (m.kind === 'project' ? glyph('project') : glyph(m.kind)) + `<span>${esc(m.kind === 'project' ? projectName(m) : m.title)}</span>`;
      li.onclick = () => setFocus(m.id);
      ul.appendChild(li);
    }
    $('peek').hidden = false;
  }

  function degreeVisible(n) { return [...(S.adj.get(n.id) || [])].filter((id) => visible(S.byId.get(id))).length; }
  function projectEmoji(n) { const p = S.projects.get(n.project); return p ? p.emoji : '📁'; }
  function projectName(n) { const p = S.projects.get(n.project); return p ? p.name : n.title; }

  function openNode(n) {
    // A project hub opens the project's overview.
    const path = n.kind === 'project' ? `projects/${n.project}/wiki/overview.md` : n.id;
    navigate('sbgraph://open/' + encodeURIComponent(path));
  }

  // ---------- Chips (inside a project: one per kind, click filters) ----------

  function buildChips() {
    const box = $('chips');
    box.innerHTML = '';
    if (S.colorBy !== 'kind') return;
    const counts = new Map();
    for (const n of S.nodes) if (n.kind !== 'project') counts.set(n.kind, (counts.get(n.kind) || 0) + 1);
    for (const kind of KIND_ORDER) {
      if (!counts.get(kind)) continue;
      const b = document.createElement('button');
      b.className = 'chip' + (S.hiddenKinds.has(kind) ? ' off' : '');
      b.style.setProperty('--c', kind === 'person' ? 'var(--person-ring)' : KIND_COLORS[kind]);
      b.innerHTML = `${glyph(kind)}<span>${esc(kindPlural(kind))}</span><span class="n">${counts.get(kind)}</span>`;
      b.onclick = (e) => {
        if (e.altKey) {
          // ⌥-click: only this kind.
          const only = [...counts.keys()].filter((k) => k !== kind);
          const already = only.every((k) => S.hiddenKinds.has(k)) && !S.hiddenKinds.has(kind);
          S.hiddenKinds = already ? new Set() : new Set(only);
        } else if (S.hiddenKinds.has(kind)) S.hiddenKinds.delete(kind); else S.hiddenKinds.add(kind);
        buildChips();
        afterVisibilityChange();
      };
      box.appendChild(b);
    }
  }

  function afterVisibilityChange() {
    if (S.focus) {
      if (!visible(S.byId.get(S.focus))) clearFocus(false);
      else S.focusSet = neighbourhood(S.focus, 2);
    }
    applySearch();
    updateDots();
    requestDraw();
  }

  // ---------- Time strip ----------

  function hasDates() { return S.nodes.some((n) => n.date); }

  function buildTimebar() {
    const bar = $('timebar');
    const dated = S.nodes.filter((n) => n.date);
    if (!dated.length) { bar.hidden = true; S.time = Infinity; return; }
    bar.hidden = false;
    const today = S.payload.today || Date.now();
    const min = d3.min(dated, (n) => n.date);
    S.timeMin = min - 86400000;
    S.timeMax = Math.max(today, S.timeMin + 86400000 * 2);
    S.time = Infinity;
    $('todayLabel').textContent = L('today');
    $('strip').style.marginRight = ($('todayLabel').offsetWidth + 16) + 'px';   // the label never runs under the thumb
    $('playBtn').innerHTML = glyph('play');
    $('playBtn').setAttribute('aria-label', L('play'));
    $('playBtn').title = L('play');
    // One dot per meeting (per day and project); no meetings → every dated page.
    let marks = dated.filter((n) => n.kind === 'meeting');
    if (!marks.length) marks = dated;
    const seen = new Set();
    const dots = $('dots');
    dots.innerHTML = '';
    for (const n of marks.sort((a, b) => a.date - b.date)) {
      const day = Math.floor(n.date / 86400000) + ':' + (n.project || '');
      if (seen.has(day)) continue;
      seen.add(day);
      const d = document.createElement('div');
      d.className = 'dot' + (n.kind === 'meeting' ? ' meeting' : '');
      d.style.left = pct(Math.min(n.date, S.timeMax)) + '%';
      d.style.setProperty('--c', n.kind === 'meeting' && S.colorBy === 'kind' ? KIND_COLORS.meeting : n.color);
      d.dataset.t = n.date;
      d.title = n.title + ' · ' + fmtDate(n.date, true);
      dots.appendChild(d);
    }
    updateDots();
  }

  function pct(t) { return ((t - S.timeMin) / (S.timeMax - S.timeMin)) * 100; }

  function updateDots() {
    const t = Math.min(S.time, S.timeMax);
    const p = Math.max(0, Math.min(100, pct(t)));
    $('thumb').style.left = p + '%';
    $('fill').style.width = p + '%';
    $('thumbLabel').textContent = S.time === Infinity ? L('today') : fmtDate(S.time, false);
    for (const d of $('dots').children) d.classList.toggle('on', +d.dataset.t <= t);
  }

  function setTime(t, fromUser) {
    const prev = S.time;
    S.time = t >= S.timeMax ? Infinity : Math.max(S.timeMin, t);
    const now = performance.now();
    for (const n of S.nodes) {
      if (!n.date) continue;
      const was = n.date <= prev, is = n.date <= S.time;
      if (!was && is) n.born = now;
    }
    if (fromUser) stopPlay();
    afterVisibilityChange();
  }

  function startPlay(duration, replay) {
    stopPlay();
    const from = S.time === Infinity || S.time >= S.timeMax ? S.timeMin : S.time;
    const span = S.timeMax - from;
    const total = duration || Math.max(2500, 7000 * (span / (S.timeMax - S.timeMin)));
    // The replay grows the brain in place: frame the final shape first.
    if (replay) fit(S.nodes.filter((n) => !S.hiddenKinds.has(n.kind)), false);
    S.time = from;
    for (const n of S.nodes) if (n.date && n.date > from) n.born = null;
    afterVisibilityChange();
    for (const n of S.nodes) if (!visible(n)) n.alpha = 0;   // start empty at once, no fade-out first
    $('playBtn').innerHTML = glyph('pause');
    $('strip').classList.add('active');
    S.playing = d3.timer((elapsed) => {
      const k = Math.min(1, elapsed / total);
      setTime(from + span * d3.easeQuadInOut(k), false);
      if (k >= 1) {
        stopPlay();
        setTime(Infinity, false);
        fit(S.focus ? [...S.focusSet].map((i) => S.byId.get(i)) : null, true);
        if (replay && S.payload.hint) showHint();
      }
    });
  }

  function stopPlay() {
    if (S.playing) { S.playing.stop(); S.playing = null; }
    $('playBtn').innerHTML = glyph('play');
    $('strip').classList.remove('active');
  }

  function stripTime(ev) {
    const r = $('strip').getBoundingClientRect();
    const x = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
    return S.timeMin + x * (S.timeMax - S.timeMin);
  }

  // ---------- Hint ----------

  function showHint() {
    if (!S.labels.hint) return;
    $('hintText').textContent = S.labels.hint;
    $('hint').hidden = false;
  }

  // ---------- Fit ----------

  function fit(nodes, animate) {
    const list = (nodes || S.nodes.filter(visible)).filter(Boolean);
    if (!list.length || !S.width) return;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const n of list) {
      x0 = Math.min(x0, n.x - n.r); y0 = Math.min(y0, n.y - n.r);
      x1 = Math.max(x1, n.x + n.r); y1 = Math.max(y1, n.y + n.r);
    }
    const top = 52, bottom = $('timebar').hidden ? 16 : 66;
    const right = $('peek').hidden ? 16 : 300;
    const left = 16;
    const w = Math.max(50, S.width - left - right), h = Math.max(50, S.height - top - bottom);
    const pad = S.colorBy === 'project' && S.projects.size > 1 && !nodes ? 70 : 40;
    const k = Math.min(1.8, Math.max(0.08, Math.min(w / (x1 - x0 + pad * 2), h / (y1 - y0 + pad * 2))));
    const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    const t = d3.zoomIdentity.translate(left + w / 2 - cx * k, top + h / 2 - cy * k).scale(k);
    const sel = d3.select(canvas);
    if (animate) sel.transition().duration(650).ease(d3.easeCubicInOut).call(zoom.transform, t);
    else sel.call(zoom.transform, t);
  }

  // ---------- Drawing ----------

  function requestDraw() {
    if (S.drawQueued) return;
    S.drawQueued = true;
    requestAnimationFrame(frame);
  }

  function targetAlpha(n) {
    if (!visible(n)) return 0;
    let a = 1;
    if (S.focusSet && !S.focusSet.has(n.id)) a = 0.07;
    if (S.matches) a = S.matches.has(n.id) ? 1 : Math.min(a, 0.13);
    if (S.hover) {
      const near = n.id === S.hover || S.adj.get(S.hover).has(n.id);
      a = near ? Math.max(a, 0.9) : Math.min(a, 0.18);
    }
    return a;
  }

  function frame(now) {
    S.drawQueued = false;
    let animating = false;
    for (const n of S.nodes) {
      const t = targetAlpha(n);
      if (Math.abs(n.alpha - t) > 0.01) { n.alpha += (t - n.alpha) * 0.22; animating = true; } else n.alpha = t;
      if (n.born) {
        const k = (now - n.born) / 420;
        if (k >= 1) { n.born = null; n.appear = 1; } else { n.appear = d3.easeBackOut.overshoot(2.2)(Math.max(0, k)); animating = true; }
      } else n.appear = 1;
    }
    draw(now);
    if (animating) requestDraw();
  }

  function hullOf(points) {
    if (points.length === 0) return null;
    const cx = d3.mean(points, (p) => p[0]), cy = d3.mean(points, (p) => p[1]);
    // Robust: leave out far outliers so one stray page doesn't stretch the halo across the screen.
    const dist = points.map((p) => Math.hypot(p[0] - cx, p[1] - cy));
    const med = d3.median(dist) || 0;
    const kept = points.filter((p, i) => dist[i] <= Math.max(med * 2.4, 60));
    return { cx, cy, hull: kept.length >= 3 ? d3.polygonHull(kept) : null, kept };
  }

  function draw(now) {
    const { width: W, height: H, dpr } = S;
    const t = S.transform;
    const th = S.theme;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = th.bg;
    ctx.fillRect(0, 0, W, H);
    ctx.save();
    ctx.translate(t.x, t.y);
    ctx.scale(t.k, t.k);
    const k = t.k;

    // 1. Halos per project (whole brain).
    const clusters = [];
    if (S.colorBy === 'project' && S.projects.size > 0) {
      for (const p of S.projects.values()) {
        const members = S.nodes.filter((n) => n.project === p.slug && n.kind !== 'person' && n.alpha > 0.05);
        if (!members.length) continue;
        const h = hullOf(members.map((n) => [n.x, n.y]));
        const dim = S.focusSet ? (members.some((n) => S.focusSet.has(n.id)) ? 1 : 0.3) : 1;
        clusters.push({ p, h, dim, members });
      }
      ctx.restore();
      drawHalos(clusters);
      ctx.save();
      ctx.translate(t.x, t.y);
      ctx.scale(t.k, t.k);
    }

    // 2. Edges, bucketed by opacity (one path per bucket keeps thousands of edges cheap).
    const buckets = new Map();
    const strong = [];
    for (const e of S.links) {
      const s = e.source, d = e.target;
      const a = Math.min(s.alpha * s.appear, d.alpha * d.appear);
      if (a < 0.02) continue;
      const hot = (S.hover && (s.id === S.hover || d.id === S.hover)) ||
        (S.focus && !S.hover && (s.id === S.focus || d.id === S.focus));
      if (hot) { strong.push(e); continue; }
      const q = Math.round((s.kind === 'person' || d.kind === 'person' ? a * 0.6 : a) * 5) / 5;
      if (!buckets.has(q)) buckets.set(q, []);
      buckets.get(q).push(e);
    }
    ctx.strokeStyle = th.edge;
    ctx.lineWidth = 1 / k;
    for (const [a, list] of buckets) {
      ctx.globalAlpha = Math.max(0.05, a);
      ctx.beginPath();
      for (const e of list) { ctx.moveTo(e.source.x, e.source.y); ctx.lineTo(e.target.x, e.target.y); }
      ctx.stroke();
    }
    if (strong.length) {
      ctx.globalAlpha = 1;
      ctx.strokeStyle = th.edgeStrong;
      ctx.lineWidth = 1.6 / k;
      ctx.beginPath();
      for (const e of strong) { ctx.moveTo(e.source.x, e.source.y); ctx.lineTo(e.target.x, e.target.y); }
      ctx.stroke();
    }

    // 3. Nodes.
    const ring = 1.5 / k;
    for (const n of S.nodes) {
      const a = n.alpha;
      if (a < 0.02) continue;
      const r = n.r * n.appear;
      if (r <= 0.1) continue;
      ctx.globalAlpha = a;
      ctx.beginPath();
      if (n.kind === 'page') roundedSquare(n.x, n.y, r * 0.9, r * 0.32);
      else ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      if (n.kind === 'person') {
        ctx.fillStyle = th.person;
        ctx.fill();
        ctx.lineWidth = Math.max(ring, r * 0.22);
        ctx.strokeStyle = th.personRing;
        ctx.stroke();
      } else {
        ctx.fillStyle = n.color;
        ctx.fill();
        ctx.lineWidth = ring;
        ctx.strokeStyle = th.bg;
        ctx.stroke();
      }
      if (n.kind === 'project') {
        ctx.font = `${Math.round(r * 1.05)}px -apple-system, "Apple Color Emoji"`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(projectEmoji(n), n.x, n.y + r * 0.06);
      }
      const ringed = n.id === S.focus || n.id === S.hover || (S.matches && S.matches.has(n.id));
      if (ringed) {
        ctx.beginPath();
        ctx.arc(n.x, n.y, r + 3.5 / k, 0, Math.PI * 2);
        ctx.lineWidth = 2 / k;
        ctx.strokeStyle = n.id === S.focus ? th.text : th.accent;
        ctx.stroke();
      }
      // A ring that expands and fades when a node appears (time strip / replay).
      if (n.born) {
        const p = Math.min(1, (now - n.born) / 700);
        ctx.globalAlpha = (1 - p) * 0.6;
        ctx.beginPath();
        ctx.arc(n.x, n.y, n.r + (6 + 14 * p) / k, 0, Math.PI * 2);
        ctx.lineWidth = 1.5 / k;
        ctx.strokeStyle = n.kind === 'person' ? th.personRing : n.color;
        ctx.stroke();
      }
    }
    ctx.globalAlpha = 1;
    ctx.restore();

    // 4. Labels in screen space (constant size): cluster names first, then the most useful node labels.
    drawLabels(clusters);
  }

  function roundedSquare(x, y, h, rad) {
    ctx.moveTo(x - h + rad, y - h);
    ctx.arcTo(x + h, y - h, x + h, y + h, rad);
    ctx.arcTo(x + h, y + h, x - h, y + h, rad);
    ctx.arcTo(x - h, y + h, x - h, y - h, rad);
    ctx.arcTo(x - h, y - h, x + h, y - h, rad);
    ctx.closePath();
  }

  function drawHalos(clusters) {
    const t = S.transform;
    const s = 1 / 8;
    const hw = Math.ceil(S.width * s) + 2, hh = Math.ceil(S.height * s) + 2;
    if (!S.haloCanvas) S.haloCanvas = document.createElement('canvas');
    const hc = S.haloCanvas;
    if (hc.width !== hw || hc.height !== hh) { hc.width = hw; hc.height = hh; }
    const g = hc.getContext('2d');
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, hw, hh);
    g.setTransform(s * t.k, 0, 0, s * t.k, s * t.x, s * t.y);
    g.lineJoin = 'round';
    g.lineCap = 'round';
    g.lineWidth = Math.max(70, 44 / t.k);
    for (const c of clusters) {
      const h = c.h;
      g.globalAlpha = c.dim;
      g.fillStyle = c.p.color;
      g.strokeStyle = c.p.color;
      g.beginPath();
      if (h.hull) { h.hull.forEach((q, i) => (i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]))); g.closePath(); g.fill(); }
      else if (h.kept.length === 2) { g.moveTo(h.kept[0][0], h.kept[0][1]); g.lineTo(h.kept[1][0], h.kept[1][1]); }
      else { g.moveTo(h.cx, h.cy); g.lineTo(h.cx + 0.1, h.cy); }
      g.stroke();
    }
    ctx.save();
    ctx.setTransform(S.dpr, 0, 0, S.dpr, 0, 0);
    ctx.globalAlpha = S.theme.haloAlpha;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(hc, 0, 0, hw, hh, 0, 0, hw / s, hh / s);
    ctx.restore();
  }

  function textWidth(text, font) {
    const key = font + '|' + text;
    let w = S.textWidths.get(key);
    if (w === undefined) { ctx.font = font; w = ctx.measureText(text).width; S.textWidths.set(key, w); }
    return w;
  }

  function drawLabels(clusters) {
    const t = S.transform;
    const th = S.theme;
    // The floating controls (hint, peek card, chips, tools) are obstacles: no label goes under them.
    const placed = ['hint', 'peek', 'chips', 'tools', 'searchBox'].map($).filter((el) => el && !el.hidden).map((el) => {
      const r = el.getBoundingClientRect();
      return { x: r.left - 4, y: r.top - 4, w: r.width + 8, h: r.height + 8 };
    }).filter((r) => r.w > 8 && r.h > 8);
    const hit = (r) => placed.some((q) => r.x < q.x + q.w && r.x + r.w > q.x && r.y < q.y + q.h && r.y + r.h > q.y);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round';

    // Cluster labels: "emoji name" right by each project's cluster — above it, or below / beside it when that spot
    // would cover other pages or leave the screen.
    const clusterFont = '700 17px -apple-system, "SF Pro Display", sans-serif';
    const screenNodes = S.nodes.filter((n) => n.alpha > 0.3).map((n) => [t.applyX(n.x), t.applyY(n.y), n.r * t.k]);
    const bottomLimit = S.height - ($('timebar').hidden ? 16 : 70);
    for (const c of clusters) {
      const text = `${c.p.emoji} ${c.p.name}`;
      const w = textWidth(text, clusterFont) + 12;
      const xs = c.h.kept.map((q) => t.applyX(q[0])), ys = c.h.kept.map((q) => t.applyY(q[1]));
      const cx = t.applyX(c.h.cx), cy = t.applyY(c.h.cy);
      const minX = d3.min(xs), maxX = d3.max(xs), minY = d3.min(ys), maxY = d3.max(ys);
      const candidates = [
        [cx, minY - 30], [cx, maxY + 30], [minX - w / 2 - 22, cy], [maxX + w / 2 + 22, cy],
      ];
      let x = candidates[0][0], y = candidates[0][1], bestCost = Infinity;
      candidates.forEach(([px, py], idx) => {
        let cost = idx * 0.5;
        if (px - w / 2 < 6 || px + w / 2 > S.width - 6 || py < 18 || py > bottomLimit) cost += 100;
        for (const [nx, ny, nr] of screenNodes) {
          if (nx + nr > px - w / 2 && nx - nr < px + w / 2 && ny + nr > py - 13 && ny - nr < py + 13) cost += 1;
        }
        for (const q of placed) if (px - w / 2 < q.x + q.w && px + w / 2 > q.x && py - 13 < q.y + q.h && py + 13 > q.y) cost += 50;
        if (cost < bestCost) { bestCost = cost; x = px; y = py; }
      });
      x = Math.max(w / 2 + 8, Math.min(S.width - w / 2 - 8, x));
      y = Math.max(20, Math.min(bottomLimit, y));
      const rect = { x: x - w / 2, y: y - 13, w, h: 26 };
      placed.push(rect);
      ctx.globalAlpha = c.dim;
      ctx.font = clusterFont;
      ctx.lineWidth = 6;
      ctx.strokeStyle = th.labelHalo;
      ctx.strokeText(text, x, y);
      ctx.fillStyle = c.p.labelColor;
      ctx.fillText(text, x, y);
    }
    ctx.globalAlpha = 1;

    for (const n of S.nodes) {
      if (n.kind !== 'project' || n.alpha < 0.3) continue;
      const r = n.r * t.k + 2;
      placed.push({ x: t.applyX(n.x) - r, y: t.applyY(n.y) - r, w: r * 2, h: r * 2 });
    }

    // Node labels, by priority, skipping any that would overlap.
    const vis = S.nodes.filter((n) => n.alpha > 0.5 && n.appear > 0.6);
    const ranked = vis.filter((n) => n.kind !== 'page' && n.kind !== 'project').sort((a, b) => b.links - a.links);
    const K = Math.round(Math.min(40, Math.max(7, 6 + vis.length * 0.07)) * Math.min(3, Math.max(0.6, t.k)));
    const prio = new Map();
    ranked.slice(0, K).forEach((n, i) => prio.set(n.id, 10 + (K - i) / K));
    for (const n of vis) if (isOverview(n)) prio.set(n.id, 25);
    // The 3 most connected knowledge pages (topics, meetings, decisions …) of each project.
    const perProject = new Map();
    for (const n of ranked) {
      if (isHub(n) || !n.project) continue;
      const c = perProject.get(n.project) || 0;
      if (c >= 3) continue;
      perProject.set(n.project, c + 1);
      prio.set(n.id, Math.max(prio.get(n.id) || 0, 20 + n.links / 1000));
    }
    if (t.k >= 1.8) vis.forEach((n) => { if (!prio.has(n.id)) prio.set(n.id, 5 + n.links / 1000); });
    const bump = (id, p) => { if (S.byId.has(id)) prio.set(id, Math.max(prio.get(id) || 0, p)); };
    if (S.focus) { bump(S.focus, 90); for (const id of S.adj.get(S.focus)) if (S.focusSet.has(id)) bump(id, 40 + (S.byId.get(id).links / 1000)); }
    if (S.matches) for (const id of S.matches) bump(id, 70);
    if (S.hover) { bump(S.hover, 100); for (const id of S.adj.get(S.hover)) bump(id, 30); }
    // In a cluster view the project hub carries the cluster label already.
    if (S.colorBy === 'project') for (const n of vis) if (n.kind === 'project' && prio.get(n.id) < 30) prio.delete(n.id);

    const items = [...prio.entries()].map(([id, p]) => [S.byId.get(id), p]).filter(([n]) => n && n.alpha > 0.05)
      .sort((a, b) => b[1] - a[1]).slice(0, 160);
    for (const [n, p] of items) {
      const strong = p >= 30;
      const font = `${strong ? 600 : 500} ${strong ? 12 : 11}px -apple-system, "SF Pro Text", sans-serif`;
      let text = n.kind === 'project' ? `${projectEmoji(n)} ${projectName(n)}`
        : isOverview(n) ? `📋 ${S.labels.overview || n.title}` : n.title;
      if (text.length > 38) text = text.slice(0, 36) + '…';
      const w = textWidth(text, font) + 6;
      const x = t.applyX(n.x), y = t.applyY(n.y) + n.r * n.appear * t.k + 9;
      const rect = { x: x - w / 2, y: y - 7, w, h: 14 };
      if (p < 90 && hit(rect)) continue;
      if (x < -w || x > S.width + w || y < -20 || y > S.height + 20) continue;
      placed.push(rect);
      ctx.globalAlpha = Math.min(1, n.alpha * 1.1);
      ctx.font = font;
      ctx.lineWidth = 3.5;
      ctx.strokeStyle = th.labelHalo;
      ctx.strokeText(text, x, y);
      ctx.fillStyle = strong ? th.text : th.muted;
      ctx.fillText(text, x, y);
    }
    ctx.globalAlpha = 1;
  }

  // ---------- Pointer ----------

  function nodeAt(px, py) {
    const t = S.transform;
    const x = t.invertX(px), y = t.invertY(py);
    let best = null, bestD = Infinity;
    for (const n of S.nodes) {
      if (n.alpha < 0.3 || !visible(n)) continue;
      const d = Math.hypot(n.x - x, n.y - y);
      const reach = n.r + 5 / t.k;
      if (d < reach && d < bestD) { best = n; bestD = d; }
    }
    return best;
  }

  function showTooltip(n, px, py) {
    const tip = $('tooltip');
    if (!n) { tip.hidden = true; return; }
    const color = n.kind === 'person' ? S.theme.personRing : n.color;
    const parts = [kindLabel(n.kind)];
    if (n.date) parts.push(fmtDate(n.date, true));
    parts.push(L('links', degreeVisible(n)));
    tip.innerHTML = `<b>${esc(n.kind === 'project' ? projectEmoji(n) + ' ' + projectName(n) : n.title)}</b>` +
      `<div class="sub" style="--c:${color}">${glyph(n.kind === 'project' ? 'project' : n.kind)}<span>${esc(parts.join(' · '))}</span></div>`;
    tip.hidden = false;
    const r = tip.getBoundingClientRect();
    let x = px + 14, y = py + 14;
    if (x + r.width > S.width - 8) x = px - r.width - 14;
    if (y + r.height > S.height - 60) y = py - r.height - 14;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }

  function setupPointer() {
    zoom = d3.zoom().scaleExtent([0.06, 8]).clickDistance(4)
      .on('zoom', (e) => { S.transform = e.transform; requestDraw(); });

    const drag = d3.drag()
      .container(canvas)
      .clickDistance(4)
      .subject((e) => {
        const [px, py] = d3.pointer(e.sourceEvent || e, canvas);
        return nodeAt(px, py) || undefined;
      })
      .on('start', (e) => {
        if (!e.active) S.sim.alphaTarget(0.25).restart();
        e.subject.fx = e.subject.x;
        e.subject.fy = e.subject.y;
        canvas.classList.add('dragging');
        $('tooltip').hidden = true;
      })
      .on('drag', (e) => {
        const [px, py] = d3.pointer(e.sourceEvent, canvas);
        e.subject.fx = S.transform.invertX(px);
        e.subject.fy = S.transform.invertY(py);
      })
      .on('end', (e) => {
        if (!e.active) S.sim.alphaTarget(0);
        e.subject.fx = null;
        e.subject.fy = null;
        canvas.classList.remove('dragging');
      });

    d3.select(canvas).call(drag).call(zoom).on('dblclick.zoom', null);

    canvas.addEventListener('mousemove', (e) => {
      if (canvas.classList.contains('dragging')) return;
      const n = nodeAt(e.offsetX, e.offsetY);
      const id = n ? n.id : null;
      canvas.classList.toggle('pointer', !!n);
      if (id !== S.hover) { S.hover = id; requestDraw(); }
      showTooltip(n, e.offsetX, e.offsetY);
    });
    canvas.addEventListener('mouseleave', () => {
      S.hover = null;
      $('tooltip').hidden = true;
      requestDraw();
    });
    canvas.addEventListener('click', (e) => {
      const n = nodeAt(e.offsetX, e.offsetY);
      if (n) setFocus(n.id);
      else clearFocus();
    });
  }

  function setupControls() {
    $('showAll').textContent = L('showAll');
    $('showAll').onclick = () => clearFocus();
    $('fitBtn').innerHTML = glyph('fit');
    $('fitBtn').onclick = () => fit(S.focus ? [...S.focusSet].map((i) => S.byId.get(i)) : null, true);
    $('searchBtn').innerHTML = glyph('search');
    $('searchBtn').onclick = () => toggleSearch(!S.searchOpen);
    $('searchGlyph').innerHTML = glyph('search');
    $('searchInput').addEventListener('input', (e) => { S.query = e.target.value; applySearch(); });
    $('searchInput').addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && S.matches && S.matches.size) {
        const best = [...S.matches].map((id) => S.byId.get(id)).sort((a, b) => b.links - a.links)[0];
        setFocus(best.id);
      }
      if (e.key === 'Escape') { e.stopPropagation(); toggleSearch(false); }
    });
    $('peekClose').onclick = () => clearFocus();
    $('hintClose').onclick = () => { $('hint').hidden = true; navigate('sbgraph://hint-dismissed'); };
    $('playBtn').onclick = () => (S.playing ? stopPlay() : startPlay());

    const strip = $('strip');
    let scrubbing = false;
    strip.addEventListener('pointerdown', (e) => {
      scrubbing = true;
      strip.setPointerCapture(e.pointerId);
      strip.classList.add('active');
      setTime(stripTime(e), true);
    });
    strip.addEventListener('pointermove', (e) => { if (scrubbing) setTime(stripTime(e), true); });
    const end = () => { if (!scrubbing) return; scrubbing = false; strip.classList.remove('active'); };
    strip.addEventListener('pointerup', end);
    strip.addEventListener('pointercancel', end);

    document.addEventListener('keydown', (e) => {
      if (e.metaKey && (e.key === 'f' || e.key === 'F')) { e.preventDefault(); toggleSearch(); return; }
      if (e.key === 'Escape') {
        if (S.searchOpen) toggleSearch(false);
        else if (S.focus) clearFocus();
      }
    });
  }

  function updateControlLabels() {
    $('fitBtn').title = L('fit');
    $('fitBtn').setAttribute('aria-label', L('fit'));
    $('searchBtn').title = L('search') + ' (⌘F)';
    $('searchBtn').setAttribute('aria-label', L('search'));
    $('searchInput').placeholder = L('search');
    $('showAll').textContent = L('showAll');
    $('peekClose').setAttribute('aria-label', L('close'));
    $('hintClose').setAttribute('aria-label', L('close'));
  }

  function resize() {
    const r = $('stage').getBoundingClientRect();
    S.width = r.width;
    S.height = r.height;
    S.dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(r.width * S.dpr);
    canvas.height = Math.round(r.height * S.dpr);
    requestDraw();
  }

  // ---------- Boot ----------

  function boot() {
    canvas = $('canvas');
    ctx = canvas.getContext('2d');
    resize();
    new ResizeObserver(() => resize()).observe($('stage'));
    setupPointer();
    setupControls();
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { readTheme(); requestDraw(); });
  }

  const errors = [];
  window.addEventListener('error', (e) => errors.push(String(e.message)));

  window.SB = {
    render(payload) {
      if (!canvas) boot();
      render(payload);
      updateControlLabels();
    },
    focus(id) {
      if (!id) clearFocus();
      else if (S.byId.has(id)) setFocus(id);
    },
    setTheme(theme) {
      document.documentElement.dataset.theme = theme;
      readTheme();
      if (S.focus) showPeek(S.byId.get(S.focus));
      buildTimebar();
      requestDraw();
    },
    toggleSearch() { if (canvas) toggleSearch(); },
    // Development: exercise focus, search, filters and the time strip; returns what broke (snapshots print it).
    selfcheck() {
      const out = [];
      const tryIt = (name, f) => { try { f(); out.push(name + ':ok'); } catch (e) { out.push(name + ':FAIL ' + e.message); } };
      const someNode = S.nodes.find((n) => n.kind === 'topic') || S.nodes[0];
      tryIt('focus', () => { setFocus(someNode.id, false); if (!S.focusSet || !S.focusSet.has(someNode.id)) throw new Error('no focus set'); });
      tryIt('focusSize', () => { if (S.focusSet.size >= S.nodes.length && S.nodes.length > 30) throw new Error('2 hops = everything'); });
      tryIt('peek', () => { if ($('peek').hidden || !$('peekTitle').textContent) throw new Error('peek hidden'); });
      tryIt('clear', () => { clearFocus(false); if (S.focus || !$('peek').hidden) throw new Error('still focused'); });
      tryIt('search', () => { toggleSearch(true); S.query = someNode.title.slice(0, 4); applySearch(); if (!S.matches || !S.matches.size) throw new Error('no matches'); toggleSearch(false); });
      tryIt('time', () => {
        setTime((S.timeMin + S.timeMax) / 2, true);
        const hidden = S.nodes.filter((n) => !visible(n)).length;
        if (hasDates() && !hidden) throw new Error('nothing hidden mid-way');
        if (S.nodes.some((n) => !n.date && !visible(n) && !S.hiddenKinds.has(n.kind))) throw new Error('undated hidden');
        setTime(Infinity, true);
        if (S.nodes.some((n) => !visible(n))) throw new Error('not all visible at Hoy');
      });
      tryIt('play', () => { startPlay(50); stopPlay(); setTime(Infinity, false); });
      tryIt('kinds', () => { S.hiddenKinds.add('person'); afterVisibilityChange(); if (S.nodes.some((n) => n.kind === 'person' && visible(n))) throw new Error('filter'); S.hiddenKinds.clear(); afterVisibilityChange(); });
      tryIt('hover', () => { S.hover = someNode.id; frame(performance.now()); S.hover = null; frame(performance.now()); });
      tryIt('theme', () => { const th = document.documentElement.dataset.theme; SB.setTheme(th === 'dark' ? 'light' : 'dark'); SB.setTheme(th || 'light'); });
      if (errors.length) out.push('errors:' + errors.join(' | '));
      fit(null, false);
      frame(performance.now());
      return out.join(' ');
    },
    bench() {
      const t0 = performance.now();
      for (let i = 0; i < 20; i++) draw(performance.now());
      const t1 = performance.now();
      const sim = S.sim;
      sim.alpha(0.3);
      for (let i = 0; i < 20; i++) sim.tick();
      sim.stop();
      const t2 = performance.now();
      return `nodes=${S.nodes.length} edges=${S.links.length} draw=${((t1 - t0) / 20).toFixed(1)}ms tick=${((t2 - t1) / 20).toFixed(1)}ms`;
    },
    // Development: run the simulation to rest and draw now (snapshots).
    settle() { if (!S.sim) return; S.sim.stop(); for (let i = 0; i < 200; i++) S.sim.tick(); fit(null, false); frame(performance.now()); },
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
