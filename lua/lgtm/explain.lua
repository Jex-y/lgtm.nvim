-- The explanation column: a fourth pane, right of the working file, carrying one
-- block per hunk and scrolling with it.
--
-- Not created with the session. A review often does not need it — the diff is the
-- diff — and it costs an agent invocation per file, so it is opened on demand and
-- populated at that moment.
--
-- One block per *region*, not per hunk. A region is a run of hunks with no fold
-- between them, which is what the reviewer sees as one contiguous block of
-- change. Explaining raw `vim.diff` hunks instead spends a block on every
-- consequence of a nearby edit — a line that moved because four lines above it
-- were deleted is its own hunk, and it is not its own change.
--
-- Alignment is anchored, not row-for-row. A block of prose about a two-line hunk
-- is taller than the hunk it describes, so padding the pane to the working file's
-- length cannot both keep every block level with its hunk and keep them from
-- colliding. Instead each hunk is an anchor pairing a working-file line with an
-- explanation line, and the pane's top is interpolated between the two anchors
-- the viewport currently sits between — then clamped so the block for the hunk
-- you are actually looking at stays on screen. Landing exactly on a hunk puts its
-- explanation exactly at the top; between hunks the pane slides.

local ai = require("lgtm.ai")
local colors = require("lgtm.colors")
local git = require("lgtm.git")
local markdown = require("lgtm.markdown")
local reviewers = require("lgtm.reviewers")
local state = require("lgtm.state")
local store = require("lgtm.store")

local M = {}

local PAD_NS = vim.api.nvim_create_namespace("lgtm_explain_pad")

--- Guards the write-back into the pane's own view, which fires WinScrolled and
--- would otherwise re-enter through the session's scroll autocmd.
local syncing = false

function M.setup_highlights(diff_colors)
    local opts = type(diff_colors) == "table" and diff_colors or {}
    vim.api.nvim_set_hl(0, "LgtmExplainHead", { link = "NonText" })
    vim.api.nvim_set_hl(0, "LgtmExplainTitle", { bold = true })
    vim.api.nvim_set_hl(0, "LgtmExplainMeta", { link = "Comment" })
    vim.api.nvim_set_hl(0, "LgtmExplainAdd", { fg = colors.accent("add", opts) })
    vim.api.nvim_set_hl(0, "LgtmExplainDel", { fg = colors.accent("delete", opts) })
    -- No "active block" highlight: the panes are aligned row for row, so which
    -- explanation belongs to what you are looking at is answered by where it is.
    reviewers.setup_highlights()
end

function M.is_open(session)
    return session ~= nil
        and session.explain_win ~= nil
        and vim.api.nvim_win_is_valid(session.explain_win)
end

--- The review column, which has its own lifecycle: it does not come and go
--- with the explain column, only with the session.
function M.review_open(session)
    return session ~= nil
        and session.review_win ~= nil
        and vim.api.nvim_win_is_valid(session.review_win)
end

local function any_open(session)
    return M.is_open(session) or M.review_open(session)
end

-- ---------------------------------------------------------------------------
-- The store
--
-- One directory per branch and merge base, one JSON file per changed file, written
-- by the agent itself. See store.lua for why that shape.
-- ---------------------------------------------------------------------------

local function store_dir(session)
    return store.dir(session.branch, session.merge_base, ai.PROMPT_VERSION)
end

--- The full change. `session.entries` is the list the tree is showing, and a
--- selected chapter narrows it — but the run, its progress and its resume list are
--- always about every file in the PR.
local function all_entries(session)
    return session.all_entries or session.entries
end

--- How far the run has got, for the pane's own progress line.
local function progress(session)
    local done = 0
    for _ in pairs(session.explain_store or {}) do
        done = done + 1
    end
    return done, #all_entries(session)
end

--- Files in the change with no explanation yet.
local function outstanding(session)
    local out = {}
    for _, e in ipairs(all_entries(session)) do
        if not (session.explain_store or {})[e.path] then
            table.insert(out, e.path)
        end
    end
    return out
end

--- Drop this branch's store. Exposed as :LgtmExplainClearCache, because a prompt
--- this long is worth iterating on and stale results hide the change.
function M.clear_store(session)
    if not session then
        return 0
    end
    session.explain_store = {}
    local n = store.clear(store_dir(session))
    -- The guide is part of the store, so clearing one clears the other; the
    -- chapter picker follows it off the screen.
    if session.guide then
        session.guide, session.guide_json = nil, nil
        if session.on_guide then
            session.on_guide()
        end
    end
    return n
end

--- The reviewer guide for this branch, if a run has written one.
function M.load_guide(session)
    return store.load_guide(store_dir(session))
end

--- Which roles have findings on which paths, as one string: the tree's dots
--- change exactly when this does.
function M.review_signature(session)
    local parts = {}
    for path, by_role in pairs(session.review_store or {}) do
        for key, comments in pairs(by_role) do
            if #comments > 0 then
                table.insert(parts, path .. "=" .. key)
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

--- The stored explanations and review findings, loaded on demand — the tree's
--- reviewer dots and the ask float both want them whether or not a column is
--- open. Cached on the session; `reload` refreshes them when a run writes.
function M.ensure_loaded(session)
    session.explain_store = session.explain_store or store.load(store_dir(session))
    session.review_store = session.review_store or store.load_reviews(store_dir(session))
    return session.explain_store, session.review_store
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Where a hunk sits in the working file: a range when it has lines there, a
--- single position when it only removes.
local function hunk_span(h)
    local count_a, start_b, count_b = h[2], h[3], h[4]
    if count_b > 0 then
        return start_b, start_b + count_b - 1, count_b, count_a
    end
    return start_b, start_b, 0, count_a
end

local function span_label(first, last, added)
    if added == 0 then
        return "after " .. first
    elseif first == last then
        return tostring(first)
    end
    return string.format("%d–%d", first, last)
end

--- Unchanged lines within `context` of a change are left unfolded by Vim, so a
--- gap of 2*context or less between two hunks is never collapsed and the two read
--- as one region on screen.
local function diff_context()
    for _, part in ipairs(vim.split(vim.o.diffopt or "", ",", { plain = true })) do
        local n = part:match("^context:(%d+)$")
        if n then
            -- `context:0` means one, not zero: "folds require a line in between,
            -- also for a deleted line". Taking it literally would make the merge
            -- rule stricter than the folds it is meant to model.
            return math.max(1, tonumber(n))
        end
    end
    -- Absent from diffopt, which is the default, and Vim then uses six.
    return 6
end

