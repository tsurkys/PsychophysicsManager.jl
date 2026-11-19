# Model observers: participants that are programs rather than people.
#
# A *simulated* observer decides from the stimulus description with a known
# psychometric rule, and validates this package end to end; a *model* observer
# forwards the rendered stimulus to an external model, and measures that model.
# Both plug in through the same backend interface, so the session, the method
# and the analytics cannot tell them apart. The transport of the second kind
# (HTTP, an API key, image encoding) lives in an extension, never here: the core
# stays headless and dependency-free.
#
# What is asked, and what an answer means, is not here either: `ObserverTask`
# belongs to the session (`Core/task.jl`), because a person is asked the same
# question in the same terms.

"""
    AbstractObserverBackend

Something that can be asked a forced-choice question about a presentation and
answers it. Implement [`query_observer`](@ref) for a concrete backend.
"""
abstract type AbstractObserverBackend end

"""
    ObserverQuestion(task, context)

One presentation put to a backend: the fixed task plus the
[`TrialContext`](@ref) of the trial being answered (which carries the rendered
frame, when the engine reports one).
"""
struct ObserverQuestion
    task::ObserverTask
    context::TrialContext
end

"""
    ObserverAnswer(; choice, raw, latency_s, metadata)

What a backend reports back.

`choice` is one of the task's options, or `nothing` when the backend produced
nothing usable (a declined request, an unparseable reply, a transport failure) —
missing data, which is never coerced into a response.

`latency_s` is wall-clock time spent obtaining the answer: for a networked model
that is transport plus inference, and it is **not** a reaction time.
"""
struct ObserverAnswer
    choice::Union{Nothing, String}
    raw::String
    latency_s::Float64
    metadata::Dict{String, Any}
end

ObserverAnswer(; choice::Union{Nothing, AbstractString} = nothing, raw::AbstractString = "",
               latency_s::Real = 0.0, metadata::AbstractDict = Dict{String, Any}()) =
    ObserverAnswer(choice === nothing ? nothing : String(choice), String(raw),
                   Float64(latency_s), Dict{String, Any}(metadata))

"""
    query_observer(backend::AbstractObserverBackend, question::ObserverQuestion) -> ObserverAnswer

Asks `backend` one question and returns its answer. Implementations report a
failed or unusable reply as an `ObserverAnswer` with `choice = nothing` rather
than throwing, so that the retry and invalidation policy stays in one place
(see [`ModelObserverSource`](@ref)).
"""
function query_observer(backend::AbstractObserverBackend, question::ObserverQuestion)
    error("query_observer not implemented for $(typeof(backend))")
end
