"""Check a built site: python3 tools/check_site.py _site /canopus."""

from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag in {"a", "link", "img", "script"}:
            target = attrs.get("href") or attrs.get("src")
            if target:
                self.links.append(target)


root = Path(sys.argv[1]).resolve()
prefix = sys.argv[2].rstrip("/") + "/"
pages = {path: Page(path) for path in root.rglob("*.html")}
assert pages, f"No HTML pages in {root}; run jekyll build first"
errors = []
for path, page in pages.items():
    for link in page.links:
        url = urlsplit(link)
        if url.scheme or url.netloc:
            continue
        target_path = unquote(url.path)
        if target_path.startswith(prefix):
            target_path = target_path[len(prefix) :]
            target = root / target_path
        elif target_path.startswith("/"):
            target = root / target_path.lstrip("/")
        else:
            target = path.parent / target_path if target_path else path
        if target.is_dir():
            target /= "index.html"
        target = target.resolve()
        if not target.is_file():
            errors.append(f"{path.relative_to(root)}: missing {link}")
        elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
            errors.append(f"{path.relative_to(root)}: missing fragment {link}")
assert not errors, "\n".join(errors)
print(f"Checked local links and fragments in {len(pages)} pages")
