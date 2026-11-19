include(joinpath(@__DIR__, "_example_setup.jl"))

using PsychophysicsManager
using GLMakie
using GLFW

requested_idx = if isempty(ARGS)
    load_display_config().screen_idx
else
    parsed = tryparse(Int, ARGS[1])
    parsed === nothing && error("Monitor index must be an integer: $(ARGS[1])")
    parsed
end

GLFW.Init()
monitors = GLFW.GetMonitors()
isempty(monitors) && error("GLFW did not detect any monitors.")

target_idx = clamp(requested_idx, 1, length(monitors))
if target_idx != requested_idx
    @warn "Requested monitor $requested_idx is unavailable; using monitor $target_idx."
end

target_monitor = monitors[target_idx]
m_pos = GLFW.GetMonitorPos(target_monitor)
m_mode = GLFW.GetVideoMode(target_monitor)

println("\n=========================================")
println("          DISPLAY BITMAP TEST            ")
println("=========================================")
println("Monitor $target_idx: $(GLFW.GetMonitorName(target_monitor))")
println("Resolution: $(m_mode.width)x$(m_mode.height)")
println("Position: $(m_pos.x), $(m_pos.y)")
println("=========================================")

GLMakie.activate!(
    fullscreen = false,
    decorated = false,
    focus_on_show = true,
    px_per_unit = 1.0,
    title = "PsychophysicsManager Display Bitmap Test",
)
fig = Figure(
    backgroundcolor = :black,
    size = (m_mode.width, m_mode.height),
    fxaa = false,
)

canvas = fill(RGBf(0, 0, 0), m_mode.width, m_mode.height)
canvas[1:10, :] .= RGBf(1, 1, 1)
canvas[end-9:end, :] .= RGBf(1, 1, 1)
canvas[:, 1:10] .= RGBf(1, 1, 1)
canvas[:, end-9:end] .= RGBf(1, 1, 1)
mid_x, mid_y = div(m_mode.width, 2), div(m_mode.height, 2)
canvas[(mid_x-5):(mid_x+5), :] .= RGBf(1, 1, 1)
canvas[:, (mid_y-5):(mid_y+5)] .= RGBf(1, 1, 1)

img_obs = Observable(canvas)
image!(fig.scene, img_obs; interpolate = false)
campixel!(fig.scene)

screen = display(fig)

sleep(1.0)
try
    win = screen.glscreen
    GLFW.SetWindowPos(win, m_pos.x, m_pos.y)
    println("Moved borderless window to $(m_pos.x),$(m_pos.y)")
catch err
    @warn "Window positioning failed" exception = (err, catch_backtrace())
end

println("\nCheck the selected monitor:")
println("1. Is the background pure black with a white border and cross?")
println("2. Does the pattern cover the expected display area without scaling?")
wait_for_enter()

GLMakie.closeall()
