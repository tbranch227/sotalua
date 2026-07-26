-- core/fx.lua -- time-based animation for retained widgets.
--
-- Everything here is built from the only things the host actually animates:
-- a widget's position, size, scale, rotation, colour and alpha, stepped once
-- per frame. There are no particles, no shaders and no shapes beyond
-- rectangles, so an "effect" is a rectangle whose properties change over time.
--
-- ShroudDeltaTime is the right clock for this. It is clamped at the project's
-- maximum timestep (~0.1s), which the reference says is "correct for pacing
-- animation, wrong for measuring stalls" -- exactly the trade wanted here,
-- since a stalled frame should not teleport an animation to its end.
--
-- Cost control matters: this runs in ShroudOnUpdate, under the host's 1 second
-- callback watchdog. The update hook does nothing at all when no tween is
-- active, tweens self-remove on completion, and the total is capped.

return function(M)
    local F = {}

    local MAX_ACTIVE = 64

    local active = {}
    local installed = false
    local nextHandle = 0

    ----------------------------------------------------------------------
    -- Easing
    ----------------------------------------------------------------------

    F.ease = {}

    function F.ease.linear(t) return t end
    function F.ease.inQuad(t) return t * t end
    function F.ease.outQuad(t) return 1 - (1 - t) * (1 - t) end

    function F.ease.inOutQuad(t)
        if t < 0.5 then return 2 * t * t end
        return 1 - (-2 * t + 2) ^ 2 / 2
    end

    function F.ease.outCubic(t) return 1 - (1 - t) ^ 3 end

    --- Overshoots past the target and settles back. Good for anything that
    --- should feel like it landed rather than arrived.
    function F.ease.outBack(t)
        local c1, c3 = 1.70158, 2.70158
        return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
    end

    function F.ease.inOutSine(t)
        return -(math.cos(math.pi * t) - 1) / 2
    end

    --- Up and back down within one unit of time. For pulses and flashes, where
    --- the value must return to where it started.
    function F.ease.pingPong(t)
        if t < 0.5 then return t * 2 end
        return (1 - t) * 2
    end

    ----------------------------------------------------------------------
    -- The tween loop
    ----------------------------------------------------------------------

    local function step()
        local count = #active
        if count == 0 then return end

        local dt = ShroudDeltaTime or 0.016
        -- Walk backwards so a completed tween can be removed in place.
        for i = count, 1, -1 do
            local tween = active[i]
            tween.elapsed = tween.elapsed + dt

            local t = tween.duration > 0 and (tween.elapsed / tween.duration) or 1
            local finished = t >= 1
            if finished then t = 1 end

            local eased = tween.ease(t)
            if tween.onUpdate then
                tween.onUpdate(tween.from + (tween.to - tween.from) * eased, eased, t)
            end

            if finished then
                if tween.loops and tween.loops > 1 then
                    tween.loops = tween.loops - 1
                    tween.elapsed = 0
                else
                    table.remove(active, i)
                    if tween.onComplete then tween.onComplete() end
                end
            end
        end
    end

    --- Subscribe the stepper. Called once by core/addon; safe to call again.
    function F.install()
        if installed then return F end
        installed = true
        M.events.on("ShroudOnUpdate", step, "fx.step")
        M.events.on("ShroudOnDisableScript", F.cancelAll, "fx.cancelOnDisable")
        return F
    end

    --- Animate a number from `from` to `to` over `duration` seconds.
    --
    -- opts: from, to, duration, ease, loops, onUpdate(value, eased, raw),
    -- onComplete. Returns a handle for fx.cancel, or nil when the cap is hit.
    function F.tween(opts)
        if #active >= MAX_ACTIVE then
            -- Dropping the newest is the right failure: an effect that never
            -- starts is invisible, while starving the running ones leaves
            -- widgets frozen mid-animation in a wrong state.
            M.log.debug("fx: too many active tweens, dropping one")
            return nil
        end

        nextHandle = nextHandle + 1
        local tween = {
            handle = nextHandle,
            from = opts.from or 0,
            to = opts.to or 1,
            duration = math.max(opts.duration or 0.3, 0),
            ease = opts.ease or F.ease.outQuad,
            loops = opts.loops,
            elapsed = 0,
            onUpdate = opts.onUpdate and M.env.protect("fx.onUpdate", opts.onUpdate) or nil,
            onComplete = opts.onComplete and M.env.protect("fx.onComplete", opts.onComplete) or nil,
        }
        active[#active + 1] = tween
        return tween.handle
    end

    function F.cancel(handle)
        for i, tween in ipairs(active) do
            if tween.handle == handle then
                table.remove(active, i)
                return true
            end
        end
        return false
    end

    function F.cancelAll()
        active = {}
        return true
    end

    function F.activeCount() return #active end

    ----------------------------------------------------------------------
    -- Effects
    ----------------------------------------------------------------------

    --- Fade a widget's alpha.
    function F.fade(widget, from, to, duration, onComplete)
        if not widget then return nil end
        M.ui.setAlpha(widget, from)
        return F.tween({
            from = from, to = to, duration = duration or 0.3,
            ease = F.ease.outQuad,
            onUpdate = function(value) M.ui.setAlpha(widget, value) end,
            onComplete = onComplete,
        })
    end

    --- Flash a widget to a colour and back to its resting one.
    function F.flash(widget, flashColor, restColor, duration)
        if not widget then return nil end
        duration = duration or 0.4
        return F.tween({
            from = 0, to = 1, duration = duration,
            ease = F.ease.pingPong,
            onUpdate = function(_, eased)
                M.ui.setColor(widget, M.util.mixHex(restColor, flashColor, eased))
            end,
            onComplete = function() M.ui.setColor(widget, restColor) end,
        })
    end

    --- Pulse alpha between two values, `cycles` times.
    function F.pulse(widget, low, high, period, cycles)
        if not widget then return nil end
        return F.tween({
            from = 0, to = 1, duration = period or 0.8,
            ease = F.ease.pingPong,
            loops = cycles or 3,
            onUpdate = function(_, eased)
                M.ui.setAlpha(widget, low + (high - low) * eased)
            end,
            onComplete = function() M.ui.setAlpha(widget, low) end,
        })
    end

    --- Jitter a widget around its current position.
    --
    -- Reads the position once and restores it exactly, so a shake interrupted
    -- by a reload cannot leave a window drifted from where the player put it.
    function F.shake(widget, magnitude, duration)
        if not widget then return nil end
        local originX, originY = M.ui.getPosition(widget)
        if not originX then return nil end
        magnitude = magnitude or 6

        local seed = 0
        return F.tween({
            from = 1, to = 0, duration = duration or 0.35,
            ease = F.ease.outQuad,
            onUpdate = function(strength)
                -- A cheap deterministic wobble; Math.random is unavailable in
                -- some hosts and a fixed pattern is indistinguishable here.
                seed = seed + 1
                local offsetX = math.sin(seed * 2.7) * magnitude * strength
                local offsetY = math.cos(seed * 3.9) * magnitude * strength
                M.ui.setPosition(widget, originX + offsetX, originY + offsetY)
            end,
            onComplete = function() M.ui.setPosition(widget, originX, originY) end,
        })
    end

    --- Slide a widget to an absolute position.
    function F.slideTo(widget, toX, toY, duration, ease)
        if not widget then return nil end
        local fromX, fromY = M.ui.getPosition(widget)
        if not fromX then return nil end
        return F.tween({
            from = 0, to = 1, duration = duration or 0.35,
            ease = ease or F.ease.outCubic,
            onUpdate = function(_, eased)
                M.ui.setPosition(widget,
                    fromX + (toX - fromX) * eased,
                    fromY + (toY - fromY) * eased)
            end,
        })
    end

    --- Grow or shrink a widget. Scale is uniform; the host takes one factor.
    function F.scale(widget, from, to, duration, ease)
        if not widget then return nil end
        return F.tween({
            from = from, to = to, duration = duration or 0.25,
            ease = ease or F.ease.outBack,
            onUpdate = function(value) M.ui.setScale(widget, value) end,
        })
    end

    --- Spin a widget to an absolute angle. ShroudRotateObject sets rather than
    --- accumulates, so the tween drives the absolute value.
    function F.spin(widget, fromDegrees, toDegrees, duration, ease)
        if not widget then return nil end
        return F.tween({
            from = fromDegrees, to = toDegrees, duration = duration or 0.6,
            ease = ease or F.ease.inOutQuad,
            onUpdate = function(value) M.ui.setRotation(widget, value) end,
        })
    end

    --- A masked wipe: slide a child across its parent's clipping rectangle.
    --
    -- Panels are created with a Mask already attached, so a child moved beyond
    -- the panel's bounds is clipped rather than overflowing. That is the only
    -- way to get a reveal without shipping artwork.
    function F.wipe(child, width, duration, reverse)
        if not child then return nil end
        local _, y = M.ui.getPosition(child)
        if not y then return nil end
        return F.tween({
            from = reverse and 0 or -width, to = reverse and -width or 0,
            duration = duration or 0.4,
            ease = F.ease.outCubic,
            onUpdate = function(value) M.ui.setPosition(child, value, y) end,
        })
    end

    return F
end
