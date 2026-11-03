#!/usr/bin/env -S python3 -I
"""Writes the Sparkle appcast of a release: one <item>, the latest version (scripts/release.sh).

    python3 -I scripts/make-appcast.py <out.xml> <version> <owner/repo> <edSignature> <length> <notes.md>

The "### Novedades" bullets of the release notes become the item's description (Sparkle's update window shows it);
the full notes stay on GitHub. The enclosure is the zip of that release, signed by `sign_update`.
"""
import html
import re
import sys
from email.utils import formatdate


def novedades(notes: str) -> list[str]:
    section = re.search(r"^### Novedades\n(.*?)(?=^#|\Z)", notes, re.S | re.M)
    items = []
    for line in (section.group(1) if section else "").splitlines():
        if line.startswith("- "):
            text = html.escape(line[2:].strip())
            items.append("<li>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text) + "</li>")
    return items


def appcast(version: str, repo: str, signature: str, length: int, notes: str) -> str:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?", version):
        raise SystemExit(f"bad version: {version!r}")
    if not re.fullmatch(r"[A-Za-z0-9+/=]+", signature):
        raise SystemExit("bad edSignature")
    page = f"https://github.com/{repo}/releases/tag/v{version}"
    url = f"https://github.com/{repo}/releases/download/v{version}/SecondBrain-{version}.zip"
    items = novedades(notes)
    description = (f"<h2>secondbrain {version}</h2>"
                   + (f"<ul>{''.join(items)}</ul>" if items else "")
                   + f'<p><a href="{html.escape(page)}">Notas completas / Full notes</a></p>')
    description = description.replace("]]>", "]]&gt;")
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>secondbrain</title>
    <link>https://github.com/{html.escape(repo)}</link>
    <language>es</language>
    <item>
      <title>secondbrain {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <link>{html.escape(page)}</link>
      <description><![CDATA[{description}]]></description>
      <enclosure url="{html.escape(url)}" sparkle:edSignature="{signature}" length="{int(length)}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""


if __name__ == "__main__":
    if len(sys.argv) != 7:
        raise SystemExit(__doc__)
    out, version, repo, signature, length, notes_path = sys.argv[1:]
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read()
    with open(out, "w", encoding="utf-8") as f:
        f.write(appcast(version, repo, signature, int(length), notes))
