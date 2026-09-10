#!/usr/bin/env python3
# Renders site/*.md into the static site published at
# https://bisak.github.io/SpaceSwitchSpeed/.
#
#   make site     build it into build/site
#   make serve    build it and serve it on http://localhost:8000
#
# The pages are their own sources under site/, except How it works, which is
# docs/REVERSE-ENGINEERING.md rendered as-is so there is one copy of it.

import html
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "site"
OUT = ROOT / "build" / "site"
ORIGIN = "https://bisak.github.io"
BASE = "/SpaceSwitchSpeed"
SITE = ORIGIN + BASE
REPO = "https://github.com/bisak/SpaceSwitchSpeed"

# slug -> (source, nav label). Order is the nav order and the sitemap order.
PAGES = [
    ("", SRC / "index.md", "Home"),
    ("install", SRC / "install.md", "Install"),
    ("why-defaults-write-doesnt-work", SRC / "why-defaults-write-doesnt-work.md", "defaults write"),
    ("high-refresh-rate", SRC / "high-refresh-rate.md", "120 Hz"),
    ("how-it-works", ROOT / "docs" / "REVERSE-ENGINEERING.md", "How it works"),
    ("alternatives", SRC / "alternatives.md", "Alternatives"),
    ("faq", SRC / "faq.md", "FAQ"),
]

# Front matter that docs/REVERSE-ENGINEERING.md cannot carry itself.
EXTERNAL_META = {
    "how-it-works": {
        "title": "How the macOS Space-switch animation works, disassembled",
        "description": (
            "Dock animates a Space switch with a spring, not a timed curve: the "
            "integrator, its constants, the display-derived timestep, and the five-"
            "instruction patch."
        ),
        "schema": "techarticle",
        "heading": "How it works",
    }
}


def marketing_version():
    out = run("sed", "-nE", r"s/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p",
              "SpaceSwitchSpeed.xcodeproj/project.pbxproj")
    return out.splitlines()[0].strip() if out else "1.0"


def run(*args, default=""):
    try:
        return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return default


def front_matter(text):
    meta = {}
    if text.startswith("---\n"):
        head, _, text = text[4:].partition("\n---\n")
        for line in head.splitlines():
            key, _, value = line.partition(":")
            if key.strip():
                meta[key.strip()] = value.strip()
    return meta, text.lstrip("\n")


def make_markdown():
    return markdown.Markdown(
        extensions=["tables", "fenced_code", "codehilite", "attr_list", "md_in_html", "sane_lists", "smarty", "toc"],
        extension_configs={
            "codehilite": {"css_class": "highlight", "guess_lang": False},
            "toc": {"permalink": "#", "permalink_class": "headerlink", "permalink_title": "Permalink", "toc_depth": "2-4"},
            "smarty": {"smart_dashes": True, "smart_quotes": False},
        },
    )


def rewrite_links(body, slug):
    """Point the repo's own relative links at the site, and everything else at GitHub."""
    site_targets = {
        "docs/REVERSE-ENGINEERING.md": f"{BASE}/how-it-works/",
        "README.md": f"{BASE}/",
    }

    def repl(m):
        target = m.group(2)
        if target in site_targets:
            return f"{m.group(1)}{site_targets[target]}{m.group(3)}"
        if target.startswith(("http", "#", "mailto:", "/")):
            return m.group(0)
        return f"{m.group(1)}{REPO}/blob/main/{target}{m.group(3)}"

    return re.sub(r"(\]\()([^)\s]+)(\))", repl, body)


def wrap_tables(html_text):
    return re.sub(r"<table>", '<div class="table-scroll"><table>', html_text).replace("</table>", "</table></div>")


def strip_h1_permalink(html_text):
    """toc_depth only trims the table of contents, so drop the h1's own anchor here."""
    return re.sub(r'(<h1\b[^>]*>.*?)<a class="headerlink".*?</a>(</h1>)', r"\1\2", html_text, flags=re.S)


def faq_pairs(md_text):
    """Extract `### Question` / answer pairs for FAQPage structured data."""
    pairs = []
    for block in re.split(r"^## ", md_text, flags=re.M)[1:]:
        question, _, answer = block.partition("\n")
        answer = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", answer)
        answer = re.sub(r"[*`#>|]|\n\s*-\s", " ", answer)
        answer = re.sub(r"\s+", " ", answer).strip()
        if question.strip() and answer:
            pairs.append((question.strip(), answer[:1200]))
    return pairs


