---@class Bot
---@field enabled boolean
---@field busy boolean
---@field delay number
---@field timer number
local Bot = {
    enabled = false,
    busy = false,
    delay = .15,
    -- delay = 0,
    timer = 0,
    t2 = 0,
    playing = false,
    is_waiting = false,
    actions = 0,
}
_G.Bot = Bot

local max = math.max
local GAME = GAME
local M = GAME.mod
local CD = Cards
local TABLE = TABLE
local game_stats = GAME.playing
local last_sound = CONF.sfx

local function applyCombo(set)
    local changed
    for _, C in ipairs(Cards) do
        local cur = C.active and (C.upright and 1 or 2) or 0
        local tar = TABLE.find(set, C.id) and 1 or TABLE.find(set, 'r' .. C.id) and 2 or 0
        if cur ~= tar then
            if cur > 0 then C:setActive(true) end
            if tar > 0 then C:setActive(true, tar == 2 and 2 or 1) end
            changed = true
        end
    end
    if set.ultra ~= nil and set.ultra ~= URM then
        URM = set.ultra
        ultraStateChange()
    end
    if changed then SFX.play('mmstart') end
end

local function ultraStateChange()
    GAME.hardMode = M.EX > 0 or GAME.anyRev and not URM
    GAME.refreshLayout()
    GAME.refreshUltra()
    GAME.refreshCurrentCombo()
    GAME.refreshPBText()
    RefreshBGM()
    GAME.refreshRPC()
    RefreshHelpText()
end

local function toggleUltra()
    if RevUnlocked then
        URM = not URM
        SFX.play(URM and 'exchange' or 'undo')
        ultraStateChange()
    else
        SFX.play('no')
    end
end

-- ──────────────────────────────────────────────
--  Public API
-- ──────────────────────────────────────────────

function Bot.toggle()
    Bot.enabled = not Bot.enabled
    Bot.busy = false
    Bot.timer = 0
    Bot.t2 = 0
    Bot.is_waiting = false
    if Bot.enabled then
        SFX.play('menuconfirm')
        MSG('dark', "BOT ENGAGED", 2.6)
        last_sound = CONF.sfx
    else
        SFX.play('menuback')
        MSG('dark', "BOT DISENGAGED", 2.6)
        Bot.playing = false
        if last_sound ~= CONF.sfx then
            love.keypressed('f3')
            love.keyreleased('f3')
        end
    end
end

function Bot.update(dt)
    if GAME.playing then
        if not game_stats then
            game_stats = true
        end
        if Bot.enabled then
            if Bot.actions / GAME.time < 30 then
                if last_sound > CONF.sfx then
                    love.keypressed('f3')
                    love.keyreleased('f3')
                end
            end
        end
    else
        if game_stats then
            game_stats = false
        end
        Bot.actions = 0
    end

    if not Bot.enabled then return end
    if Bot.busy then
        Bot.timer = Bot.timer - dt
        if Bot.timer > 0 then return end
        Bot.busy = false
    end
    if Bot.is_waiting then
        Bot.t2 = Bot.t2 - dt
        if GAME.playing then
            Bot.t2 = 0
            MSG('warn', "Game started while waiting - resuming", 3)
        elseif Bot.t2 > 0 then
            return
        else
            Bot.is_waiting = false
        end
    end

    if GAME.playing then
        if not Bot.playing then
            Bot.playing = true
            Bot.is_waiting = false
            Bot.t2 = 0
        end
        Bot._updatePlaying()
        if Bot.actions / GAME.time > 30 then
            if CONF.sfx > 0 then
                MSG('warn', "Bot is acting too fast! Turning off sfx")
                love.keypressed('f3')
                love.keyreleased('f3')
            end
        end
    else
        if Bot.playing then
            Bot.playing = false
            if URM then
                toggleUltra()
            end
            MSG('dark', "Next game in 10 seconds", 5)
            Bot._game_wait(10)
        end
        if not Bot.is_waiting then
            Bot._updateMenu()
        end
    end
end

-- ──────────────────────────────────────────────
--  Internal
-- ──────────────────────────────────────────────

function Bot._schedule(d)
    Bot.busy = true
    Bot.timer = d or Bot.delay
end

function Bot._game_wait(d)
    Bot.is_waiting = true
    Bot.t2 = d or Bot.delay
end

--- Check if every card in `ids` is selected (active in menu / M set).
local function allSelected(ids)
    for _, id in ipairs(ids) do
        if M[id] == 0 then return false end
    end
    return true
end

--- Return the first card-object whose `id` matches.
local function findCard(id)
    for _, C in ipairs(CD) do
        if C.id == id then return C end
    end
end

