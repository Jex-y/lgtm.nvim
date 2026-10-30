-- Ask a question about one part of the diff.
--
-- The reviewer selects lines in the working pane (or stands on a hunk) and
-- types a question. The agent is handed the pull request, the file's diff, the
-- selected lines, whatever the explain run wrote about that change, and any
-- findings the review panel raised on it — so the question can be about the
-- code, about the explanation, or about a reviewer's comment, and the answer
-- is judged against all three.
--
-- The answer opens in a float. Each question starts a thread: a follow-up from
-- inside the float resumes the same agent session, so it remembers the hunk
-- and what it already said. Every ask is a fresh thread; the float shows one
-- thread at a time.

local ai = require("lgtm.ai")
local explain = require("lgtm.explain")
local git = require("lgtm.git")
local layout = require("lgtm.layout")
local markdown = require("lgtm.markdown")
local reviewers = require("lgtm.reviewers")

local M = {}

local NS = vim.api.nvim_create_namespace("lgtm_ask")
local SLACK = 3

local function notify(msg, level)
    vim.notify("lgtm: " .. msg, level or vim.log.levels.INFO)
end

function M.is_open(session)
    local a = session and session.ask
    return a ~= nil and a.win ~= nil and vim.api.nvim_win_is_valid(a.win)
end

-- ---------------------------------------------------------------------------
-- What the question is about
-- ---------------------------------------------------------------------------

--- Lines in the WORKING file for a selection made in either code pane. A
--- selection in the base pane is mapped across the hunks, the same way the
--- scroll lock maps one pane onto the other.
local function to_working(session, win, first, last)
    if win == session.base_win then
        first = layout.map_line(session.hunks, first, true)
        last = layout.map_line(session.hunks, last, true)
    end
    if last < first then
        first, last = last, first
    end
    return first, last
end

--- The hunk under the cursor: the region containing the line, else the nearest
--- region within SLACK lines, else the line itself.
local function region_at(session, line)
    local regions = explain.regions_for(session)
    for _, r in ipairs(regions) do
        if line >= r.first and line <= r.last then
            return r.first, r.last
        end
    end
    local best, best_gap
    for _, r in ipairs(regions) do
        local gap = math.max(line - r.last, r.first - line)
        if gap <= SLACK and (best_gap == nil or gap < best_gap) then
            best, best_gap = r, gap
        end
    end
    if best then
        return best.first, best.last
    end
    return line, line
end

local function overlaps(item, first, last)
    local s = tonumber(item.start) or tonumber(item["from"])
    local e = tonumber(item["end"]) or s
    if not s then
        return false
    end
    if e < s then
        s, e = e, s
    end
    return s <= last + SLACK and e >= first - SLACK
end

--- Everything the prompt wants about a selection of the current file.
local function gather(session, first, last)
    local entry = session.entries[session.index]
    if not entry then
        return nil
    end
    local explain_store, review_store = explain.ensure_loaded(session)

    local explanations = {}
    for _, e in ipairs((explain_store[entry.path] or {}).explanations or {}) do
        if overlaps(e, first, last) then
            table.insert(explanations, e)
        end
    end

    local findings = {}
    for _, role in ipairs(reviewers.roles) do
        for _, c in ipairs((review_store[entry.path] or {})[role.key] or {}) do
            if overlaps(c, first, last) then
                table.insert(findings, {
                    role = role.title,
                    severity = c.severity,
                    start = c.start,
                    ["end"] = c["end"],
                    title = c.title,
                    body = c.body,
                })
            end
        end
    end

    local chapter
    for _, ch in ipairs(session.guide and session.guide.chapters or {}) do
        if vim.tbl_contains(ch.files or {}, entry.path) then
            chapter = ch
            break
        end
    end

    local wbuf = vim.api.nvim_win_get_buf(session.working_win)
    local count = vim.api.nvim_buf_line_count(wbuf)
    local lines = {}
    if first <= count then
        lines = vim.api.nvim_buf_get_lines(wbuf, first - 1, math.min(last, count), false)
    end

    return {
        entry = entry,
        path = entry.path,
        first = first,
        last = last,
        lines = lines,
        chapter = chapter,
        explanations = explanations,
        findings = findings,
        diff = git.file_diff(session.diff_base, entry, session.root, session.diff_head) or "",
    }