def jsonld(slug, meta, md_text, updated):
    url = f"{SITE}/{slug}/" if slug else f"{SITE}/"
    author = {"@type": "Person", "name": "Biser Atanasov", "url": "https://github.com/bisak"}
    graph = []

    if not slug:
        graph.append({
            "@type": "WebSite",
            "@id": f"{SITE}/#website",
            "url": f"{SITE}/",
            "name": "Space Switch Speed",
            "description": meta["description"],
            "inLanguage": "en",
            "publisher": author,
        })
        graph.append({
            "@type": "SoftwareApplication",
            "@id": f"{SITE}/#app",
            "name": "Space Switch Speed",
            "url": f"{SITE}/",
            "downloadUrl": f"{REPO}/releases/latest",
            "codeRepository": REPO,
            "applicationCategory": "UtilitiesApplication",
            "applicationSubCategory": "Desktop customisation",
            "operatingSystem": "macOS 15 Sequoia or later, Apple Silicon",
            "processorRequirements": "Apple Silicon (arm64)",
            "softwareVersion": marketing_version(),
            "license": "https://www.gnu.org/licenses/agpl-3.0.html",
            "isAccessibleForFree": True,
            "author": author,
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "description": meta["description"],
        })
    else:
        graph.append({
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Space Switch Speed", "item": f"{SITE}/"},
                {"@type": "ListItem", "position": 2, "name": meta.get("heading", meta["title"]), "item": url},
            ],
        })

    if meta.get("schema") == "faq":
        pairs = faq_pairs(md_text)
        if pairs:
            graph.append({
                "@type": "FAQPage",
                "@id": url + "#faq",
                "mainEntity": [
                    {"@type": "Question", "name": q,
                     "acceptedAnswer": {"@type": "Answer", "text": a}}
                    for q, a in pairs
                ],
            })
    elif meta.get("schema") == "techarticle":
        graph.append({
            "@type": "TechArticle",
            "@id": url + "#article",
            "headline": meta["title"][:110],
            "description": meta["description"],
            "url": url,
            "datePublished": "2026-09-06",
            "dateModified": updated,
            "author": author,
            "inLanguage": "en",
            "proficiencyLevel": "Expert",
            "isPartOf": {"@id": f"{SITE}/#website"},
        })

    doc = {"@context": "https://schema.org", "@graph": graph}
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False)


def nav_html(current):
    out = []
    for slug, _, label in PAGES:
        href = f"{BASE}/{slug}/" if slug else f"{BASE}/"
        current_attr = ' aria-current="page"' if slug == current else ""
        out.append(f'<a href="{href}"{current_attr}>{html.escape(label)}</a>')
    return "".join(out)


def git_updated(path):
    stamp = run("git", "log", "-1", "--format=%cs", "--", str(path.relative_to(ROOT)))
    return stamp or datetime.now(timezone.utc).strftime("%Y-%m-%d")


