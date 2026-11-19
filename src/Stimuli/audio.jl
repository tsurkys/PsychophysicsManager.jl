"""
    TemporalOppelKundt

Parameters for the auditory filled-time (divided-time) analogue of the
Oppel-Kundt stimulus. Two intervals are marked by short tone bursts. The
reference interval contains `filler_count` equally spaced bursts, while the
comparison interval is empty.

`peak_amplitude` is a unitless digital peak amplitude, not a calibrated sound
pressure level. Its mapping to dB SPL depends on the output interface,
amplifier, and headphones and must be measured for each laboratory setup.
"""
Base.@kwdef mutable struct TemporalOppelKundt <: AbstractStimulusParameters
    reference_interval_ms::Float64 = 1000.0
    comparison_interval_ms::Float64 = 1000.0
    filler_count::Int = 6
    filled_interval::Symbol = :first
    gap_ms::Float64 = 0.0

    frequency_hz::Float64 = 1000.0
    burst_duration_ms::Float64 = 30.0
    ramp_duration_ms::Float64 = 3.4
    peak_amplitude::Float64 = 0.1
    sample_rate_hz::Int = 44100

    leading_silence_ms::Float64 = 0.0
    trailing_silence_ms::Float64 = 100.0
end

function validate_temporal_oppel_kundt(p::TemporalOppelKundt)
    p.reference_interval_ms > 0 ||
        throw(ArgumentError("reference_interval_ms must be positive"))
    p.comparison_interval_ms > 0 ||
        throw(ArgumentError("comparison_interval_ms must be positive"))
    p.filler_count >= 0 || throw(ArgumentError("filler_count cannot be negative"))
    p.filled_interval in (:first, :second) ||
        throw(ArgumentError("filled_interval must be :first or :second"))
    p.gap_ms >= 0 || throw(ArgumentError("gap_ms cannot be negative"))

    p.frequency_hz > 0 || throw(ArgumentError("frequency_hz must be positive"))
    p.burst_duration_ms > 0 ||
        throw(ArgumentError("burst_duration_ms must be positive"))
    p.ramp_duration_ms >= 0 ||
        throw(ArgumentError("ramp_duration_ms cannot be negative"))
    2 * p.ramp_duration_ms <= p.burst_duration_ms ||
        throw(ArgumentError("two ramps must fit within burst_duration_ms"))
    0 <= p.peak_amplitude <= 1 ||
        throw(ArgumentError("peak_amplitude must be between 0 and 1"))
    p.sample_rate_hz > 2 * p.frequency_hz ||
        throw(ArgumentError("sample_rate_hz must exceed twice frequency_hz"))

    p.leading_silence_ms >= 0 ||
        throw(ArgumentError("leading_silence_ms cannot be negative"))
    p.trailing_silence_ms >= 0 ||
        throw(ArgumentError("trailing_silence_ms cannot be negative"))
    return p
end

validate_stimulus(p::TemporalOppelKundt) = validate_temporal_oppel_kundt(p)

"""
    temporal_oppel_kundt_onsets(p) -> NamedTuple

Return boundary- and filler-burst onset times in milliseconds, relative to the
first boundary burst. With no gap, the two adjacent intervals share their
middle boundary. A positive gap produces separate end and start boundaries.
"""
function temporal_oppel_kundt_onsets(p::TemporalOppelKundt)
    validate_temporal_oppel_kundt(p)

    first_duration = p.filled_interval == :first ?
        p.reference_interval_ms : p.comparison_interval_ms
    second_duration = p.filled_interval == :first ?
        p.comparison_interval_ms : p.reference_interval_ms

    boundary_ms = if iszero(p.gap_ms)
        [0.0, first_duration, first_duration + second_duration]
    else
        [
            0.0,
            first_duration,
            first_duration + p.gap_ms,
            first_duration + p.gap_ms + second_duration,
        ]
    end

    filler_origin = p.filled_interval == :first ? 0.0 : first_duration + p.gap_ms
    filler_step = p.reference_interval_ms / (p.filler_count + 1)
    filler_ms = filler_origin .+ filler_step .* collect(1:p.filler_count)

    return (boundary_ms = boundary_ms, filler_ms = filler_ms)
end

function temporal_oppel_kundt_burst(p::TemporalOppelKundt)
    sample_count = round(Int, p.burst_duration_ms * p.sample_rate_hz / 1000)
    sample_count > 0 ||
        throw(ArgumentError("burst_duration_ms is shorter than one sample"))

    ramp_count = round(Int, p.ramp_duration_ms * p.sample_rate_hz / 1000)
    2 * ramp_count <= sample_count ||
        throw(ArgumentError("rounded attack and release ramps do not fit in the burst"))

    phase_step = 2pi * p.frequency_hz / p.sample_rate_hz
    burst = Float32.(p.peak_amplitude .* sin.(phase_step .* (0:(sample_count - 1))))

    if ramp_count > 0
        ramp = Float32.(range(0.0, 1.0; length = ramp_count + 1)[1:ramp_count])
        burst[1:ramp_count] .*= ramp
        burst[(end - ramp_count + 1):end] .*= reverse(ramp)
    end

    return burst
end

"""
    generate_temporal_oppel_kundt_waveform(p) -> Vector{Float32}

Generate a mono waveform for `p` without opening an audio device. The pure
generator can be tested, inspected, or exported independently of PortAudio.
All boundary and filler bursts use the same frequency, duration, ramps, and
per-burst digital peak amplitude.

Overlapping bursts are added. The function refuses combinations whose mixed
waveform would exceed the digital range instead of silently clipping or
normalizing a scientifically meaningful level difference.
"""
function generate_temporal_oppel_kundt_waveform(p::TemporalOppelKundt)
    onsets = temporal_oppel_kundt_onsets(p)
    burst = temporal_oppel_kundt_burst(p)
    all_onsets_ms = sort(vcat(onsets.boundary_ms, onsets.filler_ms))

    total_duration_ms = p.leading_silence_ms + last(onsets.boundary_ms) +
                        p.burst_duration_ms + p.trailing_silence_ms
    total_samples = ceil(Int, total_duration_ms * p.sample_rate_hz / 1000)
    waveform = zeros(Float32, total_samples)

    for onset_ms in all_onsets_ms
        first_sample = round(
            Int,
            (p.leading_silence_ms + onset_ms) * p.sample_rate_hz / 1000,
        ) + 1
        last_sample = first_sample + length(burst) - 1
        @views waveform[first_sample:last_sample] .+= burst
    end

    waveform_peak = maximum(abs, waveform)
    waveform_peak <= 1.0f0 || throw(ArgumentError(
        "mixed waveform peak $(round(waveform_peak, digits=4)) exceeds 1.0; " *
        "reduce peak_amplitude or change the event spacing",
    ))

    return waveform
end
