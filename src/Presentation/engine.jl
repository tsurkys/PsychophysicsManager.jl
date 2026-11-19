# The stimulus engine contract. An engine owns the
# devices and the timing of ONE presentation; it never interprets responses or
# mutates method-relevant parameters. Concrete engines live in this
# directory (headless built-ins) or in the backend extensions under `ext/`.

"""
    initialize_engine(::Type{T}, stim_params::AbstractStimulusParameters, config::DisplayConfig) where T <: AbstractStimulusEngine

Initializes and returns a stimulus engine of type T with the given configuration.
"""
function initialize_engine(::Type{T}, stim_params::AbstractStimulusParameters, config::DisplayConfig) where T <: AbstractStimulusEngine
    error("initialize_engine not implemented for type $T")
end

"""
    close_engine!(engine::AbstractStimulusEngine)

Release resources owned by an engine. The default implementation is a no-op;
engines that own streams, devices, or external processes override it. Callers
that initialize an engine explicitly also own its cleanup.
"""
close_engine!(::AbstractStimulusEngine) = nothing

"""
    isopen(engine::AbstractStimulusEngine) -> Bool

Whether the engine can still present: an engine whose window has been closed — by
[`close_engine!`](@ref), or by the person in front of it — returns `false`, and a new
one has to be initialized. The default is `true`, which suits an engine that owns no
window.
"""
Base.isopen(::AbstractStimulusEngine) = true

"""
    last_frame(engine::AbstractStimulusEngine) -> Union{Nothing, AbstractMatrix}

The pixel buffer of the engine's most recent presentation, or `nothing` when the
engine keeps none. Engines that rasterize into a buffer they own may return it
so that a context-aware response source (a model observer) answers about exactly
the pixels that were presented — see [`TrialContext`](@ref).

The buffer is borrowed, not given away: callers must read it and must not mutate
it, and an engine is free to overwrite it on the next presentation.
"""
last_frame(::AbstractStimulusEngine) = nothing

"""
    display_info(engine::AbstractStimulusEngine) -> Dict{String, String}

What the engine can say about the viewing conditions it presented under —
`"display_resolution" => "1920x1080"` for an engine that knows its window or
canvas size. The default is empty: an engine that owns no display, or cannot
report one, adds nothing.

`start_session!` merges the result into `session.environment`, so the entries
end up in the session file beside the Julia version and the hostname. Keys are
free-form; use `display_resolution` for the presented size, so that sessions
recorded on different engines stay comparable.
"""
display_info(::AbstractStimulusEngine) = Dict{String, String}()

"""
    present_feedback(engine::AbstractStimulusEngine, correct::Bool)

Tells the participant whether the trial that just concluded was answered
correctly — a tone, a colour, a line of text: what the announcement is belongs
to the engine, which owns the devices. The default does nothing, so an engine
that has no way to say it is unaffected.

The Core calls it once per concluded trial, and only for a session that declares
[`set_feedback!`](@ref) and a trial the task scored: a measurement
session stays silent, and a trial with no right answer has no outcome to report.
"""
present_feedback(::AbstractStimulusEngine, ::Bool) = nothing

"""
    present_message(engine::AbstractStimulusEngine, message::ParticipantMessage)

Shows `message.text` to the participant and returns once it has ended — a
dismissible message when the participant pressed a key no sooner than `message.min_s`
after it appeared (keys before that are discarded), any message as soon as
`message.keep_waiting()` is `false` (poll it, e.g. every 20 ms). How it looks is the
engine's. The default hands the message to the active response source, so an engine that
shows no messages keeps working.
"""
present_message(engine::AbstractStimulusEngine, message::ParticipantMessage) =
    present_message(ACTIVE_RESPONSE_SOURCE[], message)

