-- GitHub review comments: posting one on the lines under the cursor or the
-- selection, and showing the PR's existing threads at the end of the lines
-- they sit on.
--
-- GitHub anchors a comment to a line of the file at a commit (`commit_id`),
-- on the RIGHT (that commit's version) or LEFT (the PR base) side. The panes
-- do not always show a pushed commit: the working file can carry unpushed or
-- uncommitted edits. A working-file line is therefore mapped back to the PR
-- head through a diff of the two, and a line the head does not have is
-- refused rather than guessed at.

local git = require("lgtm.git")
local layout = require("lgtm.layout")

local M = {}

local NS = vim.api.nvim_create_namespace("lgtm_comments")

local function notify(msg, level)
    vim.notify("lgtm: " .. msg, level or vim.log.levels.INFO)
end

local function buf_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Hunks taking the file at the PR head to the working buffer, or nil when
--- the head has no such file (not pushed, or not fetched).
local function head_hunks(session, entry, buf)
    local head = session.pr and session.pr.headRefOid
    local raw = head and git.show(head, entry.path, session.root)
    if not raw then
        return nil
    end
    local ok, hunks = pcall(vim.diff, raw, buf_text(buf), {
        result_type = "indices",
        algorithm = "histogram",
        linematch = 40,
    })
    return ok and hunks or nil
end

--- A working-buffer line as a line of the file at the PR head, or nil when
--- the line is not there (inside a region the working copy changed).
local function working_to_head(hunks, line)
    local offset = 0
    for _, h in ipairs(hunks) do
        local ca, sb, cb = h[2], h[3], h[4]
        if cb == 0 then
            -- A pure deletion: `sb` is the line the removed block hung after.
            if line <= sb then
                break
            end
        elseif line < sb then
            break
        elseif line < sb + cb then
            return nil
        end
        offset = offset + (ca - cb)
    end
    return line + offset
end

--- Where a comment posted from `win` lands on GitHub.
--- @return table|nil { commit_id, side, first, last }, or nil and why
local function anchor(session, win, first, last)
    local pr = session.pr
    if not (pr and pr.number and pr.headRefOid) then
        return nil, "no GitHub PR for this branch"
    end
    if win == session.base_win then
        if session.commit then
            return nil, "in commit mode, comment from the right-hand pane"
        end
        return { commit_id = pr.headRefOid, side = "LEFT", first = first, last = last }
    end
    if session.diff_head then
        return { commit_id = session.diff_head, side = "RIGHT", first = first, last = last }
    end
    local entry = session.entries[session.index]
    local hunks = head_hunks(session, entry, vim.api.nvim_win_get_buf(win))
    if not hunks then
        return nil, string.format("%s is not at the PR head %s — push (or fetch) first", entry.path, pr.headRefOid:sub(1, 7))
    end
    local hf, hl = working_to_head(hunks, first), working_to_head(hunks, last)
    if not (hf and hl) then
        return nil, "those lines have unpushed changes — push first, then comment"
    end
    return { commit_id = pr.headRefOid, side = "RIGHT", first = hf, last = hl }
end

local function api_error(res)
    local text = (res.stderr or "") .. (res.stdout or "")
    local ok, decoded = pcall(vim.json.decode, res.stdout or "")
    if ok and type(decoded) == "table" and decoded.message then
        local details = {}
        for _, e in ipairs(type(decoded.errors) == "table" and decoded.errors or {}) do
            table.insert(details, type(e) == "table" and (e.message or e.code) or tostring(e))
        end
        text = decoded.message .. (#details > 0 and (": " .. table.concat(details, "; ")) or "")
    end
    return vim.trim(text)
end

local JQ = ".[] | {id, path, line, start_line, original_line, side, commit_id, original_commit_id,"
    .. " body, in_reply_to_id, html_url, user: .user.login}"

--- Fetch the PR's review comments into `session.comments`, then `cb()`.
function M.load(session, cb)
    local pr = session.pr
    if not (pr and pr.number) or vim.fn.executable("gh") ~= 1 or vim.env.LGTM_NO_GH then
        return
    end
    vim.system({
        "gh",
        "api",
        "--paginate",
        string.format("repos/{owner}/{repo}/pulls/%d/comments", pr.number),
        "--jq",
        JQ,
    }, { cwd = session.root, text = true }, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                notify("could not load PR comments: " .. api_error(res), vim.log.levels.WARN)
                return
            end
            local comments = {}
            for line in (res.stdout or ""):gmatch("[^\n]+") do
                local ok, c = pcall(vim.json.decode, line, { luanil = { object = true } })
                if ok and type(c) == "table" then
                    table.insert(comments, c)
                end
            end
            session.comments = comments
            if cb then
                cb()
            end
        end)
    end)
end

--- Threads on the file on show, as { line, side, root, replies } against the
--- panes' own line numbers.
local function threads_for(session, entry)
    local by_id, roots = {}, {}
    for _, c in ipairs(session.comments or {}) do
        if c.path == entry.path then
            by_id[c.id] = c
        end
    end
    for _, c in ipairs(session.comments or {}) do
        if c.path == entry.path and not (c.in_reply_to_id and by_id[c.in_reply_to_id]) then
            table.insert(roots, c)
        end
    end
    local function replies(root)
        local out = {}
        for _, c in ipairs(session.comments or {}) do
            if c.in_reply_to_id == root.id then
                table.insert(out, c)
            end
        end
        return out
    end

    local head = session.pr and session.pr.headRefOid
    local hunks
    local threads = {}
    for _, root in ipairs(roots) do
        local line, side
        if session.diff_head then
            if root.original_commit_id == session.diff_head and root.side == "RIGHT" then
                line, side = root.original_line, "RIGHT"
            end
        elseif root.line and root.commit_id == head then
            if root.side == "LEFT" and not session.commit then
                line, side = root.line, "LEFT"
            elseif root.side == "RIGHT" then
                hunks = hunks or head_hunks(session, entry, vim.api.nvim_win_get_buf(session.working_win)) or {}
                line, side = layout.map_line(hunks, root.line, true), "RIGHT"
            end
        end
        if line then
            table.insert(threads, { line = line, side = side, root = root, replies = replies(root) })
        end
    end
    return threads
end

--- Clear and redraw the end-of-line markers for the file on show.
function M.decorate(session)
    for buf in pairs(session.comment_bufs or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
        end
    end
    session.comment_bufs = {}
    local entry = session.entries[session.index]
    if not (entry and session.comments and #session.comments > 0) then
        return
    end
    for _, t in ipairs(threads_for(session, entry)) do
        local win = t.side == "LEFT" and session.base_win or session.working_win
        local buf = vim.api.nvim_win_get_buf(win)
        local first = (t.root.body or ""):match("[^\r\n]+") or ""
        local text = string.format(" 󰆉 %s: %s", t.root.user or "?", first)
        if #t.replies > 0 then
            text = text .. string.format("  (+%d)", #t.replies)
        end
        if t.line >= 1 and t.line <= vim.api.nvim_buf_line_count(buf) then
            pcall(vim.api.nvim_buf_set_extmark, buf, NS, t.line - 1, 0, {
                virt_text = { { text, "LgtmComment" } },
                virt_text_pos = "eol",
                hl_mode = "combine",
            })
            session.comment_bufs[buf] = true
        end
    end
end

--- Clear every marker the session placed; the working buffers outlive it.
function M.clear(session)
    for buf in pairs(session.comment_bufs or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
        end
    end
    session.comment_bufs = {}
end

--- Post a review comment on lines of the file on show.
--- @param opts table|nil { first, last, win, body } — the cursor line of the
---        current window when no range is given
function M.comment(session, opts)
    opts = opts or {}
    local win = opts.win or vim.api.nvim_get_current_win()
    if win ~= session.base_win and win ~= session.working_win then
        win = session.working_win
    end
    local entry = session.entries[session.index]
    if not entry then
        return
    end
    local first, last = opts.first, opts.last
    if not (first and last) then
        first = vim.api.nvim_win_get_cursor(win)[1]
        last = first
    end
    local where, why = anchor(session, win, first, last)
    if not where then
        notify(why, vim.log.levels.WARN)
        return
    end

    local function post(body)
        body = body and vim.trim(body) or ""
        if body == "" then
            return
        end
        local args = {
            "gh",
            "api",
            "-X",
            "POST",
            string.format("repos/{owner}/{repo}/pulls/%d/comments", session.pr.number),
            "-f",
            "body=" .. body,
            "-f",
            "commit_id=" .. where.commit_id,
            "-f",
            "path=" .. entry.path,
            "-F",
            "line=" .. where.last,
            "-f",
            "side=" .. where.side,
        }
        if where.first < where.last then
            vim.list_extend(args, { "-F", "start_line=" .. where.first, "-f", "start_side=" .. where.side })
        end
        notify("posting comment…")
        vim.system(args, { cwd = session.root, text = true }, function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    notify("comment not posted: " .. api_error(res), vim.log.levels.ERROR)
                    return
                end
                notify("comment posted")
                M.load(session, function()
                    M.decorate(session)
                end)
            end)
        end)
    end

    if opts.body then
        post(opts.body)
        return
    end
    local span = where.first == where.last and tostring(first) or (first .. "–" .. last)
    require("lgtm.ask")._prompt(
        session,
        string.format("comment on %s:%s", entry.path:match("[^/]+$") or entry.path, span),
        post,
        { verb = "posts" }
    )
end

function M.setup_highlights()
    vim.api.nvim_set_hl(0, "LgtmComment", { link = "DiagnosticInfo", default = true })
end

return M