--- Collapse hunks into the regions the reviewer actually sees.
--- @param view_height number|nil rows in the code pane; caps the merge distance
--- @return table list of { first, last, base_last, added, removed, hunks }
local function build_regions(hunks, context, view_height)
    -- Folds are why two hunks read as one region, but `context:999999` is the
    -- documented way to disable folding altogether, and that would otherwise
    -- collapse a whole file of scattered changes into a single block. Two changes
    -- that cannot be on screen together are not one region whatever the fold
    -- settings say, so the pane's height is the ceiling.
    local limit = math.min(2 * context, view_height or math.huge)
    local out = {}
    for i, h in ipairs(hunks or {}) do
        local first, last, added, removed = hunk_span(h)
        -- Where the region ends on the base side. When a side has no lines in the
        -- hunk `vim.diff` reports the line the other side's block hangs after, so
        -- that is already the last line this side covers.
        local base_last = h[2] > 0 and (h[1] + h[2] - 1) or h[1]
        local prev = out[#out]
        if prev and (first - prev.last - 1) <= limit then
            prev.last = math.max(prev.last, last)
            prev.base_last = math.max(prev.base_last, base_last)
            prev.added = prev.added + added
            prev.removed = prev.removed + removed
            table.insert(prev.hunks, i)
        else
            table.insert(out, {
                first = first,
                last = last,
                base_last = base_last,
                added = added,
                removed = removed,
                hunks = { i },
            })
        end
    end
    return out
end

M._build_regions = build_regions

--- The regions of the file on show, computed from its hunks the same way the
--- columns compute them, so "the hunk under the cursor" means the same block
--- the explanation column would put beside it.
function M.regions_for(session)
    if not session.hunks or #session.hunks == 0 then
        return {}
    end
    if session.explain_regions and #session.explain_regions > 0 then
        return session.explain_regions
    end
    local height = (session.working_win and vim.api.nvim_win_is_valid(session.working_win))
            and vim.api.nvim_win_get_height(session.working_win)
        or nil
    return build_regions(session.hunks, diff_context(), height)
end

--- Display rows the code pane leaves beside region `i`, from its first line up to
--- the next region's. Display rows, not buffer lines: the gap between two regions
--- is a closed fold plus its context, which is a dozen rows however many hundred
--- lines it stands for. That is the number an explanation has to fit inside.
--- Display rows the working pane needs for buffer lines 1..line-1 — which is the
--- screen row that line sits on, counted from the top of the buffer.
---
--- Display rows rather than buffer lines is the whole basis of the alignment: folds,
--- diff filler and virtual lines are all already folded into this number, so a
--- canvas indexed by it needs to reproduce none of them.
local function rows_above(win, line)
    if line <= 1 then
        return 0
    end
    local ok, h = pcall(vim.api.nvim_win_text_height, win, { start_row = 0, end_row = line - 2 })
    return (ok and h and h.all) or (line - 1)
end

local function total_rows(win)
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    local ok, h = pcall(vim.api.nvim_win_text_height, win, { start_row = 0, end_row = count - 1 })
    return (ok and h and h.all) or count
end

--- Everything the laid-out pane depends on: the width, which sets how the prose
--- wraps and therefore every block's height, and the screen row each region sits on.
--- Both change without anything regenerating — the pane is resized, a fold is opened
--- — so both are watched rather than assumed fixed.
---
--- The rows are measured rather than inferred from the fold state. Probing folds
--- directly is what the first attempt did, by asking whether the line after a region
--- was folded — and that line is always inside the region's own unfolded context, so
--- opening every fold in the file changed nothing it could see.
local function layout_signature(session)
    if not any_open(session) then
        return nil
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return nil
    end
    local parts = {}
    if M.is_open(session) then
        table.insert(parts, "e" .. vim.api.nvim_win_get_width(session.explain_win))
    end
    if M.review_open(session) then
        table.insert(parts, "r" .. vim.api.nvim_win_get_width(session.review_win))
    end
    for _, r in ipairs(session.explain_regions or {}) do
        table.insert(parts, rows_above(win, r.first))
    end
    table.insert(parts, total_rows(win))
    return table.concat(parts, ":")
end

--- Blank display rows inserted below a region, so the next region is pushed far
--- enough down the screen that this region's explanation fits beside it.
---
--- Virtual lines rather than real ones: the working pane is the file itself, and
--- padding it with blank lines would mean editing the thing under review. They go
--- into both code panes at the same logical line — the end of the region's trailing
--- context, where the fold begins — because those context lines are unchanged and
--- therefore common to the two sides, so the same offset lands on the same row in
--- each and the panes stay level with one another.
local function clear_padding(session)
    for _, buf in ipairs(session.explain_padded or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, PAD_NS, 0, -1)
        end
    end
    session.explain_padded = {}
end

--- @param deficits table region index -> extra rows wanted below it
local function apply_padding(session, deficits)
    clear_padding(session)
    if session.cfg.explain.pad == false or not M.is_open(session) then
        return false
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(session.base_win)) then
        return false
    end
    if vim.tbl_isempty(deficits) then
        return false
    end

    local wbuf = vim.api.nvim_win_get_buf(win)
    local bbuf = vim.api.nvim_win_get_buf(session.base_win)
    local wcount = vim.api.nvim_buf_line_count(wbuf)
    local bcount = vim.api.nvim_buf_line_count(bbuf)
    local regions = session.explain_regions or {}
    local context = diff_context()

    local touched, seen = {}, {}
    for i, need in pairs(deficits) do
        local r = regions[i]
        if r then
            local virt = {}
            for _ = 1, need do
                table.insert(virt, { { "", "NonText" } })
            end
            -- Never past the start of the next region, and never the buffer's final
            -- line: virtual lines attached there are not counted as display rows —
            -- measurably, nvim_win_text_height returns the unpadded number — so a
            -- region at the end of the file would be given room that does not exist.
            local ceiling = regions[i + 1] and (regions[i + 1].first - 1) or math.huge
            for buf, row in pairs({
                [wbuf] = math.min(r.last + context, ceiling, math.max(1, wcount - 1)) - 1,
                [bbuf] = math.min((r.base_last or r.last) + context, math.max(1, bcount - 1)) - 1,
            }) do
                if row >= 0 then
                    pcall(vim.api.nvim_buf_set_extmark, buf, PAD_NS, row, 0, { virt_lines = virt })
                    if not seen[buf] then
                        seen[buf] = true
                        table.insert(touched, buf)
                    end
                end
            end
        end
    end
    session.explain_padded = touched
    return true
end

