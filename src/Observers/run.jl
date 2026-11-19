# Running a session with a model observer, and reporting what the run cost.
#
# The invalidation callback and the provenance record are part of the method,
# and both are easy to forget, so they live here rather than in every
# experiment script. So are the task and the tags that identify a model session:
# hand-written in a script they are a second place for a fact that the backend
# already knows, free to disagree with it.

"""
    run_observer_experiment!(session, source, engine; kwargs...) -> ModelObserverSource

Runs `session` with a model observer as the participant and returns `source`,
whose `records` hold the per-request audit trail.

It installs `source` as the active response source, records the source's task
and the tags that mark a model session, invalidates every unanswered trial the
moment it is recorded (see [`invalidate_failed_trials!`](@ref)), stores the
observer provenance in the session, and closes `engine` — the last two in a
`finally`, so an interrupted run still says who answered.

`kwargs` are forwarded to [`run_experiment!`](@ref); an `on_trial_end` callback
of your own runs after the invalidation step. Pass `close_engine = false` to keep
the engine open for another session.

```julia
source = run_observer_experiment!(session,
                                  ModelObserverSource(backend, task; on_failure = :invalidate),
                                  OffscreenVisualEngine(900, 200))
print_observer_summary(session, source)
```
"""
function run_observer_experiment!(session::SessionContext, source::ModelObserverSource,
                                  engine::AbstractStimulusEngine;
                                  on_trial_end = nothing, close_engine::Bool = true,
                                  kwargs...)
    function after_trial(s::SessionContext)
        invalidate_failed_trials!(source, s)
        on_trial_end === nothing || on_trial_end(s)
        return nothing
    end

    set_task!(session, source.task)
    stamp_observer_tags!(session, source.backend)

    try
        with_response_source(source) do
            run_experiment!(session, engine; on_trial_end = after_trial, kwargs...)
        end
    finally
        set_observer_metadata!(session, observer_provenance(source))
        close_engine && close_engine!(engine)
    end
    return source
end

const MODEL_OBSERVER_TAG = "ai-observer"

"""
    stamp_observer_tags!(session, backend) -> session

Adds the tags that identify a session answered by a program: `ai-observer`, and
`model:<id>` for a backend that names one. Derived from the backend rather than
written in the experiment script, so a tag cannot name a model other than the
one that answered. Idempotent, and it never removes a tag of the operator's.
"""
function stamp_observer_tags!(session::SessionContext, backend::AbstractObserverBackend)
    description = describe_backend(backend)
    tags = [MODEL_OBSERVER_TAG]
    haskey(description, "model") && push!(tags, "model:" * string(description["model"]))
    for tag in tags
        tag in session.tags || push!(session.tags, tag)
    end
    return session
end

"""
    observer_summary(source) -> NamedTuple

What the requests behind a session cost, and what went wrong:

- `requests`, `failed` — attempts made, and how many produced nothing usable
  (retries included, so `requests` exceeds the trial count when answers failed);
- `failures` — the failure reasons, most frequent first; a refusal, an
  unroutable request and an unparseable reply call for different fixes;
- `median_latency_s` — transport plus inference, **not** a reaction time;
- `cost` — the real price when the channel reports it (OpenRouter does), `0.0`
  otherwise.
"""
function observer_summary(source::ModelObserverSource)
    tally = Dict{String, Int}()
    for record in source.records
        record.response === nothing || continue
        reason = string(get(record.metadata, "failure", "unknown"))
        tally[reason] = get(tally, reason, 0) + 1
    end
    failures = sort!(collect(tally); by = pair -> (-pair.second, pair.first))

    latencies = Float64[r.latency_s for r in source.records]
    cost = sum(Float64[Float64(r.metadata["cost"]) for r in source.records
                       if haskey(r.metadata, "cost")]; init = 0.0)

    return (requests = length(source.records),
            failed = sum(pair -> pair.second, failures; init = 0),
            failures = failures,
            median_latency_s = isempty(latencies) ? 0.0 : median(latencies),
            cost = cost)
end

"""
    constant_response(session) -> Union{Nothing, Tuple{String, Int, Int}}

The option that dominated a session — its name, how many valid trials chose it,
and how many valid trials there were — or `nothing` when no option reached 90 %
of them, when there are fewer than 10, or when the session declared no task to
name the option with.

An observer that answers the same way regardless of the stimulus scores exactly
50 % on a level set balanced around the threshold, so aggregate accuracy cannot
tell it from a random one. A handful of departures from one option does not
change that reading, which is why the rule is a share and not a unanimity; below
10 valid trials it would demand unanimity anyway, so short sessions are left
unjudged rather than judged by a different rule.
"""
function constant_response(session::SessionContext)
    task = session.task
    task === nothing && return nothing
    valid = count(t -> t.is_valid, session.history)
    valid >= 10 || return nothing

    positive = count(t -> t.is_valid && t.response == 1, session.history)
    option, times = 2 * positive >= valid ? (task.positive_option, positive) :
                                            (negative_option(task), valid - positive)
    return 10 * times >= 9 * valid ? (option, times, valid) : nothing
end

"""
    print_observer_summary(session, source)

Prints how much of the session the observer actually answered, whether one option
dominated its answers, what the failures were, and what the run cost. Works
headless, like [`print_adjustment_summary`](@ref).
"""
function print_observer_summary(session::SessionContext, source::ModelObserverSource)
    answered = count(t -> t.is_valid, session.history)
    total = length(session.history)
    summary = observer_summary(source)

    println("\n── Model observer ──")
    println("Answered: $answered of $total trials")
    constant = constant_response(session)
    if constant !== nothing
        option, times, valid = constant
        println("Dominant answer: \"$option\" on $times of $valid valid trials. " *
                "Either every level sits on one side of the threshold, or the observer " *
                "answered without regard to the stimulus; the per-level proportions " *
                "tell the two apart.")
    end
    if !isempty(summary.failures)
        reasons = join(["$(reason) ×$(times)" for (reason, times) in summary.failures], ", ")
        println("Unanswered requests: $(summary.failed) of $(summary.requests) ($reasons)")
        answered < total &&
            println("Their trials are marked invalid and excluded from the fit.")
    end
    summary.median_latency_s > 0 &&
        println("Request latency: median $(round(summary.median_latency_s, digits = 2)) s")
    summary.cost > 0 &&
        println("Cost: \$$(round(summary.cost, digits = 4)) " *
                "($(round(summary.cost / max(summary.requests, 1), digits = 5)) per request)")
    return nothing
end