"""
    set_response_timeout!(engine::AbstractStimulusEngine, timeout_s::Union{Nothing, Float64})

Tells an engine that captures its own responses how long the participant has to
answer, or `nothing` for an unbounded wait. The default does nothing, so an
engine that reports no response is unaffected.

The Core calls it before every presentation, with the session's current
`timeout_s` — a deadline the operator changes mid-session therefore
reaches the device on the next trial. An engine that runs out of time reports
the sentinel `:timeout` as its response instead of a number, exactly as a
response source does; what it must not do is invent an answer or keep the
participant waiting past the window it was given.
"""
# The second argument is left untyped so that an engine can claim the hook with
# the plain `set_response_timeout!(engine::MyEngine, timeout_s)` an implementer
# writes, rather than having to repeat the union to escape an ambiguity
set_response_timeout!(::AbstractStimulusEngine, timeout_s) = nothing

"""
    set_min_response_time!(engine::AbstractStimulusEngine, min_s::Float64)

Tells an engine that captures its own responses how soon after the onset of the next
presentation a press may answer it: an earlier one is dropped without a word, and the
wait goes on. The Core calls it before every presentation, with the session's
`min_response_s` for a trial's first presentation and `0.0` for the presentations that
follow within the trial (the steps of an adjustment, a repeat request), so a double press
or a key held from the trial before cannot answer a new trial while an adjustment still
follows a held key. The default does nothing.
"""
set_min_response_time!(::AbstractStimulusEngine, min_s) = nothing

"""
    reads_response_keys(engine::AbstractStimulusEngine) -> Bool

Whether `engine` takes the participant's answers from the keys of its own window: ← and
→ for −1 and +1, Enter or Space for 0. The console then prints, when a session starts,
what each key means in the session's task ([`response_key_guide`](@ref)). The default is
`false`: an engine that only presents, or one a program answers through, has no keys to
explain.
"""
reads_response_keys(::AbstractStimulusEngine) = false

"""
    can_abandon_presentation(engine::AbstractStimulusEngine) -> Bool

Whether the presentation under way can be abandoned now, for a stimulus the
operator wants presented at once ([`present_condition!`](@ref) with `when = :now`).
The Core abandons a trial as Ctrl+C does: the trial loop is resumed with an
exception wherever it waits, inside the engine included. The default is `true`,
which suits an engine that waits on a timer or on a channel of its own: a key
pressed later answers the next presentation, as after a closed response window.

An engine waiting for a reply from another process returns `false` while it
waits, unless it can ask that process to end the presentation
([`abandon_presentation!`](@ref)): the reply would arrive after all and be read as
the answer to its next command. The operator's stimulus is then presented right
after the trial under way.
"""
can_abandon_presentation(::AbstractStimulusEngine) = true

"""
    abandon_presentation!(engine::AbstractStimulusEngine) -> Bool

Asks the engine to end the presentation under way itself, for a trial the Core
abandons ([`can_abandon_presentation`](@ref)). An engine that does returns `true`, and
its `present_stimulus` then throws the exception the Core abandons a trial with, in the
trial loop's own task, once the presentation has ended. The default returns `false`,
and the Core resumes the loop's task with that exception wherever it waits.

`RemoteEngine` sends a worker that declares it can the `abandon` command while it awaits
the worker's reply to `present`, and the worker answers that `present` with
`"abandoned"` (`workers/README.md`).
"""
abandon_presentation!(::AbstractStimulusEngine) = false

"""
    declared_parameters(engine, stim_par::WorkerStimulus) -> Union{Nothing, Vector{Pair{Symbol, Any}}}

The parameters, with their defaults, that the stimulus program behind `engine` declares
for `stim_par`, or `nothing` when it declares none and the stimulus is presented
as it is — an emulator's dry run. `RemoteEngine` gives what its worker's hello reply
declares, and refuses a stimulus the worker does not declare.
"""
declared_parameters(::AbstractStimulusEngine, ::WorkerStimulus) = nothing

