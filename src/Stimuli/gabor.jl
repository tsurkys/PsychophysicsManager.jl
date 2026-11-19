# A Gabor patch shown in one of two temporal intervals: the stimulus of a
# two-interval forced-choice contrast detection task. The pixels of every frame
# of the sequence are computed here, headless and generic in the canvas element
# type; the engine that shows them owns the window, the order of
# the frames and their timing.
#
# Canvas convention as in `render.jl`: `canvas[x, y]` with the origin at the
# canvas centre and y pointing up as displayed.

"""
    Gabor

A sinusoidal grating in a Gaussian window, shown in one of two intervals: the
stimulus of a two-interval forced-choice (2IFC) contrast detection task. A trial
is a blank lead-in, interval 1, a blank pause, interval 2, and a blank screen
while the participant answers; four black marks frame the patch location during
each interval, so an interval without the patch can be told from the pause.

`contrast` is **digital** Michelson contrast, a proportion of the framebuffer's
grey level; what it amounts to in luminance depends on a display calibration
PsychophysicsManager does not perform. `target_interval` (`1` or `2`) is declared as an
independent variable with the range `[1, 2]`, so that it is drawn per trial, and
the correct answer is `-1` for the first interval and `+1` for the second — the
codes of the left and right arrow keys.

The parameters, their units and the display's limits are described in
`docs/STIMULI.md` §6.
"""
Base.@kwdef mutable struct Gabor <: AbstractStimulusParameters
    contrast::Float64 = 0.5
    cycles_per_px::Float64 = 1 / 32
    orientation_deg::Float64 = 0.0
    phase_deg::Float64 = 0.0
    sigma_px::Float64 = 16.0
    size_px::Int = 128
    mean_luminance::Float64 = 0.5

    target_interval::Int = 1
    interval_ms::Float64 = 200.0
    isi_ms::Float64 = 500.0
    leading_blank_ms::Float64 = 500.0
end

required_variables(::Gabor) = [:target_interval => [1, 2]]

"Side of the four black marks that frame the patch location during an interval, and their offset beyond its corners."
const GABOR_CUE_PX = 4

"""
    validate_gabor(p::Gabor) -> p

Rejects a Gabor that would be drawn as something other than what it describes.
Each refused value yields a plausible picture: a carrier at or above the Nyquist
limit aliases into a coarser grating (a frequency in cycles per degree lands
here), peaks above white are clipped to a lower contrast than the one recorded,
a window cut off before it fades draws a visible square edge, and a pause of
zero between the intervals makes them one interval.

Called from [`render_stimulus!`](@ref), which every frame passes through.
"""
function validate_gabor(p::Gabor)
    0 <= p.contrast <= 1 ||
        throw(ArgumentError("contrast must be in [0, 1], got $(p.contrast)."))
    0 < p.mean_luminance < 1 || throw(ArgumentError(
        "mean_luminance must be in (0, 1), got $(p.mean_luminance)."))
    p.mean_luminance * (1 + p.contrast) <= 1 || throw(ArgumentError(
        "contrast $(p.contrast) around mean_luminance $(p.mean_luminance) reaches " *
        "above white: the peaks would be clipped and the contrast shown would be " *
        "lower than the one recorded."))
    0 < p.cycles_per_px < 0.5 || throw(ArgumentError(
        "cycles_per_px must be in (0, 0.5), got $(p.cycles_per_px): the carrier is " *
        "given in cycles per pixel, and at 0.5 or above it aliases."))
    isfinite(p.orientation_deg) ||
        throw(ArgumentError("orientation_deg must be finite, got $(p.orientation_deg)."))
    isfinite(p.phase_deg) ||
        throw(ArgumentError("phase_deg must be finite, got $(p.phase_deg)."))
    p.sigma_px > 0 ||
        throw(ArgumentError("sigma_px must be positive, got $(p.sigma_px)."))
    p.size_px >= 6 * p.sigma_px || throw(ArgumentError(
        "size_px $(p.size_px) is less than 6 * sigma_px ($(6 * p.sigma_px)): the " *
        "window would not have faded at the patch edge, and its square outline " *
        "would be visible."))
    p.target_interval in (1, 2) || throw(ArgumentError(
        "target_interval must be 1 or 2, got $(p.target_interval)."))
    p.interval_ms > 0 ||
        throw(ArgumentError("interval_ms must be positive, got $(p.interval_ms)."))
    p.isi_ms > 0 || throw(ArgumentError(
        "isi_ms must be positive, got $(p.isi_ms): without a pause the two " *
        "intervals are shown as one."))
    p.leading_blank_ms >= 0 || throw(ArgumentError(
        "leading_blank_ms must not be negative, got $(p.leading_blank_ms)."))
    return p
