-- GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
-- Madeira LOVE smoke test: does a LOVE window open and keep presenting frames?
function love.conf(t)
    t.identity = "madeira-love-tests"
    t.version = "11.5"
    t.console = false
    t.window.title = "Madeira LOVE hello"
    t.window.width = 960
    t.window.height = 540
    t.window.vsync = 1
end
