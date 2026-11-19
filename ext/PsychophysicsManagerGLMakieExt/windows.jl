# GLFW window management: which monitor a window lands on, where it is placed,
# the dedicated GLMakie screen of the stimulus window, and GLMakie's check of the
# current OpenGL context. Nothing here knows about stimuli, sessions, or responses.

"""
    available_monitors() -> Vector{GLFW.Monitor}

Initializes GLFW and returns every monitor it reports, printing the list. The
listing is deliberate: GLFW's monitor order need not match the operating
system's, so an operator configuring `screen_idx` has to see the order *this*
process sees.
"""
function available_monitors()
    GLFW.Init()
    monitors = GLFW.GetMonitors()
    for (i, monitor) in enumerate(monitors)
        mode = GLFW.GetVideoMode(monitor)
        println("  [Monitor $i] ", GLFW.GetMonitorName(monitor),
                " ($(mode.width)x$(mode.height))")
    end
    return monitors
end

"""
    resolve_monitor(monitors, config::DisplayConfig) -> GLFW.Monitor

The monitor the configuration asks for, announced on the console.
"""
function resolve_monitor(monitors, config::DisplayConfig)
    names = String[GLFW.GetMonitorName(m) for m in monitors]
    monitor = monitors[select_monitor_index(names, config.screen_idx, config.screen_name)]
    println("  [Monitor] Selected: ", GLFW.GetMonitorName(monitor))
    return monitor
end

# ── Dedicated screens ────────────────────────────────────────────────────────
# A window must never share the singleton GLMakie screen: a later plain
# `display(fig)` would replace its content instead of opening a second window.
# The stimulus window therefore gets a screen of its own.

stimulus_screen(title::AbstractString, fullscreen::Bool) = GLMakie.Screen(;
    decorated = !fullscreen,
    focus_on_show = true,
    px_per_unit = 1.0,
    title = title,
)

# Most recently placed stimulus window, used by single-screen focus transitions.
const STIMULUS_WINDOW = Ref{Union{Nothing, GLFW.Window}}(nothing)

"""
    place_window!(screen, monitor; fullscreen) -> Bool

Moves an already displayed window onto `monitor`: borderless fullscreen at the
monitor's video mode, or offset slightly from the monitor's top-left corner.
Returns whether positioning succeeded — a caller that has to resize its own
buffers to match the fullscreen window must not do so when this failed.
"""
function place_window!(screen, monitor; fullscreen::Bool)
    window = screen.glscreen
    STIMULUS_WINDOW[] = window
    try
        position = GLFW.GetMonitorPos(monitor)
        GLFW.SetWindowPos(window, position.x + 50, position.y + 50)
        if fullscreen
            # GNOME under Wayland makes an X11 window fullscreen on the monitor it is on,
            # whichever one SetWindowMonitor names, so it is moved there first
            sleep(0.3)
            mode = GLFW.GetVideoMode(monitor)
            # SetWindowMonitor(window, monitor, xpos, ypos, width, height, refreshRate)
            GLFW.SetWindowMonitor(window, monitor, 0, 0,
                                  mode.width, mode.height, mode.refreshrate)

            # CRITICAL: force Makie to notice the new window size before the
            # first trial is presented
            yield()
            sleep(0.1)
            yield()
        end
        return true
    catch e
        @warn "Manual window positioning failed: $e"
        return false
    end
end

# ── The current OpenGL context ───────────────────────────────────────────────
# GLMakie records which OpenGL context is current in a variable and, for a GLFW
# window, trusts it. Another library in the process that makes its own context
# current — the Dear ImGui dashboard does, every frame — leaves the record stale,
# and GLMakie then draws or uploads textures into that library's context. Asking
# GLFW as well makes the check true only when it is. This adds a method to another
# package's function for another package's type: it belongs in GLMakie, beside
# its `native_switch_context!(::GLFW.Window)`, and goes once GLMakie has it.
ShaderAbstractions.is_current_context(window::GLFW.Window) =
    window == ShaderAbstractions.ACTIVE_OPENGL_CONTEXT[] &&
    GLFW.GetCurrentContext().handle == window.handle

# ── Display backend (window cleanup before results plots) ────────────────────

struct GLMakieDisplayBackend <: PsychophysicsManager.DisplayBackend end

# Raises and focuses the stimulus window without moving, resizing, or recreating it.
# GLFW.jl does not wrap `glfwFocusWindow`, so call libglfw directly. On native Wayland
# focusing without user interaction raises a GLFWError; log and continue.
function focus_stimulus_glfw_window!(window::GLFW.Window)
    GLMakie.was_destroyed(window) && return nothing
    try
        GLFW.GetWindowAttrib(window, GLFW.ICONIFIED) != 0 && GLFW.RestoreWindow(window)
        GLFW.GetWindowAttrib(window, GLFW.VISIBLE) == 0 && GLFW.ShowWindow(window)
        ccall((:glfwFocusWindow, GLFW.libglfw), Cvoid, (Ptr{Cvoid},), window.handle)
    catch err
        @warn "Could not focus stimulus window" exception = err
    end
    return nothing
end

function PsychophysicsManager.focus_stimulus_window!(::GLMakieDisplayBackend)
    window = STIMULUS_WINDOW[]
    window === nothing && return nothing
    if GLMakie.was_destroyed(window)
        STIMULUS_WINDOW[] = nothing
        return nothing
    end
    focus_stimulus_glfw_window!(window)
    return nothing
end

function close_all_windows(::GLMakieDisplayBackend)
    STIMULUS_WINDOW[] = nothing
    GLMakie.closeall()
    GLMakie.activate!(
        fullscreen = false,
        decorated = true,
        focus_on_show = true,
        px_per_unit = 1.0
    )
    return nothing
end
