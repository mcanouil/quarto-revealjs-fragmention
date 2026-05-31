# Changelog

## Unreleased

### Bug Fixes

- fix: Strip every leading whitespace token (`Space`, `SoftBreak`, `LineBreak`) after removing the empty fragment marker, not just the first one, so marker spans on their own line do not leave whitespace artefacts.
- fix: Escape HTML special characters in hoisted class, identifier and attribute values, so values containing `&`, `<`, `>` or `"` produce well-formed output.

### Internal Changes

- refactor: Walk lists with a top-down AST traversal that builds nested HTML in a single pass, avoiding repeated `pandoc.write()` round-trips through `RawBlock` at every nesting level.
- chore: Reset module-level state (`css_injected`) in the `Meta` pass so batch renders do not carry state between documents.

## 0.2.0 (2026-05-24)

### New Features

- feat: Hoist fragment attributes from an empty marker span to the rendered `<dd>` of a definition list, so a glossary or Q&A definition reveals as one fragment.
- feat: Hoist fragment attributes from a leading empty marker span to the rendered `<blockquote>`, so a whole quote reveals as one fragment.

## 0.1.0 (2026-04-05)

- feat: Initial release.
