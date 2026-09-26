-- GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
-- Madeira LOVE test suite.
--
-- Runs a fixed sequence of stages, each checking one piece of the stack
-- (OpenGL ES through winios, the audio driver, window handling, input) and
-- logging PASS / FAIL / INFO lines to results.txt in the save directory (see
-- ../README.md). Rendering checks draw into an offscreen canvas and read the
-- pixels back, so they judge the GPU output rather than a person squinting at
-- the screen. Every stage runs under pcall: one failure never stops the run.

local W, H = 960, 540
local LOG = "results.txt"

local font_small, font_big
local stages, current, stage_time, stage_frames = {}, 0, 0, 0
local results = {}
local status_line = ""

-- ---------------------------------------------------------------- logging

local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print(line)
    love.filesystem.append(LOG, line .. "\n")
end

local function record(kind, name, detail)
    results[#results + 1] = { kind = kind, name = name, detail = detail or "" }
    log("[%s] %s %s", kind, name, detail or "")
end

local function pass(name, detail) record("PASS", name, detail) end
local function fail(name, detail) record("FAIL", name, detail) end
local function info(name, detail) record("INFO", name, detail) end

-- ---------------------------------------------------------------- pixels

local function near(a, b, tol) return math.abs(a - b) <= (tol or 0.03) end

-- Returns ok, description for pixel (x, y) of ImageData `img`.
local function pixel_is(img, x, y, r, g, b, a, tol)
    local pr, pg, pb, pa = img:getPixel(x, y)
    a = a or 1
    local ok = near(pr, r, tol) and near(pg, g, tol) and near(pb, b, tol) and near(pa, a, tol)
    return ok, string.format("(%d,%d)=%.2f,%.2f,%.2f,%.2f want %.2f,%.2f,%.2f,%.2f",
        x, y, pr, pg, pb, pa, r, g, b, a)
end

-- Check a list of {x, y, r, g, b[, a]} expectations; one result line per stage.
local function check_pixels(name, img, expectations, tol)
    local bad = {}
    for _, e in ipairs(expectations) do
        local ok, desc = pixel_is(img, e[1], e[2], e[3], e[4], e[5], e[6], tol)
        if not ok then bad[#bad + 1] = desc end
    end
    if #bad == 0 then pass(name, string.format("%d pixels ok", #expectations))
    else fail(name, table.concat(bad, "; ")) end
end

-- Render `fn` into a fresh canvas and return the canvas and its pixels.
local function render_to_canvas(w, h, fn, stencil)
    local canvas = love.graphics.newCanvas(w, h)
    love.graphics.push("all")
    -- Start from default state: colour, blend mode, shader and font otherwise
    -- leak in from the results overlay drawn in the previous frame.
    love.graphics.reset()
    love.graphics.setCanvas({ canvas, stencil = stencil or false })
    fn()
    love.graphics.pop()
    return canvas, canvas:newImageData()
end

-- ---------------------------------------------------------------- stages
--
-- Each stage: name, duration (seconds on screen), and optional
--   enter()          once, before the first frame
--   draw(t)          every frame while the stage is shown
--   update(t, dt)    every frame
--   finish()         once, after `duration`
--   bare = true      draw nothing over the stage (whole-window pixel checks)

local shown_canvas   -- canvas a stage wants displayed while it runs

stages[#stages + 1] = {
    name = "renderer info", duration = 1.5,
    enter = function()
        local name, version, vendor, device = love.graphics.getRendererInfo()
        info("renderer", string.format("%s | %s | %s | %s", name, version, vendor, device))
        -- Madeira has two GL backends: desktop OpenGL (Mesa Zink) and OpenGL ES (EAGL).
        if name == "OpenGL" and device and device:lower():find("zink") then pass("gl context", "desktop OpenGL via Zink " .. version)
        elseif name == "OpenGL ES" then pass("gl context", "OpenGL ES backend " .. version)
        else fail("gl context", "unexpected renderer " .. tostring(name) .. " / " .. tostring(device)) end

        local limits = love.graphics.getSystemLimits()
        info("limits", string.format("texturesize=%d multicanvas=%d canvasmsaa=%d anisotropy=%.0f",
            limits.texturesize or -1, limits.multicanvas or -1, limits.canvasmsaa or -1, limits.anisotropy or -1))

        local feats = {}
        for k, v in pairs(love.graphics.getSupported()) do feats[#feats + 1] = k .. "=" .. tostring(v) end
        table.sort(feats)
        info("features", table.concat(feats, " "))

        local formats = {}
        for k, v in pairs(love.graphics.getCanvasFormats()) do if v then formats[#formats + 1] = k end end
        table.sort(formats)
        info("canvas formats", table.concat(formats, " "))

        local dw, dh = love.window.getDesktopDimensions()
        info("window", string.format("%dx%d desktop %dx%d dpi %.2f os %s cpus %d",
            love.graphics.getWidth(), love.graphics.getHeight(), dw, dh,
            love.window.getDPIScale(), love.system.getOS(), love.system.getProcessorCount()))
    end,
}

stages[#stages + 1] = {
    name = "clear", duration = 1,
    enter = function()
        local c, img = render_to_canvas(64, 64, function() love.graphics.clear(1, 0, 0, 1) end)
        check_pixels("clear", img, { { 0, 0, 1, 0, 0 }, { 32, 32, 1, 0, 0 }, { 63, 63, 1, 0, 0 } })
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "shapes", duration = 1.5,
    enter = function()
        local c, img = render_to_canvas(128, 128, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("fill", 0, 0, 64, 64)
            love.graphics.setColor(0, 1, 0, 1)
            love.graphics.circle("fill", 96, 96, 20)
            love.graphics.setColor(0, 0, 1, 1)
            love.graphics.polygon("fill", 70, 10, 120, 10, 95, 50)
        end)
        check_pixels("shapes", img, {
            { 32, 32, 1, 1, 1 },     -- rectangle
            { 96, 96, 0, 1, 0 },     -- circle centre
            { 95, 20, 0, 0, 1 },     -- triangle
            { 10, 120, 0, 0, 0 },    -- untouched corner
        })
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "shader", duration = 1.5,
    enter = function()
        local shader = love.graphics.newShader([[
            vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
                return vec4(tc.x, tc.y, 0.5, 1.0);
            }
        ]])
        local white = love.graphics.newImage(love.image.newImageData(1, 1, "rgba8", string.char(255, 255, 255, 255)))
        local c, img = render_to_canvas(128, 128, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setShader(shader)
            love.graphics.draw(white, 0, 0, 0, 128, 128)
            love.graphics.setShader()
        end)
        check_pixels("shader", img, {
            { 0, 0, 0, 0, 0.5 },
            { 127, 127, 1, 1, 0.5 },
            { 64, 0, 0.5, 0, 0.5 },
            { 0, 64, 0, 0.5, 0.5 },
        }, 0.04)
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "texture", duration = 1.5,
    enter = function()
        local data = love.image.newImageData(4, 4)
        for y = 0, 3 do
            for x = 0, 3 do
                if (x + y) % 2 == 0 then data:setPixel(x, y, 1, 0, 0, 1)
                else data:setPixel(x, y, 0, 0, 1, 1) end
            end
        end
        local tex = love.graphics.newImage(data)
        tex:setFilter("nearest", "nearest")
        local c, img = render_to_canvas(128, 128, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.draw(tex, 0, 0, 0, 32, 32)
        end)
        check_pixels("texture", img, {
            { 16, 16, 1, 0, 0 }, { 48, 16, 0, 0, 1 }, { 16, 48, 0, 0, 1 }, { 112, 112, 1, 0, 0 },
        })
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "blend", duration = 1,
    enter = function()
        local c, img = render_to_canvas(64, 64, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setBlendMode("alpha")
            love.graphics.setColor(1, 0, 0, 0.5)
            love.graphics.rectangle("fill", 0, 0, 32, 64)
            love.graphics.setBlendMode("add")
            love.graphics.setColor(0, 0.25, 0, 1)
            love.graphics.rectangle("fill", 32, 0, 32, 64)
            love.graphics.rectangle("fill", 32, 0, 32, 64)
        end)
        check_pixels("blend", img, { { 16, 32, 0.5, 0, 0 }, { 48, 32, 0, 0.5, 0 } })
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "stencil", duration = 1,
    enter = function()
        local c, img = render_to_canvas(128, 128, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.stencil(function() love.graphics.circle("fill", 64, 64, 32) end, "replace", 1)
            love.graphics.setStencilTest("greater", 0)
            love.graphics.setColor(1, 1, 0, 1)
            love.graphics.rectangle("fill", 0, 0, 128, 128)
            love.graphics.setStencilTest()
        end, true)
        check_pixels("stencil", img, { { 64, 64, 1, 1, 0 }, { 4, 4, 0, 0, 0 }, { 124, 124, 0, 0, 0 } })
        shown_canvas = c
    end,
}

stages[#stages + 1] = {
    name = "text", duration = 1.5,
    enter = function()
        local c, img = render_to_canvas(320, 80, function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setFont(font_big)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.print("MADEIRA", 8, 8)
        end)
        local lit = 0
        img:mapPixel(function(x, y, r, g, b, a)
            if r > 0.5 then lit = lit + 1 end
            return r, g, b, a
        end)
        if lit > 400 then pass("text", lit .. " glyph pixels") else fail("text", "only " .. lit .. " glyph pixels") end
        shown_canvas = c
    end,
}

-- Default framebuffer: exercises opengl32's FBO-backed default framebuffer
-- and the winios drawable, which the canvas stages never touch.
local shot
stages[#stages + 1] = {
    name = "screenshot", duration = 1, bare = true,
    enter = function()
        shot = nil
        love.graphics.captureScreenshot(function(data) shot = data end)
    end,
    draw = function() love.graphics.clear(0, 1, 0, 1) end,
    finish = function()
        if not shot then fail("screenshot", "callback never ran"); return end
        local w, h = shot:getDimensions()
        check_pixels("screenshot", shot, { { math.floor(w / 2), math.floor(h / 2), 0, 1, 0 } })
        info("screenshot size", w .. "x" .. h)
    end,
}

-- Draw-call throughput: a SpriteBatch of 2000 moving quads.
local batch, sprite
stages[#stages + 1] = {
    name = "spritebatch", duration = 4,
    enter = function()
        sprite = love.graphics.newImage(love.image.newImageData(8, 8, "rgba8", string.rep(string.char(255, 200, 80, 255), 64)))
        batch = love.graphics.newSpriteBatch(sprite, 2000, "stream")
    end,
    draw = function(t)
        batch:clear()
        for i = 1, 2000 do
            local a = i * 0.618 + t * (0.5 + (i % 7) * 0.1)
            batch:add(W / 2 + math.cos(a) * (i % 400), H / 2 + math.sin(a * 1.3) * (i % 250))
        end
        love.graphics.draw(batch)
    end,
    finish = function(frames, t)
        info("spritebatch", string.format("%d frames in %.1fs = %.1f fps (2000 sprites)", frames, t, frames / t))
    end,
}

-- Window resize: LOVE may recreate the window and GL context here, which is
-- what Balatro does at startup.
local resize_shot
stages[#stages + 1] = {
    name = "resize", duration = 2, bare = true,
    enter = function()
        local ok = love.window.setMode(1280, 720, { vsync = 1, stencil = true })
        W, H = love.graphics.getDimensions()
        info("setMode 1280x720", string.format("ok=%s now %dx%d", tostring(ok), W, H))
        resize_shot = nil
    end,
    update = function(t)
        if t > 0.5 and not resize_shot then
            resize_shot = false
            love.graphics.captureScreenshot(function(data) resize_shot = data end)
        end
    end,
    draw = function() love.graphics.clear(0, 0, 1, 1) end,
    finish = function()
        if resize_shot then
            local w, h = resize_shot:getDimensions()
            check_pixels("resize", resize_shot, { { math.floor(w / 2), math.floor(h / 2), 0, 0, 1 } })
            if w == 1280 and h == 720 then pass("resize size", w .. "x" .. h)
            else fail("resize size", "framebuffer is " .. w .. "x" .. h .. ", want 1280x720") end
        else
            fail("resize", "no screenshot after setMode")
        end
        love.window.setMode(960, 540, { vsync = 1, stencil = true })
        W, H = love.graphics.getDimensions()
    end,
}

-- Audio: a generated 1.5 s tone must actually play, i.e. the source position
-- must advance. Stalls in the audio driver show up here as tell() stuck at 0.
local source, max_tell
stages[#stages + 1] = {
    name = "audio", duration = 2.5,
    enter = function()
        local rate, len = 44100, 1.5
        local sd = love.sound.newSoundData(math.floor(rate * len), rate, 16, 1)
        for i = 0, sd:getSampleCount() - 1 do
            sd:setSample(i, 0.2 * math.sin(2 * math.pi * 440 * i / rate))
        end
        source = love.audio.newSource(sd)
        max_tell = 0
        local ok = source:play()
        info("audio device", string.format("play()=%s active=%d", tostring(ok), love.audio.getActiveSourceCount()))
    end,
    update = function()
        if source then max_tell = math.max(max_tell, source:tell("seconds")) end
    end,
    finish = function()
        if max_tell >= 0.5 then pass("audio playback", string.format("position reached %.2fs", max_tell))
        else fail("audio playback", string.format("position only reached %.2fs (driver not consuming)", max_tell)) end
        source:stop()
    end,
}

-- Input: optional, needs a person. Counts events; never fails.
local input_counts
stages[#stages + 1] = {
    name = "input (tap/click/type now)", duration = 6,
    enter = function() input_counts = { mouse = 0, touch = 0, key = 0, moved = 0 } end,
    finish = function()
        info("input", string.format("mousepressed=%d touchpressed=%d keypressed=%d mousemoved=%d",
            input_counts.mouse, input_counts.touch, input_counts.key, input_counts.moved))
    end,
}

-- ---------------------------------------------------------------- driver

local function run_hook(stage, hook, ...)
    if not stage[hook] then return end
    local ok, err = pcall(stage[hook], ...)
    if not ok then fail(stage.name .. " (" .. hook .. ")", tostring(err)) end
end

local function start_stage(i)
    current, stage_time, stage_frames, shown_canvas = i, 0, 0, nil
    local s = stages[i]
    if not s then
        local p, f = 0, 0
        for _, r in ipairs(results) do
            if r.kind == "PASS" then p = p + 1 elseif r.kind == "FAIL" then f = f + 1 end
        end
        status_line = string.format("DONE: %d passed, %d failed", p, f)
        log("== %s ==", status_line)
        return
    end
    status_line = string.format("stage %d/%d: %s", i, #stages, s.name)
    log("-- %s", status_line)
    run_hook(s, "enter")
end

function love.load()
    font_small = love.graphics.newFont(16)
    font_big = love.graphics.newFont(48)
    love.filesystem.write(LOG, "Madeira LOVE test suite " .. os.date() .. "\n")
    log("save directory: %s", love.filesystem.getSaveDirectory())
    start_stage(1)
end

function love.update(dt)
    local s = stages[current]
    if not s then return end
    stage_time = stage_time + dt
    run_hook(s, "update", stage_time, dt)
    if stage_time >= s.duration then
        run_hook(s, "finish", stage_frames, stage_time)
        start_stage(current + 1)
    end
end

function love.draw()
    local s = stages[current]
    love.graphics.clear(0.12, 0.12, 0.16, 1)
    if s then
        stage_frames = stage_frames + 1
        if s.draw then
            local ok, err = pcall(s.draw, stage_time)
            if not ok then fail(s.name .. " (draw)", tostring(err)); s.draw = nil end
        end
        if shown_canvas then
            love.graphics.setColor(1, 1, 1, 1)
            local cw, ch = shown_canvas:getDimensions()
            local scale = math.min(300 / cw, 300 / ch)
            love.graphics.draw(shown_canvas, W - cw * scale - 24, 80, 0, scale, scale)
        end
    end

    if s and s.bare then return end

    -- Status and the last results, on top of everything else.
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, W, 44)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font_small)
    love.graphics.print(status_line .. string.format("   %d fps", love.timer.getFPS()), 12, 12)
    local y = 60
    for i = math.max(1, #results - 18), #results do
        local r = results[i]
        if r.kind == "PASS" then love.graphics.setColor(0.4, 1, 0.4, 1)
        elseif r.kind == "FAIL" then love.graphics.setColor(1, 0.4, 0.4, 1)
        else love.graphics.setColor(0.7, 0.8, 1, 1) end
        love.graphics.print(string.format("%s %s  %s", r.kind, r.name, r.detail:sub(1, 70)), 12, y)
        y = y + 20
    end
end

function love.mousepressed() if input_counts then input_counts.mouse = input_counts.mouse + 1 end end
function love.mousemoved() if input_counts then input_counts.moved = input_counts.moved + 1 end end
function love.touchpressed() if input_counts then input_counts.touch = input_counts.touch + 1 end end
function love.keypressed(key)
    if input_counts then input_counts.key = input_counts.key + 1 end
    if key == "escape" then love.event.quit() end
end
