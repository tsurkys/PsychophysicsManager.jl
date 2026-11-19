# Built-in engine that presents through a program running outside Julia: a
# worker that owns the display and the input device — Psychtoolbox under MATLAB
# or Octave is the case this was written for — and answers one JSON line per
# presentation. The transport is the `Sockets` stdlib or the standard streams of
# a spawned process, so the core gains no dependency and the worker needs no
# Julia at all. The line protocol is described in `workers/README.md`.

using Sockets

"""
The protocol version this PsychophysicsManager speaks. It is sent with every command and
checked against what the worker reports at the handshake, so that a worker
written for an older line format is refused at connection time rather than
halfway through a session.
"""
const REMOTE_PROTOCOL_VERSION = 1

"""
    RemoteEngine(host, port; read_timeout_s = nothing)
    RemoteEngine(io::IO; read_timeout_s = nothing, address = "stdio")

A stimulus engine whose presentation happens in another process. Constructing it
connects, performs the handshake, and refuses anything that does not answer as a
worker — so a wrong program listening on the port is a connection-time error and
not a puzzling first trial.

Each presentation sends one JSON line and blocks for one JSON reply line. **The
response timestamp is measured by the worker**, where the input device is read,
and travels back in the reply: were the Core to stamp the reply's arrival, every
reaction time would carry the inter-process latency of that trial. For the same
reason a reported timestamp must be a unix time (see [`set_response_timeout!`](@ref)
for the response window, and `workers/README.md` for the whole protocol).

A worker whose `hello` reply declares the `abandon` capability ends a presentation
when asked to — for a stimulus the operator wants at once, or for Stop
([`abandon_presentation!`](@ref)). One that does not is waited for: its answer would
otherwise arrive after all and be read as the answer to the next command.

`read_timeout_s` is the transport's patience, and is **not** the participant's
response window: a worker that answers nothing at all is a dropped connection
with the socket still open, which no response window can end, because the window
is enforced by the worker that stopped answering. Left `nothing` (the default) a
silent worker blocks the session until the operator interrupts it; set to a few
seconds more than the longest legitimate response window it will be given, and
silence past that aborts the session with a message naming the worker.

The second constructor takes an already-connected stream, which is how a spawned
process is driven:

```julia
RemoteEngine(open(`octave --quiet --eval "pem_worker(0)"`, "r+"))
```
"""
mutable struct RemoteEngine <: AbstractStimulusEngine
    io::IO
    address::String                       # how to say where this worker is
    worker::String                        # what it called itself at the handshake
    version::Union{Nothing, String}       # the version its hello reply named
    capabilities::Vector{String}          # the optional commands it named there
    stimuli::Vector{WorkerStimulus}       # the stimuli it declared, with their defaults
    display::Dict{String, String}         # viewing conditions it reported
    timeout_s::Union{Nothing, Float64}    # the participant's response window
    min_response_s::Float64               # presses sooner after onset are dropped
    read_timeout_s::Union{Nothing, Float64}  # the transport's patience
    presentations::Int
    live::Bool
    awaiting::Union{Nothing, String}  # the command whose reply line is not yet read
    abandoned::Int                    # the presentation an abandon was sent for, or 0
end

function RemoteEngine(io::IO; read_timeout_s::Union{Nothing, Real} = nothing,
                      address::AbstractString = "stdio")
    engine = RemoteEngine(io, String(address), "unidentified", nothing, String[],
                          WorkerStimulus[], Dict{String, String}(), nothing, 0.0,
                          read_timeout_s === nothing ? nothing : Float64(read_timeout_s),
                          0, true, nothing, 0)
    return _remote_hello!(engine)
end

function RemoteEngine(host, port::Integer; read_timeout_s::Union{Nothing, Real} = nothing)
    address = "$host:$port"
    io = try
        Sockets.connect(host, port)
    catch e
        error("No remote worker answered at $address ($(sprint(showerror, e))). " *
              "Start the presentation worker before the session: it listens, " *
              "PsychophysicsManager connects.")
    end
    return RemoteEngine(io; read_timeout_s = read_timeout_s, address = address)
end