"""
    complete_parameters!(stim_par, engine) -> Vector{Symbol}

Completes a worker's stimulus to what the engine's program declares now: a
parameter the program no longer declares is refused, by name, before anything changes,
and one it declares that the stimulus lacks is added with its declared default, in the
program's order. Returns the parameters added. Any other stimulus is left as it is.
"""
complete_parameters!(::AbstractStimulusParameters, ::AbstractStimulusEngine) = Symbol[]

function complete_parameters!(stim_par::WorkerStimulus, engine::AbstractStimulusEngine)
    declared = declared_parameters(engine, stim_par)
    declared === nothing && return Symbol[]
    names = first.(declared)
    undeclared = setdiff(parameter_names(stim_par), names)
    isempty(undeclared) || error(
        "The stimulus program no longer declares " *
        "$(join(("$name (set to $(repr(parameter_value(stim_par, name))))"
                 for name in undeclared), ", ")) of $(stim_par.stimulus), so the stimulus " *
        "is not presented: a session presents only parameters its program declares. " *
        "Start from the program's own stimulus (worker_stimulus) or restore the " *
        "parameter in the program.")
    added = setdiff(names, parameter_names(stim_par))
    stim_par.parameters = Pair{Symbol, Any}[
        name => (has_parameter(stim_par, name) ? parameter_value(stim_par, name) : default)
        for (name, default) in declared]
    return added
end

"""
    preview_stimulus(engine::AbstractStimulusEngine, stim_par, values = Float64[])

Presents `stim_par` once on an open engine, for the experimenter to look at or listen
to: no trial is recorded, no session is involved, and no answer is awaited — the
engine is given a response window of zero, and a render-only engine is not asked for a
response at all. `values` are the independent variables' values for the presentation,
as [`present_stimulus`](@ref) takes them. What stays on the screen afterwards is the
engine's: a static image stays until the next presentation. Since nothing waits on a
preview, an engine may let the person looking at it close its window afterwards (the
GLMakie window closes on Esc); `isopen(engine)` then tells.
"""
function preview_stimulus(engine::AbstractStimulusEngine, stim_par::AbstractStimulusParameters,
                          values::AbstractVector{<:Real} = Float64[])
    # A worker's stimulus is shown as the worker declares it; the caller's is not changed
    stim_par = deepcopy(stim_par)
    complete_parameters!(stim_par, engine)
    set_response_timeout!(engine, 0.0)
    present_stimulus(engine, stim_par, values)
    return nothing
end

"""
    preview_stimulus(stim_par; engine_type = default_engine_type(stim_par),
                     config = load_display_config(), values = Float64[])

Opens an engine for `stim_par`, presents it once ([`preview_stimulus`](@ref) on the
engine), and closes the engine.
"""
function preview_stimulus(stim_par::AbstractStimulusParameters;
                          engine_type::Type = default_engine_type(stim_par),
                          config::DisplayConfig = load_display_config(),
                          values::AbstractVector{<:Real} = Float64[])
    engine = initialize_engine(engine_type, stim_par, config)
    try
        preview_stimulus(engine, stim_par, values)
    finally
        close_engine!(engine)
    end
    return nothing
end

"""
    restore_engine(session::SessionContext, config::DisplayConfig) -> AbstractStimulusEngine

Creates the exact engine used when the session was saved, based on `session.engine_name`.
"""
function restore_engine(session::SessionContext, config::DisplayConfig)
    engine_name = session.engine_name

    if engine_name == "UnknownEngine"
        @warn "Engine name not found in session file. Falling back to default."
        engine_type = default_engine_type(session.stim_par)
        return initialize_engine(engine_type, session.stim_par, config)
    end

    # Engine types come from the registry; backends register
    # theirs when loaded (e.g. `using GLMakie` registers GeometryVisualEngine)
    engine_type = registered_type(ENGINE_REGISTRY, "engine", Symbol(engine_name),
        "Load the backend that provides it first (e.g. `using GLMakie`), or register a custom engine with PsychophysicsManager.register_engine_type!.")
    return initialize_engine(engine_type, session.stim_par, config)
