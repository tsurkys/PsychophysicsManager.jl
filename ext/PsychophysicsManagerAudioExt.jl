# Audio extension: loads automatically on `using PortAudio, SampledSignals`.
# Waveform construction stays in the headless core; this extension owns only
# the audio-device stream and real-time playback.

module PsychophysicsManagerAudioExt

using PsychophysicsManager
using PortAudio
using SampledSignals
import PsychophysicsManager: close_engine!, initialize_engine,
                  present_stimulus
using PsychophysicsManager: AbstractStimulusEngine, DisplayConfig, PresentationResult,
                 TemporalOppelKundt,
                 generate_temporal_oppel_kundt_waveform, load_audio_output_device

"""
    AudioStimulusEngine

A render-only PortAudio engine. It plays a generated stereo waveform and
reports the estimated first-burst onset; the Core obtains the participant
response from the active response source.
"""
mutable struct AudioStimulusEngine <: AbstractStimulusEngine
    stream::PortAudioStream
    sample_rate_hz::Int
    output_device::Union{Nothing, String}
end

function AudioStimulusEngine(
    sample_rate_hz::Integer;
    output_device::Union{Nothing, String}=nothing,
)
    stream = try
        if output_device === nothing
            PortAudioStream(
                0,
                2;
                eltype = Float32,
                samplerate = sample_rate_hz,
                warn_xruns = false,
            )
        else
            PortAudioStream(
                output_device,
                0,
                2;
                eltype = Float32,
                samplerate = sample_rate_hz,
                warn_xruns = false,
            )
        end
    catch err
        device_description = output_device === nothing ?
            "the system default output" : "configured output '$output_device'"
        error(
            "Could not open $device_description at $(sample_rate_hz) Hz. " *
            "Check [audio] output_device in settings.toml, the device sample " *
            "rate, and whether another application is holding it. Original error: " *
            sprint(showerror, err),
        )
    end
    return AudioStimulusEngine(stream, Int(sample_rate_hz), output_device)
end

function initialize_engine(
    ::Type{AudioStimulusEngine},
    stim_params::TemporalOppelKundt,
    config::DisplayConfig,
)
    output_device = load_audio_output_device()
    return AudioStimulusEngine(
        stim_params.sample_rate_hz;
        output_device = output_device,
    )
end

function close_engine!(engine::AudioStimulusEngine)
    isopen(engine.stream) && close(engine.stream)
    return nothing
end

function present_stimulus(
    engine::AudioStimulusEngine,
    stim_params::TemporalOppelKundt,
    indep_var_vals::AbstractVector{<:Number},
)
    stim_params.sample_rate_hz == engine.sample_rate_hz || throw(ArgumentError(
        "stimulus sample_rate_hz ($(stim_params.sample_rate_hz)) differs from " *
        "the open audio stream ($(engine.sample_rate_hz)); reinitialize the engine",
    ))

    mono = generate_temporal_oppel_kundt_waveform(stim_params)
    stereo = Matrix{Float32}(undef, length(mono), 2)
    stereo[:, 1] .= mono
    stereo[:, 2] .= mono

    write_start = time()
    # Write in ~250 ms blocks with a yield between them, so the dashboard's
    # render loop and session listeners stay live during long stimuli (a
    # single blocking write starved the GUI until the next trial)
    block = max(1, round(Int, 0.25 * engine.sample_rate_hz))
    first_row = 1
    total_rows = Base.size(stereo, 1)
    while first_row <= total_rows
        last_row = min(first_row + block - 1, total_rows)
        write(engine.stream, stereo[first_row:last_row, :])
        yield()
        first_row = last_row + 1
    end

    # PortAudio's device latency has not yet been measured. This timestamp
    # accounts for the generated leading silence but remains an estimate of
    # acoustic onset at the headphones.
    first_burst_onset = write_start + stim_params.leading_silence_ms / 1000
    return PresentationResult(onset = first_burst_onset)
end

function __init__()
    PsychophysicsManager.register_engine_type!(AudioStimulusEngine)
end

end # module
