#!/bin/bash
set -e

echo "building..."
zig build -Doptimize=ReleaseFast

BIN=./zig-out/bin/ypsilanti
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

echo "test: no args shows usage"
$BIN 2>&1 | grep -q "commands:" || { echo "FAIL: no args"; exit 1; }

echo "test: invalid command shows usage"
$BIN invalid 2>&1 | grep -q "commands:" || { echo "FAIL: invalid cmd"; exit 1; }

echo "test: build missing args"
$BIN build 2>&1 | grep -q "usage:" || { echo "FAIL: build no args"; exit 1; }

echo "test: serve missing args"
$BIN serve 2>&1 | grep -q "usage:" || { echo "FAIL: serve no args"; exit 1; }

echo "test: build example site"
$BIN build ./example $TMP/out
[ -f "$TMP/out/index.html" ] || { echo "FAIL: no index.html"; exit 1; }
[ -f "$TMP/out/about/index.html" ] || { echo "FAIL: no about/index.html"; exit 1; }
[ -f "$TMP/out/404.html" ] || { echo "FAIL: no 404.html"; exit 1; }
[ -f "$TMP/out/posts/index.html" ] || { echo "FAIL: no generated posts index"; exit 1; }
[ -f "$TMP/out/tags/linux/index.html" ] || { echo "FAIL: no generated tag page"; exit 1; }
[ -f "$TMP/out/categories/technology/index.html" ] || { echo "FAIL: no generated category page"; exit 1; }
[ -f "$TMP/out/sitemap.xml" ] || { echo "FAIL: no sitemap"; exit 1; }
[ -f "$TMP/out/feed.xml" ] || { echo "FAIL: no feed"; exit 1; }
[ -f "$TMP/out/style.css" ] || { echo "FAIL: no static files"; exit 1; }

echo "test: html contains content"
grep -q "Example Site" $TMP/out/index.html || { echo "FAIL: missing content"; exit 1; }
grep -q "<nav>" $TMP/out/index.html || { echo "FAIL: missing partial"; exit 1; }
grep -q "og:title" "$TMP/out/posts/first-post/index.html" || { echo "FAIL: missing seo metadata"; exit 1; }
grep -q 'id="markdown-features"' "$TMP/out/posts/first-post/index.html" || { echo "FAIL: missing heading id"; exit 1; }
grep -q 'href="/posts/first-post/"' "$TMP/out/posts/index.html" || { echo "FAIL: post index link is not root-relative"; exit 1; }

echo "test: sitemap has urls"
grep -q "<loc>" $TMP/out/sitemap.xml || { echo "FAIL: sitemap empty"; exit 1; }

echo "test: rss generated"
grep -q "<rss" $TMP/out/feed.xml || { echo "FAIL: rss missing"; exit 1; }

echo "test: static collision rejected"
mkdir -p "$TMP/collision/site/content" "$TMP/collision/site/layouts" "$TMP/collision/site/static"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/collision/site/layouts/base.html"
printf '%s\n' '---' 'title: Collision' 'layout: base' '---' '# Collision' > "$TMP/collision/site/content/index.md"
printf '%s\n' 'bad sitemap' > "$TMP/collision/site/static/sitemap.xml"
if $BIN build "$TMP/collision/site" "$TMP/collision/out" >/dev/null 2>&1; then
  echo "FAIL: static collision allowed"
  exit 1
fi

echo "test: invalid base url rejected"
mkdir -p "$TMP/baseurl/site/content" "$TMP/baseurl/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/baseurl/site/layouts/base.html"
printf '%s\n' 'javascript:alert(1)' > "$TMP/baseurl/site/url"
printf '%s\n' '---' 'title: Base URL' 'layout: base' '---' '# Base URL' > "$TMP/baseurl/site/content/index.md"
if $BIN build "$TMP/baseurl/site" "$TMP/baseurl/out" >/dev/null 2>&1; then
  echo "FAIL: invalid base url allowed"
  exit 1
fi

echo "test: protocol-relative markdown links rejected"
mkdir -p "$TMP/link/site/content" "$TMP/link/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/link/site/layouts/base.html"
printf '%s\n' '---' 'title: Link' 'layout: base' '---' '[bad](//attacker.example/path)' > "$TMP/link/site/content/index.md"
$BIN build "$TMP/link/site" "$TMP/link/out" >/dev/null
grep -q 'href="#"' "$TMP/link/out/index.html" || { echo "FAIL: protocol-relative link not blocked"; exit 1; }