end

validate_stimulus(p::Gabor) = validate_gabor(p)

"""
    render_stimulus!(canvas, params::Gabor; interval = params.target_interval,
                     pixel = identity) -> canvas

Draws one frame of the two-interval sequence. `interval = 1` or `2` is that
interval: the background at `mean_luminance`, the four marks framing the patch
location, and the patch itself when this is the target interval. `interval = 0`
is the blank shown before, between and after the intervals. The default is the
frame that holds the patch.

`pixel` maps a grey level in `[0, 1]` to the canvas element type: the identity
suits a real-valued canvas, and the GLMakie engine passes `g -> RGBf(g, g, g)`.
The stimulus parameters are never mutated.
"""
function render_stimulus!(canvas::AbstractMatrix, params::Gabor;
                          interval::Integer = params.target_interval, pixel = identity)
    validate_gabor(params)
    interval in (0, 1, 2) ||
        throw(ArgumentError("interval must be 0, 1 or 2, got $interval."))

    fill!(canvas, pixel(params.mean_luminance))
    interval == 0 && return canvas

    width, height = size(canvas)
    center_x = round(Int, width / 2)
    center_y = round(Int, height / 2)
    reach_low, reach_high = fld(params.size_px, 2), cld(params.size_px, 2) - 1

    if interval == params.target_interval
        wavenumber = 2π * params.cycles_per_px
        cos_theta, sin_theta = cosd(params.orientation_deg), sind(params.orientation_deg)
        phase = deg2rad(params.phase_deg)
        two_variance = 2 * params.sigma_px^2
        mean, contrast = params.mean_luminance, params.contrast

        for iy in max(1, center_y - reach_low):min(height, center_y + reach_high),
            ix in max(1, center_x - reach_low):min(width, center_x + reach_high)
            x, y = ix - center_x, iy - center_y
            envelope = exp(-(x^2 + y^2) / two_variance)
            carrier = cos(wavenumber * (x * cos_theta + y * sin_theta) + phase)
            canvas[ix, iy] = pixel(mean * (1 + contrast * envelope * carrier))
        end
    end

    offset = params.size_px / 2 + GABOR_CUE_PX
    for sx in (-1, 1), sy in (-1, 1)
        draw_marker!(canvas, sx * offset, sy * offset, GABOR_CUE_PX, GABOR_CUE_PX, pixel(0.0))
    end
    return canvas
end

"""
    correct_answer(::Gabor, vars::NamedTuple) -> Int

`-1` when the patch was in the first interval, `+1` when it was in the second.

The interval is read from the trial's variables, so a design has to declare
`:target_interval` among them; one that fixes it in the stimulus instead is
refused, because a participant who always sees the patch in the same interval
is not being tested on the patch.
"""
function correct_answer(::Gabor, vars::NamedTuple)
    haskey(vars, :target_interval) || throw(ArgumentError(
        "A two-interval Gabor session must declare :target_interval as an " *
        "independent variable with the range [1, 2], so that the interval holding " *
        "the patch is drawn per trial."))
    vars.target_interval == 1 && return -1
    vars.target_interval == 2 && return 1
    throw(ArgumentError("target_interval must be 1 or 2, got $(vars.target_interval)."))
end
