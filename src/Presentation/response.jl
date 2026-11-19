# Participant response sources. Separated from the engine contract on purpose:
# an engine renders, a response source supplies the response,
# and an engine that owns its own input device may still report both.

"""
    TrialContext

What a response source is told about the presentation it is answering. A human
participant reads this off the screen; a programmatic participant (a model
observer, a scripted bot) needs it handed over explicitly.

`frame` holds the pixels of the presentation when the engine keeps a buffer and
reports it through [`last_frame`](@ref) — that is what lets a model observer see
the *same* raster a human sees, rather than a separately generated picture. It
is `nothing` for engines that do not rasterize (audio, external processes) and
for engines that simply do not report a buffer.

`timeout_s` is how long the session gives the participant to answer this
presentation, or `nothing` for an unbounded wait (`set_timeout!`).
Enforcing it belongs to the source rather than to the Core, because only the
source knows how to stop waiting on its own device without swallowing the input
that arrives late — an abandoned reader would consume the next trial's keypress.
A source that cannot honor a deadline ignores the field and keeps blocking.

`earliest_response` is the unix time before which a press does not answer this
presentation, or `nothing`: on a trial's first presentation it is the trial's onset plus
the session's `min_response_s`, so a double press or a key held from the trial before is
dropped, silently, by the source that reads the device ([`await_channel_response`](@ref)).

The context is a value object: it carries the stimulus description and the
trial's independent-variable values, never the mutable `SessionContext`. A
response source answers a question; it does not steer the session.
"""
struct TrialContext
    stim_par::AbstractStimulusParameters
    indep_var_names::Vector{Symbol}
    indep_var_vals::Vector{Float64}
    trial_index::Int
    experiment_name::String
    frame::Union{Nothing, AbstractMatrix}
    timeout_s::Union{Nothing, Float64}
    earliest_response::Union{Nothing, Float64}
end

# Compatibility constructor: a deadline is opt-in, and a caller assembling a
# context by hand (a preview, a test) usually has none to declare
TrialContext(stim_par, names, vals, trial_index, experiment_name, frame) =
    TrialContext(stim_par, names, vals, trial_index, experiment_name, frame, nothing)
TrialContext(stim_par, names, vals, trial_index, experiment_name, frame, timeout_s) =
    TrialContext(stim_par, names, vals, trial_index, experiment_name, frame, timeout_s,
                 nothing)

TrialContext(session::SessionContext, vals::AbstractVector{<:Number},
             frame::Union{Nothing, AbstractMatrix};
             earliest_response::Union{Nothing, Float64} = nothing) =
    TrialContext(session.stim_par,
                 session.ex_par.indep_var_names,
                 Float64.(vals),
                 session.current_trial_idx,
                 session.ex_par.experiment_name,
                 frame,
                 session.timeout_s,
                 earliest_response)

"""
    AbstractResponseSource

Supplies participant responses for engines that do not capture input
themselves (see `PresentationResult`). One source is active per process
(`set_response_source!`); the default is `ConsoleResponseSource`, so a
render-only engine works headless out of the box. The GLMakie operator
dashboard registers itself as the source when opened, turning the dashboard
window's keyboard into the response device.
"""
abstract type AbstractResponseSource end

"""
    request_response(source::AbstractResponseSource) -> (response, timestamp::Float64)
    request_response(source::AbstractResponseSource, context::TrialContext) -> (response, timestamp::Float64)

Blocks until one raw response (abstract coding -1/0/+1) is available, or until
the context's response window closes, in which case the response is the sentinel
`:timeout`. A source that does not implement a deadline blocks until an
answer arrives, whatever the context declares.

The Core loop always calls the two-argument form. Sources that
answer from a device or a script ignore the context and need only implement the
one-argument form — the fallback below forwards to it, so every source written
against the original contract keeps working unchanged. Sources that *derive* a
response from the stimulus (model observers) implement the two-argument form and
read the presentation out of the [`TrialContext`](@ref).
"""
function request_response(source::AbstractResponseSource)
    error("request_response not implemented for $(typeof(source))")
end

request_response(source::AbstractResponseSource, ::TrialContext) = request_response(source)

"""
    present_message(source::AbstractResponseSource, message::ParticipantMessage)

Shows a message to the participant through the response source. The default
does nothing and returns at once, which suits sources answered programmatically
or by scripts.
"""
present_message(::AbstractResponseSource, ::ParticipantMessage) = nothing

"""
    reads_messages(source::AbstractResponseSource) -> Bool

Whether the participant answering through `source` reads messages shown between
trials. The default is `true`. Model observers override this to `false` because
their requests carry the instructions directly and a programmatic observer has
no need for breaks or closing messages.
"""
reads_messages(::AbstractResponseSource) = true

# ── Console source (headless default) ────────────────────────────────────────

