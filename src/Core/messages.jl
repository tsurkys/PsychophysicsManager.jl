# Participant messages between trials: instructions before the first trial,
# breaks after scheduled trial counts, and a closing message after the last trial.

"""
    SessionMessages(; instructions=false, break_every=0, break_after=Int[],
                    break_waits_for=:participant, break_min_s=0.0,
                    break_text="", closing_text="")

Declares when messages are shown to the participant during a session and what they say;
a session's are set with [`set_messages!`](@ref).

# Fields
- `instructions::Bool`: show `session.task.instructions` before the first trial.
- `break_every::Int`: a break after every `n` recorded trials; 0 = none.
- `break_after::Vector{Int}`: explicit recorded-trial counts after which a break is shown.
- `break_waits_for::Symbol`: who dismisses the break: `:participant` or `:operator`.
- `break_min_s::Float64`: minimum display time before a participant's key dismisses the break.
- `break_text::String`: message shown during a break.
- `closing_text::String`: message shown after the last trial (`""` = none).
"""
struct SessionMessages
    instructions::Bool
    break_every::Int
    break_after::Vector{Int}
    break_waits_for::Symbol
    break_min_s::Float64
    break_text::String
    closing_text::String

    function SessionMessages(instructions::Bool,
                             break_every::Integer,
                             break_after::AbstractVector{<:Integer},
                             break_waits_for::Symbol,
                             break_min_s::Real,
                             break_text::AbstractString,
                             closing_text::AbstractString)
        break_every >= 0 ||
            throw(ArgumentError("break_every must be non-negative, got $break_every."))
        after = sort(unique(Int.(break_after)))
        for entry in after
            entry >= 1 ||
                throw(ArgumentError("Every break_after entry must be >= 1, got $entry."))
        end
        break_waits_for in (:participant, :operator) ||
            throw(ArgumentError("break_waits_for must be :participant or :operator, got $(repr(break_waits_for))."))
        (isfinite(break_min_s) && break_min_s >= 0.0) ||
            throw(ArgumentError("break_min_s must be finite and >= 0.0, got $break_min_s."))
        scheduled = break_every > 0 || !isempty(after)
        if scheduled && isempty(strip(break_text))
            throw(ArgumentError("break_text must not be blank when breaks are scheduled."))
        end
        return new(instructions, Int(break_every), after, break_waits_for,
                   Float64(break_min_s), String(break_text), String(closing_text))
    end
end

SessionMessages(; instructions::Bool = false,
                  break_every::Integer = 0,
                  break_after::AbstractVector{<:Integer} = Int[],
                  break_waits_for::Symbol = :participant,
                  break_min_s::Real = 0.0,
                  break_text::AbstractString = "",
                  closing_text::AbstractString = "") =
    SessionMessages(instructions, break_every, break_after, break_waits_for,
                    break_min_s, break_text, closing_text)

function Base.:(==)(a::SessionMessages, b::SessionMessages)
    return a.instructions == b.instructions &&
           a.break_every == b.break_every &&
           a.break_after == b.break_after &&
           a.break_waits_for == b.break_waits_for &&
           a.break_min_s == b.break_min_s &&
           a.break_text == b.break_text &&
           a.closing_text == b.closing_text
end

function Base.hash(m::SessionMessages, h::UInt)
    h = hash(m.instructions, h)
    h = hash(m.break_every, h)
    h = hash(m.break_after, h)
    h = hash(m.break_waits_for, h)
    h = hash(m.break_min_s, h)
    h = hash(m.break_text, h)
    return hash(m.closing_text, h)
end

breaks_scheduled(m::SessionMessages) = m.break_every > 0 || !isempty(m.break_after)

function break_due(m::SessionMessages, recorded::Int)::Bool
    return (m.break_every > 0 && recorded > 0 && recorded % m.break_every == 0) ||
           (recorded in m.break_after)
end

"""
    ParticipantMessage(kind, text, dismissible, min_s, keep_waiting)

A message displayed to the participant.

# Fields
- `kind::Symbol`: `:instructions`, `:break`, or `:closing`.
- `text::String`: the text of the message.
- `dismissible::Bool`: whether the participant can end it with a key.
- `min_s::Float64`: minimum display time in seconds before a key is accepted; earlier keys are discarded.
- `keep_waiting::Function`: predicate `() -> Bool` polled by whoever presents the message; returns `false` once the operator or the session ended it.

A presenter returns as soon as `keep_waiting()` is `false`. A non-dismissible message
is shown until `keep_waiting()` is `false`.
"""
struct ParticipantMessage
    kind::Symbol
    text::String
    dismissible::Bool
    min_s::Float64
    keep_waiting::Function

    function ParticipantMessage(kind::Symbol, text::AbstractString, dismissible::Bool,
                                min_s::Real, keep_waiting::Function)
        return new(kind, String(text), dismissible, Float64(min_s), keep_waiting)
    end
end