echo "test: symlinked static rejected"
mkdir -p "$TMP/staticlink/site/content" "$TMP/staticlink/site/layouts" "$TMP/staticlink/target"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/staticlink/site/layouts/base.html"
printf '%s\n' '---' 'title: Static Link' 'layout: base' '---' '# Static Link' > "$TMP/staticlink/site/content/index.md"
ln -s "$TMP/staticlink/target" "$TMP/staticlink/site/static"
if $BIN build "$TMP/staticlink/site" "$TMP/staticlink/target/out" >/dev/null 2>&1; then
  echo "FAIL: symlinked static allowed"
  exit 1
fi

echo "test: draft pages skipped"
mkdir -p "$TMP/draft/site/content" "$TMP/draft/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/draft/site/layouts/base.html"
printf '%s\n' '---' 'title: Draft' 'layout: base' 'draft: true' '---' '# Draft' > "$TMP/draft/site/content/draft.md"
$BIN build "$TMP/draft/site" "$TMP/draft/out" >/dev/null
[ ! -e "$TMP/draft/out/draft/index.html" ] || { echo "FAIL: draft was built"; exit 1; }

echo "test: markdown tables and footnotes"
mkdir -p "$TMP/md/site/content" "$TMP/md/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/md/site/layouts/base.html"
printf '%s\n' '---' 'title: Markdown' 'layout: base' '---' '| a | b |' '| - | - |' '| 1 | 2 |' '' 'note[^1]' '' '[^1]: footnote text' > "$TMP/md/site/content/index.md"
$BIN build "$TMP/md/site" "$TMP/md/out" >/dev/null
grep -q '<table>' "$TMP/md/out/index.html" || { echo "FAIL: table missing"; exit 1; }
grep -q 'class="footnotes"' "$TMP/md/out/index.html" || { echo "FAIL: footnotes missing"; exit 1; }

echo "test: toc shortcodes syntax aliases pagination"
mkdir -p "$TMP/features/site/content/posts" "$TMP/features/site/layouts"
printf '%s\n' '<main>{{{toc}}}{{{content}}}</main>' > "$TMP/features/site/layouts/base.html"
printf '%s\n' 'paginate: 1' > "$TMP/features/site/config"
printf '%s\n' '---' 'title: One' 'date: 2026-01-02' 'layout: base' 'tags: zig' 'aliases: /old-one/' '---' '## Heading One' '' '{{< callout text="note" >}}' '' '```zig' 'const x = 1;' '```' > "$TMP/features/site/content/posts/one.md"
printf '%s\n' '---' 'title: Two' 'date: 2026-01-01' 'layout: base' 'tags: zig' '---' '# Two' > "$TMP/features/site/content/posts/two.md"
$BIN build "$TMP/features/site" "$TMP/features/out" >/dev/null
[ -f "$TMP/features/out/posts/page/2/index.html" ] || { echo "FAIL: posts page 2 missing"; exit 1; }
[ -f "$TMP/features/out/tags/zig/page/2/index.html" ] || { echo "FAIL: tag page 2 missing"; exit 1; }
[ -f "$TMP/features/out/old-one/index.html" ] || { echo "FAIL: alias redirect missing"; exit 1; }
grep -q 'class="toc"' "$TMP/features/out/posts/one/index.html" || { echo "FAIL: toc missing"; exit 1; }
grep -q 'class="callout callout-note"' "$TMP/features/out/posts/one/index.html" || { echo "FAIL: shortcode missing"; exit 1; }
grep -q 'tok-keyword' "$TMP/features/out/posts/one/index.html" || { echo "FAIL: syntax highlight missing"; exit 1; }
grep -q 'url=/posts/one/' "$TMP/features/out/old-one/index.html" || { echo "FAIL: alias target missing"; exit 1; }

echo "test: broken internal links rejected"
mkdir -p "$TMP/brokenlink/site/content" "$TMP/brokenlink/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/brokenlink/site/layouts/base.html"
printf '%s\n' '---' 'title: Broken Link' 'layout: base' '---' '[missing](/missing/)' > "$TMP/brokenlink/site/content/index.md"
if $BIN build "$TMP/brokenlink/site" "$TMP/brokenlink/out" >/dev/null 2>&1; then
  echo "FAIL: broken internal link allowed"
  exit 1
fi

