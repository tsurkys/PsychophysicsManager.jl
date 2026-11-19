# The response source that turns a model observer into a participant: it asks
# the backend about the trial context the Core hands over, maps the answer onto
# the abstract response coding, and keeps a per-request audit trail.
#
# Retries, what counts as an answer, and what happens when none arrives are
# handled here and only here, so that a backend stays a transport.

"""
    ObserverRecord

One request put to a model observer, including the ones that produced nothing
usable. `response` is the abstract code the answer was mapped to, or `nothing`
for a failed attempt.

`raw` keeps what came back; on a failed attempt that is the whole reply, the
only place the reason survives.
"""
struct ObserverRecord
    trial_index::Int
    attempt::Int
    choice::Union{Nothing, String}
    response::Union{Nothing, Int}
    raw::String
    latency_s::Float64
    metadata::Dict{String, Any}
end

"""
    MISSING_RESPONSE

Raw response handed to the method when a model observer produced no usable
answer and the source is running with `on_failure = :invalidate`. `NaN` rather
than a valid code, so it can never pass for a decision: the trial carries no
information and is marked invalid by [`invalidate_failed_trials!`](@ref).
"""
const MISSING_RESPONSE = NaN

"""
    ModelObserverSource(backend, task; max_attempts=3, on_failure=:error)

Makes a model observer the active participant: install it with
`with_response_source` (or `set_response_source!`) and run the session as usual.

A trial is answered by asking `backend` the `task`'s question about the
presentation. An unusable reply — declined, unparseable, or a transport failure —
is retried up to `max_attempts` times in total, after which `on_failure` decides:

- `:error` (default) raises; `run_experiment!` aborts and persists the session,
  so a run stops with the data it collected and nothing invented. Right for
  pilots and short runs, where a refusal is a finding.
- `:invalidate` records the trial with [`MISSING_RESPONSE`](@ref) so a long
  unattended run continues. **It only closes the loop if
  `invalidate_failed_trials!` runs after every trial** — which is what
  [`run_observer_experiment!`](@ref) wires up.

Every request, including failed attempts, is appended to `records`.
"""
mutable struct ModelObserverSource{B <: AbstractObserverBackend} <: AbstractResponseSource
    backend::B
    task::ObserverTask
    max_attempts::Int
    on_failure::Symbol
    records::Vector{ObserverRecord}
    pending_invalid::Vector{Int}
end

function ModelObserverSource(backend::AbstractObserverBackend, task::ObserverTask = length_comparison_task();
                             max_attempts::Integer = 3, on_failure::Symbol = :error)
    max_attempts >= 1 ||
        throw(ArgumentError("max_attempts must be at least 1, got $max_attempts."))
    on_failure in (:error, :invalidate) ||
        throw(ArgumentError("on_failure must be :error or :invalidate, got $(repr(on_failure))."))
    return ModelObserverSource(backend, task, Int(max_attempts), on_failure,
                               ObserverRecord[], Int[])
end

"""
    reads_messages(::ModelObserverSource) -> Bool

A model observer's requests carry the instructions and nobody reads a break;
the loop then shows no message at all.
"""
reads_messages(::ModelObserverSource) = false

function request_response(source::ModelObserverSource, context::TrialContext)
    question = ObserverQuestion(source.task, context)

    for attempt in 1:source.max_attempts
        answer = query_observer(source.backend, question)
        usable = answer.choice !== nothing && answer.choice in source.task.options
        response = usable ? response_code(source.task, answer.choice) : nothing

        push!(source.records, ObserverRecord(context.trial_index, attempt, answer.choice,
                                             response, answer.raw, answer.latency_s,
                                             answer.metadata))

        response === nothing || return (response, time())
    end

    if source.on_failure === :error
        final = source.records[end]
        error("Model observer produced no usable answer for trial " *
              "$(context.trial_index) after $(source.max_attempts) attempt(s). " *
              "Expected one of $(source.task.options); the last reply was " *
              "$(repr(first(final.raw, 200))). Inspect the source's `records` for the full " *
              "exchange, or construct the source with `on_failure = :invalidate` " *
              "to keep an unattended run going.")
    end

    push!(source.pending_invalid, context.trial_index)
    @warn "Model observer gave no usable answer; the trial will be marked invalid." trial = context.trial_index attempts = source.max_attempts
    return (MISSING_RESPONSE, time())
end

"""
    invalidate_failed_trials!(source::ModelObserverSource, session::SessionContext) -> Int

Marks every trial the source could not get an answer for as invalid, and returns
how many were marked. Idempotent, and safe to call when nothing is pending.

Pass it as `on_trial_end` so an uninformative trial is invalidated the moment it
is recorded:

```julia
run_experiment!(session, engine;
                on_trial_end = s -> invalidate_failed_trials!(source, s))
```
"""
function invalidate_failed_trials!(source::ModelObserverSource, session::SessionContext)
    isempty(source.pending_invalid) && return 0
    marked = 0
    for trial_index in source.pending_invalid
        any(t -> t.trial_index == trial_index, session.history) || continue
        mark_outlier!(session, trial_index) && (marked += 1)
    end
    filter!(idx -> !any(t -> t.trial_index == idx, session.history), source.pending_invalid)
    return marked
end

"""
    describe_backend(backend::AbstractObserverBackend) -> Dict{String, Any}

What a backend wants recorded about itself: the model it queried, its settings,
anything else needed to repeat the measurement. Backends override it; the
default reports only the type.
"""
describe_backend(backend::AbstractObserverBackend) =
    Dict{String, Any}("backend" => string(nameof(typeof(backend))))

describe_backend(backend::SimulatedObserver) = Dict{String, Any}(
    "backend" => "SimulatedObserver",
    "model" => "simulated",
    "bias_per_distractor" => backend.bias_per_distractor,
    "noise_sd" => backend.noise_sd,
    "lapse_rate" => backend.lapse_rate,
    "positive_interval" => backend.positive_interval,
)

"""
    observer_provenance(source::ModelObserverSource) -> Dict{String, Any}

Everything needed to say *who* answered: the backend's own description, the
failure policy, and how many requests it took. Store it with the session
(`set_observer_metadata!`) so the measurement can be repeated and the data
cannot be mistaken for a human participant's.

What the observer was *asked* is not here: the instructions, the options and the
response coding are `session.task`, which a human session carries too.
"""
function observer_provenance(source::ModelObserverSource)
    provenance = describe_backend(source.backend)
    provenance["max_attempts"] = source.max_attempts
    provenance["on_failure"] = String(source.on_failure)
    provenance["requests"] = length(source.records)
    provenance["failed_requests"] = count(r -> r.response === nothing, source.records)
    return provenance
end
