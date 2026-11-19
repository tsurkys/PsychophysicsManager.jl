@enum SessionState begin
    READY
    RUNNING
    PAUSED
    ABORTED
    FINISHED
end

"""
    ExperimentParameters

Defines the experiment setup.
`indep_var_names`: List of symbols (e.g., [:contrast, :frequency])
`indep_var_ranges`: List of value sets (vectors or ranges) for each variable.
"""
mutable struct ExperimentParameters
    experiment_name::String
    indep_var_names::Vector{Symbol}
    indep_var_ranges::Vector{Any}
    repeats::Int

    # These are the numbers a method turns into its trial plan (`build_trial_table`),
    # and every way of getting them wrong produces a session that runs to FINISHED
    # without measuring what was intended — an empty history, or a trial vector no
    # longer aligned with the names its columns are exported under.
    function ExperimentParameters(experiment_name::String,
                                  indep_var_names::Vector{Symbol},
                                  indep_var_ranges::Vector{Any}, repeats::Int)
        repeats >= 1 ||
            throw(ArgumentError("repeats must be at least 1, got $repeats."))
        length(indep_var_names) == length(indep_var_ranges) ||
            throw(ArgumentError("Each independent variable needs one value set: got " *
                                "$(length(indep_var_names)) name(s) and " *
                                "$(length(indep_var_ranges)) range(s)."))
        for (name, range) in zip(indep_var_names, indep_var_ranges)
            isempty(range) &&
                throw(ArgumentError("Independent variable $name has no values to present."))
        end
        return new(experiment_name, indep_var_names, indep_var_ranges, repeats)
    end
end

# Multi-variable constructor: ensures ranges are stored in a flexible Vector{Any}
function ExperimentParameters(experiment_name::String, names::Vector{Symbol}, ranges::Vector, repeats::Int)
    return ExperimentParameters(experiment_name, names, Vector{Any}(ranges), repeats)
end

# Single-variable constructor: simplifies usage for the most common case
function ExperimentParameters(experiment_name::String, name::Symbol, range::AbstractVector, repeats::Int)
    return ExperimentParameters(experiment_name, [name], Any[range], repeats)
end

mutable struct BaseStimulusParameters <: AbstractStimulusParameters
    duration_ms::Float64
end

"""
    Trial

One completed stimulus presentation. `response` keeps its natural numeric
type: discrete codes stay `Int` (e.g. 0/1 for detection), continuous results
stay `Float64` (e.g. the confirmed value of an adjustment). The one value that
is not a number is the sentinel `:timeout`, recorded when the response window
expired and nothing was answered; no other symbol is accepted, so a
reader of the column knows that anything non-numeric is exactly that outcome.

`onset_source` records where `timestamp_onset` came from: `:engine` when the
engine supplied it, `:estimated` when the Core had to stamp it before calling
the engine. Precision of an engine-supplied timestamp is engine- and
hardware-specific (see `PresentationResult`).

`correct` is the outcome of scoring the concluding response against
[`correct_answer`](@ref), and stays `nothing` for a task that defines no
correct answer.

`origin` says who chose the condition: `:method`, or `:operator` for a trial the
operator asked for ([`present_condition!`](@ref), [`repeat_trial!`](@ref)). The
analysis counts an operator's trial as any other valid one.

`start_value` is, for a method whose response is the value of a field it adjusts
([`adjusted_fields`](@ref)), the value that field stood at when the trial was first
presented — where the participant's adjustment began. It stays `nothing` for any other
method.
"""
mutable struct Trial
    trial_index::Int
    timestamp_onset::Float64      # unix time of the trial's first presentation
    timestamp_response::Float64   # unix time of the confirmed response
    indep_var_vals::Vector{Float64}
    response::Union{Real, Symbol} # a number, or :timeout for an expired window
    is_valid::Bool                # soft-delete flag (undo / outlier)
    onset_source::Symbol          # :engine (reported) or :estimated (core-side)
    correct::Union{Nothing, Bool} # nothing when the task defines no right answer
    origin::Symbol                # :method, or :operator when the operator chose it
    start_value::Union{Nothing, Float64} # where an adjustment began; nothing otherwise

    function Trial(trial_index, timestamp_onset, timestamp_response, indep_var_vals,
                   response, is_valid, onset_source, correct, origin, start_value)
        response isa Symbol && response !== :timeout && throw(ArgumentError(
            "A response is a number or the sentinel :timeout, got :$response."))
        origin in (:method, :operator) || throw(ArgumentError(
            "A trial's origin is :method or :operator, got :$origin."))
        return new(trial_index, timestamp_onset, timestamp_response, indep_var_vals,
                   response, is_valid, onset_source, correct, origin, start_value)
    end
end

