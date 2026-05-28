--- Fragmention - Filter
--- @module fragmention
--- @license MIT License
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil
--- @brief Hoist fragment attributes from empty marker spans to parent elements.
--- @description Moves .fragment class and fragment-index from empty inline
---   Spans to their parent <li>, <dd> and <blockquote> elements in RevealJS
---   presentations. Renames fragment-index to data-fragment-index on Table
---   cells/rows for compatibility with pandoc-ext/list-table. Also offers an
---   optional auto-numbering mode and a validation pass that flags duplicate
---   or mixed fragment indices.

--- Extension name constant used in log messages.
local EXTENSION_NAME = 'fragmention'

local log = require(quarto.utils.resolve_path('_modules/logging.lua'):gsub('%.lua$', ''))

-- ============================================================================
-- MODULE-LEVEL STATE
-- ============================================================================

--- Whether the table fragment CSS has already been injected.
--- Reset in the Meta pass so batch renders do not skip injection on later
--- documents that need it.
--- @type boolean
local css_injected = false

--- Whether sequential auto-numbering is enabled via metadata.
--- @type boolean
local auto_number = false

--- Whether the validation pass is enabled via metadata.
--- @type boolean
local validate_indices = false

--- Counter for sequential auto-numbering across the document.
--- @type integer
local auto_number_counter = 0

-- ============================================================================
-- METADATA HANDLING
-- ============================================================================

--- Read a boolean option from a metadata table, accepting MetaBool and
--- MetaInlines forms ("true", "yes", "1" are truthy).
--- @param value any The metadata value
--- @return boolean
local function meta_to_bool(value)
  if value == nil then
    return false
  end
  if type(value) == 'boolean' then
    return value
  end
  local text = pandoc.utils.stringify(value):lower()
  return text == 'true' or text == 'yes' or text == '1'
end

--- Reset module-level state and read options from document metadata.
--- @param meta pandoc.Meta
--- @return pandoc.Meta
local function read_meta(meta)
  css_injected = false
  auto_number_counter = 0
  auto_number = false
  validate_indices = false

  local options = meta.fragmention
  if options then
    auto_number = meta_to_bool(options['auto-number'])
    validate_indices = meta_to_bool(options['validate'])
  end
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
-- AUTO-NUMBERING AND VALIDATION
-- ============================================================================

--- Assign a sequential fragment index to a Span when auto-numbering is on
--- and no fragment-index is already set.
--- @param span pandoc.Span
local function maybe_auto_number(span)
  if not auto_number then
    return
  end
  if span.attributes['fragment-index'] then
    return
  end
  auto_number_counter = auto_number_counter + 1
  span.attributes['fragment-index'] = tostring(auto_number_counter)
end

--- Validate fragment indices in a Span against a per-slide ledger.
--- Warns on duplicate indices within the same slide and on mixed
--- present/absent indices on a slide. Treats every non-empty value as opaque
--- text so non-numeric indices are still compared structurally.
--- @param span pandoc.Span
--- @param ledger { seen: table<string, integer>, has_index: boolean, has_missing: boolean, slide: string }
local function record_index(span, ledger)
  local idx = span.attributes['fragment-index']
  if idx == nil or idx == '' then
    ledger.has_missing = true
    return
  end
  ledger.has_index = true
  local count = (ledger.seen[idx] or 0) + 1
  ledger.seen[idx] = count
  if count == 2 then
    log.log_warning(EXTENSION_NAME,
      'Duplicate fragment-index "' .. idx .. '" on slide "' .. ledger.slide .. '".')
  end
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

--- Add a `.fragment` marker span (without indices) to an item if
--- auto-numbering is enabled and the item has no leading marker. This lets
--- authors enable bullets-as-fragments document-wide without per-item markup.
--- Returns the (possibly new) span, or nil if no marker should be added.
--- @param item table List of Blocks
--- @return pandoc.Span|nil
local function inject_auto_marker(item)
  if not auto_number then
    return nil
  end
  local first_block = item[1]
  if not first_block then
    return nil
  end
  if first_block.t ~= 'Plain' and first_block.t ~= 'Para' then
    return nil
  end
  return pandoc.Span({}, pandoc.Attr('', { 'fragment' }, {}))
end

--- Forward declarations for mutual recursion.
local render_bullet_list_html, render_ordered_list_html

--- Render an item's inner content to HTML by walking its Blocks once.
--- Nested fragment-bearing lists are rendered directly to HTML strings to
--- avoid round-tripping through pandoc.write for each nesting level.
--- @param blocks pandoc.Blocks Stripped item blocks
--- @param ledger { seen: table<string, integer>, has_index: boolean, has_missing: boolean, slide: string }|nil
--- @return string
local function render_item_html(blocks, ledger)
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
      table.insert(parts, render_bullet_list_html(block, ledger))
    elseif block.t == 'OrderedList' then
      table.insert(parts, render_ordered_list_html(block, ledger))
    elseif (block.t == 'Plain' or block.t == 'Para') and i == 1 then
      table.insert(parts, render_inlines_html(block.content))
    else
      table.insert(parts, render_block_html(block))
    end
  end
  return table.concat(parts, '\n')
end

