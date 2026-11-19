# The control channel (`docs/CONTROL_CHANNEL.md`): a
# Python or MATLAB script or an AI agent works with a running dashboard while the
# operator watches it. One JSON object per line, in the worker protocol's style;
# every command calls the DashboardController function the dashboard's own
# control calls, so every rule holds for a program as for the operator. The
# protocol is here, headless; the dashboard only starts and stops the listener.
# The user's description is docs/CONTROL_CHANNEL.md.

using Sockets

const CONTROL_PROTOCOL_VERSION = 1

# Who is on the other end of one connection, as the operator's messages name it
mutable struct ControlClient
    name::Union{Nothing, String}
end

client_name(client::ControlClient) = something(client.name, ui_label(:control_unnamed_client))

# ── Requests and replies ─────────────────────────────────────────────────────

# A request the protocol cannot carry out — not JSON, an unknown command, an argument
# missing or of the wrong kind — as opposed to a command the controller refuses
struct ControlRequestError <: Exception
    msg::String
end

function argument(request::AbstractDict, name::String, ::Type{T}) where {T}
    haskey(request, name) || throw(ControlRequestError(
        "`$(request["command"])` needs `$name`."))
    value = request[name]
    value isa T || throw(ControlRequestError(
        "`$name` of `$(request["command"])` cannot be $(JSON3.write(value))."))
    return value
end

optional(request::AbstractDict, name::String, ::Type{T}) where {T} =
    haskey(request, name) && request[name] !== nothing ? argument(request, name, T) : nothing

function when_argument(request::AbstractDict)
    when = something(optional(request, "when", String), "after")
    when in ("after", "now") || throw(ControlRequestError(
        "`when` is \"after\" or \"now\", not $(JSON3.write(when))."))
    return Symbol(when)
end

trial_argument(request::AbstractDict) = argument(request, "trial", Integer)

"""
    handle_control_request(controller, line, client = ControlClient(nothing)) -> String

The reply, one line of JSON, to one request line of the control channel. A reading
(`hello`, `status`, `trials`, `messages`, `comments`, `templates`, `sessions`, `series`, `plans`) answers
`{"ok":true,…}` with what was asked. A command calls the controller function the
dashboard's control calls, after noting the command and who sent it among the
operator's messages, and answers `{"ok":…,"message":…}`: whether it was done, and the
message the panel shows for it — a refusal the same words the operator would read. A
request the protocol cannot carry out answers `{"ok":false,"error":…}`. An `id` in the
request is returned in its reply.
"""
function handle_control_request(controller::DashboardController, line::AbstractString,
                                client::ControlClient = ControlClient(nothing))
    request = try
        JSON3.read(line, Dict{String, Any})
    catch
        return control_reply(nothing, Dict("ok" => false,
                                           "error" => "A request is one JSON object on one line."))
    end
    id = get(request, "id", nothing)
    reply = try
        command = get(request, "command", nothing)
        command isa String || throw(ControlRequestError("A request names its `command`."))
        if haskey(CONTROL_READINGS, command)
            CONTROL_READINGS[command](controller, request, client)
        elseif haskey(CONTROL_COMMANDS, command)
            # The arguments are read before anything is noted or done
            run = CONTROL_COMMANDS[command](request)
            set_message!(controller, ui_label(:msg_control_command; client = client_name(client),
                                              command = command_text(request)))
            Dict("ok" => run(controller), "message" => controller.message)
        else
            throw(ControlRequestError("There is no command `$command`; the commands are " *
                                      join(control_command_names(), ", ") * "."))
        end
    catch err
        err isa ControlRequestError || rethrow()
        Dict("ok" => false, "error" => err.msg)
    end
    return control_reply(id, reply)
end

function control_reply(id, reply::AbstractDict)
    id === nothing || (reply["id"] = id)
    return JSON3.write(reply)
end

control_command_names() = sort!([collect(keys(CONTROL_READINGS)); collect(keys(CONTROL_COMMANDS))])

# A command as the operator's messages show it: its name and its arguments
function command_text(request::AbstractDict)
    arguments = [(key, value) for (key, value) in request if !(key in ("command", "id"))]
    isempty(arguments) && return request["command"]
    return request["command"] * " " *
           join(("$key=$(JSON3.write(value))" for (key, value) in sort!(arguments)), " ")
end

# ── Readings ─────────────────────────────────────────────────────────────────

function control_hello(controller::DashboardController, request::AbstractDict,
                       client::ControlClient)
    name = optional(request, "client", String)
    if name !== nothing && !isempty(strip(name))
        client.name = String(strip(name))
        set_message!(controller, ui_label(:msg_control_connected; client = client.name))
    end
    return Dict("ok" => true, "program" => "PsychophysicsManager",
                "version" => string(pkgversion(@__MODULE__)),
                "protocol" => CONTROL_PROTOCOL_VERSION,
                "language" => ui_language(),
                "commands" => control_command_names())