--- 1 % roll – simulates a human misclick.
local function misroll()
    return math.random() < .01
end

--- Pick a random card that is NOT in a given set of ids.
local function randomCardNotIn(ids)
    local pool = {}
    for _, C in ipairs(CD) do
        if not C.lock and not TABLE.find(ids, C.id) then
            pool[#pool + 1] = C
        end
    end
    if #pool == 0 then return nil end
    return pool[math.random(#pool)]
end

-- ── Menu phase ────────────────────────────────

function Bot._updateMenu()
    -- First run: no quests exist yet; pick a starter set & go
    if #GAME.quests == 0 then
        local dc = Daily.combo
        applyCombo(dc)
        -- If nothing to select (all locked or all active), just start
        if not TASK.getLock('cannotStart') then
            Bot._schedule(.42)
            GAME.start()
            Bot.actions = 0
        end
        return
    end

    local q1 = GAME.quests[1].combo
    -- applyCombo(q1)

    -- 1. Activate required cards
    for _, id in ipairs(q1) do
        if M[id] == 0 then
            local C = findCard(id)
            if C and not C.lock then
                C:setActive(true, math.random(1, 2))
                Bot._schedule()
                return
            end
        end
    end

    -- 2. De-activate cards not in the quest
    for _, C in ipairs(CD) do
        if C.active and not TABLE.find(q1, C.id) then
            C:setActive(true, 1)
            Bot._schedule()
            return
        end
    end

    -- 3. All set – start the run
    if allSelected(q1) then
        Bot._schedule(.42)
        if math.random() < .25 and not URM then
            toggleUltra()
        end
        GAME.start()
        Bot.actions = 0
    end
end

-- ── In-game phase ─────────────────────────────

--- Check if a card should stay active (required for quest 1, or quest 2 in DP).
local function cardShouldBeActive(C)
    if M.DP == 2 then
        if C.required2 then
            return true
        else
            return false
        end
    else
        if C.required then
            return true
        else
            return false
        end
    end
end

function Bot._updatePlaying()
    if #GAME.quests == 0 then return end

    -- 1. Activate required cards that aren't flipped yet (with 1 % misclick)
    for _, C in ipairs(CD) do
        if cardShouldBeActive(C) and not C.active then
            -- if misroll() then
            --     local wrong = randomCardNotIn({ C.id })
            --     if wrong and not cardShouldBeActive(wrong) then
            --         wrong:setActive(true)
            --         Bot._schedule()
            --         return
            --     end
            -- end
            if not GAME.playing then
                return
            end
            -- C:setActive(false)
            if M.VL == 2 then
                for i = 1, 4 do
                    C:setActive(false)
                    Bot.actions = Bot.actions + 1
                    Bot._schedule(Bot.delay / 2)
                    return
                end
            elseif M.VL == 1 then
                for i = 1, 2 do
                    C:setActive(false)
                    Bot.actions = Bot.actions + 1
                    Bot._schedule(Bot.delay / 2)
                    return
                end
            else
                C:setActive(false)
                Bot.actions = Bot.actions + 1
            end
            Bot._schedule()
            return
        end
    end

    -- 2. De-activate cards that are active but NOT needed (unless NH prevents it)
    --    (bot uses auto=true, bypassing the in-game NH lock, so this always works)
    if M.NH ~= 1 then
        for _, C in ipairs(CD) do
            if not GAME.playing then
                return
            end
            if C.active and not cardShouldBeActive(C) then
                -- if misroll() then
                --     Bot._schedule()
                --     return
                -- end
                if M.VL == 2 then
                    for i = 1, 4 do
                        C:setActive(false)
                        Bot.actions = Bot.actions + 1
                        Bot._schedule(Bot.delay / 2)
                        return
                    end
                else
                    C:setActive(false)
                    Bot.actions = Bot.actions + 1
                end
                Bot._schedule()
                return
            end
        end
    end

    -- 3. If AS is active and a required card has a burn, wait for burn to clear
    -- if M.AS == 1 then
    --     for _, C in ipairs(CD) do
    --         if not GAME.playing then
    --             return
    --         end
    --         if cardShouldBeActive(C) and C.burn then
    --             Bot._schedule(.05)
    --             return
    --         end
    --     end
    -- end

    -- 4. Commit when everything is ready
    --
    if not GAME.playing then
        return
    end
    if M.VL == 2 and GAME.isUltraRun then
        for i = 1, 4 do
            GAME.commit()
            Bot.actions = Bot.actions + 1
            Bot._schedule(Bot.delay / 2)
            return
        end
    else
        GAME.commit()
        Bot.actions = Bot.actions + 1
    end
    Bot._schedule(.26)
end

return Bot