"""
    ConsoleResponseSource

Default response source: prompts for one response on the terminal.

The prompt outlives a response window that closes before the participant types.
The reader is kept and awaited again on the next request, so a line typed
late answers the next presentation instead of being swallowed by a reader nobody
waits for any more, and the terminal is never read by two waiters at once.

A session whose last presentation timed out therefore ends with that reader
still waiting. A script exits and takes it with it; in an interactive session it
consumes the next line typed at the REPL, so run a timed session from a script,
or answer the prompt once after it.

Between trials it prints instructions, break and closing messages, awaiting a line
on dismissible messages once the required display time has passed.
"""
mutable struct ConsoleResponseSource <: AbstractResponseSource
    reader::Union{Nothing, Task}   # a prompt still waiting for its line

    ConsoleResponseSource() = new(nothing)
end

function _parse_console_response(input::AbstractString)
    response = tryparse(Int, strip(input))
    return response !== nothing && response in (-1, 0, 1) ? response : nothing
end

function _await_console_response(source::ConsoleResponseSource,
                                 timeout_s::Union{Nothing, Real})
    deadline = timeout_s === nothing ? nothing : time() + Float64(timeout_s)
    while true
        if source.reader === nothing
            print("Response (-1, 0, or 1): ")
            source.reader = @async (String(readline()), time())
        end
        reader = source.reader

        if deadline !== nothing && !istaskdone(reader)
            remaining = deadline - time()
            if remaining <= 0.0
                return (:timeout, time())
            end
            timedwait(() -> istaskdone(reader), remaining; pollint = 0.02)
            istaskdone(reader) || return (:timeout, time())
        end

        (line, t) = fetch(reader)
        source.reader = nothing
        response = _parse_console_response(line)
        if response !== nothing
            return (response, t)
        end
        println("Invalid response. Enter -1, 0, or 1.")
    end
end

function present_message(source::ConsoleResponseSource, message::ParticipantMessage)
    println()
    println(message.text)
    if !message.dismissible
        while message.keep_waiting()
            sleep(0.02)
        end
        return nothing
    end

    t0 = time()
    while time() - t0 < message.min_s
        message.keep_waiting() || return nothing
        sleep(0.02)
    end
    message.keep_waiting() || return nothing

    println("Press Enter to continue.")
    if source.reader === nothing
        source.reader = @async (String(readline()), time())
    end

    while true
        message.keep_waiting() || return nothing
        if istaskdone(source.reader)
            source.reader = nothing
            return nothing
        end
        sleep(0.02)
    end
end

request_response(source::ConsoleResponseSource) =
    _await_console_response(source, nothing)

request_response(source::ConsoleResponseSource, context::TrialContext) =
    _await_console_response(source, context.timeout_s)

# ── Scripted source (tests, previews, dry runs) ──────────────────────────────

"""
    ScriptedResponseSource(responses::AbstractVector{<:Real})

Replays a fixed sequence of responses, one per `request_response` call. Use it
to drive a render-only engine deterministically — in tests, in a stimulus
preview that must not open the console, or in a dry run of a scenario.

Running out of scripted responses is an error rather than a silent repeat: a
session that asks for more responses than the script provides is presenting
more often than the script's author expected.

A scripted entry may be the sentinel `:timeout`, which stands for a response
window that closed with nothing answered — the outcome of a real deadline,
written down instead of waited for.
"""
struct ScriptedResponseSource{T} <: AbstractResponseSource
    responses::Vector{T}
    next_idx::Base.RefValue{Int}
end

# Responses keep their natural numeric type: a script of Ints
# stays Int, so methods dispatching on integer responses see what they expect.
function ScriptedResponseSource(responses::AbstractVector{T}) where {T}
    for response in responses
        response isa Real || response === :timeout || throw(ArgumentError(
            "A scripted response is a number or the sentinel :timeout, got " *
            "$(repr(response))."))
    end
    return ScriptedResponseSource{T}(collect(responses), Ref(1))
end

function request_response(source::ScriptedResponseSource)
    idx = source.next_idx[]
    if idx > length(source.responses)
        error("ScriptedResponseSource is exhausted: all " *
              "$(length(source.responses)) scripted responses were consumed, " *
              "but another response was requested.")
    end
    source.next_idx[] = idx + 1
    return (source.responses[idx], time())
end

# ── Window keys ──────────────────────────────────────────────────────────────

"""
    ChannelResponseSource(channel)

Makes a window's response keys the active participant response source, so
render-only engines (e.g. the audio engine) collect responses without any input
code of their own. The window puts one `(response, unix time)` pair into
`channel` per key press, the time taken when the key event arrived; the operator
dashboard registers one for its own window. A message between trials
([`present_message`](@ref)) is held in the source ([`shown_message`](@ref)) until a key
ends it.
"""
struct ChannelResponseSource <: AbstractResponseSource
    channel::Channel{Tuple{Int, Float64}}
    message::Base.RefValue{Union{Nothing, ParticipantMessage}}

    ChannelResponseSource(channel::Channel{Tuple{Int, Float64}}) =
        new(channel, Ref{Union{Nothing, ParticipantMessage}}(nothing))
end

"""
    shown_message(source::ChannelResponseSource) -> Union{Nothing, ParticipantMessage}

The message the source shows the participant while it waits for the key that ends it,
or `nothing`. The window that feeds the source draws it, and passes its keys on
meanwhile as during a trial.
"""
shown_message(source::ChannelResponseSource) = source.message[]

