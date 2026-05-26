(function () {
  const reader = document.getElementById("reader");
  let currentDocument = null;

  const imageExtensions = /\.(png|jpe?g|gif|webp|svg|bmp|avif)$/i;
  const videoExtensions = /\.(mp4|mov|webm|m4v)$/i;

  function notify(name, payload) {
    if (window.webkit?.messageHandlers?.[name]) {
      window.webkit.messageHandlers[name].postMessage(payload);
    }
  }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function escapeAttr(value) {
    return escapeHtml(value).replace(/'/g, "&#39;");
  }

  function slugify(value) {
    return String(value)
      .trim()
      .toLowerCase()
      .replace(/<[^>]+>/g, "")
      .replace(/[`*_~[\](){}:;,.!?'"\\/]+/g, " ")
      .replace(/\s+/g, "-")
      .replace(/^-+|-+$/g, "") || "section";
  }

  function splitFrontmatter(markdown) {
    if (!markdown.startsWith("---\n")) {
      return { frontmatter: null, body: markdown };
    }
    const end = markdown.indexOf("\n---\n", 4);
    if (end === -1) {
      return { frontmatter: null, body: markdown };
    }
    return {
      frontmatter: markdown.slice(4, end),
      body: markdown.slice(end + 5),
    };
  }

  function parseFrontmatter(frontmatter) {
    if (!frontmatter) return [];
    const rows = [];
    const lines = frontmatter.split(/\r?\n/);
    let current = null;

    for (const raw of lines) {
      if (!raw.trim()) continue;
      const match = raw.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
      if (match) {
        current = { label: match[1], value: match[2] || "—" };
        rows.push(current);
      } else if (current && /^\s+-\s+/.test(raw)) {
        const nextValue = raw.replace(/^\s+-\s+/, "").trim();
        current.value = current.value === "—" ? nextValue : `${current.value}, ${nextValue}`;
      } else if (current) {
        const nextValue = raw.trim();
        current.value = current.value === "—" ? nextValue : `${current.value} ${nextValue}`;
      }
    }

    return rows;
  }

  function splitWikiTarget(raw) {
    const pipeIndex = raw.indexOf("|");
    if (pipeIndex === -1) {
      return { target: raw.trim(), label: raw.trim() };
    }
    return {
      target: raw.slice(0, pipeIndex).trim(),
      label: raw.slice(pipeIndex + 1).trim() || raw.slice(0, pipeIndex).trim(),
    };
  }

  function mapOutsideCodeFences(markdown, transform) {
    return markdown
      .split(/(```[\s\S]*?```)/g)
      .map((segment) => (segment.startsWith("```") ? segment : transform(segment)))
      .join("");
  }

  function preprocessWikiLinks(markdown) {
    return mapOutsideCodeFences(markdown, (segment) => {
      let next = segment.replace(/!\[\[([^[\]]+?)\]\]/g, (_, inner) => {
        const { target, label } = splitWikiTarget(inner);
        const cleanTarget = target.split("#")[0];
        if (imageExtensions.test(cleanTarget)) {
          return `![${label}](${`zenith-wiki:${target}`})`;
        }
        if (videoExtensions.test(cleanTarget)) {
          return `\n<div class="embed-fallback"><a href="#" data-zenith-link="${escapeAttr(`zenith-wiki:${target}`)}">${escapeHtml(label)}</a></div>\n`;
        }
        return `\n<div class="embed-fallback"><a href="#" data-zenith-link="${escapeAttr(`zenith-wiki:${target}`)}">${escapeHtml(label)}</a></div>\n`;
      });
      next = next.replace(/\[\[([^[\]]+?)\]\]/g, (_, inner) => {
        const { target, label } = splitWikiTarget(inner);
        return `[${label}](${`zenith-wiki:${target}`})`;
      });
      return next;
    });
  }

  function extractFootnotes(markdown) {
    const defs = new Map();
    const lines = markdown.split(/\r?\n/);
    const body = [];

    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const match = line.match(/^\[\^([^\]]+)\]:\s*(.*)$/);
      if (!match) {
        body.push(line);
        continue;
      }

      const id = match[1];
      const chunks = [match[2]];
      while (index + 1 < lines.length && (/^\s{2,}/.test(lines[index + 1]) || lines[index + 1].startsWith("\t"))) {
        index += 1;
        chunks.push(lines[index].replace(/^\s{1,4}/, ""));
      }
      defs.set(id, chunks.join("\n").trim());
    }

    const order = [];
    const markdownWithoutDefs = mapOutsideCodeFences(body.join("\n"), (segment) =>
      segment.replace(/\[\^([^\]]+)\]/g, (_, id) => {
        if (!defs.has(id)) return _;
        if (!order.includes(id)) {
          order.push(id);
        }
        const number = order.indexOf(id) + 1;
        return `<sup class="footnote-ref"><a href="#fn-${slugify(id)}">${number}</a></sup>`;
      }),
    );

    return {
      markdown: markdownWithoutDefs,
      footnotes: order.map((id, index) => ({
        id,
        number: index + 1,
        markdown: defs.get(id) || "",
      })),
    };
  }

  function preprocessMath(markdown) {
    return mapOutsideCodeFences(markdown, (segment) => {
      let next = segment.replace(/\$\$([\s\S]+?)\$\$/g, (_, expr) => {
        return `\n<div class="math-block"><div class="math-title">Math</div><code>${escapeHtml(expr.trim())}</code></div>\n`;
      });
      next = next.replace(/\$(?!\$)([^$\n]+?)\$/g, (_, expr) => {
        return `<span class="math-inline">${escapeHtml(expr.trim())}</span>`;
      });
      return next;
    });
  }

  function plainTextFromTokens(tokens) {
    if (!Array.isArray(tokens)) return "";
    return tokens
      .map((token) => {
        if (typeof token.text === "string") return token.text;
        if (Array.isArray(token.tokens)) return plainTextFromTokens(token.tokens);
        return token.raw || "";
      })
      .join("");
  }

  function splitTargetAndFragment(href) {
    const hashIndex = href.indexOf("#");
    if (hashIndex === -1) {
      return { target: href, fragment: null };
    }
    return {
      target: href.slice(0, hashIndex),
      fragment: href.slice(hashIndex + 1) || null,
    };
  }

  function resolveMediaHref(href) {
    if (!href) return null;
    if (/^(https?:|data:|zenith-file:)/i.test(href)) return href;
    if (/^zenith-wiki:/i.test(href)) return null;

    const source = currentDocument?.sourceURL;
    if (!source) return href;

    try {
      const sourceURL = new URL(source);
      if (sourceURL.protocol === "file:") {
        const baseDirectory = sourceURL.href.replace(/[^/]+$/, "");
        const resolved = new URL(href, baseDirectory);
        return `zenith-file://${resolved.pathname}`;
      }
    } catch (_) {
      return href;
    }

    return href;
  }

  function renderFootnotes(footnotes) {
    if (!footnotes.length) return "";
    const items = footnotes
      .map((footnote) => {
        const html = marked.parse(footnote.markdown || "", { async: false });
        return `<li id="fn-${slugify(footnote.id)}">${html}<a class="footnote-backref" href="#">↩</a></li>`;
      })
      .join("");
    return `<section class="footnotes"><div class="footnotes-title">Footnotes</div><ol>${items}</ol></section>`;
  }

  function emitLayout() {
    if (!reader) return;
    const rect = reader.getBoundingClientRect();
    notify("markdownLayout", {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    });
  }

  const renderer = new marked.Renderer();

  renderer.heading = function heading({ tokens, depth }) {
    const html = this.parser.parseInline(tokens);
    const plain = plainTextFromTokens(tokens);
    const id = slugify(plain);
    return `<h${depth} id="${escapeAttr(id)}">${html}</h${depth}>`;
  };

  renderer.link = function link({ href, title, tokens }) {
    const text = this.parser.parseInline(tokens);
    const attrs = title ? ` title="${escapeAttr(title)}"` : "";
    if (/^(https?:|mailto:|tel:)/i.test(href || "")) {
      return `<a href="${escapeAttr(href)}"${attrs}>${text}</a>`;
    }
    return `<a href="#" class="internal-link" data-zenith-link="${escapeAttr(href || "")}"${attrs}>${text}</a>`;
  };

  renderer.image = function image({ href, title, text }) {
    const resolved = resolveMediaHref(href);
    if (!resolved) {
      const label = text || href || "Embedded asset";
      return `<div class="embed-fallback"><a href="#" data-zenith-link="${escapeAttr(href || "")}">${escapeHtml(label)}</a></div>`;
    }
    const attrs = [
      `src="${escapeAttr(resolved)}"`,
      `alt="${escapeAttr(text || "")}"`,
      title ? `title="${escapeAttr(title)}"` : "",
      "loading=\"lazy\"",
    ]
      .filter(Boolean)
      .join(" ");

    if (videoExtensions.test(resolved)) {
      return `<video controls ${attrs}></video>`;
    }
    return `<img ${attrs} />`;
  };

  renderer.code = function code({ text, lang }) {
    const language = (lang || "").trim().toLowerCase();
    if (language === "mermaid") {
      return `<div class="mermaid-fallback"><div class="mermaid-title">Mermaid</div><pre><code>${escapeHtml(text)}</code></pre></div>`;
    }
    const title = language ? `<div class="code-block-title">${escapeHtml(language)}</div>` : "";
    return `<div class="code-block">${title}<pre><code class="language-${escapeAttr(language)}">${escapeHtml(text)}</code></pre></div>`;
  };

  marked.use({
    gfm: true,
    breaks: false,
    renderer,
  });

  function upgradeCallouts(root) {
    const blockquotes = root.querySelectorAll("blockquote");
    for (const blockquote of blockquotes) {
      const firstParagraph = blockquote.querySelector("p");
      if (!firstParagraph) continue;
      const firstChild = firstParagraph.firstChild;
      const firstText = firstChild && firstChild.nodeType === Node.TEXT_NODE
        ? firstChild.textContent || ""
        : firstParagraph.textContent || "";
      const match = firstText.match(/^\s*\[!([A-Za-z0-9_-]+)\]\s*(.*)$/);
      if (!match) continue;

      const type = match[1].toLowerCase();
      const title = (match[2] || type).trim();

      if (firstChild && firstChild.nodeType === Node.TEXT_NODE) {
        firstChild.textContent = "";
      }
      firstParagraph.innerHTML = firstParagraph.innerHTML.replace(/^\s*\[![^\]]+\]\s*/, "");

      const callout = document.createElement("div");
      callout.className = `callout callout-${type}`;

      const heading = document.createElement("div");
      heading.className = "callout-title";
      heading.textContent = title;

      const body = document.createElement("div");
      body.className = "callout-body";
      while (blockquote.firstChild) {
        body.appendChild(blockquote.firstChild);
      }

      callout.appendChild(heading);
      callout.appendChild(body);
      blockquote.replaceWith(callout);
    }
  }

  function scrollToFragment(fragment) {
    if (!fragment) return;
    const target = document.getElementById(slugify(fragment))
      || document.getElementById(fragment);
    if (target) {
      requestAnimationFrame(() => {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    }
  }

  function renderProperties(rows) {
    if (!rows.length) return "";
    const cells = rows
      .map(
        (row) => `<div class="document-property">
          <div class="document-property-label">${escapeHtml(row.label)}</div>
          <div class="document-property-value">${escapeHtml(row.value)}</div>
        </div>`,
      )
      .join("");
    return `<section class="document-properties">${cells}</section>`;
  }

  function renderDocument(documentSource) {
    currentDocument = documentSource;
    document.body.classList.remove("presentation-inline", "presentation-process-modal");
    document.body.classList.add(`presentation-${documentSource.presentationMode || "inline"}`);

    const { frontmatter, body } = splitFrontmatter(documentSource.markdown || "");
    const properties = parseFrontmatter(frontmatter);
    const { markdown: withFootnoteRefs, footnotes } = extractFootnotes(body);
    const prepared = preprocessMath(preprocessWikiLinks(withFootnoteRefs));
    const html = marked.parse(prepared, { async: false });

    reader.innerHTML = `${renderProperties(properties)}${html}${renderFootnotes(footnotes)}`;
    upgradeCallouts(reader);
    emitLayout();
    scrollToFragment(documentSource.focusFragment);
  }

  document.addEventListener("click", (event) => {
    const anchor = event.target.closest("a[data-zenith-link]");
    if (anchor) {
      event.preventDefault();
      notify("markdownLink", anchor.getAttribute("data-zenith-link"));
      return;
    }

    const footnoteBackref = event.target.closest(".footnote-backref");
    if (footnoteBackref) {
      event.preventDefault();
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
  });

  window.ZenithMarkdownViewer = {
    renderDocument,
  };

  window.addEventListener("resize", emitLayout);

  notify("markdownReady", "ready");
})();
