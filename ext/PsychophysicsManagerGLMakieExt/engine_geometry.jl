# The GLMakie stimulus engine for stimuli rendered into a pixel buffer. It owns
# the window, the buffer, and the presentation timing; the pixels themselves
# come from the headless rasterizers (`render_stimulus!`) and the key mapping
# from `input.jl`.

"""
    GeometryVisualEngine

GLMakie engine for the stimuli the headless core rasterizes: the marker layouts
of `MarkerLayout`, shown until the participant answers, and the
two-interval Gabor sequence of `Gabor` (see `docs/STIMULI.md`). Renders
into a pixel buffer for exact 1:1 pixel control.

After a [`preview_stimulus`](@ref), Esc closes the window; during a session it does
not, since the trial under way would wait for an answer from a window that is gone.
"""
mutable struct GeometryVisualEngine <: AbstractStimulusEngine
    fig::Figure
    screen::Union{Nothing, GLMakie.Screen}
    screen_img::Observable{Matrix{RGBf}}
    canvas_buffer::Matrix{RGBf}
    response_channel::Channel{Tuple{Int, Float64}}
    timeout_s::Union{Nothing, Float64}   # response window, set by the Core
    min_response_s::Float64              # presses sooner after onset are dropped
    frame_period_s::Float64              # how often the render loop takes a new frame
    closable::Bool                       # Esc closes the window: after a preview only
    message_text::Observable{String}     # a participant message drawn over the buffer
    message_color::Observable{RGBf}

    function GeometryVisualEngine()
        engine = new()
        engine.screen = nothing
        engine.timeout_s = nothing
        engine.min_response_s = 0.0
        engine.closable = false
        return engine
    end
end

function close_engine!(engine::GeometryVisualEngine)
    screen = engine.screen
    engine.screen = nothing
    # `close(screen)` would keep the window for GLMakie's next screen, still
    # fullscreen on its monitor; `destroy!` (internal to GLMakie) frees it. A window
    # `GLMakie.closeall()` has destroyed already must not be destroyed again.
    screen === nothing || GLMakie.was_destroyed(screen.glscreen) || GLMakie.destroy!(screen)
    return nothing
end

# Closed by Esc, by the window manager, or by `close_engine!`
Base.isopen(engine::GeometryVisualEngine) = engine.screen !== nothing && isopen(engine.screen)

# Nothing waits on a preview's window, so the person looking at it may close it
function preview_stimulus(engine::GeometryVisualEngine, stim_par::AbstractStimulusParameters,
                          values::AbstractVector{<:Real})
    invoke(preview_stimulus,
           Tuple{AbstractStimulusEngine, AbstractStimulusParameters, AbstractVector{<:Real}},
           engine, stim_par, values)
    engine.closable = true
    return nothing
end

# This engine owns its keyboard, so the Core tells it the session's response
# window instead of a response source, and the console what its keys mean
set_response_timeout!(engine::GeometryVisualEngine, timeout_s) =
    (engine.timeout_s = timeout_s; nothing)
set_min_response_time!(engine::GeometryVisualEngine, min_s) =
    (engine.min_response_s = Float64(min_s); nothing)
earliest_response(engine::GeometryVisualEngine, t_onset::Float64) =
    engine.min_response_s > 0 ? t_onset + engine.min_response_s : nothing
reads_response_keys(::GeometryVisualEngine) = true

function initialize_engine(::Type{GeometryVisualEngine}, stim_params::MarkerLayout,
                           config::DisplayConfig)
    engine = GeometryVisualEngine()
    open_stimulus_window!(engine, config)
    return engine
end