"""
    initialize_engine(::Type{RemoteEngine}, stim_par, config::DisplayConfig)

Connects to the worker named by the `[remote]` section of the nearest
`settings.toml`. `config` is unused on purpose: the display belongs to
the worker's process, which is why the worker reports its own viewing conditions
at the handshake and they reach the session through [`display_info`](@ref)
instead of being dictated from here.
"""
function initialize_engine(::Type{RemoteEngine}, ::AbstractStimulusParameters,
                           ::DisplayConfig)
    config = load_remote_worker_config()
    return RemoteEngine(config.host, config.port;
                        read_timeout_s = config.read_timeout_s)
end

# The worker's own identity travels with the session: `engine_name` records only
# that a remote worker presented, and which program that was is exactly what a
# later reader of the file cannot reconstruct.
function display_info(engine::RemoteEngine)
    info = copy(engine.display)
    info["remote_worker"] = engine.worker
    info["remote_address"] = engine.address
    return info
end

# The worker is the program that presents, and its version is what it says it is
find_stimulus(engine::RemoteEngine, ::AbstractStimulusParameters) =
    ("remote worker $(engine.worker)", something(engine.version, UNKNOWN_STIMULUS_VERSION), false)

set_response_timeout!(engine::RemoteEngine, timeout_s) =
    (engine.timeout_s = timeout_s; nothing)
set_min_response_time!(engine::RemoteEngine, min_s) =
    (engine.min_response_s = Float64(min_s); nothing)


"""
    declared_stimuli(engine::RemoteEngine) -> Vector{String}

The stimuli the worker declares in its hello reply, by name and in its order. A
worker that declares none is given Julia stimulus types.
"""
declared_stimuli(engine::RemoteEngine) = [stimulus.stimulus for stimulus in engine.stimuli]

"""
    worker_stimulus(engine::RemoteEngine, name) -> WorkerStimulus

The stimulus the worker declares as `name`, with the defaults it declares: what a session
presenting it starts from. Saved as a template, it is chosen in the dashboard as any
other.

```julia
engine = RemoteEngine("127.0.0.1", 5555)
stimulus = worker_stimulus(engine, "oppel_kundt")
set_parameter!(stimulus, :Ref, 120)
session = SessionContext("P01", ExperimentParameters("OK", :DistrN, 0:4, 5), stimulus,
                         ConstantStimuli())
```
"""
function worker_stimulus(engine::RemoteEngine, name::AbstractString)
    index = findfirst(stimulus -> stimulus.stimulus == name, engine.stimuli)
    index === nothing && throw(ArgumentError(undeclared_text(engine, name)))
    return deepcopy(engine.stimuli[index])
end

function declared_parameters(engine::RemoteEngine, stim_par::WorkerStimulus)
    index = findfirst(stimulus -> stimulus.stimulus == stim_par.stimulus, engine.stimuli)
    index === nothing && error(undeclared_text(engine, stim_par.stimulus))
    return engine.stimuli[index].parameters
end

undeclared_text(engine::RemoteEngine, name::AbstractString) = isempty(engine.stimuli) ?
    "The worker $(engine.worker) at $(engine.address) declares no stimuli in its hello " *
    "reply, so it cannot be given the stimulus $name: a worker lists the stimuli it " *
    "presents, with their parameters and defaults, under \"stimuli\" (workers/README.md)." :
    "The worker $(engine.worker) at $(engine.address) declares no stimulus $name; it " *
    "declares $(join(declared_stimuli(engine), ", "))."

# A reply abandoned on the way would be read as the answer to the next command, so a
# presentation awaiting its reply is ended by the worker or not at all
can_abandon_presentation(engine::RemoteEngine) =
    engine.awaiting === nothing || ends_presentation(engine)

ends_presentation(engine::RemoteEngine) =
    engine.awaiting == "present" && "abandon" in engine.capabilities

# The worker answers the `present` under way with "abandoned", which
# `_remote_response` raises in the trial loop's task; `abandon` has no reply of its
# own. A worker that answered first ignores it, and that answer is recorded.
function abandon_presentation!(engine::RemoteEngine)
    ends_presentation(engine) || return false
    engine.abandoned = engine.presentations
    try
        _remote_send(engine, Dict{String, Any}("command" => "abandon",
                                               "presentation" => engine.presentations))
    catch
        # The reply the loop awaits cannot come over a broken connection either
        return false
    end
    return true
end

# ── The line protocol ────────────────────────────────────────────────────────

