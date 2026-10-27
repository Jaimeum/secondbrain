(function () {
  "use strict";

  const PAGE_PREFIX = "sbwiki://page/";
  const HIDDEN_PROPS = new Set(["title", "source_id", "sources", "speakers", "aliases", "original_file", "source_url", "language"]);

  let links = {};

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
      if (!value || value === "null" || value === "[]" || HIDDEN_PROPS.has(kv[1])) continue;
      value = value.replace(/^\[|\]$/g, "").replace(/["']/g, "").replace(/\[\[|\]\]/g, "");
      props.push([kv[1], value]);
    }
    return { body: src.slice(m[0].length), props };
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
        token.meta = { target, label: label || target };
      }
      state.pos = end + 2;
      return true;
    });
    md.renderer.rules.wikilink = function (tokens, idx) {
      const { target, label } = tokens[idx].meta;
      const path = links[target];
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
  }

  // A front-matter value as the user should read it: names instead of slugs, localized words, a short date.
  // Returns "" to hide the chip (a technical value such as `type: index`).
  function chipValue(key, value, payload) {
    const map = (payload.propValues || {})[key];
    if (map && Object.prototype.hasOwnProperty.call(map, value)) return map[value];
    if (key === "project") return (payload.projectNames || {})[value] || value;
    if (key === "people") {
      const names = payload.peopleNames || {};
      return value.split(/\s*,\s*/).map(s => names[s.replace(/^people\//, "")] || s).join(", ");
    }
    const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (d && (key === "updated" || key === "date")) {
      try {
        return new Date(+d[1], +d[2] - 1, +d[3]).toLocaleDateString(payload.locale || undefined,
          { day: "numeric", month: "short", year: "numeric" });
      } catch (e) { return value; }
    }
    return value;
  }

  window.SB = {
    render(payload) {
      links = payload.links || {};
      const scrollY = payload.keepScroll ? window.scrollY : 0;
      const { body, props } = splitFrontMatter(payload.markdown || "");

      document.getElementById("props").innerHTML = props
        .map(([k, v]) => [k, chipValue(k, v, payload)])
        .filter(([, v]) => v)
        .map(([k, v]) => '<span class="chip">' + escapeHTML((payload.propLabels || {})[k] || k) + ": <b>" + escapeHTML(v) + "</b></span>")
        .join("");

      const content = document.getElementById("content");
      content.innerHTML = body.trim() ? md.render(body) : '<p class="empty">' + escapeHTML(payload.emptyText || "") + "</p>";
      decorate(content);

      const backlinks = payload.backlinks || [];
      document.getElementById("backlinks").innerHTML = backlinks.length
        ? "<h5>" + escapeHTML(payload.backlinksTitle || "") + "</h5><ul>" +
          backlinks.map(b => '<li><a href="' + PAGE_PREFIX + encodeURIComponent(b.path) + '">' + escapeHTML(b.title) + "</a></li>").join("") +
          "</ul>"
        : "";

      window.scrollTo(0, scrollY);
    }
  };
})();