# Compatibility constructors: engine-reported onsets, scoring, the operator's choice
# and the starting value of an adjustment are opt-in
Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source, correct,
      origin) =
    Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source,
          correct, origin, nothing)
Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source, correct) =
    Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source,
          correct, :method)
Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source) =
    Trial(trial_index, t_onset, t_response, vals, response, is_valid, onset_source,
          nothing)

Trial(trial_index, t_onset, t_response, vals, response, is_valid) =
    Trial(trial_index, t_onset, t_response, vals, response, is_valid, :estimated)

# A condition the operator asked to present,
# waiting for the trial loop to take it up. Runtime-only: a crash between the request
# and its trial loses the request, never an answer.
struct OperatorRequest
    vals::Vector{Float64}
    replaces::Union{Nothing, Int}   # the trial whose answer the new one takes the place of
end

"""
    SessionComment

A note the operator wrote about a session ([`add_comment!`](@ref)): when it was written
(unix time), the trial it is about, if any, and the text.
"""
struct SessionComment
    time::Float64
    trial::Union{Nothing, Int}
    text::String
end

# The trial under way, as abandoning it needs it: the task running the trial loop and
# the engine presenting the trial (runtime-only)
struct TrialRun
    task::Task
    engine::AbstractStimulusEngine
end

# Raised in the trial loop's task to abandon the trial under way (`abandon_trial!`):
# delivered into the task, or thrown by an engine whose presentation was ended at its
# request (`abandon_presentation!`)
struct TrialAbandoned <: Exception end

mutable struct SessionContext
    id::UUID
    participant_id::String
    tags::Vector{String}
    start_time::Union{Float64, Nothing}
    program_version::String
    state::SessionState
    ex_par::ExperimentParameters
    stim_par::AbstractStimulusParameters
    history::Vector{Trial}
    current_trial_idx::Int
    method_instance::AbstractPsychoMethod
    task::Union{Nothing, ObserverTask}  # what the observer was asked, and what +1 means
    engine_name::String # The name of the engine used to collect this data
    fit_gamma::Float64  # lower asymptote used when fitting this session's data
    feedback::Bool      # tell the participant whether each scored trial was right
    timeout_s::Union{Nothing, Float64}  # response window; nothing waits forever
    min_response_s::Float64  # a press sooner after a trial's onset is dropped ([input])
    rig::Dict{String, Any}   # the rig's name and constants it started with ([rig])
    messages::SessionMessages # what the participant is shown between trials
    unit_conversions::Dict{Symbol, UnitConversion}  # the units a report shows a variable in
    observer_metadata::Dict{String, Any}  # who answered, when the participant is a program
    rng_seed::UInt64    # seeds every random choice this session makes
    environment::Dict{String, String}  # where the data was collected (start_session!)
    comments::Vector{SessionComment}   # the operator's notes, in the order written
    rng::AbstractRNG    # runtime-only: the stream opened from rng_seed (not serialized)
    listeners::Vector{Function} # runtime-only observers (not serialized)
    save_path::Union{Nothing, String} # runtime-only: pinned checkpoint file, set by
                                      # the first save or by load_session (not serialized)
    trial_under_way::Bool # runtime-only: run_next_trial! is between a trial's start
                          # and its record (not serialized)
    trial_run::Union{Nothing, TrialRun} # runtime-only: the trial under way while it
                                        # awaits its answer (not serialized)
    operator_requests::Vector{OperatorRequest} # runtime-only: presented first, in order
                                               # (not serialized)
    shown_message::Union{Nothing, ParticipantMessage} # runtime-only: the message the
                                                      # participant is being shown (not serialized)
end

"""
    DEFAULT_PARTICIPANT_ID

Reserved participant id (`"test_user"`) substituted when a session is created
without naming a participant — for rapid setup, demos, and equipment tests.
Name the participant explicitly for real
data collection.
"""
const DEFAULT_PARTICIPANT_ID = "test_user"

"""
    DEFAULT_FIT_GAMMA

Lower asymptote (`gamma`) a new session fits its psychometric curve from.

`0.0` suits threshold and detection data, where the measured quantity can fall
to zero. Forced-choice *accuracy* data needs `0.5`, because guessing already
scores 50% and the curve cannot descend below it — fitting such data from zero
displaces the threshold estimate. The choice describes the data, so it cannot
be derived from the responses alone: a yes/no detection task and a two-
alternative task both produce 0/1 responses while needing different asymptotes.
It is therefore an explicit, persisted property of the session
(`session.fit_gamma`), set through `set_fit_gamma!`.
"""
const DEFAULT_FIT_GAMMA = 0.0

# Program version stamped into session metadata, read from the package's
# Project.toml (fallback covers loading the module outside a package context)
function program_version()
    v = pkgversion(@__MODULE__)
    return v === nothing ? "0.0.0-dev" : string(v)
end

"""
    draw_rng_seed() -> UInt64

Seed from the operating system's entropy source, drawn for a session that was
not given one.

Handing a recorded seed back — `SessionContext(...; rng_seed = seed)` — makes a
fresh session repeat the sequence that seed produced; a session that has
already run is untouched by it.
"""
draw_rng_seed() = rand(RandomDevice(), UInt64)

