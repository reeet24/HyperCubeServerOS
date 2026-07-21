local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Chirper",
        label = "Chirp",
        color = C.purple,
        dock = false,
        render_mode = "exclusive",
        refresh_rate = 10,
    },
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function request(message, expected)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    message.username = api.identity and api.identity.username or message.username
    local ok, reply, err = pcall(api.hypernet.request, message, expected, 10)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.loaded = false
    state.posts = {}
    state.profile = nil
    state.body = ""
    state.focus = "body"
    state.status = nil
    state.error = nil
end

local function refresh(state)
    local reply, err = request({
        type = "chirper.feed",
    }, "chirper.feed.result")

    state.loaded = true
    if reply and reply.ok then
        state.profile = reply.result and reply.result.profile or nil
        state.posts = reply.result and reply.result.posts or {}
        state.error = nil
    else
        state.error = (reply and reply.error) or err or "ChirperUnavailable"
    end
end

local function post(state)
    if state.body == "" then
        state.error = "Write something first"
        return
    end

    state.status = "Posting..."
    local reply, err = request({
        type = "chirper.post",
        body = state.body,
    }, "chirper.post.result")

    if reply and reply.ok then
        state.body = ""
        state.status = "Posted"
        state.error = nil
        refresh(state)
    else
        state.status = nil
        state.error = (reply and reply.error) or err or "PostFailed"
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state)
    end

    local username = state.profile and state.profile.username or (api.identity and api.identity.username) or "guest"
    write_line(ctx, 0, "Chirper @" .. tostring(username), C.yellow)

    ctx.buttons.chirper_refresh = api.screen.button("chirper_refresh", ctx.x, ctx.y + 2, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })
    ctx.buttons.chirper_post = api.screen.button("chirper_post", ctx.x + 11, ctx.y + 2, 7, "Post", {
        fg = C.white,
        bg = state.body ~= "" and C.green or C.gray,
    })

    local composer = state.body == "" and "Say something..." or state.body
    ctx.buttons.chirper_body = api.screen.button("chirper_body", ctx.x, ctx.y + 4, math.min(ctx.width, 24), truncate(composer, 24), {
        fg = state.body == "" and C.lightGray or C.white,
        bg = state.focus == "body" and C.blue or C.gray,
    })

    local row = 6
    if #state.posts == 0 then
        write_line(ctx, row, "No chirps yet.", C.lightGray)
    else
        for _, item in ipairs(state.posts) do
            if row >= ctx.height - 2 then
                break
            end
            write_line(ctx, row, "@" .. tostring(item.username or "user"), C.cyan)
            row = row + 1
            write_line(ctx, row, tostring(item.body or ""), C.white)
            row = row + 2
        end
    end

    if state.error then
        write_line(ctx, ctx.height - 1, state.error, C.red)
    elseif state.status then
        write_line(ctx, ctx.height - 1, state.status, C.green)
    else
        write_line(ctx, ctx.height - 1, "Enter posts, Backspace edits", C.lightGray)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "chirper_refresh" then
        refresh(state)
        return true
    elseif ctx.button_id == "chirper_post" then
        post(state)
        return true
    elseif ctx.button_id == "chirper_body" then
        state.focus = "body"
        state.status = nil
        state.error = nil
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event.type == "char" then
        local ch = ctx.event.raw and ctx.event.raw[2] or ""
        if #state.body < 240 then
            state.body = state.body .. ch
            state.status = nil
            state.error = nil
        end
        return true
    end

    if not keys then
        return false
    end
    local key = ctx.event.raw and ctx.event.raw[2]
    if key == keys.backspace then
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
        state.status = nil
        state.error = nil
        return true
    elseif key == keys.enter then
        post(state)
        return true
    elseif key == keys.r then
        refresh(state)
        return true
    end
    return false
end

return app
