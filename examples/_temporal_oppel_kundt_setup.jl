# Shared configuration for the auditory filled-time integration experiment. The
# design lives in the keyword defaults below; `run_temporal_oppel_kundt.jl` only
# names the participant and the number of repeats.

using PsychophysicsManager

"""
    create_temporal_oppel_kundt_session(participant_id = DEFAULT_PARTICIPANT_ID;
                                        repeats, levels, extra_tags)

The auditory filled-time (temporal Oppel-Kundt) Constant Stimuli session: a
filled 1000 ms reference against an empty comparison interval swept over
`levels`, in milliseconds.
"""
function create_temporal_oppel_kundt_session(
    participant_id::AbstractString = DEFAULT_PARTICIPANT_ID;
    repeats::Integer,
    levels::AbstractVector{<:Real} = collect(800.0:200.0:2000.0),
    extra_tags::AbstractVector{<:AbstractString} = String[],
)
    ex_par = ExperimentParameters(
        "Temporal_Oppel_Kundt_Constant_Stimuli",
        :comparison_interval_ms,
        collect(Float64, levels),
        Int(repeats),
    )

    stim_par = TemporalOppelKundt(
        reference_interval_ms = 1000.0,
        comparison_interval_ms = 1000.0,
        filler_count = 6,
        filled_interval = :first,
        gap_ms = 0.0,
        frequency_hz = 1000.0,
        burst_duration_ms = 30.0,
        ramp_duration_ms = 3.4,
        peak_amplitude = 0.5,
        sample_rate_hz = 48000,
        # The published protocol's approximately 2.6 s response-to-next-onset
        # interval.
        leading_silence_ms = 2600.0,
        trailing_silence_ms = 100.0,
    )

    tags = [
        "example",
        "audio",
        "temporal-oppel-kundt",
        "constant-stimuli",
        String.(extra_tags)...,
    ]
    return SessionContext(
        String(participant_id),
        ex_par,
        stim_par,
        ConstantStimuli();
        tags = tags,
    )
end
