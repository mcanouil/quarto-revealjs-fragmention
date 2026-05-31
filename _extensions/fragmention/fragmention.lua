--- Fragmention - Filter
--- @module fragmention
--- @license MIT License
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil
--- @brief Hoist fragment attributes from empty marker spans to parent elements.
--- @description Moves .fragment class and fragment-index from empty inline
---   Spans to their parent <li>, <dd> and <blockquote> elements in RevealJS
---   presentations. Renames fragment-index to data-fragment-index on Table
---   cells/rows for compatibility with pandoc-ext/list-table.

-- ============================================================================
-- MODULE-LEVEL STATE
-- ============================================================================

--- Whether the table fragment CSS has already been injected.
--- Reset in the Meta pass so batch renders do not skip injection on later
--- documents that need it.
--- @type boolean
local css_injected = false

-- ============================================================================
-- METADATA HANDLING
-- ============================================================================

--- Reset module-level state before processing a document.
--- @param meta pandoc.Meta
--- @return pandoc.Meta
local function read_meta(meta)
  css_injected = false
  return meta
end

-- ============================================================================
-- CSS INJECTION
-- ============================================================================

--- Inject CSS to collapse table fragment rows/cells until they become visible.
--- RevealJS hides fragments with opacity:0 but the row still occupies space
--- and shows borders, so collapse them entirely.
local function inject_table_fragment_css()
  if css_injected then
    return
  end
  css_injected = true
  quarto.doc.add_html_dependency({
    name = 'fragmention',
    version = '0.0.0',
    stylesheets = {},
  })
  quarto.doc.include_text('in-header', [[
<style>
.reveal table tbody tr.fragment:not(.visible) {
  border-color: transparent;
}
.reveal table tbody tr.fragment:not(.visible) td,
.reveal table tbody tr.fragment:not(.visible) th {
  border-color: transparent;
}
</style>
]])
end

-- ============================================================================
-- FORMAT DETECTION
-- ============================================================================

--- Check whether the current output format is RevealJS.
--- @return boolean
local function is_revealjs()
  return quarto.doc.is_format('revealjs')
end

-- ============================================================================
-- HTML BUILDING
-- ============================================================================

--- HTML special-character escape table for attribute values.
local HTML_ATTR_ESCAPES = {
  ['&'] = '&amp;',
  ['<'] = '&lt;',
  ['>'] = '&gt;',
  ['"'] = '&quot;',
}

--- Escape a string for use as an HTML attribute value.
--- @param value string
--- @return string
local function escape_html_attr(value)
  return (value:gsub('[&<>"]', HTML_ATTR_ESCAPES))
end

--- Check whether a Span is an empty fragment marker.
--- An empty fragment marker is a Span with the "fragment" class and no content.
--- @param span pandoc.Span
--- @return boolean
local function is_empty_fragment_span(span)
  return span.t == 'Span'
      and span.classes:includes('fragment')
      and #span.content == 0
end

--- Build an HTML attribute string from a fragment Span's classes and
--- attributes. Maps fragment-index to data-fragment-index for RevealJS.
--- Returns an empty string if no attributes/classes/identifier are present.
--- @param span pandoc.Span
--- @return string
local function build_fragment_attrs(span)
  local parts = {}

  if #span.classes > 0 then
    table.insert(parts, 'class="' .. escape_html_attr(table.concat(span.classes, ' ')) .. '"')
  end

  if span.identifier and span.identifier ~= '' then
    table.insert(parts, 'id="' .. escape_html_attr(span.identifier) .. '"')
  end

  for key, value in pairs(span.attributes) do
    table.insert(parts, 'data-' .. key .. '="' .. escape_html_attr(value) .. '"')
  end

  return table.concat(parts, ' ')
end

--- Build an HTML opening tag for a wrapper element with hoisted fragment
--- attributes from a Span. When the Span is nil, a bare opening tag is emitted.
--- @param tag string The element name (e.g. "li", "dd", "blockquote")
--- @param span pandoc.Span|nil The fragment span, or nil
--- @return string
local function open_fragment_element(tag, span)
  if not span then
    return '<' .. tag .. '>'
  end
  local attrs = build_fragment_attrs(span)
  if attrs == '' then
    return '<' .. tag .. '>'
  end
  return '<' .. tag .. ' ' .. attrs .. '>'
end

