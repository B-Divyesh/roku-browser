// Runs in the laptop's browser once a page has loaded and its JavaScript has run. Turns
// what is actually rendered (CSS decides what's hidden) into Lite mode's own document
// structure, which the Roku reads with its built-in JSON parser: no HTML parsing in
// BrightScript, and pages built with JavaScript work. Mirrors channel/components/lite/
// HtmlParser.brs, block for block.
(() => {
  const MAX_BLOCKS = 900;     // what Lite mode lays out; menus are dropped before this cap
  const WALK_LIMIT = 4000;
  const meta = name => {
    const m = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
    return m ? (m.content || '') : '';
  };
  const doc = {
    title: (document.title || '').trim(), url: location.href, base: document.baseURI,
    blocks: [], links: [], forms: [], videos: [], image: meta('og:image'),
    description: meta('og:description') || meta('description'), ogTitle: meta('og:title'),
    canonical: (document.querySelector('link[rel=canonical]') || {}).href || '', mainStart: -1,
  };
  if (!doc.title) doc.title = doc.ogTitle;

  const KINDS = {H1: 'h1', H2: 'h2', H3: 'h3', H4: 'h4', H5: 'h4', H6: 'h4', LI: 'li',
                 BLOCKQUOTE: 'quote', PRE: 'pre', FIGCAPTION: 'caption'};
  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'CANVAS', 'IFRAME', 'OBJECT',
                        'EMBED', 'HEAD', 'svg', 'math', 'DIALOG']);
  // Navigation wherever it is; a header or footer only outside the main content, since
  // inside an article it holds the article's own title or byline.
  const CHROME_TAGS = new Set(['NAV', 'ASIDE']);
  const OUTER_TAGS = new Set(['HEADER', 'FOOTER']);
  const CHROME_ROLES = new Set(['navigation', 'complementary', 'search']);
  const OUTER_ROLES = new Set(['banner', 'contentinfo']);
  const CHROME_NAMES = /(^|[-_\s])(nav|navbar|navigation|sidebar|side-bar|menu|toc|breadcrumbs?)([-_\s]|$)/i;
  const length = s => Array.from(s).length;   // BrightScript counts characters, not UTF-16 units

  const linkAt = new Map(), formAt = new Map(), videoKeys = new Set();
  let runs = [], plain = '', kind = 'p', link = -1, bold = 0, pre = 0, quote = 0, li = 0;
  let liFresh = false, space = false, chrome = 0, main = 0, mainSeen = false, markStart = false;

  function flush() {
    if (!runs.length) return;
    if (!plain.trim()) { runs = []; plain = ''; space = false; return; }
    let k = kind;
    if (k === 'p') k = quote ? 'quote' : li ? 'lic' : 'p';
    if (k === 'li') { if (!liFresh) k = 'lic'; liFresh = false; }
    push({k, r: runs, t: plain});
    runs = []; plain = ''; space = false;
  }
  function push(block) {
    if (doc.blocks.length >= WALK_LIMIT) return;
    if (chrome) block.c = true;
    if (main) block.m = true;
    if (markStart && block.t !== undefined) { block.start = true; markStart = false; }
    doc.blocks.push(block);
  }
  function addRun(s) {
    const b = bold > 0, last = runs[runs.length - 1];
    if (last && last.a === link && last.b === b) { last.s += s; plain += s; return; }
    runs.push({s, a: link, b, o: length(plain)});
    plain += s;
  }
  function addText(t) {
    if (pre) { addRun(t); return; }
    const trimmed = t.replace(/\s+/g, ' ').trim();
    if (!trimmed) { if (t) space = true; return; }
    const lead = /^\s/.test(t), trail = /\s$/.test(t);
    let s = trimmed;
    if ((lead || space) && plain && !plain.endsWith('\n')) s = ' ' + s;
    space = trail;
    addRun(s);
  }
  function linkIndex(a) {
    const href = a.href;
    if (!href || !/^https?:/.test(href)) return -1;
    if (!linkAt.has(href)) { linkAt.set(href, doc.links.length); doc.links.push({u: href}); }
    return linkAt.get(href);
  }
  function formIndex(form) {
    if (!form) return -1;
    if (!formAt.has(form)) {
      formAt.set(form, doc.forms.length);
      const hidden = [];
      for (const h of form.querySelectorAll('input[type=hidden]')) if (h.name) hidden.push({n: h.name, v: h.value});
      doc.forms.push({action: form.action || location.href, method: (form.method || 'get').toLowerCase(), hidden});
    }
    return formAt.get(form);
  }
  function mediaFormat(u) {
    const path = u.split(/[?#]/)[0].toLowerCase();
    if (path.endsWith('.m3u8')) return 'hls';
    if (path.endsWith('.mpd')) return 'dash';
    if (/\.(mp4|m4v|mov)$/.test(path)) return 'mp4';
    if (path.endsWith('.mp3')) return 'mp3';
    return '';
  }
  function addVideo(item) {
    if (!videoKeys.has(item.key)) { videoKeys.add(item.key); doc.videos.push(item); }
  }
  function youtube(u) {
    const m = u.match(/(?:youtube(?:-nocookie)?\.com\/(?:embed\/|watch\?v=|shorts\/)|youtu\.be\/)([\w-]{11})/);
    return m ? m[1] : '';
  }
  function hidden(el, cs) {
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return true;
    if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
    if (cs.position === 'absolute' || cs.position === 'fixed') {
      const r = el.getBoundingClientRect();
      if (r.width <= 1 && r.height <= 1) return true;   // screen-reader-only text
    }
    return false;
  }
  function formBlock(el, tag) {
    const f = formIndex(el.form);
    const type = (el.type || '').toLowerCase();
    if (tag === 'BUTTON' || type === 'submit' || type === 'image' || type === 'button') {
      if (type === 'button' && !el.form) return;
      const label = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim();
      if (label) { flush(); push({k: 'button', f, label, n: el.name || '', v: el.value || ''}); }
      return;
    }
    if (tag === 'SELECT') {
      if (f >= 0 && el.name) doc.forms[f].hidden.push({n: el.name, v: el.value});
      return;
    }
    if (type === 'hidden') return;
    if (type === 'checkbox' || type === 'radio') {
      if (f >= 0 && el.name && el.checked) doc.forms[f].hidden.push({n: el.name, v: el.value || 'on'});
      return;
    }
    flush();
    push({k: 'input', f, n: el.name || '', v: el.value || '',
          ph: el.placeholder || el.getAttribute('aria-label') || '', type: tag === 'TEXTAREA' ? 'textarea' : (type || 'text')});
  }
  function image(el) {
    const r = el.getBoundingClientRect();
    const w = el.naturalWidth || Math.round(r.width), h = el.naturalHeight || Math.round(r.height);
    if (r.width < 48 || r.height < 32) return;          // icons, spacers, trackers
    const src = el.currentSrc || el.src;
    if (!/^https?:/.test(src)) return;
    flush();
    push({k: 'img', src, alt: (el.alt || '').trim(), w, h, a: link});
  }

  function walk(node) {
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (doc.blocks.length >= WALK_LIMIT) return;
      if (child.nodeType === Node.TEXT_NODE) { addText(child.data); continue; }
      if (child.nodeType !== Node.ELEMENT_NODE) continue;
      const tag = child.tagName;
      if (SKIP.has(tag)) {
        if (tag === 'IFRAME') {
          const yt = youtube(child.src || '');
          if (yt) addVideo({yt, key: 'yt:' + yt});
        }
        continue;
      }
      const cs = getComputedStyle(child);
      if (hidden(child, cs)) continue;
      if (tag === 'BR') { if (!pre) addRun('\n'); continue; }
      if (tag === 'HR') { flush(); push({k: 'hr'}); continue; }
      if (tag === 'IMG') { image(child); continue; }
      if (tag === 'VIDEO' || tag === 'AUDIO') {
        const u = child.currentSrc || child.src || (child.querySelector('source') || {}).src || '';
        if (/^https?:/.test(u) && mediaFormat(u)) addVideo({u, fmt: mediaFormat(u), key: u});
        continue;
      }
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'BUTTON') { formBlock(child, tag); continue; }

      // Table cells read along their row, as in HtmlParser; rows and real blocks break lines.
      const display = cs.display;
      const cell = display === 'table-cell' || display === 'table-column' || display === 'table-caption';
      const blockish = !!KINDS[tag] || !(cell || display.startsWith('inline') || display === 'contents' || display === 'ruby');
      if (cell) space = true;
      const role = child.getAttribute('role') || '';
      const isChrome = CHROME_TAGS.has(tag) || CHROME_ROLES.has(role) ||
                       (main === 0 && (OUTER_TAGS.has(tag) || OUTER_ROLES.has(role))) ||
                       CHROME_NAMES.test(child.id) || CHROME_NAMES.test(typeof child.className === 'string' ? child.className : '');
      const isMain = tag === 'MAIN' || role === 'main' || (tag === 'ARTICLE' && !mainSeen);
      const heavy = parseInt(cs.fontWeight, 10) >= 600;
      const savedKind = kind, savedLink = link;
      if (blockish) {
        flush();
        if (KINDS[tag]) kind = KINDS[tag];
        if (tag === 'LI') { li++; liFresh = true; }
        if (tag === 'BLOCKQUOTE') quote++;
        if (tag === 'PRE') pre++;
      }
      if (isChrome) chrome++;
      if (isMain) { main++; if (!mainSeen) { mainSeen = true; markStart = true; } }
      if (heavy) bold++;
      if (tag === 'A') link = linkIndex(child);
      walk(child);
      if (tag === 'A') link = savedLink;
      if (heavy) bold--;
      if (isMain) main--;
      if (isChrome) chrome--;
      if (blockish) {
        flush();
        if (tag === 'LI') li--;
        if (tag === 'BLOCKQUOTE') quote--;
        if (tag === 'PRE') pre--;
        kind = savedKind;
      }
    }
  }

  walk(document.body || document.documentElement);
  flush();

  // As HtmlParser's finishDoc: with a substantial article, leave out navigation and footers.
  let mainChars = 0;
  for (const b of doc.blocks) if (b.m && !b.c && b.t) mainChars += b.t.length;
  if (mainChars > 1200) doc.blocks = doc.blocks.filter(b => !b.c);
  doc.blocks = doc.blocks.slice(0, MAX_BLOCKS);
  const og = meta('og:video') || meta('og:video:url');
  if (og) {
    const yt = youtube(og);
    if (yt) addVideo({yt, key: 'yt:' + yt});
    else if (mediaFormat(og)) addVideo({u: og, fmt: mediaFormat(og), key: og});
  }
  if (doc.videos.length) {
    const cards = doc.videos.slice(0, 3).map(v => ({k: 'video', v, title: doc.title, thumb: doc.image}));
    doc.blocks = cards.concat(doc.blocks);
  }
  doc.mainStart = doc.blocks.findIndex(b => b.start);
  let chars = 0;
  for (const b of doc.blocks) if (b.t) chars += b.t.length;
  doc.chars = chars;
  return doc;
})()