end

-- ---------------------------------------------------------------------------
-- The ramp: blue running into sea green, on the title and round the border
-- ---------------------------------------------------------------------------

-- The ramp: sky blue into white. Interpolated per character on titles. The border continues the title: the title starts blue
-- at the top-left corner and ends white on the top edge, so the ring picks
-- up white there and runs clockwise — right side, bottom, left side — back
-- to sky blue at the corner the title begins on.
local RAMP_SKY, RAMP_WHITE = { 0x89, 0xdc, 0xeb }, { 0xff, 0xff, 0xff }
local RAMP_STEPS = 12

--- The colour at t in [0, 1]: sky blue straight to white.
local function ramp_color(t)
    local c = {}
    for k = 1, 3 do
        c[k] = math.floor(RAMP_SKY[k] + (RAMP_WHITE[k] - RAMP_SKY[k]) * t + 0.5)
    end
    return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

local function ramp_hl(i)
    return "LgtmAskRamp" .. i
end

--- Define the ramp groups. Called from setup_highlights.
local function setup_ramp()
    for i = 1, RAMP_STEPS do
        vim.api.nvim_set_hl(0, ramp_hl(i), { fg = ramp_color((i - 1) / (RAMP_STEPS - 1)), bold = true })
    end
end

--- A title as highlight chunks, one ramp step per character.
local function gradient_title(text)
    local chars = vim.fn.split(text, "\\zs")
    local out = {}
    for i, ch in ipairs(chars) do
        local step = #chars <= 1 and 1 or (1 + math.floor((i - 1) / (#chars - 1) * (RAMP_STEPS - 1) + 0.5))
        table.insert(out, { ch, ramp_hl(step) })
    end
    return out
end

--- The rounded border, coloured to continue the title round the box.
local function gradient_border()
    -- Neovim's order: top-left, top, top-right, right, bottom-right, bottom,
    -- bottom-left, left. The top edge carries the title's white end; each
    -- piece after it steps back towards sky blue, and the top-left corner is sky blue.
    local pieces = {
        { "╭", 1 },
        { "─", RAMP_STEPS },
        { "╮", RAMP_STEPS },
        { "│", RAMP_STEPS - 2 },
        { "╯", RAMP_STEPS - 4 },
        { "─", RAMP_STEPS - 6 },
        { "╰", RAMP_STEPS - 8 },
        { "│", RAMP_STEPS - 10 },
    }
    local out = {}
    for _, pc in ipairs(pieces) do
        table.insert(out, { pc[1], ramp_hl(math.max(1, pc[2])) })
    end
    return out
end

M._gradient_title, M._gradient_border = gradient_title, gradient_border

-- ---------------------------------------------------------------------------
-- The float
-- ---------------------------------------------------------------------------

local function geometry(session, content_rows)
    local cfg = session.cfg.ask or {}
    local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local width = math.min(cfg.width or 100, cols - 8)
    local max_h = math.floor(lines * 0.7)
    local height = math.max(6, math.min(max_h, content_rows))
    return {
        width = width,
        height = height,
        col = math.floor((cols - width) / 2),
        row = math.floor((lines - height) / 2) - 1,
    }
end

local function title(session)
    local t = session.ask.thread
    return string.format(" 󰙴 ASK — %s:%s ", t.path:match("[^/]+$") or t.path, t.first == t.last and tostring(t.first) or (t.first .. "–" .. t.last))
end