--- Render Pandoc Inlines to an HTML string, trimming whitespace.
--- A single conversion pass per inline run keeps the cost linear.
--- @param inlines pandoc.Inlines
--- @return string
local function render_inlines_html(inlines)
  if #inlines == 0 then
    return ''
  end
  local html = pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines) }), 'html')
  return (html:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^<p>(.*)</p>$', '%1'))
end

--- Render a single Pandoc Block to an HTML string, trimming whitespace.
--- @param block pandoc.Block
--- @return string
local function render_block_html(block)
  local html = pandoc.write(pandoc.Pandoc({ block }), 'html')
  return (html:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- ============================================================================
-- LIST PROCESSING (AST WALKER)
-- ============================================================================

--- Detect whether an inline element is a "whitespace" token that should be
--- skipped after removing a leading empty fragment span. SoftBreak appears
--- when the marker span sits on its own line; LineBreak when explicit.
--- @param inline pandoc.Inline
--- @return boolean
local function is_whitespace_inline(inline)
  return inline.t == 'Space' or inline.t == 'SoftBreak' or inline.t == 'LineBreak'
end

--- Strip the leading empty fragment span and any subsequent whitespace tokens
--- from the first block of a list item or definition. Returns the resulting
--- Blocks list (a fresh copy).
--- @param item table List of Blocks (one list item or definition)
--- @return pandoc.Blocks
local function strip_leading_fragment(item)
  local blocks = pandoc.Blocks({})
  for i = 1, #item do
    blocks:insert(item[i])
  end

  local first_block = blocks[1]
  if not first_block then
    return blocks
  end
  if first_block.t ~= 'Plain' and first_block.t ~= 'Para' then
    return blocks
  end

  local inlines = pandoc.Inlines(first_block.content)
  if #inlines == 0 or not is_empty_fragment_span(inlines[1]) then
    return blocks
  end

  inlines:remove(1)
  while #inlines > 0 and is_whitespace_inline(inlines[1]) do
    inlines:remove(1)
  end

  if #inlines == 0 then
    blocks:remove(1)
  elseif first_block.t == 'Para' then
    blocks[1] = pandoc.Para(inlines)
  else
    blocks[1] = pandoc.Plain(inlines)
  end

  return blocks
end

--- Detect the leading fragment span on an item, if any.
--- @param item table List of Blocks
--- @return pandoc.Span|nil
local function get_item_fragment_span(item)
  local first_block = item[1]
  if not first_block then
    return nil
  end
  if first_block.t ~= 'Plain' and first_block.t ~= 'Para' then
    return nil
  end
  local inlines = first_block.content
  if #inlines == 0 then
    return nil
  end
  if is_empty_fragment_span(inlines[1]) then
    return inlines[1]
  end
  return nil
end

--- Forward declarations for mutual recursion.
local render_bullet_list_html, render_ordered_list_html

--- Render an item's inner content to HTML by walking its Blocks once.
--- Nested fragment-bearing lists are rendered directly to HTML strings to
--- avoid round-tripping through pandoc.write for each nesting level.
--- @param blocks pandoc.Blocks Stripped item blocks
--- @return string
local function render_item_html(blocks)
  if #blocks == 0 then
    return ''
  end

  local first_block = blocks[1]

  if #blocks == 1 and (first_block.t == 'Plain' or first_block.t == 'Para') then
    return render_inlines_html(first_block.content)
  end

  local parts = {}
  for i = 1, #blocks do
    local block = blocks[i]
    if block.t == 'BulletList' then
      table.insert(parts, render_bullet_list_html(block))
    elseif block.t == 'OrderedList' then
      table.insert(parts, render_ordered_list_html(block))
    elseif (block.t == 'Plain' or block.t == 'Para') and i == 1 then
      table.insert(parts, render_inlines_html(block.content))
    else
      table.insert(parts, render_block_html(block))
    end
  end
  return table.concat(parts, '\n')
end

--- Render the items of a BulletList or OrderedList as `<li>` lines, hoisting
--- fragment attributes from a leading marker span (or an auto-injected one).
--- @param items table List of items (each is a list of Blocks)
--- @return string[] Lines to append between the list's opening and closing tags
local function render_list_items_html(items)
  local lines = {}
  for _, item in ipairs(items) do
    local frag_span = get_item_fragment_span(item)
    local stripped = frag_span and strip_leading_fragment(item) or pandoc.Blocks(item)
    table.insert(lines,
      open_fragment_element('li', frag_span)
      .. render_item_html(stripped)
      .. '</li>')
  end
  return lines
end

--- Render a BulletList to HTML with fragment attributes hoisted to <li>.
--- @param list pandoc.BulletList
--- @return string
render_bullet_list_html = function(list)
  local lines = { '<ul>' }
  for _, line in ipairs(render_list_items_html(list.content)) do
    table.insert(lines, line)
  end
  table.insert(lines, '</ul>')
  return table.concat(lines, '\n')
end

--- Render an OrderedList to HTML with fragment attributes hoisted to <li>.
--- Preserves start number and list type.
--- @param list pandoc.OrderedList
--- @return string
render_ordered_list_html = function(list)
  local type_map = {
    Decimal = '1',
    LowerAlpha = 'a',
    UpperAlpha = 'A',
    LowerRoman = 'i',
    UpperRoman = 'I',
  }

  local ol_attrs = {}
  if list.start and list.start ~= 1 then
    table.insert(ol_attrs, 'start="' .. tostring(list.start) .. '"')
  end
  local html_type = type_map[list.style]
  if html_type and html_type ~= '1' then
    table.insert(ol_attrs, 'type="' .. html_type .. '"')
  end

  local ol_open = '<ol'
  if #ol_attrs > 0 then
    ol_open = ol_open .. ' ' .. table.concat(ol_attrs, ' ')
  end
  ol_open = ol_open .. '>'

  local lines = { ol_open }
  for _, line in ipairs(render_list_items_html(list.content)) do
    table.insert(lines, line)
  end
  table.insert(lines, '</ol>')
  return table.concat(lines, '\n')
end

--- Render a DefinitionList to HTML with fragment attributes hoisted to <dd>.
--- @param list pandoc.DefinitionList
--- @return string
local function render_definition_list_html(list)
  local lines = { '<dl>' }
  for _, item in ipairs(list.content) do
    local term = item[1]
    local definitions = item[2]
    table.insert(lines, '<dt>' .. render_inlines_html(pandoc.Inlines(term)) .. '</dt>')
    for _, definition in ipairs(definitions) do
      local frag_span = get_item_fragment_span(definition)
      local stripped = frag_span and strip_leading_fragment(definition) or pandoc.Blocks(definition)
      table.insert(lines,
        open_fragment_element('dd', frag_span)
        .. render_item_html(stripped)
        .. '</dd>')
    end
  end
  table.insert(lines, '</dl>')
  return table.concat(lines, '\n')
end

--- Check whether a BulletList/OrderedList (or its nested lists) has any
--- fragment span on an item, so unmodified lists can short-circuit.
--- @param items table List of list items
--- @return boolean
local function list_has_fragments(items)
  for _, item in ipairs(items) do
    if get_item_fragment_span(item) then
      return true
    end
    for _, block in ipairs(item) do
      if (block.t == 'BulletList' or block.t == 'OrderedList')
          and list_has_fragments(block.content)
      then
        return true
      end
    end
  end
  return false
end

--- Check whether any definition in a DefinitionList has a fragment span.
--- @param items table List of {term, definitions} pairs
--- @return boolean
local function definition_list_has_fragments(items)
  for _, item in ipairs(items) do
    for _, definition in ipairs(item[2]) do
      if get_item_fragment_span(definition) then
        return true
      end
    end
  end
  return false
end

-- ============================================================================
-- TABLE PROCESSING
-- ============================================================================

--- Rename fragment-index to data-fragment-index on an Attr object.
--- @param attr pandoc.Attr
--- @return boolean Whether a rename occurred
local function fix_fragment_attr(attr)
  local idx = attr.attributes['fragment-index']
  if idx then
    attr.attributes['fragment-index'] = nil
    attr.attributes['data-fragment-index'] = idx
    return true
  end
  return false
end

--- Process a Table to rename fragment-index on cells and rows.
--- Ensures compatibility with pandoc-ext/list-table which transfers
--- empty span attributes to table elements but does not add the data- prefix.
--- @param el pandoc.Table
--- @return pandoc.Table|nil
local function process_table(el)
  local changed = false

  local function process_rows(rows)
    for _, row in ipairs(rows) do
      if row.attr and row.attr.classes:includes('fragment') then
        if fix_fragment_attr(row.attr) then
          changed = true
        end
      end
      for _, cell in ipairs(row.cells) do
        if cell.attr and cell.attr.classes:includes('fragment') then
          if fix_fragment_attr(cell.attr) then
            changed = true
          end
        end
      end
    end
  end

  process_rows(el.head.rows)
  for _, body in ipairs(el.bodies) do
    process_rows(body.head)
    process_rows(body.body)
  end
  if el.foot then
    process_rows(el.foot.rows)
  end

  if changed then
    inject_table_fragment_css()
    return el
  end
  return nil
end

-- ============================================================================
-- FILTER ENTRY POINT
-- ============================================================================

return {
  {
    Meta = read_meta,
  },
  {
    traverse = 'topdown',
    BulletList = function(el)
      if not is_revealjs() then
        return el
      end
      if not list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_bullet_list_html(el)), false
    end,
    OrderedList = function(el)
      if not is_revealjs() then
        return el
      end
      if not list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_ordered_list_html(el)), false
    end,
    DefinitionList = function(el)
      if not is_revealjs() then
        return el
      end
      if not definition_list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_definition_list_html(el)), false
    end,
    BlockQuote = function(el)
      if not is_revealjs() then
        return el
      end
      local frag_span = get_item_fragment_span(el.content)
      if not frag_span then
        return el
      end
      local stripped = strip_leading_fragment(el.content)
      local html = open_fragment_element('blockquote', frag_span)
        .. render_item_html(stripped)
        .. '</blockquote>'
      return pandoc.RawBlock('html', html), false
    end,
    Table = function(el)
      if not is_revealjs() then
        return el
      end
      return process_table(el)
    end,
  },
}