echo "test: broken fragment links rejected"
mkdir -p "$TMP/brokenfragment/site/content" "$TMP/brokenfragment/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/brokenfragment/site/layouts/base.html"
printf '%s\n' '---' 'title: Broken Fragment' 'layout: base' '---' '# Exists' '' '[missing](#missing)' > "$TMP/brokenfragment/site/content/index.md"
if $BIN build "$TMP/brokenfragment/site" "$TMP/brokenfragment/out" >/dev/null 2>&1; then
  echo "FAIL: broken fragment link allowed"
  exit 1
fi

echo "test: symlinked layout rejected"
mkdir -p "$TMP/layoutlink/site/content" "$TMP/layoutlink/site/layouts"
printf '%s\n' 'SECRET_LAYOUT_SENTINEL' > "$TMP/layoutlink/secret.html"
ln -s "$TMP/layoutlink/secret.html" "$TMP/layoutlink/site/layouts/leak.html"
printf '%s\n' '---' 'title: Layout Link' 'layout: leak' '---' '# Layout Link' > "$TMP/layoutlink/site/content/index.md"
if $BIN build "$TMP/layoutlink/site" "$TMP/layoutlink/out" >/dev/null 2>&1; then
  echo "FAIL: symlinked layout allowed"
  exit 1
fi

echo "test: reserved content frontmatter rejected"
mkdir -p "$TMP/rawcontent/site/content" "$TMP/rawcontent/site/layouts"
printf '%s\n' '---' 'content: <img src=x onerror=alert(1)>' '---' '{{{content}}}' > "$TMP/rawcontent/site/content/index.md"
if $BIN build "$TMP/rawcontent/site" "$TMP/rawcontent/out" >/dev/null 2>&1; then
  echo "FAIL: reserved content frontmatter allowed"
  exit 1
fi

echo "test: template url variables sanitized"
mkdir -p "$TMP/templateurl/site/content" "$TMP/templateurl/site/layouts"
printf '%s\n' '<a href = "{{link}}">profile</a>{{{content}}}' > "$TMP/templateurl/site/layouts/base.html"
printf '%s\n' '---' 'title: Template URL' 'layout: base' 'link: javascript:alert(1)' '---' '# Template URL' > "$TMP/templateurl/site/content/index.md"
$BIN build "$TMP/templateurl/site" "$TMP/templateurl/out" >/dev/null
grep -q 'href = "#"' "$TMP/templateurl/out/index.html" || { echo "FAIL: template url not sanitized"; exit 1; }

echo "test: xml control chars rejected"
mkdir -p "$TMP/xmlcontrol/site/content" "$TMP/xmlcontrol/site/layouts"
printf '%s\n' '<main>{{{content}}}</main>' > "$TMP/xmlcontrol/site/layouts/base.html"
printf '%s' $'---\ntitle: Bad\001Title\ndate: 2026-01-01\nlayout: base\n---\n# XML\n' > "$TMP/xmlcontrol/site/content/index.md"
if $BIN build "$TMP/xmlcontrol/site" "$TMP/xmlcontrol/out" >/dev/null 2>&1; then
  echo "FAIL: xml control char allowed"
  exit 1
fi

echo "test: serve starts and responds"
cp -a ./example "$TMP/serve-site"
$BIN serve "$TMP/serve-site" 3456 &
PID=$!
sleep 1
curl -s http://localhost:3456/ | grep -q "Example Site" || { kill $PID 2>/dev/null; echo "FAIL: serve"; exit 1; }
curl -s http://localhost:3456/posts/ | grep -q '<h1>posts</h1>' || { kill $PID 2>/dev/null; echo "FAIL: serve posts index"; exit 1; }
curl -s http://localhost:3456/posts/ | grep -q 'href="/posts/first-post/"' || { kill $PID 2>/dev/null; echo "FAIL: served post link is not root-relative"; exit 1; }
curl -s http://localhost:3456/posts/first-post/ | grep -q "First Post" || { kill $PID 2>/dev/null; echo "FAIL: serve post page"; exit 1; }
curl -s http://localhost:3456/nope | grep -q "404" || { kill $PID 2>/dev/null; echo "FAIL: 404 page"; exit 1; }
before=$(curl -s http://localhost:3456/_reload)
touch "$TMP/serve-site/content/posts/first-post.md"
sleep 1
after=$(curl -s http://localhost:3456/_reload)
[ "$after" -gt "$before" ] || { kill $PID 2>/dev/null; echo "FAIL: nested live reload"; exit 1; }
kill $PID 2>/dev/null

echo ""
echo "all tests passed"