--- Redraw the float from the thread: every question, every answer, and the
--- pending marker while one is out.
local function render(session)
    if not M.is_open(session) then
        return
    end
    local a = session.ask
    local width = vim.api.nvim_win_get_width(a.win)
    local text_width = math.max(20, width - 4)
    local lines, marks = {}, {}

    local function emit(line, hl)
        table.insert(lines, line)
        if hl then
            table.insert(marks, { line = #lines - 1, col = 0, end_col = #line, hl = hl })
        end
    end

    for i, turn in ipairs(a.thread.turns) do
        if i > 1 then
            emit("")
        end
        for _, l in ipairs(markdown.wrap("▌ " .. turn.question, text_width, "  ")) do
            emit(l, "LgtmAskQuestion")
        end
        emit("")
        if turn.answer then
            local indented = {}
            for _, l in ipairs(vim.split(turn.answer, "\n", { plain = true })) do
                table.insert(indented, "  " .. l)
            end
            local body_lines, body_marks = markdown.format(table.concat(indented, "\n"), text_width)
            local offset = #lines
            vim.list_extend(lines, body_lines)
            for _, m in ipairs(body_marks) do
                table.insert(marks, { line = m.line + offset, col = m.col, end_col = m.end_col, hl = m.hl, eol = m.eol })
            end
        elseif turn.error then
            emit("  ✗ " .. turn.error, "WarningMsg")
        else
            local secs = a.started and math.floor((vim.uv.now() - a.started) / 1000) or 0
            emit(string.format("  thinking… %ds", secs), "LgtmExplainMeta")
        end
    end
    emit("")
    local n = #a.thread.explanations
    local f = #a.thread.findings
    emit(
        string.format(
            "  %d explanation%s · %d finding%s in hand   ·   %s follow-up · q close",
            n,
            n == 1 and "" or "s",
            f,
            f == 1 and "" or "s",
            session.cfg.keys.ask or "a"
        ),
        "LgtmExplainMeta"
    )

    markdown.apply(a.buf, lines, marks)
    vim.api.nvim_buf_clear_namespace(a.buf, NS, 0, -1)
    local g = geometry(session, #lines)
    pcall(vim.api.nvim_win_set_config, a.win, {
        relative = "editor",
        width = g.width,
        height = g.height,
        col = g.col,
        row = g.row,
        title = gradient_title(title(session)),
        title_pos = "left",
    })
    -- Follow the newest text: the answer to the latest question is what the
    -- reviewer is waiting on.
    pcall(vim.api.nvim_win_set_cursor, a.win, { #lines, 0 })
end

local function stop_clock(session)
    local a = session.ask
    if a and a.timer then
        pcall(function()
            a.timer:stop()
            a.timer:close()
        end)
        a.timer = nil
    end
end

function M.close(session)
    local a = session and session.ask
    if not a then
        return
    end
    stop_clock(session)
    if a.job then
        pcall(function()
            a.job:kill(15)
        end)
        a.job = nil
    end
    if a.win and vim.api.nvim_win_is_valid(a.win) then
        pcall(vim.api.nvim_win_close, a.win, true)
    end
    if a.buf and vim.api.nvim_buf_is_valid(a.buf) then
        pcall(vim.api.nvim_buf_delete, a.buf, { force = true })
    end
    session.ask = nil
end

local function open_float(session)
    if M.is_open(session) then
        return
    end
    local a = session.ask
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, "lgtm://ask")
    vim.bo[buf].filetype = "lgtm-ask"

    local g = geometry(session, 8)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = gradient_border(),
        title = gradient_title(title(session)),
        title_pos = "left",
        width = g.width,
        height = g.height,
        col = g.col,
        row = g.row,
        zindex = 60,
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].conceallevel = 2
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = "Normal:Normal"
    a.win, a.buf = win, buf

    local function bufmap(lhs, fn, desc)
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lgtm: " .. desc })
        end
    end
    bufmap("q", function()
        M.close(session)
    end, "close the answer")
    bufmap("<Esc>", function()
        M.close(session)
    end, "close the answer")
    bufmap("a", function()
        M.follow_up(session)
    end, "ask a follow-up")
    bufmap(session.cfg.keys.ask, function()
        M.follow_up(session)
    end, "ask a follow-up")
end

-- ---------------------------------------------------------------------------
-- The runs
-- ---------------------------------------------------------------------------

--- Send the latest turn's question. A follow-up resumes the thread's agent
--- session; if that session is gone, the thread is replayed into a fresh one
--- so the follow-up still lands with its context.
local function send(session, fresh)
    local a = session.ask
    local t = a.thread
    local turn = t.turns[#t.turns]
    local cfg = session.cfg.explain
    local ask_cfg = session.cfg.ask or {}

    local prompt
    if t.agent and not fresh then
        prompt = turn.question
    else
        local ctx = {
            pr = session.pr,
            branch = session.branch,
            base_ref = session.base_ref,
            chapter = t.chapter,
            path = t.path,
            diff = t.diff,
            first = t.first,
            last = t.last,
            lines = t.lines,
            explanations = t.explanations,
            findings = t.findings,
            question = turn.question,
            budget = cfg.max_diff_bytes,
        }
        if #t.turns > 1 then
            -- Replay the thread so far, so a fresh session answers the
            -- follow-up rather than the first question again.
            local history = {}
            for i = 1, #t.turns - 1 do
                local prev = t.turns[i]
                table.insert(history, "Q: " .. prev.question .. "\nA: " .. (prev.answer or prev.error or "(no answer)"))
            end
            ctx.question = "Earlier in this thread:\n\n" .. table.concat(history, "\n\n") .. "\n\nNow the reviewer asks:\n" .. turn.question
        end
        prompt = ai.build_ask_prompt(ctx)
    end

    a.started = vim.uv.now()
    if not a.timer then
        local timer = vim.uv.new_timer()
        a.timer = timer
        timer:start(1000, 1000, vim.schedule_wrap(function()
            if session.ask == a then
                render(session)
            end
        end))
    end
    render(session)

    a.job = ai.ask(
        prompt,
        ai.ASK_CONTRACT,
        { repo = session.root },
        cfg,
        { resume = (not fresh) and t.agent or nil, model = ask_cfg.model },
        function(ok, text, agent)
            if session.ask ~= a then
                return
            end
            a.job = nil
            if not ok and t.agent and not fresh then
                -- The resumed session is gone (or refused): replay into a new one.
                t.agent = nil
                send(session, true)
                return
            end
            stop_clock(session)
            if ok then
                turn.answer = text ~= "" and text or "(empty answer)"
                if agent then
                    t.agent = agent
                end
            else
                turn.error = text
            end
            render(session)
        end
    )
end

-- ---------------------------------------------------------------------------
-- The question box
-- ---------------------------------------------------------------------------

--- A small floating buffer to type the question in. `vim.ui.input` is one
--- line, and a real question about a diff runs longer than that: the text
--- wrapped back over itself. This box wraps, grows to fit up to ten rows,
--- and takes newlines. <C-s> (insert or normal) and <CR> in normal mode
--- submit; <Esc> in normal mode, or q, cancels. Empty text cancels too.
--- @param title string shown in the border
--- @param cb function called once with the trimmed text, or nil when cancelled
--- @param opts table|nil `verb` names what submitting does, in the footer
local function prompt(session, title, cb, opts)
    local cfg = session.cfg.ask or {}
    local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local width = math.min(cfg.width or 100, cols - 8)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "lgtm-ask-prompt"

    local function height_for()
        -- Rows the text needs once wrapped to the box, capped so it never
        -- eats the screen; the window scrolls past the cap.
        local n = 0
        for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            n = n + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / math.max(1, width - 2)))
        end
        return math.max(3, math.min(10, n))
    end

    local height = height_for()
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        style = "minimal",
        border = gradient_border(),
        title = gradient_title(" " .. title .. " "),
        title_pos = "left",
        footer = " <C-s> or <CR> in normal mode " .. (opts and opts.verb or "asks") .. " · <Esc><Esc> cancels ",
        footer_pos = "right",
        width = width,
        height = height,
        col = math.floor((cols - width) / 2),
        row = math.floor((lines - height) / 2) - 1,
        zindex = 70,
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = "Normal:Normal,FloatFooter:LgtmExplainMeta"

    local done = false
    local function finish(text)
        if done then
            return
        end
        done = true
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        -- Back to normal mode wherever focus lands, so a submit from insert
        -- mode does not leave the diff pane in insert.
        vim.cmd("stopinsert")
        cb(text)
    end
    local function submit()
        local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
        finish(text ~= "" and text or nil)
    end
    local function cancel()
        finish(nil)
    end

    local o = { buffer = buf, nowait = true, silent = true }
    vim.keymap.set({ "i", "n" }, "<C-s>", submit, o)
    vim.keymap.set("n", "<CR>", submit, o)
    vim.keymap.set("n", "<Esc>", cancel, o)
    vim.keymap.set("n", "q", cancel, o)

    local group = vim.api.nvim_create_augroup("lgtm_ask_prompt_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = buf,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                local h = height_for()
                if h ~= vim.api.nvim_win_get_height(win) then
                    pcall(vim.api.nvim_win_set_config, win, {
                        relative = "editor",
                        width = width,
                        height = h,
                        col = math.floor((cols - width) / 2),
                        row = math.floor((lines - h) / 2) - 1,
                    })
                end
            end
        end,
    })
    -- Leaving the window by any other route (:q, a mouse click elsewhere) is a cancel.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(win),
        once = true,
        callback = function()
            vim.schedule(cancel)
        end,
    })
    vim.cmd("startinsert")
