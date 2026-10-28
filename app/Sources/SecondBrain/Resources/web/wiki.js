(function () {
  "use strict";

  const PAGE_PREFIX = "sbwiki://page/";
  // Only front-matter keys with a localized label (payload.propLabels) become chips, in this order; raw keys such as
  // `owner`, `organization` (until it has a label), `source_id` never show (CONTRACT §12.7 / §15.4).
  const PROP_ORDER = ["type", "status", "date", "updated", "duration", "project", "projects", "organization", "role", "people"];
  const MONTHS = {
    es: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"],
    en: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  };
  let lang = "es";

  let links = {};
  let titles = {};

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // Splits YAML front matter off the document and returns simple key/value pairs for the chip row.
  function splitFrontMatter(src) {
    const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(src);
    if (!m) return { body: src, props: [] };
    const props = [];
    for (const line of m[1].split(/\r?\n/)) {
      const kv = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
      if (!kv) continue;
      let value = kv[2].replace(/\s+#.*$/, "").trim();
      if (!value || value === "null" || value === "[]") continue;
      value = value.replace(/^\[|\]$/g, "").replace(/["']/g, "").replace(/\[\[|\]\]/g, "");
      props.push([kv[1], value]);
    }
    return { body: src.slice(m[0].length), props };
  }

  // "2026-09-22" (or an ISO date-time) → "22 sep 2026" / "Sep 22, 2026". Returns null when it is not a date.
  function humanDate(value) {
    const d = /^(\d{4})-(\d{2})-(\d{2})(?:[T ][\d:.]+(?:Z|[+-]\d{2}:?\d{2})?)?$/.exec(value);
    if (!d) return null;
    const month = +d[2] - 1, day = +d[3];
    if (month < 0 || month > 11 || day < 1 || day > 31) return null;
    const m = (MONTHS[lang] || MONTHS.es)[month];
    return lang === "en" ? m + " " + day + ", " + d[1] : day + " " + m + " " + d[1];
  }

  function wikilinkPlugin(md) {
    md.inline.ruler.before("link", "wikilink", function (state, silent) {
      const src = state.src, pos = state.pos;
      if (src.charCodeAt(pos) !== 0x5B || src.charCodeAt(pos + 1) !== 0x5B) return false;
      const end = src.indexOf("]]", pos + 2);
      if (end < 0) return false;
      const inner = src.slice(pos + 2, end);
      if (!inner || inner.includes("\n") || inner.includes("[")) return false;
      if (!silent) {
        const bar = inner.indexOf("|");
        const rawTarget = (bar >= 0 ? inner.slice(0, bar) : inner).trim();
        const label = (bar >= 0 ? inner.slice(bar + 1) : inner).trim();
        const target = rawTarget.split("#")[0].trim();
        const token = state.push("wikilink", "", 0);
        token.meta = { target, label: label || target, labeled: bar >= 0 && label.length > 0 };
      }
      state.pos = end + 2;
      return true;
    });
    md.renderer.rules.wikilink = function (tokens, idx) {
      const { target, labeled } = tokens[idx].meta;
      const path = links[target];
      // An unlabeled [[slug]] shows its page's title (payload.titles), never the bare slug.
      const label = labeled ? tokens[idx].meta.label : (titles[target] || tokens[idx].meta.label);
      if (path) {
        return '<a class="wikilink" href="' + PAGE_PREFIX + encodeURIComponent(path) + '">' + escapeHTML(label) + "</a>";
      }
      return '<span class="wikilink broken" title="' + escapeHTML(target) + '">' + escapeHTML(label) + "</span>";
    };
  }

  const md = window.markdownit({ html: false, linkify: true, typographer: true, breaks: false }).use(wikilinkPlugin);

  function decorate(root) {
    for (const bq of root.querySelectorAll("blockquote")) {
      const p = bq.querySelector("p");
      if (!p) continue;
      const m = /^\[!(\w+)\][+-]?\s*/.exec(p.textContent);
      if (!m) continue;
      bq.classList.add("callout", "callout-" + m[1].toLowerCase());
      const firstText = p.firstChild;
      if (firstText && firstText.nodeType === Node.TEXT_NODE) {
        firstText.textContent = firstText.textContent.replace(/^\[!\w+\][+-]?\s*/, "");
      }
    }
    for (const li of root.querySelectorAll("li")) {
      const target = li.firstChild && li.firstChild.nodeType === Node.TEXT_NODE ? li.firstChild
        : (li.firstElementChild && li.firstElementChild.tagName === "P" ? li.firstElementChild.firstChild : null);
      if (!target || target.nodeType !== Node.TEXT_NODE) continue;
      const m = /^\[( |x|X)\]\s+/.exec(target.textContent);
      if (!m) continue;
      target.textContent = target.textContent.slice(m[0].length);
      const box = document.createElement("input");
      box.type = "checkbox";
      box.disabled = true;
      box.checked = m[1] !== " ";
      target.parentNode.insertBefore(box, target);
      li.style.listStyle = "none";
    }
    for (const a of root.querySelectorAll("a[href^='http']")) a.setAttribute("target", "_blank");
    // Bare ISO dates in prose read as dates ("del 2026-10-26" → "del 26 oct 2026"); code keeps them verbatim.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (t) => (t.parentElement.closest("code, pre") || !/\d{4}-\d{2}-\d{2}/.test(t.nodeValue)
        ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const texts = [];
    while (walker.nextNode()) texts.push(walker.currentNode);
    for (const t of texts) {
      t.nodeValue = t.nodeValue.replace(/(?<![\w-])(\d{4}-\d{2}-\d{2})(?![\w-])/g, (m) => humanDate(m) || m);
    }
  }

  // A front-matter value as the user should read it: names instead of slugs, localized words, a short date.
  // Returns "" to hide the chip (a technical value such as `type: index`, or the project the page already lives in).
  function chipValue(key, value, payload) {
    const map = (payload.propValues || {})[key];
    if (map && Object.prototype.hasOwnProperty.call(map, value)) return map[value];
    if (value === "true" || value === "false") return "";
    if (key === "project" || key === "projects") {
      const here = /^projects\/([^/]+)\//.exec(payload.path || "");
      const names = payload.projectNames || {};
      return value.split(/\s*,\s*/).filter((s) => s && !(here && s === here[1]))
        .map((s) => names[s] || s).join(", ");
    }
    if (key === "people") {
      const names = payload.peopleNames || {};
      return value.split(/\s*,\s*/).map(s => names[s.replace(/^people\//, "")] || s).join(", ");
    }
    if (key === "date" || key === "updated") return humanDate(value) || value;
    return value;
  }

  // The chip row is one line: chips that do not fit are left out whole (never cut mid-word), again on resize.
  let chipsHTML = "";
  function fitChips() {
    const row = document.getElementById("props");
    row.innerHTML = chipsHTML;
    const right = row.getBoundingClientRect().right;
    for (const chip of [...row.children].reverse()) {
      if (row.children.length > 1 && chip.getBoundingClientRect().right > right + 0.5) chip.remove();
    }
  }
  let fitPending = false;
  window.addEventListener("resize", () => {
    if (fitPending) return;
    fitPending = true;
    requestAnimationFrame(() => { fitPending = false; fitChips(); });
  });

  window.SB = {
    // Ajustes → Apariencia may force light/dark: WikiWebView tells the page explicitly (CONTRACT §15.1 Tema).
    setTheme(theme) {
      document.documentElement.dataset.theme = theme === "dark" ? "dark" : "light";
    },
    render(payload) {
      links = payload.links || {};
      titles = payload.titles || {};
      lang = payload.lang === "en" ? "en" : "es";
      document.documentElement.lang = lang;
      if (payload.theme) document.documentElement.dataset.theme = payload.theme;
      const scrollY = payload.keepScroll ? window.scrollY : 0;
      const { body, props } = splitFrontMatter(payload.markdown || "");

      const labels = payload.propLabels || {};
      chipsHTML = props
        .filter(([k]) => labels[k] && !(k === "type" && payload.hideType))
        .sort((a, b) => PROP_ORDER.indexOf(a[0]) - PROP_ORDER.indexOf(b[0]))
        .map(([k, v]) => [k, chipValue(k, v, payload)])
        .filter(([, v]) => v)
        .map(([k, v]) => '<span class="chip" title="' + escapeHTML(labels[k] + ": " + v) + '">' + escapeHTML(labels[k]) +
          ": <b>" + escapeHTML(v) + "</b></span>")
        .join("");
      fitChips();

      const content = document.getElementById("content");
      content.innerHTML = body.trim() ? md.render(body) : '<p class="empty">' + escapeHTML(payload.emptyText || "") + "</p>";
      decorate(content);
      // v0.6 graph side panel (§16.5): no H1 (the panel's header names the page), tighter type, no backlinks.
      document.documentElement.classList.toggle("compact", !!payload.compact);
      if (payload.compact) { const h1 = content.querySelector("h1"); if (h1) h1.remove(); }

      const backlinks = payload.compact ? [] : payload.backlinks || [];
      document.getElementById("backlinks").innerHTML = backlinks.length
        ? "<h5>" + escapeHTML(payload.backlinksTitle || "") + "</h5><ul>" +
          backlinks.map(b => '<li><a href="' + PAGE_PREFIX + encodeURIComponent(b.path) + '">' + escapeHTML(b.title) + "</a></li>").join("") +
          "</ul>"
        : "";

      window.scrollTo(0, scrollY);
    }
  };
})();