--- One block per region: its lines and their highlights, with no position yet.
---
--- Deliberately one per region even where the agent grouped several: the group's
--- text is stated once, on the first of them, and the others point back at it. A
--- block per *group* would put the blocks out of file order the moment a group
--- straddled an ungrouped region.
local function build_blocks(session, by_region, width)
    local text_width = math.max(20, width - 4)
    local blocks = {}

    for i, r in ipairs(session.explain_regions or {}) do
        local lines, marks = {}, {}
        local function emit(line, hl, col, end_col)
            table.insert(lines, line)
            if hl then
                table.insert(marks, { line = #lines - 1, col = col or 0, end_col = end_col or #line, hl = hl })
            end
        end

        local head = string.format("  ▌ %s", span_label(r.first, r.last, r.added))
        local counts = string.format("   +%d −%d", r.added, r.removed)
        table.insert(lines, head .. counts)
        local row = #lines - 1
        table.insert(marks, { line = row, col = 0, end_col = #head, hl = "LgtmExplainHead" })
        local plus_at = #head + 3
        local plus_len = #string.format("+%d", r.added)
        table.insert(marks, { line = row, col = plus_at, end_col = plus_at + plus_len, hl = "LgtmExplainAdd" })
        table.insert(marks, {
            line = row,
            col = plus_at + plus_len + 1,
            end_col = #head + #counts,
            hl = "LgtmExplainDel",
        })

        -- A region may carry several readings — a file shared between chapters
        -- is explained by each — and they are stacked, a blank line apart.
        local items = by_region and by_region[i] or nil
        if not items or #items == 0 then
            emit("    …", "LgtmExplainMeta", 0, 5)
        else
            for k, e in ipairs(items) do
                if k > 1 then
                    table.insert(lines, "")
                end
                if not e.lead then
                    local lead = session.explain_regions[e.group[1]]
                    emit(
                        "    ↑ one change with " .. span_label(lead.first, lead.last, lead.added),
                        "LgtmExplainMeta"
                    )
                else
                    if e.title ~= "" then
                        for _, l in ipairs(markdown.wrap(e.title, text_width, "  ")) do
                            emit(l, "LgtmExplainTitle")
                        end
                    end
                    -- Two spaces of lead on every body line: markdown.format takes a
                    -- line's own indent as the indent for its wrapped continuations,
                    -- so this is how a bullet's second line lands under its text.
                    local indented = {}
                    for _, l in ipairs(vim.split(e.body, "\n", { plain = true })) do
                        table.insert(indented, "  " .. l)
                    end
                    local body_lines, body_marks = markdown.format(table.concat(indented, "\n"), text_width)
                    local offset = #lines
                    vim.list_extend(lines, body_lines)
                    for _, m in ipairs(body_marks) do
                        table.insert(marks, {
                            line = m.line + offset,
                            col = m.col,
                            end_col = m.end_col,
                            hl = m.hl,
                            eol = m.eol,
                        })
                    end
                end
            end
        end

        blocks[i] = { lines = lines, marks = marks }
    end
    return blocks
end

--- Lay the blocks out on a canvas indexed by the working pane's display rows, so
--- canvas line N is screen row N of the diff and every block starts level with its
--- own region.
---
--- Where a block is taller than the rows between its region and the next, it reports
--- the shortfall rather than overlapping: the caller pads the code panes to open the
--- gap and lays out again. That is the only reason padding exists.
-- Severity icons for review findings, in the theme's own diagnostic colours.
-- The role's colour carries WHO said it (the legend is the key); the icon
-- carries HOW MUCH it matters.
-- Byte escapes rather than literal glyphs: nerd-font codepoints sit in the
-- private-use area and do not survive every editor and diff tool. U+F057 is
-- the circled cross, U+F071 the warning triangle, U+F05A the info circle.
local SEVERITIES = {
    risk = { icon = "\239\129\151", hl = "DiagnosticError" },
    warn = { icon = "\239\129\177", hl = "DiagnosticWarn" },
    info = { icon = "\239\129\154", hl = "DiagnosticInfo" },
}
local SEVERITY_ALIAS = {
    error = "risk",
    critical = "risk",
    high = "risk",
    warning = "warn",
    medium = "warn",
    low = "info",
    note = "info",
    hint = "info",
    suggestion = "info",
}

local function severity_of(item)
    local s = type(item.severity) == "string" and item.severity:lower() or "info"
    return SEVERITIES[s] or SEVERITIES[SEVERITY_ALIAS[s] or "info"]
end

--- One block per region for the review column. Unlike the explain column, a
--- region nobody found fault with renders nothing at all: a silent reviewer
--- should not fill the pane with dots. Each finding is a severity icon plus
--- its title, then its body — no role prefix, because the role's colour IS
--- the byline — with markdown's inline marks layered after the role tint so
--- code chips still read as chips.
--- @param by_region table region index -> list of { role, severity, title,
---        body, group, lead }
local function build_review_blocks(session, by_region, width)
    local text_width = math.max(20, width - 4)
    local blocks = {}
    for i, r in ipairs(session.explain_regions or {}) do
        local lines, marks = {}, {}
        local items = by_region and by_region[i] or nil
        if items and #items > 0 then
            local head = string.format("  ▌ %s", span_label(r.first, r.last, r.added))
            table.insert(lines, head)
            table.insert(marks, { line = 0, col = 0, end_col = #head, hl = "LgtmExplainHead" })
            for k, e in ipairs(items) do
                if k > 1 then
                    table.insert(lines, "")
                end
                local group = reviewers.hl_group(e.role.key)
                if not e.lead then
                    local lead = session.explain_regions[e.group[1]]
                    local l = "    ↑ one finding with " .. span_label(lead.first, lead.last, lead.added)
                    table.insert(lines, l)
                    -- Role colour, not the meta grey: the pointer still needs
                    -- its byline.
                    table.insert(marks, { line = #lines - 1, col = 0, end_col = #l, hl = group })
                else
                    local sev = severity_of(e)
                    local heading = sev.icon .. " " .. (e.title ~= "" and e.title or "(untitled finding)")
                    for li, l in ipairs(markdown.wrap(heading, text_width, "  ")) do
                        table.insert(lines, l)
                        local row = #lines - 1
                        if li == 1 then
                            -- The icon in its severity colour, the title in the
                            -- role's. The wrap indents by two spaces.
                            table.insert(marks, { line = row, col = 2, end_col = 2 + #sev.icon, hl = sev.hl })
                            table.insert(marks, { line = row, col = 2 + #sev.icon, end_col = #l, hl = group })
                        else
                            table.insert(marks, { line = row, col = 0, end_col = #l, hl = group })
                        end
                    end
                    local indented = {}
                    for _, bl in ipairs(vim.split(e.body, "\n", { plain = true })) do
                        table.insert(indented, "    " .. bl)
                    end
                    local body_lines, body_marks = markdown.format(table.concat(indented, "\n"), text_width)
                    local offset = #lines
                    for bi, bl in ipairs(body_lines) do
                        table.insert(lines, bl)
                        -- The role tint first; the inline marks below layer on
                        -- top of it, since later extmarks of equal priority win.
                        table.insert(marks, { line = offset + bi - 1, col = 0, end_col = #bl, hl = group })
                    end
                    for _, m in ipairs(body_marks) do
                        table.insert(marks, {
                            line = m.line + offset,
                            col = m.col,
                            end_col = m.end_col,
                            hl = m.hl,
                            eol = m.eol,
                        })
                    end
                end
            end
        end
        blocks[i] = { lines = lines, marks = marks }
    end
    return blocks
end

--- @return table lines, table marks, table positions, table deficits
local function place_blocks(session, blocks)
    local win = session.working_win
    local regions = session.explain_regions or {}
    local lines, marks, positions, deficits = {}, {}, {}, {}

    for i, block in ipairs(blocks) do
        local target = rows_above(win, regions[i].first)
        if #lines > target then
            -- The previous block has run into this one's row. Ask for the difference
            -- below the previous region and lay out again.
            deficits[i - 1] = (deficits[i - 1] or 0) + (#lines - target)
        else
            for _ = #lines + 1, target do
                table.insert(lines, "")
            end
        end
        positions[i] = { line = #lines, count = #block.lines }
        local offset = #lines
        vim.list_extend(lines, block.lines)
        for _, m in ipairs(block.marks) do
            table.insert(marks, {
                line = m.line + offset,
                col = m.col,
                end_col = m.end_col,
                hl = m.hl,
                eol = m.eol,
            })
        end
    end

    -- Out to the full height of the diff, so the pane can be scrolled to the end of
    -- the file rather than stopping at the last explanation.
    for _ = #lines + 1, total_rows(win) do
        table.insert(lines, "")
    end
    return lines, marks, positions, deficits
end

--- The review findings for one file, arranged per region with each comment
--- carrying its role. Roles are walked in their fixed order, so two roles'
--- findings on one region always stack the same way.
local function review_by_region(session, entry)
    local by_role = (session.review_store or {})[entry.path]
    if not by_role then
        return {}
    end
    local out = {}
    for _, role in ipairs(reviewers.roles) do
        local comments = by_role[role.key]
        if comments and #comments > 0 then
            local mapped = ai.map_to_regions(comments, session.explain_regions)
            for i, list in pairs(mapped) do
                out[i] = out[i] or {}
                for _, item in ipairs(list) do
                    item.role = role
                    table.insert(out[i], item)
                end
            end
        end
    end
    return out
end

--- Lay out every open column against the same rows: place each column's
--- blocks, take the per-region MAXIMUM of their shortfalls, pad once, place
--- again. The columns share the padding namespace, so letting them pad
--- independently would have each clearing the other's rows.
---
--- Two passes is enough: the first discovers every shortfall, the padding
--- opens exactly those gaps, and the second sees the rows it asked for. A
--- third is allowed only because padding is clamped near the end of the file
--- and can come up short there.
--- @param explain_map table|nil region map for the explain column, or nil to
---        leave that column's buffer untouched (it may be showing a status)
local function render_columns(session, explain_map, review_map)
    local cols = {}
    if M.is_open(session) and explain_map then
        cols.explain = build_blocks(session, explain_map, vim.api.nvim_win_get_width(session.explain_win))
    end
    if M.review_open(session) and review_map then
        cols.review = build_review_blocks(session, review_map, vim.api.nvim_win_get_width(session.review_win))
    end
    if vim.tbl_isempty(cols) then
        return
    end

    clear_padding(session)
    local placed = {}
    for _ = 1, 3 do
        placed = {}
        local merged = {}
        for name, blocks in pairs(cols) do
            local lines, marks, positions, deficits = place_blocks(session, blocks)
            placed[name] = { lines = lines, marks = marks, positions = positions }
            for i, d in pairs(deficits) do
                merged[i] = math.max(merged[i] or 0, d)
            end
        end
        if vim.tbl_isempty(merged) or not apply_padding(session, merged) then
            break
        end
    end

    if placed.explain then
        session.explain_blocks = placed.explain.positions
        markdown.apply(session.explain_buf, placed.explain.lines, placed.explain.marks)
    end
    if placed.review then
        session.review_blocks = placed.review.positions
        markdown.apply(session.review_buf, placed.review.lines, placed.review.marks)
    end
    session.explain_sig = layout_signature(session)
end

--- Render whatever the current file has, into every open column.
local function render_current(session)
    local entry = session.entries[session.index]
    if not entry then
        return
    end
    local explain_map
    local data = (session.explain_store or {})[entry.path]
    if M.is_open(session) and data then
        explain_map = ai.map_to_regions(data.explanations, session.explain_regions)
    end
    local review_map
    if M.review_open(session) then
        review_map = review_by_region(session, entry)
    end
    render_columns(session, explain_map, review_map)
end


local function render_status(session, headline, detail)
    if not (session.explain_buf and vim.api.nvim_buf_is_valid(session.explain_buf)) then
        return
    end
    local width = vim.api.nvim_win_get_width(session.explain_win or 0)
    local lines, marks = { "", "  " .. headline }, {}
    table.insert(marks, { line = 1, col = 0, end_col = #lines[2], hl = "LgtmExplainTitle" })
    for _, l in ipairs(markdown.wrap(detail or "", math.max(20, width - 4), "  ")) do
        table.insert(lines, l)
        table.insert(marks, { line = #lines - 1, col = 0, end_col = #l, hl = "LgtmExplainMeta" })
    end
    session.explain_blocks = {}
    session.explain_sig, session.explain_layout_width = nil, nil
    clear_padding(session)
    markdown.apply(session.explain_buf, lines, marks)
end

local function set_winbar(session, entry, note)
    if not M.is_open(session) then
        return
    end
    local name = entry and entry.path or ""
    note = note or ""
    -- Budget the path against the pane, the same way layout.bar does. Neovim
    -- truncates an over-long winbar from the LEFT, so without this a long path
    -- pushes the sparkle and the EXPLAIN label off the edge and the bar reads
    -- as a bare filename. Elide the path from its own left instead: the
    -- deepest directories and the filename are the informative end.
    local w = vim.fn.strdisplaywidth
    local avail = vim.api.nvim_win_get_width(session.explain_win)
    local fixed = w(" 󰙴 EXPLAIN  ") + (note ~= "" and (w(note) + 3) or 1)
    local room = math.max(8, avail - fixed)
    if w(name) > room then
        name = "…" .. name:sub(-(room - 1))
    end
    local text = table.concat({
        -- The sparkle, then the label in the magenta wash: this pane's content
        -- is generated, and the same mark sits on the chapter picker.
        "%#LgtmWinbarAIIcon# 󰙴 " .. require("lgtm.layout").ai_label("EXPLAIN") .. "  %#LgtmWinbarDim#",
        (name:gsub("%%", "%%%%")),
        "  %=",
        (note:gsub("%%", "%%%%")),
        " ",
    })
    vim.wo[session.explain_win].winbar = text
end

-- ---------------------------------------------------------------------------
-- Alignment
-- ---------------------------------------------------------------------------

--- Interpolate a working-file line onto an explanation line, between the two
--- anchors it falls between.
--- Put the explanation pane at the same screen row as the working pane.
---
--- Measured, not calculated. The obvious arithmetic — count the display rows above
--- the top line and put that canvas line at the top — is wrong in a way that took a
--- probe to see: `nvim_win_text_height` does not count virtual lines attached to the
--- last line of the range it is given, and `winsaveview().topfill` *does* count those
--- same rows when they are showing above the top line. Subtracting one from the other
--- therefore removes the padding twice, and the pane sits exactly `pad` rows out.
---
--- So instead: take a region whose first line is on screen, ask where that line
--- actually is with `screenpos`, and put its block on the same row. Region lines are
--- the reliable reference — never inside a fold, and their canvas position was
--- computed from the same measurement.
function M.sync(session)
    if syncing or not any_open(session) then
        return
    end
    local win = session.working_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end

    local view = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
    end)
    -- The pane's first drawn row, which is NOT where the top line's text is: diff
    -- filler and padding above it are drawn first, and `topfill` counts them. Getting
    -- this wrong is what put the pane exactly `topfill` rows out. The explanation pane
    -- has neither, so its first drawn row is simply its top line.
    local top_row = vim.fn.screenpos(win, view.topline, 1).row - (view.topfill or 0)

    -- Both canvases are laid out against the same rows, so one target serves
    -- them both; the anchor comes from whichever column is open.
    local anchor = M.is_open(session) and session.explain_blocks or session.review_blocks
    local target
    if top_row > 0 then
        for i, r in ipairs(session.explain_regions or {}) do
            local block = (anchor or {})[i]
            local row = block and vim.fn.screenpos(win, r.first, 1).row or 0
            if row > 0 then
                -- The region sits (row - top_row) rows below the top line's own row;
                -- put its block the same distance below the canvas line at the top.
                target = block.line + 1 - (row - top_row)
                break
            end
        end
    end
    if not target then
        -- Nothing to anchor on: no region on screen, or the top line is not rendered.
        -- Fall back to counting, which is right everywhere the padding is not.
        target = rows_above(win, view.topline) + 1
    end

    local function set_top(pane_win, pane_buf)
        local t = math.max(1, math.min(target, vim.api.nvim_buf_line_count(pane_buf)))
        pcall(vim.api.nvim_win_call, pane_win, function()
            local v = vim.fn.winsaveview()
            if v.topline ~= t then
                v.topline = t
                v.lnum = math.max(v.lnum, t)
                vim.fn.winrestview(v)
            end
        end)
    end

    syncing = true
    if M.is_open(session) then
        set_top(session.explain_win, session.explain_buf)
    end
    if M.review_open(session) then
        set_top(session.review_win, session.review_buf)
    end
    syncing = false
end

--- Re-lay-out the pane when something it was measured against has moved: the pane
--- was resized, so every block re-wraps to a different height, or a fold was opened
--- or closed, so the regions sit on different screen rows.
---
--- Never regenerates — it works from what is already in the store, so it costs no
--- model call. Called from the session's cursor and scroll autocmds and guarded by
--- the signature, so it is a no-op on almost every one of them.
function M.relayout_if_stale(session)
    if not any_open(session) then
        return
    end
    local entry = session.entries[session.index]
    if not entry then
        return
    end
    local has_explain = M.is_open(session) and (session.explain_store or {})[entry.path] ~= nil
    local has_review = M.review_open(session) and next((session.review_store or {})[entry.path] or {}) ~= nil
    if not (has_explain or has_review) then
        -- Still waiting on the runs, or showing a status. Nothing laid out to redo.
        return
    end
    local sig = layout_signature(session)
    if sig == nil or sig == session.explain_sig then
        return
    end
    -- Stamped before the work, not after: laying out re-pads, which fires the scroll
    -- autocmd that called this, and the stamp is what stops that re-entering.
    session.explain_sig = sig

    render_current(session)
    M.sync(session)
end

-- ---------------------------------------------------------------------------
-- The runs
--
-- Phased. A fast guide run plans the chapters; then one run per chapter, in
-- parallel up to `max_parallel`, each given its chapter and its files' diffs
-- pasted into the prompt; then one final run for the files no chapter claimed,
-- once the chapters are done. Small prompts, chapter-aware comments, and the
-- chapters overlap in time instead of queueing behind one another.
-- ---------------------------------------------------------------------------

local schedule_runs, pump, launch, update_legend

local function stop_timer(session)
    if session.explain_timer then
        pcall(function()
            session.explain_timer:stop()
            session.explain_timer:close()
        end)
        session.explain_timer = nil
    end
end

--- Kill the running jobs and drop the queued specs that `pred(spec)` selects.
--- The explain and review columns have separate lifecycles, so closing one
--- must not take the other's runs down with it.
local function kill_jobs(session, pred)
    for key, run in pairs(session.explain_jobs or {}) do
        if pred(run.spec) then
            pcall(function()
                run.job:kill(15)
            end)
            session.explain_jobs[key] = nil
        end
    end
    local rest = {}
    for _, s in ipairs(session.explain_queue or {}) do
        if not pred(s) then
            table.insert(rest, s)
        end
    end
    session.explain_queue = rest
    if vim.tbl_isempty(session.explain_jobs or {}) and #rest == 0 then
        stop_timer(session)
    end
end

--- Stop every run and drop the whole queue. Called when the session closes,
--- not when the reviewer pages: the runs are doing work for every file, so
--- paging away from the one that started them is not a reason to throw the
--- rest away.
local function stop_run(session)
    kill_jobs(session, function()
        return true
    end)
    stop_timer(session)
end

M.stop_run = stop_run

local function running(session)
    local n = 0
    for _ in pairs(session.explain_jobs or {}) do
        n = n + 1
    end
    return n
end

--- Is a spec with this key already running or waiting for a slot?
local function scheduled(session, key)
    if (session.explain_jobs or {})[key] then
        return true
    end
    for _, s in ipairs(session.explain_queue or {}) do
        if s.key == key then
            return true
        end
    end
    return false
end

--- Review runs currently in flight or queued.
local function review_runs(session)
    local n = 0
    for _, run in pairs(session.explain_jobs or {}) do
        if run.spec and run.spec.kind == "review" then
            n = n + 1
        end
    end
    for _, s in ipairs(session.explain_queue or {}) do
        if s.kind == "review" then
            n = n + 1
        end
    end
    return n
end

local function set_review_winbar(session, note)
    if not M.review_open(session) then
        return
    end
    vim.wo[session.review_win].winbar = table.concat({
        -- A magnifying glass rather than the sparkle — a reviewer looks
        -- closely — in the ramp's lilac, the same colour as the R beside it.
        -- U+F002 as byte escapes; private-use glyphs do not survive every tool.
        "%#LgtmWinbarReviewIcon# \239\128\130 ",
        -- The review ramp: lilac into teal, against the magenta wash of the
        -- other AI headers.
        require("lgtm.layout").ai_label("REVIEW", "review"),
        "  %#LgtmWinbarDim#%=",
        (note or ""):gsub("%%", "%%%%"),
        " ",
    })
end

local function render_progress(session, entry)
    if not M.is_open(session) then
        return
    end
    local done, total = progress(session)
    local active = running(session)
    local secs = session.explain_started and math.floor((vim.uv.now() - session.explain_started) / 1000) or 0
    local note = active > 0
        and string.format("%d of %d files · %d run%s · %ds", done, total, active, active == 1 and "" or "s", secs)
        or string.format("%d of %d files", done, total)
    render_status(
        session,
        "generating…",
        note
            .. "\n\nThe change is explained a chapter at a time, in parallel, each agent"
            .. " with its chapter's diffs in hand. Files appear here as they finish —"
            .. " this one's chapter runs first."
    )
    set_winbar(session, entry, note)
end

local function entry_by_path(session)
    local map = {}
    for _, e in ipairs(all_entries(session)) do
        map[e.path] = e
    end
    return map
end

--- Launch one spec now: build its prompt and start its process.
--- spec = { key, kind = "guide"|"explain", chapter, paths, only, current,
---          after_all }
function launch(session, spec)
    local cfg = session.cfg.explain
    local dir = store_dir(session)
    vim.fn.mkdir(dir, "p")

    local ctx = {
        pr = session.pr,
        branch = session.branch,
        base_ref = session.base_ref,
        merge_base = session.merge_base,
        entries = all_entries(session),
        out_dir = dir,
    }

    local prompt, contract
    if spec.kind == "guide" then
        prompt, contract = ai.build_guide_prompt(ctx), ai.GUIDE_CONTRACT
    else
        local by_path = entry_by_path(session)
        local diffs = {}
        for _, p in ipairs(spec.paths or {}) do
            local e = by_path[p]
            if e then
                diffs[p] = git.file_diff(session.merge_base, e, session.root) or ""
            end
        end
        ctx.chapter = spec.chapter
        ctx.paths = spec.paths
        ctx.diffs = diffs
        ctx.current = spec.current
        ctx.only = spec.only
        ctx.budget = cfg.max_diff_bytes
        -- Each run writes under its own tag, so two runs covering a shared
        -- file cannot overwrite one another; the store merges by path.
        ctx.run_tag = spec.key:gsub("[^%w%-]", "-")
        if spec.kind == "review" then
            ctx.role = {
                key = spec.role.key,
                title = spec.role.title,
                preamble = reviewers.preamble(spec.role),
            }
            prompt, contract = ai.build_review_prompt(ctx), ai.REVIEW_CONTRACT
        else
            prompt, contract = ai.build_explain_prompt(ctx), ai.EXPLAIN_CONTRACT
        end
    end

    -- The clock measures the current batch, not the session: reset it whenever
    -- a run starts from idle, keep it while other runs are already in flight.
    if running(session) == 0 or not session.explain_started then
        session.explain_started = vim.uv.now()
    end
    -- The live token feed: ai.run schedules these onto the main loop.
    local tokens_seen = 0
    local on_usage = function(total)
        tokens_seen = total
        local run = (session.explain_jobs or {})[spec.key]
        if run then
            run.tokens = total
        end
    end
    local job = ai.run(prompt, contract, { repo = session.root, out = dir }, cfg, function(ok, err)
        -- Bank this run's tokens against its role before the job entry goes.
        if spec.kind == "review" and spec.role then
            session.review_tokens = session.review_tokens or {}
            session.review_tokens[spec.role.key] = (session.review_tokens[spec.role.key] or 0) + tokens_seen
        end
        if session.explain_jobs then
            session.explain_jobs[spec.key] = nil
        end
        if not any_open(session) then
            return
        end
        -- The results are files, so a failed run is not necessarily an empty
        -- one: whatever it wrote before dying is still there and still good.
        M.reload(session)
        if not ok then
            vim.notify(string.format("lgtm: the %s run ended early (%s)", spec.key, err), vim.log.levels.WARN)
            if spec.kind == "review" and spec.role then
                session.review_failed = session.review_failed or {}
                session.review_failed[spec.role.key] = true
            end
        end
        -- The guide unlocking the chapters is normally caught by the directory
        -- watcher the moment guide.json lands; this is the backstop.
        if spec.kind == "guide" and session.guide then
            schedule_runs(session)
        end
        pump(session)
        if M.review_open(session) then
            update_legend(session)
            if review_runs(session) == 0 then
                -- Repaint the idle note — "N findings" or "no findings" — so a
                -- silent review is distinguishable from one still running.
                M.refresh(session)
            end
        end
        if running(session) == 0 and #(session.explain_queue or {}) == 0 then
            stop_timer(session)
            -- Everything drained: the next batch starts its own clock.
            session.explain_started = nil
        end
    end, on_usage)

    if job then
        -- The spec rides along so the scheduler can see which paths are already
        -- being worked on — a file shared by two chapters must not be handed to
        -- both.
        session.explain_jobs[spec.key] = { job = job, spec = spec }
    end

    if not session.explain_timer and running(session) > 0 then
        local timer = vim.uv.new_timer()
        session.explain_timer = timer
        timer:start(1000, 1000, vim.schedule_wrap(function()
            if not (any_open(session) and running(session) > 0) then
                return
            end
            local e = session.entries[session.index]
            if e and not (session.explain_store or {})[e.path] then
                render_progress(session, e)
            end
            local active = review_runs(session)
            if active > 0 then
                local secs = session.explain_started
                        and math.floor((vim.uv.now() - session.explain_started) / 1000)
                    or 0
                set_review_winbar(
                    session,
                    string.format("%d reviewer%s · %ds", active, active == 1 and "" or "s", secs)
                )
                -- The legend rows carry per-role status, seconds included.
                update_legend(session)
            end
        end))
    end
end

--- Start queued specs while slots are free. The leftover run is held back until
--- it is the only thing left: its files are the ones no chapter claimed, and
--- "after the chapters" is part of its meaning.
function pump(session)
    if not any_open(session) then
        return
    end
    local cap = session.cfg.explain.max_parallel or 3
    local queue = session.explain_queue or {}
    local i = 1
    while i <= #queue and running(session) < cap do
        local spec = queue[i]
        if spec.after_all and (running(session) > 0 or #queue > 1) then
            i = i + 1
        else
            table.remove(queue, i)
            launch(session, spec)
        end
    end
end

--- Work out which runs the change still needs and queue them: the guide first,
--- then a run per chapter with unexplained files (the current file's chapter at
--- the front), then the leftovers.
function schedule_runs(session)
    if not M.is_open(session) then
        return
    end
    session.explain_jobs = session.explain_jobs or {}
    session.explain_queue = session.explain_queue or {}
    session.explain_store = session.explain_store or store.load(store_dir(session))

    if not session.guide then
        if not scheduled(session, "guide") then
            table.insert(session.explain_queue, { key = "guide", kind = "guide" })
        end
        pump(session)
        return
    end

    local by_path = entry_by_path(session)
    local current = session.entries[session.index]
    local chapters = session.guide.chapters or {}

    -- The chapter holding the open file goes first: its explanation is the one
    -- being waited on.
    local order = {}
    for i, ch in ipairs(chapters) do
        if current and vim.tbl_contains(ch.files or {}, current.path) then
            table.insert(order, 1, i)
        else
            table.insert(order, i)
        end
    end

    -- A file in more than one chapter is deliberately explained by EACH of its
    -- chapters: every run writes under its own run tag and the store merges the
    -- explanations by path, so the reviewer gets both readings side by side.
    local claimed = {}
    for _, i in ipairs(order) do
        local ch = chapters[i]
        local todo = {}
        for _, p in ipairs(ch.files or {}) do
            claimed[p] = true
            if by_path[p] and not session.explain_store[p] then
                table.insert(todo, p)
            end
        end
        local key = "chapter " .. i
        if #todo > 0 and not scheduled(session, key) then
            table.insert(session.explain_queue, {
                key = key,
                kind = "explain",
                chapter = ch,
                paths = todo,
                current = (current and vim.tbl_contains(todo, current.path)) and current.path or nil,
            })
        end
    end

    local rest = {}
    for _, e in ipairs(all_entries(session)) do
        if not claimed[e.path] and not session.explain_store[e.path] then
            table.insert(rest, e.path)
        end
    end
    if #rest > 0 and not scheduled(session, "leftover") then
        table.insert(session.explain_queue, {
            key = "leftover",
            kind = "explain",
            paths = rest,
            after_all = true,
            current = (current and vim.tbl_contains(rest, current.path)) and current.path or nil,
        })
    end

    pump(session)
end

--- Queue whatever the change still needs.
--- @param opts table|nil `only` regenerates just those paths, as its own small
---        run — displacing nothing, unlike the single-run design it replaces.
local function ensure_run(session, opts)
    opts = opts or {}
    local cfg = session.cfg.explain
    session.explain_jobs = session.explain_jobs or {}
    session.explain_queue = session.explain_queue or {}

    if opts.only then
        local key = "regenerate " .. table.concat(opts.only, " ")
        if scheduled(session, key) then
            return
        end
        local chapter
        for _, ch in ipairs(session.guide and session.guide.chapters or {}) do
            if vim.tbl_contains(ch.files or {}, opts.only[1]) then
                chapter = ch
                break
            end
        end
        -- Front of the queue: a regeneration was asked for by hand.
        table.insert(session.explain_queue, 1, {
            key = key,
            kind = "explain",
            paths = opts.only,
            only = true,
            chapter = chapter,
            current = opts.only[1],
        })
        pump(session)
        return
    end

    if #outstanding(session) == 0 then
        return
    end

    -- `session.pr` is nil while the gh lookup is in flight and false once it has
    -- answered that there is no PR. Worth a short wait for the difference: the
    -- description is the statement of intent the guide is planned against, and
    -- every later run inherits its chapters.
    if session.guide == nil and session.pr == nil and (session.explain_pr_waited or 0) < (cfg.pr_wait or 3000) then
        session.explain_pr_waited = (session.explain_pr_waited or 0) + 300
        vim.defer_fn(function()
            if M.is_open(session) then
                ensure_run(session, opts)
            end
        end, 300)
        return
    end

    schedule_runs(session)
end

--- Re-read the store and show the current file if its explanation has arrived.
--- Called from the directory watcher, so this is what makes a single whole-PR run
--- appear one file at a time.
function M.reload(session)
    if not any_open(session) then
        return
    end
    local current_path = (session.entries[session.index] or {}).path
    local before = (session.explain_store or {})[current_path]
    local reviews_before = vim.json.encode((session.review_store or {})[current_path] or {})
    local dots_before = M.review_signature(session)
    session.explain_store = store.load(store_dir(session))
    session.review_store = store.load_reviews(store_dir(session))
    if session.on_reviews and M.review_signature(session) ~= dots_before then
        session.on_reviews()
    end
    -- The guide arrives through the same watcher as the explanations — it is the
    -- run's first write. Compared as JSON so a refinement at the end of the run
    -- also lands.
    local guide = store.load_guide(store_dir(session))
    if guide then
        local encoded = vim.json.encode(guide)
        if encoded ~= session.guide_json then
            session.guide, session.guide_json = guide, encoded
            if session.on_guide then
                session.on_guide()
            end
            -- The guide unlocks the chapter runs the moment it lands — this is
            -- what makes the phases overlap instead of waiting for the guide
            -- run's process to exit.
            schedule_runs(session)
        end
    end
    local entry = session.entries[session.index]
    if not entry then
        return
    end
    local now = session.explain_store[entry.path]
    local reviews_now = vim.json.encode(session.review_store[entry.path] or {})
    if (now and not before) or reviews_now ~= reviews_before then
        M.refresh(session)
    elseif not now and running(session) > 0 then
        render_progress(session, entry)
    end
end

--- Show the current file: from the store if it is there, otherwise a progress line
--- while the run gets to it.
--- @param opts table|nil `force` regenerates this one file
function M.refresh(session, opts)
    if not any_open(session) then
        return
    end
    opts = opts or {}
    local entry = session.entries[session.index]
    if not entry then
        return
    end

    -- No hunks means the pane below is not a diff: binary, deleted, too large.
    -- There is nothing to key an explanation or a finding to.
    if not session.hunks or #session.hunks == 0 then
        session.explain_regions = {}
        if M.is_open(session) then
            render_status(
                session,
                "no diff to explain",
                "This file is shown without a diff — binary, deleted, or over `max_file_size`."
            )
            set_winbar(session, entry, "")
        end
        if M.review_open(session) then
            session.review_blocks = {}
            markdown.apply(session.review_buf, { "", "  no diff to review" }, {
                { line = 1, col = 0, end_col = 20, hl = "LgtmExplainMeta" },
            })
        end
        return
    end

    session.explain_regions = build_regions(
        session.hunks,
        diff_context(),
        vim.api.nvim_win_get_height(session.working_win)
    )
    session.explain_store = session.explain_store or store.load(store_dir(session))
    session.review_store = session.review_store or store.load_reviews(store_dir(session))

    local data = not opts.force and session.explain_store[entry.path] or nil
    if M.is_open(session) then
        if data then
            local dir = store_dir(session)
            -- An explanation is of the file as it was when it was written. Edit the
            -- file in the working pane and it may no longer describe what is there.
            local sha = state.content_hash(vim.fs.joinpath(session.root, entry.path))
            local recorded = store.shas(dir)[entry.path]
            local stale = false
            if recorded == nil then
                store.record_sha(dir, entry.path, sha)
            elseif sha and recorded ~= sha then
                stale = true
            end
            set_winbar(session, entry, stale and "stale — :LgtmExplain!" or "")
        else
            if opts.force then
                -- Make the arrival of the replacement observable to the watcher, and
                -- stop the old text being shown as though it were the new.
                store.delete_path(store_dir(session), entry.path)
                session.explain_store[entry.path] = nil
                store.record_sha(store_dir(session), entry.path, nil)
            end
            render_progress(session, entry)
            ensure_run(session, opts.force and { only = { entry.path } } or nil)
        end
    end

    -- One canvas pass covers whichever columns have content. The explain
    -- column is skipped inside when it has no data — the progress text above
    -- stays on screen; the review canvas keeps every file current, including
    -- the "no findings" emptiness, which renders as blank rows.
    render_current(session)
    if M.review_open(session) and review_runs(session) == 0 then
        -- A finished review with nothing to say looks exactly like one that
        -- has not landed yet — both are a blank pane — so the winbar says
        -- which it is.
        local count = 0
        for _, comments in pairs((session.review_store or {})[entry.path] or {}) do
            count = count + #comments
        end
        set_review_winbar(
            session,
            count > 0 and string.format("%d finding%s", count, count == 1 and "" or "s") or "no findings"
        )
    end
    M.sync(session)
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local function target_width(session)
    local cfg = session.cfg
    local want = cfg.explain.width or 76
    -- What is left once the three existing panes have had their minimum. The
    -- working pane is the one being edited, so it is the last thing to give up
    -- columns.
    local room = vim.o.columns - (cfg.tree_width or 60) - (cfg.base_width or 60) - 40
    return math.max(24, math.min(want, room)), room
end

--- One directory watcher serves both columns; whichever opens first creates
--- it. Each Write an agent makes fires it, which is what turns whole runs into
--- results that arrive a file at a time.
local function ensure_watch(session)
    if session.explain_watch then
        return
    end
    session.explain_watch = store.watch(store_dir(session), function()
        M.reload(session)
    end)
end

function M.open(session)
    if M.is_open(session) then
        return true
    end
    if not (session.working_win and vim.api.nvim_win_is_valid(session.working_win)) then
        return false
    end

    local width, room = target_width(session)
    if room < 24 then
        vim.notify(
            "lgtm: not enough width for the explanation pane — narrow tree_width or base_width",
            vim.log.levels.WARN
        )
        return false
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, "lgtm://explain")
    vim.bo[buf].filetype = "lgtm-explain"

    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(session.working_win)
    vim.cmd("noautocmd rightbelow vsplit")
    local win = vim.api.nvim_get_current_win()

    -- A split inherits the window options of the window it came from, and the
    -- working pane is in diff mode. Left alone, the new window joins the diff
    -- group as a third participant and fills both real panes with filler lines.
    vim.wo[win].diff = false
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldcolumn = "0"
    vim.api.nvim_win_set_buf(win, buf)

    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].colorcolumn = ""
    vim.wo[win].cursorline = false
    vim.wo[win].winfixwidth = true
    -- No soft wrapping, and this one is load-bearing rather than cosmetic: the
    -- alignment holds because canvas line N is screen row N, and a line that wrapped
    -- would take two rows and put everything below it out by one. The prose is
    -- already hard-wrapped to the pane by markdown.format, so the only thing this
    -- clips is a token too long to break — an unspaced URL — which is worth one
    -- truncated line against every block being level with its region.
    vim.wo[win].wrap = false
    vim.api.nvim_win_set_width(win, width)

    vim.api.nvim_set_current_win(prev)

    -- Extmarks are buffer-scoped, so without this the padding would also show in
    -- any other window on the same file. Experimental API, hence the pcall: if it
    -- is not there the padding still works, it is just not confined to the panes.
    pcall(vim.api.nvim__ns_set, PAD_NS, { wins = { session.base_win, session.working_win } })

    session.explain_win = win
    session.explain_buf = buf

    ensure_watch(session)
    return true
end

--- Close the explain column. Review runs and the review pane are untouched —
--- the two columns share machinery, not a lifecycle.
function M.close(session)
    kill_jobs(session, function(spec)
        return not (spec and spec.kind == "review")
    end)
    if not M.review_open(session) then
        store.unwatch(session.explain_watch)
        session.explain_watch = nil
    end
    clear_padding(session)
    if session.explain_win and vim.api.nvim_win_is_valid(session.explain_win) then
        pcall(vim.api.nvim_win_close, session.explain_win, true)
    end
    if session.explain_buf and vim.api.nvim_buf_is_valid(session.explain_buf) then
        pcall(vim.api.nvim_buf_delete, session.explain_buf, { force = true })
    end
    session.explain_win, session.explain_buf = nil, nil
    session.explain_blocks = nil
    session.explain_sig, session.explain_layout_width = nil, nil
    if not M.review_open(session) then
        session.explain_regions = nil
    else
        -- The review column keeps the regions and the canvas; re-place it now
        -- that the explain column's padding demands are gone.
        render_current(session)
        M.sync(session)
    end
end

-- ---------------------------------------------------------------------------
-- The review column
-- ---------------------------------------------------------------------------

local function fmt_tokens(n)
    if n >= 1000 then
        return string.format("%.1fk tok", n / 1000)
    end
    return n .. " tok"
end

--- One role's place in the machinery, as a short status for its legend row:
--- queued, running (seconds and live tokens), failed, or its finding count
--- with what it cost.
local function role_status(session, key)
    for _, run in pairs(session.explain_jobs or {}) do
        if run.spec and run.spec.kind == "review" and run.spec.role and run.spec.role.key == key then
            local secs = session.explain_started and math.floor((vim.uv.now() - session.explain_started) / 1000)
                or 0
            local note = string.format("running · %ds", secs)
            if (run.tokens or 0) > 0 then
                note = note .. " · " .. fmt_tokens(run.tokens)
            end
            return note, "Comment"
        end
    end
    for _, s in ipairs(session.explain_queue or {}) do
        if s.kind == "review" and s.role and s.role.key == key then
            return "queued", "Comment"
        end
    end
    if (session.review_failed or {})[key] then
        return "failed", "WarningMsg"
    end
    local n = 0
    for _, by_role in pairs(session.review_store or {}) do
        local comments = by_role[key]
        if comments then
            n = n + #comments
        end
    end
    local note = n == 0 and "no findings" or string.format("%d finding%s", n, n == 1 and "" or "s")
    local spent = (session.review_tokens or {})[key] or 0
    if spent > 0 then
        note = note .. " · " .. fmt_tokens(spent)
    end
    return note, "Comment"
end

--- Redraw the legend: one row per launched role, dot and name in the role's
--- colour, its live status alongside. The legend is both the colour key and
--- the panel's progress board.
function update_legend(session)
    if not (session.legend_buf and vim.api.nvim_buf_is_valid(session.legend_buf)) then
        return
    end
    local ns = vim.api.nvim_create_namespace("lgtm_legend")
    local roles = session.review_roles or {}
    local lines, statuses = {}, {}
    if #roles == 0 then
        lines = { "  no reviewers yet" }
    else
        local widest = 0
        for _, key in ipairs(roles) do
            local role = reviewers.get(key)
            widest = math.max(widest, #(role and role.title or key))
        end
        for _, key in ipairs(roles) do
            local role = reviewers.get(key)
            local title = role and role.title or key
            local status, status_hl = role_status(session, key)
            local name = "  ● " .. title .. string.rep(" ", widest - #title)
            table.insert(lines, name .. "  " .. status)
            table.insert(statuses, { name_end = #name, status_hl = status_hl })
        end
    end
    vim.bo[session.legend_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.legend_buf, 0, -1, false, lines)
    vim.bo[session.legend_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(session.legend_buf, ns, 0, -1)
    for i, key in ipairs(roles) do
        pcall(vim.api.nvim_buf_set_extmark, session.legend_buf, ns, i - 1, 0, {
            end_col = statuses[i].name_end,
            hl_group = reviewers.hl_group(key),
        })
        pcall(vim.api.nvim_buf_set_extmark, session.legend_buf, ns, i - 1, statuses[i].name_end, {
            end_col = #lines[i],
            hl_group = statuses[i].status_hl,
        })
    end
    if session.legend_win and vim.api.nvim_win_is_valid(session.legend_win) then
        pcall(vim.api.nvim_win_set_height, session.legend_win, math.max(1, #lines))
    end
end

--- Open the review column (plus its legend), to the right of the explain
--- column when that is open, else right of the working pane.
function M.open_review(session)
    if M.review_open(session) then
        return true
    end
    local parent = M.is_open(session) and session.explain_win or session.working_win
    if not (parent and vim.api.nvim_win_is_valid(parent)) then
        return false
    end

    local want = (session.cfg.review and session.cfg.review.width) or 56
    local width = math.max(24, math.min(want, vim.o.columns - 80))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, "lgtm://review")
    vim.bo[buf].filetype = "lgtm-review"

    local prev = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(parent)
    vim.cmd("noautocmd rightbelow vsplit")
    local win = vim.api.nvim_get_current_win()
    -- Same discipline as the explain pane: never join the diff group, and no
    -- soft wrap — the row-for-row alignment depends on it.
    vim.wo[win].diff = false
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldcolumn = "0"
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].colorcolumn = ""
    vim.wo[win].cursorline = false
    vim.wo[win].winfixwidth = true
    vim.wo[win].wrap = false
    vim.api.nvim_win_set_width(win, width)

    -- The legend, at the bottom of the review column.
    vim.cmd("noautocmd belowright split")
    local legend_win = vim.api.nvim_get_current_win()
    local legend_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[legend_buf].buftype = "nofile"
    vim.bo[legend_buf].bufhidden = "hide"
    vim.bo[legend_buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, legend_buf, "lgtm://legend")
    vim.api.nvim_win_set_buf(legend_win, legend_buf)
    vim.wo[legend_win].number = false
    vim.wo[legend_win].relativenumber = false
    vim.wo[legend_win].signcolumn = "no"
    vim.wo[legend_win].colorcolumn = ""
    vim.wo[legend_win].cursorline = false
    vim.wo[legend_win].winfixwidth = true
    vim.wo[legend_win].winfixheight = true
    vim.wo[legend_win].wrap = false
    vim.api.nvim_win_set_height(legend_win, 1)

    vim.api.nvim_set_current_win(prev)

    session.review_win, session.review_buf = win, buf
    session.legend_win, session.legend_buf = legend_win, legend_buf
    set_review_winbar(session, "")
    update_legend(session)
    ensure_watch(session)
    return true
end

--- Ask one role to review the current chapter (or the whole change when no
--- chapter is selected). Each role is its own run through the same queue as
--- the explain phases, so several roles review in parallel under
--- `max_parallel`.
function M.start_review(session, key)
    local role = reviewers.get(key)
    if not role then
        vim.notify("lgtm: no reviewer called " .. tostring(key), vim.log.levels.WARN)
        return false
    end
    if not M.open_review(session) then
        return false
    end
    session.explain_jobs = session.explain_jobs or {}
    session.explain_queue = session.explain_queue or {}
    session.review_store = session.review_store or store.load_reviews(store_dir(session))
    session.review_roles = session.review_roles or {}
    if not vim.tbl_contains(session.review_roles, key) then
        table.insert(session.review_roles, key)
    end
    update_legend(session)

    -- Scope: the selected chapter's files, or everything on show.
    local chapter = session.chapter and session.guide and session.guide.chapters[session.chapter] or nil
    local by_path = entry_by_path(session)
    local paths = {}
    if chapter then
        for _, p in ipairs(chapter.files or {}) do
            if by_path[p] then
                table.insert(paths, p)
            end
        end
    else
        for _, e in ipairs(session.entries) do
            table.insert(paths, e.path)
        end
    end
    local todo = {}
    for _, p in ipairs(paths) do
        if not ((session.review_store[p] or {})[key]) then
            table.insert(todo, p)
        end
    end
    if #todo == 0 then
        vim.notify("lgtm: " .. role.title .. " has already covered these files", vim.log.levels.INFO)
        return true
    end

    local spec_key = "review-" .. key .. " " .. (session.chapter and ("chapter " .. session.chapter) or "all")
    if scheduled(session, spec_key) then
        vim.notify("lgtm: " .. role.title .. " is already running here", vim.log.levels.INFO)
        return true
    end
    local current = session.entries[session.index]
    table.insert(session.explain_queue, {
        key = spec_key,
        kind = "review",
        role = role,
        chapter = chapter,
        paths = todo,
        current = (current and vim.tbl_contains(todo, current.path)) and current.path or nil,
    })
    pump(session)
    M.refresh(session)
    return true
end

--- Close the review column and its legend, killing only review runs. The
--- explain column and its runs are untouched.
function M.close_review(session)
    kill_jobs(session, function(spec)
        return spec and spec.kind == "review"
    end)
    if not M.is_open(session) then
        store.unwatch(session.explain_watch)
        session.explain_watch = nil
    end
    for _, w in ipairs({ session.legend_win, session.review_win }) do
        if w and vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end
    for _, b in ipairs({ session.legend_buf, session.review_buf }) do
        if b and vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    session.review_win, session.review_buf = nil, nil
    session.legend_win, session.legend_buf = nil, nil
    session.review_blocks = nil
    session.review_roles = nil
    if M.is_open(session) then
        -- Re-place the survivor without the review column's padding demands.
        render_current(session)
        M.sync(session)
    else
        clear_padding(session)
        session.explain_regions = nil
        session.explain_sig = nil
    end
end

return M
