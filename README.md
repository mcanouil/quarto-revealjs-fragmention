# Fragmention

A Quarto filter extension that hoists `.fragment` attributes from empty marker spans to their parent `<li>` elements in RevealJS presentations.

This makes list markers (bullets and numbers) appear and disappear together with the fragment content.

Also compatible with [`pandoc-ext/list-table`](https://github.com/pandoc-ext/list-table) for adding fragments to table cells and rows.

![Side-by-side comparison of native RevealJS fragments (left) and Fragmention (right)](comparison.gif)

## Installation

```bash
quarto add mcanouil/quarto-revealjs-fragmention@0.2.0
```

This will install the extension under the `_extensions` subdirectory.
If you are using version control, you will want to check in this directory.

## Documentation

The full documentation lives at <https://m.canouil.dev/quarto-revealjs-fragmention/>: every element the filter hoists onto, the fragment classes, the `list-table` ordering, and a Reveal.js deck whose first two slides are the same list with and without the filter.

[`example.qmd`](example.qmd) is a short, standalone starting point you can copy.

## Licence

[MIT](https://github.com/mcanouil/quarto-revealjs-fragmention?tab=MIT-1-ov-file#readme).
