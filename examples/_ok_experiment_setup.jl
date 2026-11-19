# Shared OK4 configuration used by the direct and dashboard tests. The design
# lives in the keyword defaults below; the scripts only name the participant.

"""
    create_ok_session(participant_id = DEFAULT_PARTICIPANT_ID; reference,
                      distractor_range, repeats, extra_tags)

The OK4 geometric adjustment session: the participant adjusts `Diff` until both
intervals look equal, once per distractor count.
"""
function create_ok_session(
    participant_id::AbstractString = DEFAULT_PARTICIPANT_ID;
    reference::Real = 240.0,
    distractor_range = 0:5,
    repeats::Integer = 2,
    extra_tags::AbstractVector{<:AbstractString} = String[],
)
    stim_par = MarkerLayout(
        StimConfig = "d r t",
        Ref = Float64(reference),
        DistrN = first(distractor_range),
        Diff = 0.0,
        Marker = :rect,
        MarkerSize = (2, 30),
        Color = :white,
        Anchor = :middle,
    )

    ex_par = ExperimentParameters(
        "OK_Geometry_Study",
        :DistrN,
        distractor_range,
        Int(repeats),
    )

    # Keep the original adjustment range and starting behavior: each trial
    # starts at stim_par.Diff because no init_interval is configured.
    method = Adjustment(
        dep_var = :Diff,
        dep_range = -120:120,
    )

    tags = unique(vcat(["ok-experiment", "visual-test"], String.(extra_tags)))
    return SessionContext(String(participant_id), ex_par, stim_par, method; tags)
end