function _remote_hello!(engine::RemoteEngine)
    reply = _remote_call(engine, Dict{String, Any}("command" => "hello"))

    name = get(reply, :worker, nothing)
    name isa AbstractString && !isempty(name) || begin
        engine.live = false
        close(engine.io)
        error("Whatever answered at $(engine.address) is not a PsychophysicsManager " *
              "presentation worker: its reply to the hello command named no " *
              "worker. Expected a JSON line with a non-empty \"worker\" field.")
    end
    engine.worker = String(name)

    version = get(reply, :protocol, nothing)
    if version != REMOTE_PROTOCOL_VERSION
        engine.live = false
        close(engine.io)
        error("The worker $(engine.worker) at $(engine.address) named line " *
              "protocol version $(repr(version)); this PsychophysicsManager speaks " *
              "$REMOTE_PROTOCOL_VERSION. A worker names the version it speaks " *
              "in its hello reply, and a mismatch is refused here rather than " *
              "found halfway through a session — the protocol is specified in " *
              "workers/README.md of the PsychophysicsManager package.")
    end

    # Optional: a worker of protocol 1 that names no version is still a worker
    version = get(reply, :version, nothing)
    version === nothing || isempty(string(version)) || (engine.version = string(version))

    # Optional: the stimuli it presents, each with its parameters' defaults
    stimuli = get(reply, :stimuli, nothing)
    if stimuli !== nothing
        engine.stimuli = try
            stimuli isa AbstractDict || throw(ArgumentError(
                "they are an object naming each stimulus"))
            map(collect(pairs(stimuli))) do (name, parameters)
                parameters isa AbstractDict || throw(ArgumentError(
                    "the parameters of $name are an object of names and defaults"))
                WorkerStimulus(String(name), collect(pairs(parameters)))
            end
        catch err
            err isa ArgumentError || rethrow()
            engine.live = false
            close(engine.io)
            error("The worker $(engine.worker) at $(engine.address) declared its stimuli " *
                  "as $(JSON3.write(stimuli)), which PsychophysicsManager cannot read: $(err.msg). " *
                  "They are declared as {\"name\": {\"parameter\": default, …}, …}, " *
                  "each default a number, true or false, text, a list, or null.")
        end
    end

    # Optional commands, by name; one this PsychophysicsManager does not know is never sent
    capabilities = get(reply, :capabilities, nothing)
    if capabilities !== nothing
        capabilities isa AbstractVector && all(c -> c isa AbstractString, capabilities) ||
            begin
                engine.live = false
                close(engine.io)
                error("The worker $(engine.worker) at $(engine.address) named its " *
                      "capabilities as $(JSON3.write(capabilities)); they are a list of " *
                      "the optional commands it answers, such as [\"abandon\"].")
            end
        engine.capabilities = String.(capabilities)
    end

    info = get(reply, :display_info, nothing)
    if info !== nothing
        engine.display = Dict{String, String}(String(k) => string(v)
                                              for (k, v) in pairs(info))
    end
    return engine
end

"""
    present_stimulus(engine::RemoteEngine, stim_par, vals)

Sends the stimulus description and the trial's independent-variable values to
the worker and blocks for its reply. The stimulus travels as `_type`, its name
([`stimulus_name`](@ref)), and `fields`, its parameters by name — the shape a
session file stores it in, so a worker reads the same JSON offline from a saved
session as it does live; the values are also visible already bound into the
parameters the design names. A stimulus the worker declares ([`WorkerStimulus`](@ref))
is sent only with exactly the parameters it declares.
"""
function present_stimulus(engine::RemoteEngine, stim_par::AbstractStimulusParameters,
                          vals::AbstractVector{<:Number})
    stim_par isa WorkerStimulus && confirm_declared(engine, stim_par)
    engine.presentations += 1
    reply = _remote_call(engine, Dict{String, Any}(
        "command"      => "present",
        "presentation" => engine.presentations,
        "stimulus"     => Dict{String, Any}(
            "_type"  => stimulus_name(stim_par),
            "fields" => Dict(string(n) => parameter_value(stim_par, n)
                             for n in parameter_names(stim_par))),
        "values"       => collect(Float64, vals),
        "timeout_s"    => engine.timeout_s,
        "min_response_s" => engine.min_response_s))

    return PresentationResult(
        response           = _remote_response(engine, get(reply, :response, nothing)),
        onset              = _remote_stamp(engine, get(reply, :onset, nothing), "onset"),
        timestamp_response = _remote_stamp(engine, get(reply, :timestamp_response, nothing),
                                           "response timestamp"))
