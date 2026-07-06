# ypsilanti

minimal static site generator in zig.

`example/` is a demo site you can build and serve to see how everything fits together.

## install

requires [zig](https://ziglang.org/download/) (0.14+).

```
zig build -Doptimize=ReleaseFast
cp zig-out/bin/ypsilanti /usr/local/bin/
```

`-Doptimize` options: `Debug` (default), `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`. use `ReleaseFast` for production, skip the flag for development.

## usage

```
ypsilanti build ./site ./output    # build site
ypsilanti serve ./site             # dev server on :3000
ypsilanti serve ./site 8080        # custom port
```

## site structure

```
site/
├── content/     # markdown files → html
├── layouts/     # page templates
├── partials/    # reusable snippets
├── static/      # copied as-is (css, images, fonts)
└── config       # optional site config
```

## config

```text
title: example.com
url: https://example.com
author: your name
description: site description
theme: darkode
paginate: 10
nav: home=/, posts=/posts/, tags=/tags/, rss=/feed.xml
```

## front matter

```markdown
---
title: Hello World
date: 2025-01-09
description: post summary for rss
layout: post
tags: linux, software
categories: technology
draft: false
aliases: /old-post/, /legacy/post.html
---

your content here
```

- `title` - page title, available as `{{title}}`
- `date` - includes page in rss feed
- `description` - rss item description
- `layout` - which layout to use from `layouts/`
- `tags` - comma-separated tags, used for generated tag pages
- `categories` - comma-separated categories, used for generated category pages
- `draft` - set to `true` to skip the page
- `aliases` / `alias` - comma-separated local URLs that emit static redirect pages

any key except reserved `content`, `nav_html`, and `toc` is available as `{{key}}` in templates.

## templates

layouts go in `layouts/`. use `{{content}}` for the rendered markdown:

```html
<!DOCTYPE html>
<html>
<head><title>{{title}}</title></head>
<body>
  {{> header}}
  {{{toc}}}
  <main>{{{content}}}</main>
</body>
</html>
```

Template variables are HTML-escaped by default. Variables rendered directly inside `href` and `src` attributes are also checked for safe URL schemes. Triple braces render raw HTML only for built-in `content` and `nav_html` variables.

partials go in `partials/`. include with `{{> name}}`:

```html
<!-- partials/header.html -->
<nav><a href="/">home</a></nav>
```

## markdown

supported:
- `# headers` (h1-h6)
- `**bold**` and `*italic*`
- `[links](url)` with safe `http`, `https`, `mailto`, anchor, or relative URLs
- `` `inline code` ``
- fenced code blocks with language class
- basic syntax highlighting spans for common fenced code languages
- `- unordered lists`
- `> blockquotes`
- pipe tables
- footnotes with `[^id]` and `[^id]: text`
- whole-line shortcodes: `figure`, `youtube`, `vimeo`, and `callout`

Headings get generated `id` attributes and a raw `{{{toc}}}` template variable.

shortcode examples:

```markdown
{{< figure src="/img/photo.jpg" alt="Photo" caption="A caption" >}}
{{< youtube dQw4w9WgXcQ >}}
{{< vimeo 123456789 >}}
{{< callout type="warning" title="heads up" text="important note" >}}
```

## error pages

create `content/404.md` for custom 404 pages. works in dev server and most static hosts.

pages are generated with clean URLs: `content/about.md` becomes `about/index.html` and is served at `/about/`.

## rss + sitemap

auto-generated on build:
- `sitemap.xml` - all pages
- `feed.xml` - pages with `date:` front matter
- `posts/` - dated posts sorted newest first, paginated with `paginate:`
- `tags/` and `categories/` - taxonomy indexes and paginated term pages

set base url in `site/config` with `url:`. `site/url` is still supported as a fallback.

## link checking

`build` validates internal `href` and `src` links after writing pages and static files. Root-relative links, relative links, and fragment anchors must point to generated output or the build fails.

## deploy

### github pages (recommended)

ypsilanti ships a GitHub Action, so a full deploy is one `uses:` line. Copy
[`docs/github-pages.yml`](docs/github-pages.yml) into your site repo as
`.github/workflows/pages.yml`, then set Settings → Pages → Source to *GitHub
Actions*. The core of it:

```yaml
- uses: actions/checkout@v4
- uses: maxf1eld/ypsilanti@main   # pin to a tag or SHA for stability
  with:
    source: ./site               # your site source dir
- uses: actions/upload-pages-artifact@v3
  with:
    path: ./_site
```

The action builds ypsilanti and your site with no local Zig install needed.

Internal links are root-relative (`/about/`), so deploy at a **root domain** —
a user/org page (`you.github.io`) or a custom domain. A *project* page
(`you.github.io/repo/`) serves under a subpath and will break those links.

### manual / other hosts

Build locally and push the output anywhere that serves static files (Netlify,
Cloudflare Pages, S3, a plain web server):

```
ypsilanti build ./site ./docs
git add docs && git commit -m "build" && git push
```

## dev workflow

```
ypsilanti serve ./site
```

opens dev server with live reload. edit any file in content/, layouts/, partials/, or static/ and browser refreshes automatically.

## tests

```
./test.sh
```

## contributing

Contributions are welcome. Run `./test.sh` before opening a pull request; CI
runs the same suite. See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## license

MIT — see [LICENSE](LICENSE).
