# Several adaptive sequences measured at once, shuffled trial by trial so the
# participant cannot follow any one of them. A track is a method, not a new kind
# of thing: the composite satisfies the same contract it delegates to, and the
# track a trial belonged to is an ordinary independent variable in the record.

"""
    Interleaved(tracks::Vector{<:AbstractPsychoMethod}; order = :random)

Runs several methods at once, one trial at a time. Each trial is handed to one
unfinished track — drawn from the session's stream (`order = :random`) or taken
in turn (`:round_robin`) — and the run ends when every track has ended.

The design declares which track a trial belonged to as an ordinary independent
variable named `:track`, with the range `1:length(tracks)`:

```julia
ex_par = ExperimentParameters("2IFC", [:contrast, :target_interval, :track],
                              Any[levels, [1, 2], 1:2], 1)
session = SessionContext("P01", ex_par, stim_par,
                         Interleaved([Staircase(2; levels = fine),
                                            Staircase(2; levels = coarse)]))
```

Because it is a variable and not a new field, everything downstream already
handles it: the value is recorded in `Trial.indep_var_vals`, `get_aggregated_data`
groups on the full condition vector, and the export writes a `track` column — so
a per-track summary costs nothing. A track never sees that variable: it is
handed the same design with that column removed ([`with_design`](@ref)), so its
own levels and per-trial draws are unaffected by running beside others.

Track-local settings belong to the track. Two staircases measuring different
level lists carry them as their own `levels`; what `ex_par` declares is the
design the session shares.

Undo, repeat requests and timeouts all reach the track that owns the trial: a
repeat re-presents the same track's stimulus, and an undone trial is re-queued
by the track it belonged to, read off its recorded `:track` value. A trial the
operator asks for ([`present_condition!`](@ref)) is presented past the run, and its
outcome goes to the track its condition names.
"""
mutable struct Interleaved <: AbstractPsychoMethod
    tracks::Vector{AbstractPsychoMethod}
    order::Symbol
    track_position::Int   # which declared variable names the track
    active::Int           # the track whose trial is in progress (0: none yet)
    trial_open::Bool      # a trial is under way and belongs to `active`

    function Interleaved(tracks::AbstractVector{<:AbstractPsychoMethod};
                               order::Symbol = :random)
        isempty(tracks) &&
            throw(ArgumentError("An interleaved run needs at least one track."))
        order in (:random, :round_robin) || throw(ArgumentError(
            "order is :random or :round_robin, got :$order."))
        # The element type is the abstract one on purpose: tracks of different
        # types interleave, and a session file restores each through the registry
        return new(Vector{AbstractPsychoMethod}(tracks), order, 0, 0, false)
    end

    # The empty shell a session file is read into, before its fields (the tracks
    # among them) are restored
    Interleaved() = new(AbstractPsychoMethod[], :random, 0, 0, false)
end

"""
    TRACK_VARIABLE

The name an interleaved design gives the variable that says which track a trial
belonged to (`:track`).
"""
const TRACK_VARIABLE = :track

# The design a track is run against: the session's, minus the column naming the
# track. Rebuilt per trial rather than stored, because it is derived from the
# session's own declaration and must not go stale if that is replaced.
function design_without_track(ex_par::ExperimentParameters, position::Int)
    names = copy(ex_par.indep_var_names)
    ranges = copy(ex_par.indep_var_ranges)
    deleteat!(names, position)
    deleteat!(ranges, position)
    return ExperimentParameters(ex_par.experiment_name, names, ranges, ex_par.repeats)
end

function initialize_method!(method::Interleaved, ex_par::ExperimentParameters;
                            rng::AbstractRNG = Random.default_rng())
    position = findfirst(==(TRACK_VARIABLE), ex_par.indep_var_names)
    position === nothing && throw(ArgumentError(
        "An interleaved run records which track each trial belonged to, so the " *
        "design must declare `:$TRACK_VARIABLE` with the range " *
        "1:$(length(method.tracks)) among its independent variables."))

    # Sorted values rather than a set: one value per track, so a range that
    # names a track twice is a design mistake rather than a duplicate to ignore
    declared = sort(Float64.(collect(ex_par.indep_var_ranges[position])))
    declared == Float64.(1:length(method.tracks)) || throw(ArgumentError(
        "`:$TRACK_VARIABLE` must range over 1:$(length(method.tracks)), one value " *
        "per track, but the design declares $declared."))

    method.track_position = position
    method.active = 0
    method.trial_open = false

    track_par = design_without_track(ex_par, position)
    for track in method.tracks
        initialize_method!(track, track_par; rng = rng)
    end
    return method
end

# The next track to run: an unfinished one, drawn or taken in turn. A track that
# has ended is skipped rather than presented, so the others carry the run to its
# end instead of it stopping with the first track that finishes.
function next_track(method::Interleaved, rng::AbstractRNG)
    unfinished = findall(!is_experiment_finished, method.tracks)
    isempty(unfinished) && return max(method.active, 1)   # the run is over
    method.order === :random && return rand(rng, unfinished)

    total = length(method.tracks)
    for offset in 1:total
        candidate = mod1(method.active + offset, total)
        candidate in unfinished && return candidate
    end
    return first(unfinished)
end

