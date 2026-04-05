# Fragmention

A Quarto filter extension that hoists `.fragment` attributes from empty marker spans to their parent `<li>` elements in RevealJS presentations.
This makes list markers (bullets and numbers) appear and disappear together with the fragment content.

Also compatible with [`pandoc-ext/list-table`](https://github.com/pandoc-ext/list-table) for adding fragments to table cells and rows.

## Installation

```bash
quarto add mcanouil/quarto-revealjs-fragmention
```

This will install the extension under the `_extensions` subdirectory.
If you are using version control, you will want to check in this directory.

## Usage

Add the filter to your document's front matter:

```yaml
filters:
  - fragmention
```

Then place an empty `.fragment` span at the start of any list item:

```markdown
- []{.fragment fragment-index="1"} First item.
  - []{.fragment fragment-index="2"} Nested item.
  - []{.fragment fragment-index="3"} Another nested item.
- A normal item without a fragment.
```

The filter removes the empty span and applies its classes and attributes to the `<li>` element.
RevealJS then controls the entire list item's visibility, including the bullet marker.

### Fragment styles

All RevealJS fragment classes are supported:

```markdown
- []{.fragment .fade-in fragment-index="1"} Fade in.
- []{.fragment .highlight-red fragment-index="2"} Highlight red.
- []{.fragment .grow fragment-index="3"} Grow.
```

### Ordered lists

Works with ordered lists too:

```markdown
1. []{.fragment fragment-index="1"} First step.
2. []{.fragment fragment-index="2"} Second step.
3. []{.fragment fragment-index="3"} Third step.
```

### list-table compatibility

When used with [`pandoc-ext/list-table`](https://github.com/pandoc-ext/list-table), ensure `list-table` runs first:

```yaml
filters:
  - list-table
  - fragmention
```

The `list-table` extension already consumes empty spans at the start of cells/rows and transfers their attributes.
Fragmention then renames `fragment-index` to `data-fragment-index` on table elements so RevealJS can recognise them.

```markdown
:::{.list-table}

- - []{.fragment fragment-index="1"} Name
  - []{.fragment fragment-index="1"} Value

- - []{.fragment fragment-index="2"} Another
    - []{.fragment fragment-index="2"} Data
      :::
```

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).

Rendered output:

- [HTML](https://m.canouil.dev/quarto-fragmention/).