end

"""
    default_engine_type(params::AbstractStimulusParameters) -> Type{<:AbstractStimulusEngine}

The engine type that presents `params`: the one its stimulus was registered with
([`register_stimulus!`](@ref)). While that engine's backend is not loaded, the error
names the engine and the packages that load it.
"""
function default_engine_type(params::AbstractStimulusParameters)
    name = stimulus_engine_name(params)
    name === nothing && error(
        "No engine is known for $(typeof(params)): register the stimulus with " *
        "`register_stimulus!($(nameof(typeof(params))); engine = …)`.")
    haskey(ENGINE_REGISTRY, name) && return ENGINE_REGISTRY[name]
    packages = get(ENGINE_BACKEND_HINTS, name, Symbol[])
    error("$(typeof(params)) is presented by $name, which is not loaded" *
          (isempty(packages) ? "." :
           ": load its backend first (`using $(join(packages, ", "))`)."))
end

"""
    present_stimulus(engine::AbstractStimulusEngine, stim_params::AbstractStimulusParameters, indep_var_vals::AbstractVector{<:Number})

Renders the stimulus described by `stim_params` once. Reporting anything back
is **optional** — every one of these return forms is legal:

- `PresentationResult(...)` — any combination of response, onset, and
  response timestamp the engine chooses to report;
- `(response, timestamp_response)` — the classic pair;
- a bare `response::Real`, or `:timeout` when the response window closed
  (see [`set_response_timeout!`](@ref));
- `nothing` — a render-only engine: the Core collects the response from the
  active response source (`set_response_source!`) and estimates the timing.

Engines must not interpret responses or mutate method-relevant parameters;
re-presentation within a trial is driven by the Core loop. Discrete input uses the abstract coding -1/0/+1.
"""
function present_stimulus(engine::AbstractStimulusEngine, stim_params::AbstractStimulusParameters, indep_var_vals::AbstractVector{<:Number})
    error("Not implemented for $(typeof(engine))")
end

# ── Presentation results ─────────────────────────────────────────────────────

"""
    PresentationResult

What an engine reports about one presentation. Every field is optional:

- `response`: the raw participant response; `nothing` means the engine does
  not capture input, and the Core collects the response from the active
  response source instead. `:timeout` reports a response window that closed
  with nothing answered.
- `onset`: the engine's best unix-time estimate for stimulus onset; `nothing`
  makes the Core record its own pre-presentation estimate and mark the trial's
  `onset_source` as `:estimated`. Its precision depends on the engine and
  hardware calibration.
- `timestamp_response`: unix time of the response; `nothing` falls back to
  the response source's timestamp (or the arrival time).
"""
Base.@kwdef struct PresentationResult
    response::Union{Nothing, Real, Symbol} = nothing
    onset::Union{Nothing, Float64} = nothing
    timestamp_response::Union{Nothing, Float64} = nothing
end

# Accepts every legal return form of `present_stimulus` (see its docstring)
normalize_presentation(x::PresentationResult) = x
normalize_presentation(x::Tuple{Any, Any}) =
    PresentationResult(response = x[1], timestamp_response = Float64(x[2]))
normalize_presentation(x::Real) = PresentationResult(response = x)
normalize_presentation(::Nothing) = PresentationResult()

function normalize_presentation(x::Symbol)
    x === :timeout || throw(ArgumentError(
        "An engine reports a response as a number or as the sentinel :timeout, " *
        "got :$x."))
    return PresentationResult(response = x)
end

# ── Conformance check ────────────────────────────────────────────────────────

"""
    EngineReport

What [`verify_engine`](@ref) saw an engine do: how many probes it survived, and
what it reports for itself. `render_only` says a session driven by this engine
needs a response source (`set_response_source!`); `reports_onset` and
`reports_response_time` say whose clock the trial's timestamps will come from —
an engine reporting neither is not broken, only less precise, and the
Core stamps the trial itself.
"""
struct EngineReport
    engine::String
    probes::Int
    render_only::Bool
    reports_onset::Bool
    reports_response_time::Bool