"""
    open_stimulus_window!(engine::GeometryVisualEngine, config::DisplayConfig) -> engine

Internal to this extension: creates the engine's figure, pixel buffer, and
response channel, then shows the window on the configured monitor. Users
construct the engine through `initialize_engine`, never by opening its window
themselves.
"""
function open_stimulus_window!(engine::GeometryVisualEngine, config::DisplayConfig)
    monitor = resolve_monitor(available_monitors(), config)
    mode = GLFW.GetVideoMode(monitor)

    window_size = config.fullscreen ? (mode.width, mode.height) : config.window_size
    engine.fig = Figure(
        backgroundcolor = :black,
        size = window_size,
        fxaa = false
    )

    engine.canvas_buffer = fill(RGBf(0, 0, 0), window_size...)
    engine.screen_img = Observable(engine.canvas_buffer)
    image!(engine.fig.scene, engine.screen_img, interpolate = false)

    engine.message_text = Observable("")
    engine.message_color = Observable(RGBf(1, 1, 1))
    pos = lift(vp -> Point2f(vp.widths[1] / 2, vp.widths[2] / 2), engine.fig.scene.viewport)
    fs = lift(vp -> Float32(vp.widths[2]) / 30f0, engine.fig.scene.viewport)
    wrap_w = lift(vp -> Float32(vp.widths[1]) * 0.7f0, engine.fig.scene.viewport)
    vis = lift(!isempty, engine.message_text)
    text!(engine.fig.scene, pos;
          text = engine.message_text,
          color = engine.message_color,
          align = (:center, :center),
          space = :pixel,
          fontsize = fs,
          word_wrap_width = wrap_w,
          visible = vis)

    engine.response_channel = Channel{Tuple{Int, Float64}}(1)
    attach_response_keys!(engine.fig, engine.response_channel)
    on(events(engine.fig).keyboardbutton) do event
        # The handler runs inside the render loop, which closing has to stop
        engine.closable && event.key == Keyboard.escape && event.action == Keyboard.press &&
            @async close_engine!(engine)
    end

    screen = display(stimulus_screen(config.title, config.fullscreen), engine.fig)
    engine.screen = screen
    engine.frame_period_s = 1 / screen.config.framerate

    sleep(0.2)
    placed = place_window!(screen, monitor; fullscreen = config.fullscreen)
    if placed && config.fullscreen
        # Re-sync the buffer to the fullscreen window size immediately
        engine.canvas_buffer = fill(RGBf(0, 0, 0), mode.width, mode.height)
        engine.screen_img[] = engine.canvas_buffer
    end

    return engine
end

# The window may have been resized, or gone fullscreen, since the buffer was made
function fit_buffer_to_window!(engine::GeometryVisualEngine)
    vp = engine.fig.scene.viewport[]
    win_w, win_h = Int(vp.widths[1]), Int(vp.widths[2])
    if size(engine.canvas_buffer) != (win_w, win_h)
        engine.canvas_buffer = fill(RGBf(0, 0, 0), win_w, win_h)
    end
    return engine.canvas_buffer
end

# The window the stimulus was shown in, for the session's environment snapshot.
# An engine whose window was never opened has no buffer to measure.
display_info(engine::GeometryVisualEngine) =
    isdefined(engine, :canvas_buffer) ?
        Dict("display_resolution" => join(size(engine.canvas_buffer), "x")) :
        Dict{String, String}()

"""
    present_message(engine::GeometryVisualEngine, message::ParticipantMessage)

Shows `message.text` in the stimulus window on the background it last showed,
and Enter, Space, ← or → dismiss it. If the window was never opened, forwards to
the active response source.
"""
function present_message(engine::GeometryVisualEngine, message::ParticipantMessage)
    if !isdefined(engine, :fig) || engine.screen === nothing
        return invoke(present_message, Tuple{AbstractStimulusEngine, ParticipantMessage},
                      engine, message)
    end

    engine.closable = false
    # The corner holds the background the window last showed — grey for the Gabor,
    # black for marker layouts — so the message leaves the adaptation level as it was
    bg = engine.canvas_buffer[1, 1]
    fit_buffer_to_window!(engine)
    fill!(engine.canvas_buffer, bg)
    engine.screen_img[] = engine.canvas_buffer

    mean_rgb = (Float64(bg.r) + Float64(bg.g) + Float64(bg.b)) / 3
    engine.message_color[] = mean_rgb < 0.7 ? RGBf(1, 1, 1) : RGBf(0, 0, 0)
    engine.message_text[] = message.text
    yield()
    try
        await_message_key(engine.response_channel, message)
    finally
        engine.message_text[] = ""
    end
    return nothing
end

# ── Marker layouts ───────────────────────────────────────────────────────────

