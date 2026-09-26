-- GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
-- Madeira LOVE smoke test.
--
-- Animated background, a spinning square, text and an FPS counter. Writes
-- hello.txt to the save directory (see ../README.md) after the first frame and
-- every 5 seconds, so a pulled log shows whether frames kept coming even if
-- nobody was watching the screen.

local frames, elapsed, next_report = 0, 0, 0
local font

local function report(tag)
    local name, version, vendor, device = love.graphics.getRendererInfo()
    local line = string.format("%s frames=%d t=%.1fs fps=%d renderer=%s %s (%s, %s)\n",
        tag, frames, elapsed, love.timer.getFPS(), name, version, vendor, device)
    love.filesystem.append("hello.txt", line)
end

function love.load()
    love.filesystem.write("hello.txt", "Madeira LOVE hello " .. os.date() .. "\n")
    font = love.graphics.newFont(28)
end

function love.update(dt)
    elapsed = elapsed + dt
    if frames > 0 and elapsed >= next_report then
        report(next_report == 0 and "first" or "alive")
        next_report = next_report + 5
    end
end

function love.draw()
    frames = frames + 1
    local w, h = love.graphics.getDimensions()
    local t = elapsed

    love.graphics.clear(0.1 + 0.1 * math.sin(t), 0.15, 0.25 + 0.1 * math.cos(t * 0.7), 1)

    love.graphics.push()
    love.graphics.translate(w / 2, h / 2)
    love.graphics.rotate(t)
    love.graphics.setColor(1, 0.6, 0.1, 1)
    love.graphics.rectangle("fill", -60, -60, 120, 120)
    love.graphics.pop()

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font)
    love.graphics.print("Madeira OpenGL ES says hello", 24, 24)
    love.graphics.print(string.format("%d FPS   frame %d   %dx%d", love.timer.getFPS(), frames, w, h), 24, 64)
    local name, version = love.graphics.getRendererInfo()
    love.graphics.print(name .. " " .. version, 24, h - 48)
end

function love.keypressed(key)
    if key == "escape" then love.event.quit() end
end
