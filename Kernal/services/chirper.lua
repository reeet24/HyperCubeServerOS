local chirper = {}

local ChirperService = {}
ChirperService.__index = ChirperService

local MAX_POSTS = 60
local MAX_BODY = 240

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function require_owner(owner)
    owner = tostring(owner or "")
    if owner == "" then
        return nil, "AuthRequired"
    end
    return owner
end

local function normalize_username(username, owner)
    username = tostring(username or owner or "user")
    username = username:gsub("%s+", "")
    username = username:gsub("[^%w_%-%.]", "")
    if username == "" then
        username = tostring(owner or "user")
    end
    return username:sub(1, 24)
end

local function profile_key(owner)
    return "chirper:profile:" .. tostring(owner)
end

local function post_key(id)
    return "chirper:post:" .. tostring(id)
end

local function timeline_key()
    return "chirper:timeline"
end

local function public_profile(profile)
    if not profile then
        return nil
    end
    return {
        owner = profile.owner,
        username = profile.username,
        display_name = profile.display_name or profile.username,
        created_at = profile.created_at,
        updated_at = profile.updated_at,
        post_count = profile.post_count or 0,
    }
end

local function public_post(post)
    if not post then
        return nil
    end
    return {
        id = post.id,
        owner = post.owner,
        username = post.username,
        body = post.body,
        created_at = post.created_at,
    }
end

function ChirperService.new(options)
    options = options or {}
    local self = setmetatable({}, ChirperService)
    self.database = options.database
    return self
end

function ChirperService:require_database()
    if not self.database then
        return false, "DatabaseUnavailable"
    end
    return true
end

function ChirperService:profile(owner, username)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end

    local record = self.database:get(profile_key(owner))
    if not record then
        record = {
            owner = owner,
            username = normalize_username(username, owner),
            display_name = normalize_username(username, owner),
            created_at = now(),
            post_count = 0,
        }
    elseif username and username ~= "" then
        record.username = normalize_username(username, owner)
        record.display_name = record.username
    end
    record.updated_at = now()

    local set_ok, set_err = self.database:set(profile_key(owner), record)
    if not set_ok then
        return false, set_err
    end
    return true, public_profile(record)
end

function ChirperService:feed(owner, username)
    local ok, result = self:profile(owner, username)
    if not ok then
        return false, result
    end

    local timeline = self.database:get(timeline_key()) or {
        posts = {},
    }
    local feed = {}
    for i = #timeline.posts, 1, -1 do
        feed[#feed + 1] = timeline.posts[i]
        if #feed >= 20 then
            break
        end
    end
    return true, {
        profile = result,
        posts = feed,
    }
end

function ChirperService:post(owner, username, body)
    local ok, result = self:profile(owner, username)
    if not ok then
        return false, result
    end

    body = tostring(body or ""):gsub("\r", " "):gsub("\n", " ")
    body = body:match("^%s*(.-)%s*$") or ""
    if body == "" then
        return false, "EmptyPost"
    end
    if #body > MAX_BODY then
        body = body:sub(1, MAX_BODY)
    end

    local id = "chirp_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000))
    local post = {
        id = id,
        owner = result.owner,
        username = result.username,
        body = body,
        created_at = now(),
    }

    local set_ok, set_err = self.database:set(post_key(id), post)
    if not set_ok then
        return false, set_err
    end

    local timeline = self.database:get(timeline_key()) or {
        posts = {},
    }
    timeline.posts = timeline.posts or {}
    timeline.posts[#timeline.posts + 1] = public_post(post)
    while #timeline.posts > MAX_POSTS do
        table.remove(timeline.posts, 1)
    end
    timeline.updated_at = now()
    local timeline_ok, timeline_err = self.database:set(timeline_key(), timeline)
    if not timeline_ok then
        return false, timeline_err
    end

    local profile = self.database:get(profile_key(owner)) or {}
    profile.post_count = (profile.post_count or 0) + 1
    profile.updated_at = now()
    local profile_ok, profile_err = self.database:set(profile_key(owner), profile)
    if not profile_ok then
        return false, profile_err
    end

    return true, public_post(post)
end

function chirper.new(options)
    return ChirperService.new(options)
end

chirper.ChirperService = ChirperService

return chirper