end

function control_status(controller::DashboardController, ::AbstractDict, ::ControlClient)
    session = controller.session
    reply = Dict{String, Any}(
        "ok" => true,
        "running" => is_running(controller),
        "message" => controller.message,
        "actions" => Dict(string(name) => value
                          for (name, value) in pairs(action_state(controller))),
        "session" => nothing)
    session === nothing && return reply
    reply["session"] = Dict(
        "experiment" => session.ex_par.experiment_name,
        "participant" => session.participant_id,
        "method" => type_name(session.method_instance),
        "stimulus" => stimulus_name(session.stim_par),
        "variables" => string.(session.ex_par.indep_var_names),
        "state" => string(session.state),
        "trials" => length(session.history),
        "counted_trials" => count(trial -> trial.is_valid, session.history),
        "planned_trials" => planned_valid_trials(session),
        "trial_under_way" => session.trial_under_way,
        "file" => session.save_path)
    return reply
end

function control_trials(controller::DashboardController, request::AbstractDict, ::ControlClient)
    after = something(optional(request, "after", Integer), 0)
    session = controller.session
    session === nothing && return Dict("ok" => true, "trials" => Any[])
    names = string.(session.ex_par.indep_var_names)
    trials = [Dict("trial" => trial.trial_index,
                   "values" => Dict(zip(names, trial.indep_var_vals)),
                   "response" => response_to_json(trial.response),
                   "correct" => trial.correct,
                   "counted" => trial.is_valid,
                   "origin" => string(trial.origin),
                   "onset" => trial.timestamp_onset,
                   "answered_at" => trial.timestamp_response)
              for trial in session.history[min(max(after, 0), end)+1:end]]
    return Dict("ok" => true, "trials" => trials)
end

function control_messages(controller::DashboardController, request::AbstractDict,
                          ::ControlClient)
    since = something(optional(request, "since", Real), -Inf)
    return Dict("ok" => true,
                "messages" => [Dict("time" => at, "text" => text)
                               for (at, text) in controller.messages if at > since])
end

# The comments on the session in hand, in the order they were written
function control_comments(controller::DashboardController, _, _)
    session = controller.session
    session === nothing && return Dict("ok" => true, "comments" => Any[])
    return Dict("ok" => true,
                "comments" => [Dict("time" => c.time, "trial" => c.trial, "text" => c.text)
                               for c in session.comments])
end

entry_rows(rows) = [Dict(string(name) => getfield(row, name) for name in fieldnames(typeof(row)))
                    for row in rows]

const CONTROL_SESSION_FILTERS = ("participant", "experiment", "tags", "state", "text",
                                 "method", "stimulus", "from", "to", "parameter")

function parse_control_state(raw::AbstractString, cmd::AbstractString)
    s = strip(raw)
    (isempty(s) || lowercase(s) == "all") && return :all
    lowercase(s) == "continuable" && return :continuable
    for st in instances(SessionState)
        lowercase(string(st)) == lowercase(s) && return st
    end
    allowed = join(["\"continuable\""; [string(st) for st in instances(SessionState)]], ", ")
    throw(ControlRequestError(
        "`state` of `$cmd` cannot be $(JSON3.write(raw)); use $allowed."))
end

function parse_control_filters(request::AbstractDict)
    cmd = request["command"]
    for key in keys(request)
        key in ("command", "id") && continue
        key in CONTROL_SESSION_FILTERS || throw(ControlRequestError(
            "Unknown filter `$key` for `$cmd`; the filters are " *
            join(CONTROL_SESSION_FILTERS, ", ") * "."))
    end
    participant = something(optional(request, "participant", String), "")
    experiment = something(optional(request, "experiment", String), "")
    tags = if haskey(request, "tags") && request["tags"] !== nothing
        raw = request["tags"]
        if raw isa String
            raw
        elseif raw isa AbstractVector && all(item -> item isa AbstractString, raw)
            join(String[String(item) for item in raw], ", ")
        else
            throw(ControlRequestError(
                "`tags` of `$cmd` must be a string or a list of strings, not $(JSON3.write(raw))."))
        end
    else
        ""
    end
    state_raw = optional(request, "state", String)
    state = state_raw === nothing ? :all : parse_control_state(state_raw, cmd)
    text = something(optional(request, "text", String), "")
    method = something(optional(request, "method", String), "")
    stimulus = something(optional(request, "stimulus", String), "")
    from = something(optional(request, "from", String), "")
    if !isempty(strip(from)) && !last(parse_filter_date(from))
        throw(ControlRequestError(
            "`from` of `$cmd` must be a yyyy-mm-dd date, not $(JSON3.write(from))."))
    end
    to = something(optional(request, "to", String), "")
    if !isempty(strip(to)) && !last(parse_filter_date(to))
        throw(ControlRequestError(
            "`to` of `$cmd` must be a yyyy-mm-dd date, not $(JSON3.write(to))."))
    end
    parameter = something(optional(request, "parameter", String), "")
    if !isempty(strip(parameter)) && !last(parse_filter_parameter(parameter))
        throw(ControlRequestError(
            "`parameter` of `$cmd` must be \"name = value\", not $(JSON3.write(parameter))."))
    end
    return DashboardFilters(; experiment, participant, tags, state, text, method, stimulus,
                            from, to, parameter)