function present_message(source::ChannelResponseSource, message::ParticipantMessage)
    source.message[] = message
    try
        await_message_key(source.channel, message)
    finally
        source.message[] = nothing
    end
    return nothing
end

request_response(source::ChannelResponseSource) = take!(source.channel)

function request_response(source::ChannelResponseSource, context::TrialContext)
    reply = await_channel_response(source.channel, context.timeout_s;
                                   earliest = context.earliest_response)
    return reply === nothing ? (:timeout, time()) : reply
end

"""
    discard_pending_responses!(source::AbstractResponseSource)

Drops the responses a source holds that no presentation has taken yet. The Core calls
it on the active source when the trial under way is abandoned for a stimulus the
operator asked for at once, so a key pressed for the abandoned trial cannot answer the
stimulus presented in its place. The default has nothing to drop.
"""
discard_pending_responses!(::AbstractResponseSource) = nothing

function discard_pending_responses!(source::ChannelResponseSource)
    while isready(source.channel)
        take!(source.channel)
    end
    return nothing
end

"""
    await_channel_response(channel, timeout_s; earliest = nothing) -> Union{Nothing, Tuple{Int, Float64}}

One keypress from a window's response channel, or `nothing` when the response
window closed with none in it. `timeout_s === nothing` waits indefinitely. A press
stamped before `earliest`, a unix time, is dropped without a word and the wait goes on
within the same window (`min_response_s`, [`load_input_config`](@ref)).

Waiting on `take!` and abandoning it would leave a taker behind that swallows
the next trial's keypress, so the deadline is watched from outside the channel:
a key pressed late stays in it and answers the next presentation, as the console
prompt does. Every window response path waits through this one function.
"""
function await_channel_response(channel::Channel{Tuple{Int, Float64}},
                                timeout_s::Union{Nothing, Real};
                                earliest::Union{Nothing, Real} = nothing)
    deadline = timeout_s === nothing ? nothing : time() + Float64(timeout_s)
    while true
        if deadline === nothing
            reply = take!(channel)
        else
            isready(channel) || timedwait(() -> isready(channel),
                                          max(deadline - time(), 0.0); pollint = 0.02)
            isready(channel) || return nothing
            reply = take!(channel)
        end
        (earliest === nothing || last(reply) >= earliest) && return reply
    end
end

"""
    await_message_key(channel, message::ParticipantMessage)

Waits on a window's response channel until `message` ends: on a key pressed no sooner
than `message.min_s` after the wait began, for a dismissible message, or as soon as
`message.keep_waiting()` is `false`. A key pressed earlier, or one left in the channel
before or after, is dropped, so neither a key held over from the last trial nor the key
that ended the message answers a trial. Every window that shows messages waits through
this one function.
"""
function await_message_key(channel::Channel{Tuple{Int, Float64}}, message::ParticipantMessage)
    drain!(channel) = while isready(channel); take!(channel); end
    drain!(channel)
    shown = time()
    try
        while message.keep_waiting()
            while isready(channel)
                take!(channel)
                message.dismissible && time() - shown >= message.min_s && return nothing
            end
            sleep(0.02)
        end
    finally
        drain!(channel)
    end
    return nothing
end

"""
    offer_response!(channel, response) -> Bool

Puts one key press into a window's response channel, stamped now, unless a press
is already waiting there. Returns whether it was taken. The channel holds one
press: a participant hammering a key must not queue up answers for trials not
yet presented.
"""
function offer_response!(channel::Channel{Tuple{Int, Float64}}, response::Int)
    isready(channel) && return false
    put!(channel, (response, time()))
    return true
end

# ── Active source ────────────────────────────────────────────────────────────

const ACTIVE_RESPONSE_SOURCE = Ref{AbstractResponseSource}(ConsoleResponseSource())

"""
    set_response_source!(source::AbstractResponseSource)

Makes `source` the process-wide provider of participant responses for
render-only engines. Returns the source.

Prefer `with_response_source` (or `swap_response_source!` plus a `finally`
block) whenever the source is only meant to be active for part of the
process's lifetime: a source left behind by a closed window blocks the next
session on a channel nothing feeds any more.
"""
set_response_source!(source::AbstractResponseSource) =
    (ACTIVE_RESPONSE_SOURCE[] = source; source)

"""
    swap_response_source!(source::AbstractResponseSource) -> previous

Installs `source` and returns the source it replaced, so the caller can
restore it later.
"""
function swap_response_source!(source::AbstractResponseSource)
    previous = ACTIVE_RESPONSE_SOURCE[]
    ACTIVE_RESPONSE_SOURCE[] = source
    return previous
end

"""
    with_response_source(f, source::AbstractResponseSource)

Runs `f()` with `source` as the active response source and restores the
previous source afterwards, including when `f` throws.

```julia
with_response_source(ScriptedResponseSource([1, -1, 0])) do
    run_experiment!(session, engine)
end
```
"""
function with_response_source(f, source::AbstractResponseSource)
    previous = swap_response_source!(source)
    try
        return f()
    finally
        ACTIVE_RESPONSE_SOURCE[] = previous
    end
end