end

function Base.show(io::IO, ::MIME"text/plain", report::EngineReport)
    print(io, report.engine, " kept the engine contract over ", report.probes,
          " probe(s): ",
          report.render_only ? "render-only, so a response source supplies the answers" :
                               "captures its own responses",
          "; onset ", report.reports_onset ? "reported" : "estimated by the Core",
          ", response time ",
          report.reports_response_time ? "reported" : "taken on arrival", ".")
    return nothing
end

"""
    verify_engine(engine, stim_par; n_probes = 3, vals = Float64[], probe_timeout_s = 1.0) -> EngineReport

Presents `stim_par` a few times and checks that `engine` keeps the contract of
[`present_stimulus`](@ref) before a participant is sitting in front of it. Each
probe checks that

1. what `present_stimulus` returned is one of the accepted presentation forms;
2. every timestamp the engine reported is a plausible unix time, so a stopwatch
   reading or a frame count cannot pass for one;
3. `stim_par` came back unchanged — an engine renders what it is given and
   never writes to the parameters a method owns.

A violated check throws, naming the engine and what it did. Otherwise the
returned [`EngineReport`](@ref) says what the engine reports for itself.

`vals` is the independent-variable vector handed to each probe; an engine that
reads it needs a realistic one. Before probing, the engine is given a short
response window (`probe_timeout_s`, `nothing` to wait indefinitely) so that an
engine which captures its own input answers `:timeout` instead of holding the
check open; the Core sets the session's own window before every presentation,
so this leaves nothing behind.

```julia
verify_engine(MyEngine(), MyStimulusParameters())
```
"""
function verify_engine(engine::AbstractStimulusEngine,
                       stim_par::AbstractStimulusParameters;
                       n_probes::Integer = 3,
                       vals::AbstractVector{<:Number} = Float64[],
                       probe_timeout_s::Union{Nothing, Real} = 1.0)
    n_probes >= 1 ||
        throw(ArgumentError("verify_engine needs at least one probe, got $n_probes."))
    name = type_name(engine)
    fields = parameter_names(stim_par)

    set_response_timeout!(engine, probe_timeout_s === nothing ? nothing :
                                  Float64(probe_timeout_s))

    responded = false
    onsets = false
    response_times = false

    for probe in 1:n_probes
        before = Dict(field => deepcopy(parameter_value(stim_par, field)) for field in fields)

        raw = present_stimulus(engine, stim_par, vals)
        result = try
            normalize_presentation(raw)
        catch
            error("$name returned $(repr(raw)) from present_stimulus on probe " *
                  "$probe. An engine reports a PresentationResult, a " *
                  "(response, timestamp) tuple, a bare response, :timeout, or " *
                  "nothing.")
        end

        for (label, stamp) in (("onset", result.onset),
                               ("response timestamp", result.timestamp_response))
            stamp === nothing && continue
            isfinite(stamp) && stamp > 1.0e9 || error(
                "$name reported $stamp as the $label on probe $probe. Timestamps " *
                "are unix times from `time()`; a clock starting at the session, " *
                "or a frame count, is not one.")
        end

        for field in fields
            isequal(before[field], parameter_value(stim_par, field)) || error(
                "$name changed $(stimulus_name(stim_par)).$field from $(before[field]) to " *
                "$(parameter_value(stim_par, field)) on probe $probe. An engine renders " *
                "the parameters it is given; the values belong to the method and " *
                "the record.")
        end

        responded |= result.response !== nothing
        onsets |= result.onset !== nothing
        response_times |= result.timestamp_response !== nothing
    end

    return EngineReport(name, Int(n_probes), !responded, onsets, response_times)
end
