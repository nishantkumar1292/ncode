'use strict';
/* Markdown → sanitized HTML with GFM tables, highlighted code, KaTeX math, Mermaid. */
(function () {
  const BASE = (document.currentScript && document.currentScript.src || '').replace(/[^/]*$/, '');
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const LANG_ALIASES = { sh: 'bash', shell: 'bash', zsh: 'bash', console: 'bash', py: 'python', js: 'javascript', ts: 'typescript', tsx: 'typescript', jsx: 'javascript', yml: 'yaml', md: 'markdown', rb: 'ruby', rs: 'rust', kt: 'kotlin', 'objective-c': 'objectivec', txt: 'plaintext', text: 'plaintext', jsonl: 'json', html: 'xml', svg: 'xml', golang: 'go', 'c++': 'cpp', 'c#': 'csharp', cs: 'csharp', tf: 'ini', toml: 'ini', dockerfile: 'dockerfile' };

  function highlight(code, lang) {
    const l = (lang || '').toLowerCase();
    const name = LANG_ALIASES[l] || l;
    try {
      if (name && hljs.getLanguage(name)) return hljs.highlight(code, { language: name, ignoreIllegals: true }).value;
      if (!name && code.length < 4000) return hljs.highlightAuto(code).value;
    } catch (_) {}
    return esc(code);
  }

  const renderer = new marked.Renderer();
  renderer.code = function (token) {
    const text = typeof token === 'object' ? token.text : arguments[0];
    const lang = ((typeof token === 'object' ? token.lang : arguments[1]) || '').trim().split(/\s+/)[0];
    if (lang === 'mermaid') {
      return `<div class="mermaid-block"><pre class="kv">${esc(text)}</pre></div>`;
    }
    return `<div class="code-block"><div class="code-head"><span>${esc(lang || 'code')}</span>` +
      `<button class="mini-btn copy-code">Copy</button></div>` +
      `<pre><code class="hljs">${highlight(text, lang)}</code></pre></div>`;
  };
  renderer.table = function (token) {
    // Wrap tables so wide ones scroll horizontally.
    const html = marked.Renderer.prototype.table.call(this, token);
    return `<div class="table-wrap">${html}</div>`;
  };
  marked.use({ gfm: true, breaks: false, renderer });

  // ---- Math: pull out before markdown parsing so `_` and `*` survive. Skip code. ----
  function extractMath(src) {
    const store = [];
    const parts = src.split(/(```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`[^`\n]+`)/g);
    const put = (tex, display) => { store.push({ tex, display }); return `\uE000M${store.length - 1}\uE001`; };
    for (let i = 0; i < parts.length; i += 2) {
      let s = parts[i];
      if (!s) continue;
      s = s.replace(/\$\$([\s\S]+?)\$\$/g, (_, t) => put(t, true));
      s = s.replace(/\\\[([\s\S]+?)\\\]/g, (_, t) => put(t, true));
      s = s.replace(/\\\(([\s\S]+?)\\\)/g, (_, t) => put(t, false));
      // $inline$: opening $ not followed by space/digit, closing $ not preceded by space nor followed by a digit.
      s = s.replace(/(^|[^\\$\w])\$(?=[^\s$\d])((?:\\\$|[^$\n])+?[^\s\\])\$(?![\w$])/g, (m, pre, t) => pre + put(t, false));
      parts[i] = s;
    }
    return { text: parts.join(''), store };
  }
  function restoreMath(html, store) {
    if (!store.length) return html;
    return html.replace(/\uE000M(\d+)\uE001/g, (_, i) => {
      const { tex, display } = store[+i];
      try { return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'htmlAndMathml' }); }
      catch (_) { return `<code class="math-error">${esc(tex)}</code>`; }
    });
  }

  let cwdForImages = '';
  DOMPurify.addHook('afterSanitizeAttributes', (node) => {
    if (node.tagName === 'A') { node.setAttribute('rel', 'noopener'); }
    if (node.tagName === 'IMG') {
      const src = node.getAttribute('src') || '';
      if (/^(https?:|data:|ncode:)/i.test(src)) return;
      let p = src.replace(/^file:\/\//, '');
      if (p.startsWith('~/')) p = (window.__home || '') + p.slice(1);
      else if (!p.startsWith('/') && cwdForImages) p = cwdForImages.replace(/\/$/, '') + '/' + p;
      node.setAttribute('src', 'ncode://file' + encodeURI(p));
    }
  });

  const PATHISH = /^(?:~|\.{1,2})?\/?[\w@.-]+(?:\/[\w@.+-]+)*\.[A-Za-z0-9]{1,8}(?::\d+(?:-\d+)?)?$/;

  window.MD = {
    render(src, opts = {}) {
      cwdForImages = opts.cwd || '';
      const { text, store } = extractMath(src || '');
      let html;
      try { html = marked.parse(text); } catch (e) { html = `<pre>${esc(src)}</pre>`; }
      html = DOMPurify.sanitize(html, { ADD_ATTR: ['data-src', 'target'], FORBID_TAGS: ['style'] });
      return restoreMath(html, store);
    },
    /** Post-insertion enhancements that need the DOM. */
    enhance(root, opts = {}) {
      root.querySelectorAll(':not(pre) > code').forEach((c) => {
        if (c.classList.contains('path-link')) return;
        const t = c.textContent.trim();
        if (t.length < 200 && PATHISH.test(t) && t.includes('.')) { c.classList.add('path-link'); c.dataset.path = t; }
      });
      if (opts.final) root.querySelectorAll('.mermaid-block:not([data-done])').forEach(renderMermaid);
    },
    highlight,
    esc,
  };

  // ---- Mermaid, lazy-loaded on first use. ----
  let mermaidLoading = null;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve(window.mermaid);
    if (!mermaidLoading) {
      mermaidLoading = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = BASE + 'vendor/mermaid.min.js';
        s.onload = () => {
          const dark = matchMedia('(prefers-color-scheme: dark)').matches;
          window.mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'neutral', securityLevel: 'strict', fontFamily: '-apple-system, sans-serif' });
          resolve(window.mermaid);
        };
        s.onerror = reject;
        document.head.appendChild(s);
      });
    }
    return mermaidLoading;
  }
  let mermaidSeq = 0;
  const mermaidCache = new Map();
  async function renderMermaid(el) {
    el.dataset.done = '1';
    const src = (el.querySelector('pre') || el).textContent || '';
    if (mermaidCache.has(src)) { el.innerHTML = mermaidCache.get(src); return; }
    const id = 'mmd' + (++mermaidSeq);
    try {
      const m = await loadMermaid();
      const { svg } = await m.render(id, src);
      mermaidCache.set(src, svg);
      el.innerHTML = svg;
    } catch (e) {
      const html = `<div class="code-head"><span>mermaid · could not render</span></div><pre class="kv">${esc(src)}</pre>`;
      mermaidCache.set(src, html);
      el.innerHTML = html;
    } finally {
      document.getElementById('d' + id)?.remove();   // mermaid leaves a scratch node behind
    }
  }
})();