function get_next_trial_params(method::Interleaved, session::SessionContext)
    # The column was resolved when the run started, and a session file names it
    # too; a design that no longer declares it there is another experiment
    position = method.track_position
    (1 <= position <= length(session.ex_par.indep_var_names) &&
     session.ex_par.indep_var_names[position] === TRACK_VARIABLE) || throw(ArgumentError(
        "This run records its track in column $position, which the design does " *
        "not declare as `:$TRACK_VARIABLE`. The run and the design do not belong " *
        "together."))

    if !method.trial_open
        method.active = next_track(method, session.rng)
        method.trial_open = true
    end

    track_session = with_design(session,
        design_without_track(session.ex_par, method.track_position))
    # A copy: a method may hand out a vector it owns (an adjustment's trial
    # table), and the track's value must not gain a column of ours
    vals = collect(Float64, get_next_trial_params(method.tracks[method.active],
                                                  track_session))
    insert!(vals, method.track_position, Float64(method.active))
    return vals
end

# The track whose trial is under way. Asking before one is chosen is a caller
# error rather than a default, because attributing a response to the wrong
# track would be recorded as data
function active_track(method::Interleaved)
    method.active == 0 && throw(ArgumentError(
        "No track is running: ask an interleaved method for the trial's " *
        "parameters before telling it what happened in the trial."))
    return method.tracks[method.active]
end

function update_method_state!(method::Interleaved, response::Real,
                              correct::Union{Nothing, Bool})
    track = active_track(method)
    update_method_state!(track, response, correct)
    method.trial_open = !is_trial_finished(track)
    return nothing
end

function update_method_state!(method::Interleaved, response::Real)
    track = active_track(method)
    update_method_state!(track, response)
    method.trial_open = !is_trial_finished(track)
    return nothing
end

is_trial_finished(method::Interleaved) = !method.trial_open

is_experiment_finished(method::Interleaved) =
    all(is_experiment_finished, method.tracks)

# Everything a track decides about its own trial is the track's to decide
apply_method_state!(method::Interleaved, stim_par::AbstractStimulusParameters) =
    apply_method_state!(active_track(method), stim_par)

adjusted_fields(method::Interleaved) =
    unique(Symbol[field for track in method.tracks for field in adjusted_fields(track)])

unset_settings(method::Interleaved) =
    unique(Symbol[name for track in method.tracks for name in unset_settings(track)])

get_trial_result(method::Interleaved, last_response::Real) =
    get_trial_result(active_track(method), last_response)

set_task_scored!(method::Interleaved, scored::Bool) =
    (foreach(track -> set_task_scored!(track, scored), method.tracks); method)

timeout_result(method::Interleaved, session::SessionContext) =
    timeout_result(active_track(method), session)

steps_on_answers(method::Interleaved) = any(steps_on_answers, method.tracks)

fresh_instance(method::Interleaved) =
    Interleaved([fresh_instance(track) for track in method.tracks];
                      order = method.order)

function remaining_trial_count(method::Interleaved)
    counts = remaining_trial_count.(method.tracks)
    return any(isnothing, counts) ? nothing : sum(counts; init = 0)
end

function planned_trial_count(method::Interleaved)
    counts = planned_trial_count.(method.tracks)
    return any(isnothing, counts) ? nothing : sum(counts)
end

# Which track a condition belongs to, read off its track column
function condition_track(method::Interleaved, vals::AbstractVector)
    position = method.track_position
    1 <= position <= length(vals) || return nothing
    index = round(Int, vals[position])
    return 1 <= index <= length(method.tracks) ? index : nothing
end

trial_track(method::Interleaved, trial::Trial) =
    condition_track(method, trial.indep_var_vals)

# A condition as its track sees it, without the track column
track_values(method::Interleaved, vals::AbstractVector) =
    deleteat!(collect(Float64, vals), method.track_position)

# An operator's trial is passed by the run and goes to the track its condition names
function absorb_operator_trial!(method::Interleaved, vals, response, correct)
    index = condition_track(method, vals)
    index === nothing && return nothing
    absorb_operator_trial!(method.tracks[index], track_values(method, vals), response,
                           correct)
    return nothing
end

function forget_operator_trial!(method::Interleaved, trial::Trial)
    index = trial_track(method, trial)
    index === nothing && return true
    seen = Trial(trial.trial_index, trial.timestamp_onset, trial.timestamp_response,
                 track_values(method, trial.indep_var_vals), trial.response,
                 trial.is_valid, trial.onset_source, trial.correct, trial.origin,
                 trial.start_value)
    return forget_operator_trial!(method.tracks[index], seen)
end

function revert_method_state!(method::Interleaved, trial::Trial)
    index = trial_track(method, trial)
    if index === nothing
        @warn "The undone trial does not name a track of this run; the undo is cancelled."
        return false
    end

    reverted = revert_method_state!(method.tracks[index], trial)
    if reverted
        # The re-queued trial is the track's again, and the next trial picks
        # a track afresh
        method.active = index
        method.trial_open = false
    end
    return reverted
end

function describe_trial(method::Interleaved, ex_par::ExperimentParameters,
                        trial::Trial)
    index = trial_track(method, trial)
    index === nothing && return invoke(describe_trial,
                                       Tuple{AbstractPsychoMethod, ExperimentParameters,
                                             Trial},
                                       method, ex_par, trial)
    return describe_trial(method.tracks[index], ex_par, trial)
end

function describe_method_state(method::Interleaved)
    method.active == 0 && return nothing
    state = describe_method_state(active_track(method))
    return state === nothing ? "track $(method.active)" :
           "track $(method.active): $state"
end