end

# The record holds every value a stimulus was drawn with only if the worker is never
# sent a list of parameters other than the one it declares
function confirm_declared(engine::RemoteEngine, stim_par::WorkerStimulus)
    declared = first.(declared_parameters(engine, stim_par))
    Set(declared) == Set(parameter_names(stim_par)) && return nothing
    error("The worker $(engine.worker) declares the parameters " *
          "$(join(declared, ", ")) of $(stim_par.stimulus), and the stimulus to present " *
          "has $(join(parameter_names(stim_par), ", ")). A session completes its stimulus " *
          "to what the worker declares when it starts; start from worker_stimulus(engine, " *
          "\"$(stim_par.stimulus)\") to present one outside a session.")
end

"""
    present_feedback(engine::RemoteEngine, correct::Bool)

Asks the worker to announce the concluded trial's outcome — it owns the screen
and the speakers, so what the announcement is belongs to it. A worker that shows
no feedback still acknowledges the command, which keeps every command answered
by exactly one line.
"""
present_feedback(engine::RemoteEngine, correct::Bool) =
    (_remote_call(engine, Dict{String, Any}("command" => "feedback",
                                            "correct" => correct)); nothing)

"""
    present_message(engine::RemoteEngine, message::ParticipantMessage)

Shows `message.text` on the remote worker when it declares the `"message"` capability,
or forwards to the active response source otherwise. The operator's Resume or Stop takes
effect once the participant has dismissed a worker's message.
"""
function present_message(engine::RemoteEngine, message::ParticipantMessage)
    if !("message" in engine.capabilities)
        return invoke(present_message, Tuple{AbstractStimulusEngine, ParticipantMessage}, engine, message)
    end
    reply = _remote_call(engine, Dict{String, Any}(
        "command"     => "message",
        "kind"        => string(message.kind),
        "text"        => message.text,
        "dismissible" => message.dismissible,
        "min_s"       => message.min_s))
    get(reply, :ok, nothing) === true || error(
        "The remote worker $(engine.worker) at $(engine.address) answered the " *
        "message command with $(JSON3.write(reply)); expected {\"ok\": true}.")
    if !message.dismissible
        while message.keep_waiting()
            sleep(0.02)
        end
    end
    return nothing
end

"""
    close_engine!(engine::RemoteEngine)

Tells the worker the session is over and closes the connection. No reply is read:
cleanup must not be able to hang on a worker that is already shutting down, so
every failure on the way out is ignored — the connection is going away regardless.
"""
function close_engine!(engine::RemoteEngine)
    if engine.live
        engine.live = false
        try
            println(engine.io, JSON3.write(Dict{String, Any}(
                "command" => "close", "protocol" => REMOTE_PROTOCOL_VERSION)))
            flush(engine.io)
        catch
        end
    end
    try
        close(engine.io)
    catch
    end
    return nothing
end

# ── One command, one reply ───────────────────────────────────────────────────

function _remote_call(engine::RemoteEngine, payload::Dict{String, Any})
    command = payload["command"]
    # Raised before the send, which yields: a trial abandoned during it would otherwise
    # leave the worker's reply to be read as the answer to the next command
    engine.awaiting = command
    line = try
        _remote_send(engine, payload)
        _remote_readline(engine, command)
    finally
        engine.awaiting = nothing
    end

    reply = try
        JSON3.read(line)
    catch e
        engine.live = false
        error("The remote worker at $(engine.address) answered the $command " *
              "command with a line that is not JSON: $(repr(line)).")
    end
    if !(reply isa JSON3.Object)
        engine.live = false
        error("The remote worker at $(engine.address) answered the $command " *
              "command with $(repr(line)); a reply is one JSON object per line.")
    end

    # A worker that cannot present says so instead of inventing a trial: the
    # session ends with the worker's own words rather than with a wrong record.
    failure = get(reply, :error, nothing)
    failure === nothing || error(
        "The remote worker $(engine.worker) at $(engine.address) refused the " *
        "$command command: $failure")

    return reply
