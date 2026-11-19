# A render-only engine that draws into a buffer instead of onto a screen, so a
# programmatic participant can be shown the very pixels a human participant
# would see. Included after `Stimuli/` because it dispatches on concrete
# stimulus descriptions.
#
# It owns no device and captures no input: the response comes from the active
# response source, which for a model observer reads the buffer
# back out of the `TrialContext`.

"""
    OffscreenVisualEngine(width, height)

Headless visual engine: rasterizes a stimulus into a `width`×`height` `Bool`
canvas through the same [`render_stimulus!`](@ref) used by the on-screen engine,
and reports that canvas through [`last_frame`](@ref).

The canvas size is the observer's viewing conditions, uncalibrated like display
luminance for a human participant (see `docs/AI_OBSERVER.md`).
"""
mutable struct OffscreenVisualEngine <: AbstractStimulusEngine
    canvas::Matrix{Bool}
    presented::Bool
end

function OffscreenVisualEngine(width::Integer, height::Integer)
    (width > 0 && height > 0) ||
        throw(ArgumentError("Canvas size must be positive, got ($width, $height)."))
    return OffscreenVisualEngine(fill(false, width, height), false)
end

canvas_size(engine::OffscreenVisualEngine) = size(engine.canvas)

function initialize_engine(::Type{OffscreenVisualEngine},
                           stim_params::AbstractStimulusParameters,
                           config::DisplayConfig)
    return OffscreenVisualEngine(config.window_size...)
end

function present_stimulus(engine::OffscreenVisualEngine, stim_params::MarkerLayout,
                          indep_var_vals::AbstractVector{<:Number})
    # The independent variables are already bound into stim_params by the Core
    # loop; this engine only rasterizes and stamps the onset.
    render_stimulus!(engine.canvas, stim_params)
    engine.presented = true
    return PresentationResult(onset = time())
end

function present_stimulus(engine::OffscreenVisualEngine,
                          stim_params::AbstractStimulusParameters,
                          indep_var_vals::AbstractVector{<:Number})
    error("OffscreenVisualEngine cannot rasterize $(typeof(stim_params)). It renders " *
          "marker layouts; add a `render_stimulus!` method and a `present_stimulus` " *
          "method for the new stimulus type, or use an engine that owns its own device.")
end

last_frame(engine::OffscreenVisualEngine) = engine.presented ? engine.canvas : nothing

display_info(engine::OffscreenVisualEngine) =
    Dict("display_resolution" => join(canvas_size(engine), "x"))