end

function control_sessions(::DashboardController, request::AbstractDict, ::ControlClient)
    filters = parse_control_filters(request)
    kept = filtered_entries(browse_sessions(resolve_data_dir()), filters)
    return Dict("ok" => true, "sessions" => entry_rows(dashboard_entry_row.(reverse(kept))))
end

function control_series(controller::DashboardController, request::AbstractDict,
                        ::ControlClient)
    filters = parse_control_filters(request)
    rows = dashboard_series_rows(browse_sessions(resolve_data_dir()), filters,
                                 controller.checks)
    series = [Dict{String, Any}(
                  "key" => row.key,
                  "participant" => row.participant,
                  "experiment" => row.experiment,
                  "variables" => row.variables,
                  "repetitions" => row.repetitions,
                  "trials" => row.trials,
                  "last_run" => row.last_run,
                  "state" => row.state,
                  "continuable" => row.continuable,
                  "sessions" => String[s.path for s in row.sessions],
              ) for row in rows]
    return Dict("ok" => true, "series" => series)
end

const CONTROL_READINGS = Dict{String, Function}(
    "hello" => control_hello,
    "status" => control_status,
    "trials" => control_trials,
    "messages" => control_messages,
    "comments" => control_comments,
    "templates" => (_, _, _) -> Dict("ok" => true, "templates" => entry_rows(dashboard_templates())),
    "sessions" => control_sessions,
    "series" => control_series,
    "plans" => (_, _, _) -> Dict("ok" => true, "plans" => entry_rows(dashboard_plans())),
)

# ── Commands ─────────────────────────────────────────────────────────────────

# A template by its path, or by its name in the templates directory
function template_path(name::AbstractString)
    isfile(name) && return abspath(name)
    directory = resolve_templates_dir()
    for candidate in (name, name * ".json")
        path = joinpath(directory, candidate)
        isfile(path) && return path
    end
    return String(name)
end

# A new session from a template, for a participant, with parameters changed: what
# Browse, the participant field and Parameters do in turn. Overrides the session
# refuses leave it prepared as the template has it, and the reply says so.
function control_new_session(request::AbstractDict)
    template = argument(request, "template", String)
    participant = optional(request, "participant", String)
    parameters = something(optional(request, "parameters", AbstractDict), Dict{String, Any}())
    return function (controller)
        participant === nothing || set_dashboard_participant!(controller, participant)
        return after_setting_aside!(controller) do
            choose_setup!(controller, template_path(template)) || return false
            isempty(parameters) && return true
            set_dashboard_parameters!(controller, parameters) && return true
            set_message!(controller, controller.message * " " *
                                     ui_label(:msg_prepared_as_template))
            return false
        end
    end
end

# Who the next session is for, as the participant field sets it; the field gives no
# message of its own, so the reply's is written here
control_set_participant(request::AbstractDict) =
    controller -> set_control_participant!(controller, strip(argument(request, "participant",
                                                                      String)))

function set_control_participant!(controller::DashboardController, participant::AbstractString)
    if isempty(participant)
        set_message!(controller, ui_label(:msg_enter_participant))
        return false
    elseif controller.plan_run !== nothing
        set_message!(controller, ui_label(:msg_participant_fixed))
        return false
    end
    set_dashboard_participant!(controller, participant)
    set_message!(controller, ui_label(:msg_participant_set; participant))
    return true
end

function control_values(request::AbstractDict)
    values = argument(request, "values", AbstractVector)
    all(value -> value isa Real, values) || throw(ControlRequestError(
        "`values` of `present_condition` are numbers, one per variable."))
    return Float64.(values)
end