end

M._prompt = prompt

--- Ask about a range of the working file (or the hunk under the cursor when
--- no range is given). Prompts for the question, then opens the float.
--- @param opts table|nil { first, last, win, question }
function M.ask(session, opts)
    opts = opts or {}
    if not (session and session.working_win and vim.api.nvim_win_is_valid(session.working_win)) then
        return
    end
    local win = opts.win or vim.api.nvim_get_current_win()
    local first, last
    if opts.first and opts.last then
        first, last = to_working(session, win, opts.first, opts.last)
    else
        local line = vim.api.nvim_win_get_cursor(
            (win == session.base_win or win == session.working_win) and win or session.working_win
        )[1]
        line = to_working(session, win, line, line)
        first, last = region_at(session, line)
    end

    local info = gather(session, first, last)
    if not info then
        notify("no file on show", vim.log.levels.WARN)
        return
    end

    local function go(question)
        question = question and vim.trim(question) or ""
        if question == "" then
            return
        end
        -- One thread per ask: the float shows this question's conversation.
        M.close(session)
        session.ask = {
            thread = vim.tbl_extend("force", info, { turns = { { question = question } }, agent = nil }),
        }
        open_float(session)
        send(session, true)
    end

    if opts.question and opts.question ~= "" then
        go(opts.question)
        return
    end
    local where = string.format(
        "%s:%s",
        info.path:match("[^/]+$") or info.path,
        first == last and tostring(first) or (first .. "–" .. last)
    )
    local extras = {}
    if #info.explanations > 0 then
        table.insert(extras, "explanation")
    end
    if #info.findings > 0 then
        table.insert(extras, #info.findings .. " finding" .. (#info.findings == 1 and "" or "s"))
    end
    local hint = #extras > 0 and (" (+" .. table.concat(extras, ", ") .. ")") or ""
    prompt(session, string.format("ask about %s%s", where, hint), go)
end

--- A follow-up in the open thread.
function M.follow_up(session)
    if not (session and session.ask and session.ask.thread) then
        return
    end
    local a = session.ask
    if a.job then
        notify("still thinking about the last question")
        return
    end
    prompt(session, "follow-up", function(question)
        question = question and vim.trim(question) or ""
        if question == "" or session.ask ~= a then
            return
        end
        table.insert(a.thread.turns, { question = question })
        if not M.is_open(session) then
            open_float(session)
        end
        send(session, false)
    end)
end

function M.setup_highlights()
    setup_ramp()
    vim.api.nvim_set_hl(0, "LgtmAskQuestion", { bold = true })
    local fb = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false })
    vim.api.nvim_set_hl(0, "LgtmAskBorder", { fg = fb.fg })
    local ft = vim.api.nvim_get_hl(0, { name = "FloatTitle", link = false })
    vim.api.nvim_set_hl(0, "LgtmAskTitle", { fg = ft.fg, bold = true })
end

return M