--- Render a BulletList to HTML with fragment attributes hoisted to <li>.
--- @param list pandoc.BulletList
--- @param ledger { seen: table<string, integer>, has_index: boolean, has_missing: boolean, slide: string }|nil
--- @return string
render_bullet_list_html = function(list, ledger)
  local lines = { '<ul>' }
  for _, item in ipairs(list.content) do
    local frag_span = get_item_fragment_span(item)
    if not frag_span then
      frag_span = inject_auto_marker(item)
    end
    if frag_span then
      maybe_auto_number(frag_span)
      if ledger then
        record_index(frag_span, ledger)
      end
    end
    local stripped = get_item_fragment_span(item) and strip_leading_fragment(item) or pandoc.Blocks(item)
    table.insert(lines,
      open_fragment_element('li', frag_span)
      .. render_item_html(stripped, ledger)
      .. '</li>')
  end
  table.insert(lines, '</ul>')
  return table.concat(lines, '\n')
end

--- Render an OrderedList to HTML with fragment attributes hoisted to <li>.
--- Preserves start number and list type.
--- @param list pandoc.OrderedList
--- @param ledger { seen: table<string, integer>, has_index: boolean, has_missing: boolean, slide: string }|nil
--- @return string
render_ordered_list_html = function(list, ledger)
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
  for _, item in ipairs(list.content) do
    local frag_span = get_item_fragment_span(item)
    if not frag_span then
      frag_span = inject_auto_marker(item)
    end
    if frag_span then
      maybe_auto_number(frag_span)
      if ledger then
        record_index(frag_span, ledger)
      end
    end
    local stripped = get_item_fragment_span(item) and strip_leading_fragment(item) or pandoc.Blocks(item)
    table.insert(lines,
      open_fragment_element('li', frag_span)
      .. render_item_html(stripped, ledger)
      .. '</li>')
  end
  table.insert(lines, '</ol>')
  return table.concat(lines, '\n')
end

--- Render a DefinitionList to HTML with fragment attributes hoisted to <dd>.
--- @param list pandoc.DefinitionList
--- @param ledger { seen: table<string, integer>, has_index: boolean, has_missing: boolean, slide: string }|nil
--- @return string
local function render_definition_list_html(list, ledger)
  local lines = { '<dl>' }
  for _, item in ipairs(list.content) do
    local term = item[1]
    local definitions = item[2]
    table.insert(lines, '<dt>' .. render_inlines_html(pandoc.Inlines(term)) .. '</dt>')
    for _, definition in ipairs(definitions) do
      local frag_span = get_item_fragment_span(definition)
      if frag_span then
        maybe_auto_number(frag_span)
        if ledger then
          record_index(frag_span, ledger)
        end
      end
      local stripped = frag_span and strip_leading_fragment(definition) or pandoc.Blocks(definition)
      table.insert(lines,
        open_fragment_element('dd', frag_span)
        .. render_item_html(stripped, ledger)
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
-- SLIDE-SCOPED VALIDATION
-- ============================================================================

--- Walk a slide section's blocks once, collecting fragment indices found on
--- lists/definitions/blockquotes that this filter handles. Issues warnings on
--- duplicate indices and on slides that mix indexed and missing fragments.
--- @param section_blocks pandoc.Blocks
--- @param slide_title string
local function validate_slide(section_blocks, slide_title)
  if not validate_indices then
    return
  end
  local ledger = { seen = {}, has_index = false, has_missing = false, slide = slide_title }

  local function walk(blocks)
    for _, block in ipairs(blocks) do
      if block.t == 'BulletList' or block.t == 'OrderedList' then
        for _, item in ipairs(block.content) do
          local span = get_item_fragment_span(item)
          if span then
            record_index(span, ledger)
          end
          walk(item)
        end
      elseif block.t == 'DefinitionList' then
        for _, item in ipairs(block.content) do
          for _, definition in ipairs(item[2]) do
            local span = get_item_fragment_span(definition)
            if span then
              record_index(span, ledger)
            end
            walk(definition)
          end
        end
      elseif block.t == 'BlockQuote' then
        local span = get_item_fragment_span(block.content)
        if span then
          record_index(span, ledger)
        end
        walk(block.content)
      elseif block.t == 'Div' then
        walk(block.content)
      end
    end
  end

  walk(section_blocks)

  if ledger.has_index and ledger.has_missing then
    log.log_warning(EXTENSION_NAME,
      'Slide "' .. slide_title .. '" mixes fragments with and without an explicit fragment-index.')
  end
end

-- ============================================================================
-- FILTER ENTRY POINT
-- ============================================================================

return {
  {
    Meta = read_meta,
  },
  {
    Pandoc = function(doc)
      if not is_revealjs() then
        return nil
      end
      if not validate_indices then
        return nil
      end
      local current_title = 'Untitled'
      local current_blocks = pandoc.Blocks({})
      for _, block in ipairs(doc.blocks) do
        if block.t == 'Header' and block.level == 2 then
          validate_slide(current_blocks, current_title)
          current_title = pandoc.utils.stringify(block.content)
          current_blocks = pandoc.Blocks({})
        else
          current_blocks:insert(block)
        end
      end
      validate_slide(current_blocks, current_title)
      return nil
    end,
  },
  {
    traverse = 'topdown',
    BulletList = function(el)
      if not is_revealjs() then
        return el
      end
      if not auto_number and not list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_bullet_list_html(el, nil)), false
    end,
    OrderedList = function(el)
      if not is_revealjs() then
        return el
      end
      if not auto_number and not list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_ordered_list_html(el, nil)), false
    end,
    DefinitionList = function(el)
      if not is_revealjs() then
        return el
      end
      if not definition_list_has_fragments(el.content) then
        return el
      end
      return pandoc.RawBlock('html', render_definition_list_html(el, nil)), false
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
        .. render_item_html(stripped, nil)
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