end

# One line, written whole: `abandon` is sent from another task than the loop's
function _remote_send(engine::RemoteEngine, payload::Dict{String, Any})
    command = payload["command"]
    engine.live || error("The connection to the remote worker at " *
                         "$(engine.address) is closed, so the $command command " *
                         "cannot be sent. A closed engine is not reopened; " *
                         "build a new one for a new session.")
    payload["protocol"] = REMOTE_PROTOCOL_VERSION
    try
        write(engine.io, JSON3.write(payload) * "\n")
        flush(engine.io)
    catch e
        engine.live = false
        error("The connection to the remote worker at $(engine.address) broke " *
              "while sending the $command command ($(sprint(showerror, e))).")
    end
    return nothing
end

function _remote_readline(engine::RemoteEngine, command::AbstractString)
    io = engine.io
    line = ""

    if engine.read_timeout_s === nothing
        line = try
            readline(io)
        catch e
            engine.live = false
            error("The connection to the remote worker at $(engine.address) " *
                  "broke while waiting for the reply to $command " *
                  "($(sprint(showerror, e))).")
        end
    else
        reader = @async readline(io)
        if timedwait(() -> istaskdone(reader), engine.read_timeout_s;
                     pollint = 0.005) !== :ok
            engine.live = false
            close(io)
            error("The remote worker $(engine.worker) at $(engine.address) did " *
                  "not answer the $command command within read_timeout_s = " *
                  "$(engine.read_timeout_s) s. A worker that stops answering " *
                  "cannot end the participant's response window either, so the " *
                  "session is stopped here rather than left waiting.")
        end
        if istaskfailed(reader)
            engine.live = false
            error("The connection to the remote worker at $(engine.address) " *
                  "broke while waiting for the reply to $command.")
        end
        line = fetch(reader)
    end

    if isempty(line)
        engine.live = false
        error("The remote worker $(engine.worker) at $(engine.address) closed " *
              "the connection instead of answering the $command command. The " *
              "session is aborted; its trials up to this point are saved.")
    end
    return line
end

# ── Reading one reply ────────────────────────────────────────────────────────

_remote_response(::RemoteEngine, ::Nothing) = nothing
_remote_response(::RemoteEngine, x::Real) = x

_remote_response(engine::RemoteEngine, x::Bool) = error(
    "The remote worker $(engine.worker) answered the present command with " *
    "$x. A response is a number in the abstract -1/0/+1 coding, null when the " *
    "worker reads no input, or \"timeout\".")

function _remote_response(engine::RemoteEngine, x::AbstractString)
    x == "timeout" && return :timeout
    if x == "abandoned"
        engine.abandoned == engine.presentations || error(
            "The remote worker $(engine.worker) answered presentation " *
            "$(engine.presentations) with \"abandoned\", but PsychophysicsManager asked it to " *
            "abandon none. A worker answers \"abandoned\" only to a presentation the " *
            "abandon command named.")
        throw(TrialAbandoned())
    end
    error("The remote worker $(engine.worker) answered the present command " *
          "with the string $(repr(x)). The responses that are words are " *
          "\"timeout\", and \"abandoned\" after the abandon command; an answer " *
          "is a number.")
end

_remote_response(engine::RemoteEngine, x) = error(
    "The remote worker $(engine.worker) answered the present command with " *
    "$(repr(x)), which is neither a number, null, nor \"timeout\".")

_remote_stamp(::RemoteEngine, ::Nothing, ::AbstractString) = nothing

function _remote_stamp(engine::RemoteEngine, x::Real, label::AbstractString)
    stamp = Float64(x)
    isfinite(stamp) && stamp > 1.0e9 || error(
        "The remote worker $(engine.worker) reported $stamp as the $label. " *
        "Timestamps cross the connection as unix times, so that one session is " *
        "measured by one clock: a worker whose device clock starts at boot " *
        "(Psychtoolbox `GetSecs`) adds the offset it captured at startup before " *
        "answering. A session recorded against two clocks cannot be repaired " *
        "afterwards, which is why this is refused rather than written down.")
    return stamp
end

_remote_stamp(engine::RemoteEngine, x, label::AbstractString) = error(
    "The remote worker $(engine.worker) reported $(repr(x)) as the $label; it " *
    "is a unix time or null.")