function present_stimulus(engine::GeometryVisualEngine, stim_params::MarkerLayout,
                          indep_var_vals::AbstractVector{<:Number})
    engine.closable = false
    # Independent variables and method-owned values (e.g. Diff) are already
    # bound into stim_params by the Core loop; this engine only renders once
    # and returns one raw response. Re-presentation is driven by the Core.

    # --- Drawing ---
    # The pixels themselves are computed by the headless rasterizer, so the
    # rendered layout is unit-tested without a window; this
    # engine only owns the buffer, the window, and the timing.
    render_stimulus!(fit_buffer_to_window!(engine), stim_params;
                     on = RGBf(1, 1, 1), off = RGBf(0, 0, 0))

    engine.screen_img[] = engine.canvas_buffer
    yield()
    # Best available onset estimate: after the draw call was issued, not
    # confirmed by the display's vertical sync.
    t_onset = time()

    # --- Wait for one raw response (-1/0/+1 from the keyboard handler) ---
    reply = await_channel_response(engine.response_channel, engine.timeout_s;
                                   earliest = earliest_response(engine, t_onset))
    reply === nothing &&
        return PresentationResult(response = :timeout, onset = t_onset)

    resp, t_resp = reply
    return PresentationResult(response = resp, onset = t_onset,
                              timestamp_response = t_resp)
end

# ── Two-interval Gabor ───────────────────────────────────────────────────────

function initialize_engine(::Type{GeometryVisualEngine}, stim_params::Gabor,
                           config::DisplayConfig)
    engine = GeometryVisualEngine()
    open_stimulus_window!(engine, config)
    # The participant adapts to the grey of the sequence, not to a black window
    show_frame!(engine, stim_params, 0)
    return engine
end

grey_pixel(level) = RGBf(level, level, level)

# One frame of the two-interval sequence, handed to the render loop. The buffer
# is redrawn in place, so the frame before it must already have been drawn: the
# duration check in `present_stimulus` is what makes sure it has.
function show_frame!(engine::GeometryVisualEngine, stim_params::Gabor,
                     interval::Integer)
    render_stimulus!(fit_buffer_to_window!(engine), stim_params;
                     interval, pixel = grey_pixel)
    engine.screen_img[] = engine.canvas_buffer
    yield()
    return nothing
end

function present_stimulus(engine::GeometryVisualEngine, stim_params::Gabor,
                          indep_var_vals::AbstractVector{<:Number})
    engine.closable = false
    validate_gabor(stim_params)
    # The render loop takes a new frame only on its own ticks. An interval or a
    # pause shorter than two of them might never be drawn, and the trial would
    # be scored against a patch the participant was not shown.
    shortest_ms = min(stim_params.interval_ms, stim_params.isi_ms)
    frame_ms = round(1000 * engine.frame_period_s, digits = 1)
    shortest_ms >= 2 * 1000 * engine.frame_period_s || throw(ArgumentError(
        "An interval or pause of $shortest_ms ms is shorter than two frames of this " *
        "window's render loop ($frame_ms ms each), so it might not be shown at all. " *
        "Lengthen it, or present through an engine with frame-locked timing."))

    # Durations are slept, not counted in frames: each frame appears at the
    # render loop's first tick after it was handed over (docs/STIMULI.md)
    show_frame!(engine, stim_params, 0)
    sleep(stim_params.leading_blank_ms / 1000)
    show_frame!(engine, stim_params, 1)
    t_onset = time()
    sleep(stim_params.interval_ms / 1000)
    show_frame!(engine, stim_params, 0)
    sleep(stim_params.isi_ms / 1000)
    show_frame!(engine, stim_params, 2)
    sleep(stim_params.interval_ms / 1000)
    show_frame!(engine, stim_params, 0)

    # A key pressed before the second interval was over is not an answer about
    # it, so the wait for one starts from an empty channel
    while isready(engine.response_channel)
        take!(engine.response_channel)
    end
    reply = await_channel_response(engine.response_channel, engine.timeout_s;
                                   earliest = earliest_response(engine, t_onset))
    reply === nothing &&
        return PresentationResult(response = :timeout, onset = t_onset)

    resp, t_resp = reply
    return PresentationResult(response = resp, onset = t_onset,
                              timestamp_response = t_resp)
end