def build_images(cachebust):
    """Derive the site's hero poster, icon and OG card from the committed banner."""
    assets = OUT / "assets"
    banner = ROOT / "docs" / "images" / "banner.webp"
    if not banner.exists():
        print("warning: docs/images/banner.webp is missing; skipping hero art", file=sys.stderr)
        return False
    shutil.copy2(banner, assets / "banner.webp")
    try:
        from PIL import Image
    except ImportError:
        print("warning: Pillow is not installed; skipping the poster, icon and OG card", file=sys.stderr)
        return False

    with Image.open(banner) as im:
        im.seek(0)
        frame = im.convert("RGB")

    poster = frame.copy()
    poster.thumbnail((1600, 1600), Image.LANCZOS)
    poster.save(assets / "hero.webp", "WEBP", quality=88, method=6)

    # The OG card is the poster letterboxed into 1200x630 on the banner's own ground.
    card = Image.new("RGB", (1200, 630), frame.getpixel((2, 2)))
    art = frame.copy()
    art.thumbnail((1200, 630), Image.LANCZOS)
    card.paste(art, ((1200 - art.width) // 2, (630 - art.height) // 2))
    card.save(assets / "og.png", "PNG", optimize=True)

    icon = ROOT / "Sources" / "SpaceSwitchSpeed" / "Assets.xcassets" / "AppIcon.appiconset"
    biggest = max(icon.glob("*.png"), key=lambda p: p.stat().st_size, default=None) if icon.exists() else None
    if biggest:
        with Image.open(biggest) as im:
            im.convert("RGBA").resize((180, 180), Image.LANCZOS).save(assets / "icon.png", "PNG", optimize=True)
    else:
        art.resize((180, 180), Image.LANCZOS).save(assets / "icon.png", "PNG", optimize=True)
    return True


def verify_links():
    """Every internal href must resolve to a page, an anchor on it, or a built asset."""
    pages, problems = {}, []
    for page in OUT.rglob("*.html"):
        rel = page.relative_to(OUT)
        key = "/" + ("" if rel.parent == Path(".") else f"{rel.parent}/")
        pages[key if page.name == "index.html" else "/" + str(rel)] = (
            page, set(re.findall(r'id="([^"]+)"', page.read_text()))
        )

    for key, (page, _) in sorted(pages.items()):
        for href in re.findall(r'(?:href|src)="([^"]+)"', page.read_text()):
            if href.startswith(("http", "mailto:", "data:")):
                continue
            path, _, frag = href.partition("#")
            path = path.split("?")[0]
            if not path:
                target = key
            elif path.startswith(BASE):
                target = path[len(BASE):] or "/"
            else:
                problems.append((key, href, "not under " + BASE))
                continue
            if target in pages:
                anchors = pages[target][1]
                if frag and frag not in anchors:
                    problems.append((key, href, "no such anchor"))
            elif (OUT / target.lstrip("/")).is_file():
                continue
            else:
                problems.append((key, href, "no such page or asset"))

    for src, href, why in problems:
        print(f"error: {src} -> {href}: {why}", file=sys.stderr)
    return not problems


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "assets").mkdir(parents=True)

    cachebust = run("git", "rev-parse", "--short", "HEAD", default="dev")
    for asset in (SRC / "assets").iterdir():
        if asset.is_file():
            shutil.copy2(asset, OUT / "assets" / asset.name)

    # site/root/ lands at the site root verbatim. Search Console and Bing want their
    # verification files at a fixed path, and this is where those go.
    for extra in sorted((SRC / "root").glob("*")):
        if extra.is_file() and not extra.name.startswith((".", "_")):
            shutil.copy2(extra, OUT / extra.name)
            print(f"  {SITE}/{extra.name}")
    have_art = build_images(cachebust)

    layout = (SRC / "_layout.html").read_text()
    entries = []

    for slug, path, _ in PAGES:
        raw = path.read_text()
        meta, body = front_matter(raw)
        meta = {**EXTERNAL_META.get(slug, {}), **meta}
        if "title" not in meta or "description" not in meta:
            sys.exit(f"error: {path} has no title/description front matter")
        if not have_art:
            body = re.sub(r'^<figure class="hero-figure">.*?</figure>\n', "", body, flags=re.S | re.M)

        updated = git_updated(path)
        md = make_markdown()
        content = strip_h1_permalink(wrap_tables(md.convert(rewrite_links(body, slug))))
        url = f"{SITE}/{slug}/" if slug else f"{SITE}/"

        crumb = ""
        if slug:
            crumb = (f'<p class="crumb"><a href="{BASE}/">Space Switch Speed</a> '
                     f'<span aria-hidden="true">&rsaquo;</span> {html.escape(meta.get("heading", meta["title"]))}</p>\n')

        page = layout
        for key, value in {
            "{{title}}": html.escape(meta["title"]),
            "{{og_title}}": html.escape(meta.get("og_title", meta["title"])),
            "{{description}}": html.escape(meta["description"]),
            "{{canonical}}": url,
            "{{og_type}}": "website" if not slug else "article",
            "{{base}}": BASE,
            "{{robots}}": '<meta name="robots" content="noindex,follow">\n' if meta.get("noindex") else "",
            "{{jsonld}}": jsonld(slug, meta, body, updated),
            "{{nav}}": nav_html(slug),
            "{{breadcrumb}}": crumb,
            "{{content}}": content,
            "{{cachebust}}": cachebust,
        }.items():
            page = page.replace(key, value)

        target = OUT / slug / "index.html" if slug else OUT / "index.html"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(page)
        entries.append((url, updated, 1.0 if not slug else 0.8))
        print(f"  {url}")

    urls = "\n".join(
        f"  <url><loc>{u}</loc><lastmod>{m}</lastmod>"
        f"<changefreq>monthly</changefreq><priority>{p}</priority></url>"
        for u, m, p in entries
    )
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{urls}\n</urlset>\n"
    )
    (OUT / "robots.txt").write_text(
        "User-agent: *\nAllow: /\n\n"
        f"Sitemap: {SITE}/sitemap.xml\n"
    )
    (OUT / ".nojekyll").write_text("")

    notfound = (OUT / "index.html").read_text()
    notfound = notfound.replace("<title>", '<meta name="robots" content="noindex">\n<title>', 1)
    (OUT / "404.html").write_text(notfound)

    if not verify_links():
        sys.exit("error: the site has broken internal links")

    print(f"wrote {len(entries)} pages, a sitemap and robots.txt to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
