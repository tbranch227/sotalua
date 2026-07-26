-- core/modules.lua -- the load order shared by the bundler and the tests.
--
-- Dependencies are resolved lazily through the shared module table, so this
-- order only matters for module bodies that touch a sibling at load time.
-- Keeping it explicit means the bundled output and the offline harness build
-- the exact same object graph.

return {
    "util",     -- no dependencies
    "log",      -- util
    "env",      -- log
    "settings", -- env, log, util
    "events",   -- env
    "timers",   -- env, log, util
    "poll",     -- env, util
    "ui",       -- env, log, util, events
    "fx",       -- ui, events, env, util
    "layout",   -- ui, settings, timers, events, util
    "addon",    -- everything above
}
