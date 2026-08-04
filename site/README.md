# Bleat website

The website is a Zola project with Tailwind CSS. Its source lives entirely in
`site/`; generated CSS and the rendered site are ignored.

Install the pinned tools from the repository root:

```sh
mise install
```

Then use the mise tasks:

```sh
mise run site-css
mise run site-check
mise run site-build
mise run site-serve
```

`site-serve` generates the stylesheet before starting Zola. Run `site-css`
again after changing Tailwind classes or the CSS source.