# Each command reads its arguments from the request and returns what it does to the
# controller, which answers whether it was done
const CONTROL_COMMANDS = Dict{String, Function}(
    "start" => _ -> start_experiment!,
    "pause" => _ -> pause_experiment!,
    "resume" => _ -> resume_experiment!,
    "undo" => _ -> undo_dashboard_trial!,
    "stop" => _ -> stop_experiment!,
    "continue_changed" => _ -> continue_changed_stimulus!,
    "start_new" => _ -> start_new_session!,
    "prepare_next_run" => _ -> prepare_next_scenario_run!,
    "mark_outlier" => r -> (trial = trial_argument(r);
                            c -> mark_dashboard_outlier!(c, trial)),
    "add_comment" => r -> (text = argument(r, "text", String);
                           trial = optional(r, "trial", Integer);
                           c -> add_dashboard_comment!(c, text; trial)),
    "repeat_trial" => r -> (trial = trial_argument(r); when = when_argument(r);
                            c -> repeat_dashboard_trial!(c, trial; when)),
    "add_trial" => r -> (trial = trial_argument(r); when = when_argument(r);
                         c -> add_dashboard_trial!(c, trial; when)),
    "present_condition" => r -> (values = control_values(r); when = when_argument(r);
                                 c -> present_dashboard_condition!(c, values; when)),
    "set_participant" => control_set_participant,
    "new_session" => control_new_session,
    "set_parameters" => r -> (parameters = argument(r, "parameters", AbstractDict);
                              c -> set_dashboard_parameters!(c, parameters)),
    "open_session" => r -> (path = argument(r, "path", String);
                            c -> after_setting_aside!(() -> open_previous_session!(c, path), c)),
    "choose_plan" => r -> (path = argument(r, "path", String);
                           c -> after_setting_aside!(() -> choose_scenario!(c, path), c)),
)

# ── Connections ──────────────────────────────────────────────────────────────

"""
    serve_control_channel!(controller, io) -> Nothing

Answers the requests of one connection, a line each, until it closes.
"""
function serve_control_channel!(controller::DashboardController, io::IO)
    client = ControlClient(nothing)
    try
        while !eof(io)
            line = readline(io)
            isempty(strip(line)) && continue
            println(io, handle_control_request(controller, line, client))
            flush(io)
        end
    catch err
        # The dashboard closing the channel, or the other end going away
        err isa Union{Base.IOError, EOFError} || rethrow()
    end
    client.name === nothing ||
        set_message!(controller, ui_label(:msg_control_disconnected; client = client.name))
    return nothing
end

"""
    ControlChannel

A control channel listening on the loopback address for the dashboard's controller:
`port` is the one it listens on. [`stop_control_channel!`](@ref) closes it and every
connection.
"""
mutable struct ControlChannel
    server::Sockets.TCPServer
    port::Int
    connections::Vector{IO}
end

"""
    start_control_channel(controller; port) -> ControlChannel

Listens for programs on `port` of this machine's loopback address — never another
machine's — and serves each connection in a task of its own, beside the dashboard's
window on the same thread: a request is handled between two frames, as a press of a
button is. `port = 0` takes a free port, which the channel's `port` names.
"""
function start_control_channel(controller::DashboardController; port::Integer)
    server = Sockets.listen(Sockets.localhost, port)
    channel = ControlChannel(server, Int(last(Sockets.getsockname(server))), IO[])
    @async while isopen(server)
        connection = try
            accept(server)
        catch err
            err isa Base.IOError && break
            rethrow()
        end
        push!(channel.connections, connection)
        @async try
            serve_control_channel!(controller, connection)
        finally
            close(connection)
            filter!(open_one -> open_one !== connection, channel.connections)
        end
    end
    set_message!(controller, ui_label(:msg_control_listening;
                                      address = "$(Sockets.localhost):$(channel.port)"))
    return channel
end

"""
    start_control_channel_from_settings(controller, directory = ".") -> Union{Nothing, ControlChannel}

The channel `[control]` of the settings asks for ([`load_control_config`](@ref)), or
`nothing` when it is off. A port another program holds is reported in the panel, and the
dashboard goes on without the channel.
"""
function start_control_channel_from_settings(controller::DashboardController,
                                             directory::String = ".")
    config = load_control_config(directory)
    config.enabled || return nothing
    try
        return start_control_channel(controller; port = config.port)
    catch err
        err isa Base.IOError || rethrow()
        set_message!(controller, ui_label(:msg_control_failed;
                                          address = "$(Sockets.localhost):$(config.port)",
                                          error = sprint(showerror, err)))
        return nothing
    end
end

"""
    stop_control_channel!(channel) -> Nothing

Stops listening and closes every connection; `nothing` is no channel.
"""
function stop_control_channel!(channel::ControlChannel)
    close(channel.server)
    foreach(close, copy(channel.connections))
    return nothing
end
stop_control_channel!(::Nothing) = nothing