"""
    snapshot_environment(session, engine=nothing) -> Dict{String, String}

The machine the session ran on: Julia version, operating system, hostname and
package version, plus whatever the engine reports through
[`display_info`](@ref), and the stimulus program presenting it
([`stimulus_identity`](@ref), [`engine_version`](@ref)). Taken by
`start_session!`, so it describes the run rather than the moment the session
object was built.
"""
function snapshot_environment(session::SessionContext, engine=nothing)
    environment = Dict{String, String}(
        "julia_version" => string(VERSION),
        "os" => string(Sys.KERNEL),
        "hostname" => gethostname(),
        "psychophysics_manager_version" => session.program_version,
    )
    if engine !== nothing
        merge!(environment, display_info(engine))
        record_stimulus!(environment, engine, find_stimulus(engine, session.stim_par))
    end
    return environment
end

function SessionContext(participant_id::String, ex_par::ExperimentParameters,
                        stim_par::AbstractStimulusParameters,
                        method_instance::AbstractPsychoMethod;
                        tags=String[], rng_seed::Integer=draw_rng_seed())
    seed = UInt64(rng_seed)
    return SessionContext(
        uuid4(),
        participant_id,
        tags,
        nothing,
        program_version(),
        READY,
        ex_par,
        stim_par,
        Trial[],
        1,
        method_instance,
        nothing,
        "UnknownEngine",
        DEFAULT_FIT_GAMMA,
        false,
        nothing,
        0.0,
        Dict{String, Any}(),
        SessionMessages(),
        Dict{Symbol, UnitConversion}(),
        Dict{String, Any}(),
        seed,
        Dict{String, String}(),
        SessionComment[],
        Xoshiro(seed),
        Function[],
        nothing,
        false,
        nothing,
        OperatorRequest[],
        nothing
    )
end

# Rapid-setup overload: a session for the default/dummy participant
SessionContext(ex_par::ExperimentParameters, stim_par::AbstractStimulusParameters,
               method_instance::AbstractPsychoMethod;
               tags=String[], rng_seed::Integer=draw_rng_seed()) =
    SessionContext(DEFAULT_PARTICIPANT_ID, ex_par, stim_par, method_instance;
                   tags, rng_seed)

"""
    with_design(session::SessionContext, ex_par::ExperimentParameters) -> SessionContext

The same session seen through a different declaration of the design. Everything
else is shared, not copied — the random stream above all, so a method drawing
through the view draws from the session's own sequence.

It exists for a method that runs other methods: the tracks of an interleaved run
must not see the variable that names which of them is running, and
handing them a view is what keeps that out of their way without mutating the
session they are running in.
"""
with_design(session::SessionContext, ex_par::ExperimentParameters) =
    SessionContext(session.id, session.participant_id, session.tags,
                   session.start_time, session.program_version, session.state,
                   ex_par, session.stim_par, session.history,
                   session.current_trial_idx, session.method_instance, session.task,
                   session.engine_name, session.fit_gamma, session.feedback,
                   session.timeout_s, session.min_response_s, session.rig, session.messages,
                   session.unit_conversions,
                   session.observer_metadata, session.rng_seed,
                   session.environment, session.comments, session.rng, session.listeners,
                   session.save_path, session.trial_under_way, session.trial_run,
                   session.operator_requests, session.shown_message)

# ── Session event notifications (Core → GUI/Analytics) ──────────────────────

"""
    on_session_event!(f, session::SessionContext)

Registers `f(session, event::Symbol)` to be called on session events:
`:trial_completed` (a trial was recorded), `:state_changed` (start/pause/
resume/abort/finish), `:history_changed` (undo / outlier marking),
`:settings_changed` (a persisted session setting such as `fit_gamma` was
changed — the session's lifecycle state is untouched), `:interrupted` (Ctrl+C or
an error stopped the trial loop; the session is now PAUSED and checkpointed, and
continues when `run_experiment!` is called again), `:trial_abandoned` (the trial under
way was abandoned for a stimulus the operator asked for at once; nothing was recorded),
`:message_changed` (a message was shown to the participant or ended; `session.shown_message`
holds it while it is shown), `:comment_added` (the operator wrote a comment,
[`add_comment!`](@ref)).

Listeners are runtime-only (never saved to disk). Exceptions inside a
listener are caught and logged, so a crashing observer (e.g. a plot window)
can never interrupt a running experiment.
"""
function on_session_event!(f::Function, session::SessionContext)
    push!(session.listeners, f)
    return f
end

function notify_session_listeners(session::SessionContext, event::Symbol)
    for f in session.listeners
        try
            f(session, event)
        catch e
            @warn "Session event listener failed" event exception=(e, catch_backtrace())
        end
    end
    return nothing
end
