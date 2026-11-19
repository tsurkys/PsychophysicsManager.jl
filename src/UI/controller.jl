# The operator dashboard's state and lifecycle, with no widget toolkit in sight.
# Every rule an operator can observe — which actions are
# available, what the panel says, when the session listener is attached, who
# owns the engine, which response source is active — is decided here and merely
# rendered by `ext/PsychophysicsManagerGLMakieExt/dashboard.jl`.
#
# Keeping it headless is what makes these rules testable without opening a
# window, and it is the layer any other operator front end, such as a remote
# console, would reuse unchanged.

"""
    DashboardController(session=nothing; owns_engine = session === nothing)

Holds the session a dashboard is controlling, plus the runtime state that
belongs to controlling it rather than to the session itself.

`owns_engine` distinguishes the two ways a dashboard is used:

- `true` (the standalone dashboard): the dashboard loads a session, restores
  its engine, runs the trial loop in a task of its own, and closes the engine
  afterwards.
- `false` (a dashboard attached to a session a script already set up): the
  script owns the engine and runs the loop; starting from the dashboard only
  moves the session into `RUNNING`, and the script's loop takes it from there.

`update_policy` is what session events redraw the view ([`should_refresh`](@ref)).
It belongs to the dashboard, not to the session file: it changes what the operator
sees, never what is measured, and what a machine can afford to redraw during a
trial is a property of that machine.

`on_update` is the view's refresh hook, assigned when a window is attached.

`message` is the operator's last message; `messages` keeps the recent ones with the
time each was given ([`MESSAGE_HISTORY`](@ref)), for a view that lists them.

`participant` is who the next session is for, and `chosen` the file the session in
hand came from, as the Browse view shows them. `preview_engine` stays open between
previews, until a session starts or the dashboard closes.

`plan` is the scenario plan chosen in Browse, `plan_run` the run of it the session in
hand is ([`choose_scenario!`](@ref)), and `next_run` the id of the plan's next run once
that run has finished.

`changed_stimulus` is the refusal of a session's continuation under a changed stimulus
program ([`StimulusChangedError`](@ref)), which awaits the operator's choice.

`draft` backs [`prepared_session`](@ref); `setting_aside` is set while a paused
session's loop ends ([`after_setting_aside!`](@ref)).

`checks` are the optional combining checks ([`COMBINING_CHECKS`](@ref)) that form series
and govern `Save as Dataset…`, starting from `[combining]` in `settings.toml`.
`ticked` holds the paths of ticked session files in tick order. `lists_stale` marks the
Browse lists as needing a reread from disk.
"""
mutable struct DashboardController
    session::Union{Nothing, SessionContext}
    engine::Union{Nothing, AbstractStimulusEngine}
    run_task::Union{Nothing, Task}
    listener::Union{Nothing, Function}
    previous_response_source::Union{Nothing, AbstractResponseSource}
    owns_engine::Bool
    message::String
    messages::Vector{Tuple{Float64, String}}
    on_update::Function
    armed::Union{Nothing, Symbol}   # an action pressed once, awaiting its confirmation
    armed_at::Float64
    update_policy::Symbol
    participant::String
    chosen::Union{Nothing, String}
    preview_engine::Union{Nothing, AbstractStimulusEngine}
    preview_task::Union{Nothing, Task}
    plan::Union{Nothing, String}
    plan_run::Union{Nothing, ScenarioRun}
    next_run::Union{Nothing, String}
    changed_stimulus::Union{Nothing, StimulusChangedError}
    checks::Vector{Symbol}
    ticked::Vector{String}
    lists_stale::Bool
    draft::Union{Nothing, SessionContext}
    setting_aside::Bool
end

function DashboardController(session::Union{Nothing, SessionContext} = nothing;
                             owns_engine::Bool = session === nothing,
                             update_policy::Symbol = :continuous)
    return DashboardController(session, nothing, nothing, nothing, nothing, owns_engine,
                               session === nothing ? no_session_text() : "",
                               Tuple{Float64, String}[], () -> nothing, nothing, 0.0,
                               check_update_policy(update_policy), DEFAULT_PARTICIPANT_ID,
                               nothing, nothing, nothing, nothing, nothing, nothing,
                               nothing, settings_combining_checks(), String[], false,
                               nothing, false)
end

"""
    UPDATE_POLICIES

The dashboard update policies, finest first; see [`should_refresh`](@ref).
"""
const UPDATE_POLICIES = (:continuous, :between_trials, :minimal)

check_update_policy(policy::Symbol) = policy in UPDATE_POLICIES ? policy :
    throw(ArgumentError("Unknown dashboard update policy :$policy; the policies are " *
                        "$(join(repr.(UPDATE_POLICIES), ", "))."))

"""
    should_refresh(policy, event) -> Bool

Whether a session event redraws a dashboard under `policy`:

- `:continuous` — every event, the steps within a trial (`:response_registered`)
  included;
- `:between_trials` — nothing while a trial is under way: each completed trial, and
  everything coarser;
- `:minimal` — state changes, the operator's corrections and settings, and an
  interruption; progress is redrawn only when the operator asks.

The levels mirror the console reporter's `:steps`, `:trials` and `:session`. The
listener runs inside the experiment loop, so an event that does not refresh costs
nothing at all rather than a redraw put off until later.
"""
function should_refresh(policy::Symbol, event::Symbol)
    event === :response_registered && return policy === :continuous
    event === :trial_completed && return policy !== :minimal
    return true
end

"""
    CONFIRM_WINDOW_S

Seconds within which a second press of Stop or Discard confirms the first. A press
that comes later asks again, so a press forgotten in the panel cannot be completed
by accident much later.
"""
const CONFIRM_WINDOW_S = 5.0

"""
    is_running(controller) -> Bool

Whether a dashboard-owned trial loop is still running.
"""
is_running(controller::DashboardController) =
    controller.run_task !== nothing && !istaskdone(controller.run_task)

"""
    notify_view(controller)

Asks the attached view to refresh. A failing view is logged and swallowed: the
dashboard is an observer of the experiment and must never interrupt it.
"""
function notify_view(controller::DashboardController)
    try
        controller.on_update()
    catch e
        @warn "Dashboard view refresh failed" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    MESSAGE_HISTORY

How many of the operator's recent messages a dashboard keeps; older ones are dropped.
"""
const MESSAGE_HISTORY = 200

"""
    set_message!(controller, text)

Sets the operator-facing status line, keeps it in the recent messages, and
refreshes the view.
"""
function set_message!(controller::DashboardController, text::AbstractString)
    controller.message = String(text)
    push!(controller.messages, (time(), controller.message))
    length(controller.messages) > MESSAGE_HISTORY && popfirst!(controller.messages)
    notify_view(controller)
    return controller
end

# ── Session binding ──────────────────────────────────────────────────────────

"""
    bind_session!(controller, session) -> controller

Makes `session` the controlled session and subscribes to its events. The
previous session's listener is detached first: without that, every load would
leave another observer behind on a session the dashboard no longer shows.
"""
function bind_session!(controller::DashboardController, session::SessionContext)
    unbind_session!(controller)
    controller.session = session
    controller.listener = on_session_event!(session) do _, event
        should_refresh(controller.update_policy, event) && notify_view(controller)
    end
    notify_view(controller)
    return controller
end

"""
    set_update_policy!(controller, policy) -> controller

Chooses what session events redraw the dashboard ([`should_refresh`](@ref)), and
redraws it once so the view is current under the new policy.
"""
function set_update_policy!(controller::DashboardController, policy::Symbol)
    controller.update_policy = check_update_policy(policy)
    set_message!(controller, ui_label(:msg_updates; policy = update_policy_label(policy)))
    return controller
end

"""
    unbind_session!(controller) -> controller

Detaches the session listener and forgets the session, the scenario plan it was a run
of, and the new session prepared from it.
"""
function unbind_session!(controller::DashboardController)
    if controller.session !== nothing && controller.listener !== nothing
        detach_listener!(controller.session, controller.listener)
    end
    controller.listener = nothing
    controller.session = nothing
    controller.draft = nothing
    controller.plan = controller.plan_run = controller.next_run = nothing
    controller.changed_stimulus = nothing
    return controller
end

# ── Response source ──────────────────────────────────────────────────────────

"""
    install_response_source!(controller, source) -> controller

Makes `source` the active response source and remembers the one it replaced, so
`close_controller!` can put it back. Calling it twice keeps the *original*
source as the one to restore.
"""
function install_response_source!(controller::DashboardController,
                                  source::AbstractResponseSource)
    previous = swap_response_source!(source)
    controller.previous_response_source === nothing &&
        (controller.previous_response_source = previous)
    return controller
end

"""
    close_controller!(controller) -> controller

Releases everything the dashboard installed process-wide: the session listener
and the response source. Without the latter, closing a dashboard window would
leave the next session waiting forever on a channel that nothing feeds.
"""
function close_controller!(controller::DashboardController)
    close_preview!(controller)
    unbind_session!(controller)
    if controller.previous_response_source !== nothing
        set_response_source!(controller.previous_response_source)
        controller.previous_response_source = nothing
    end
    return controller
end

# ── Actions ──────────────────────────────────────────────────────────────────

"""
    action_state(controller) -> NamedTuple

Which operator actions are meaningful right now. The view uses it to signal
availability instead of letting an operator press a button that silently does
nothing.
"""
function action_state(controller::DashboardController)
    session = controller.session
    running = is_running(controller)
    live = session !== nothing && (session.state == RUNNING || session.state == PAUSED)
    return (
        # A paused session's loop gives way to another choice (`after_setting_aside!`)
        can_load   = controller.owns_engine && (!running || paused_loop(controller)),
        can_start  = session !== nothing && session.state == READY && !running,
        # A scenario's session is followed by the plan's next run instead. A session
        # its changed stimulus program stopped may be followed by a new one too.
        can_start_new = controller.owns_engine && !running && session !== nothing &&
                        controller.plan_run === nothing &&
                        (session.state == FINISHED || session.state == ABORTED ||
                         controller.changed_stimulus !== nothing),
        can_continue_changed = controller.owns_engine && !running && session !== nothing &&
                               controller.changed_stimulus !== nothing &&
                               session.state == PAUSED,
        can_prepare_next = controller.owns_engine && !running &&
                           controller.next_run !== nothing && session !== nothing &&
                           session.state == FINISHED,
        can_pause  = session !== nothing && session.state == RUNNING,
        can_resume = session !== nothing && session.state == PAUSED &&
                     !controller.setting_aside,
        can_stop   = live,
        # A session with nothing on disk has nothing to set aside unless it is
        # under way, when discarding it also stops it
        can_discard = session !== nothing && !is_discarded(session.save_path) &&
                      (live || session.save_path !== nothing),
        # A trial's start raises no event, so the view may still show Undo as
        # available while one is under way; undo_dashboard_trial! says why not
        can_undo   = session !== nothing && !isempty(session.history) &&
                     !session.trial_under_way,
        can_mark_outlier = session !== nothing && any(trial -> trial.is_valid,
                                                      session.history),
        can_set_fit_gamma = session !== nothing,
        fit_gamma  = session === nothing ? DEFAULT_FIT_GAMMA : session.fit_gamma,
    )
end

"""
    set_dashboard_fit_gamma!(controller, gamma) -> controller

Guarded delegation to [`set_fit_gamma!`](@ref): records the operator's
declaration about the nature of the data on the session itself, which is what
persists it. The controller holds no copy — a second source of truth here would
let the panel and the file disagree about how the data is fitted.
"""
function set_dashboard_fit_gamma!(controller::DashboardController, gamma::Real)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return controller
    end
    set_fit_gamma!(session, gamma)
    set_message!(controller, ui_label(:msg_fit_from; label = fit_gamma_label(session.fit_gamma)))
    return controller
end

"""
    load_replication!(controller, filepath, participant_id) -> Bool

Loads a saved session file as a fresh `READY` replication for `participant_id`
and binds it, unless [`check_parameters`](@ref) refuses it. Returns whether the session
was loaded; the reason for a refusal is reported through the controller's message.
"""
function load_replication!(controller::DashboardController,
                           filepath::AbstractString, participant_id::AbstractString)
    if is_running(controller)
        set_message!(controller, ui_label(:msg_finish_before_load))
        return false
    end

    path = strip(filepath)
    participant = strip(participant_id)
    if isempty(path)
        set_message!(controller, ui_label(:msg_enter_path))
        return false
    elseif isempty(participant)
        set_message!(controller, ui_label(:msg_enter_participant))
        return false
    end

    try
        session = create_replicated_session(read_replicable_session(abspath(String(path))),
                                            String(participant))
        check_parameters(session)
        bind_session!(controller, session)
        set_message!(controller, ui_label(:msg_loaded; file = basename(String(path))))
        return true
    catch err
        unbind_session!(controller)
        set_message!(controller, ui_label(:msg_load_failed; error = sprint(showerror, err)))
        return false
    end
end

# Whether the loop of the session in hand runs and waits, the session paused
paused_loop(controller::DashboardController) =
    is_running(controller) && controller.session !== nothing &&
    controller.session.state == PAUSED && !controller.setting_aside

"""
    after_setting_aside!(choose, controller) -> Bool

Calls `choose()` — a Browse choice — after setting aside a paused session in hand: its
loop ends, the session stays `PAUSED` and checkpointed, a trial under way is
abandoned. Returns what `choose()` returned, or `true` while waiting for the loop.
"""
function after_setting_aside!(choose::Function, controller::DashboardController)
    paused_loop(controller) || return choose()
    task = controller.run_task
    aside = controller.session
    # The loop asks `keep_waiting` while the session is paused (`_run_owned_experiment!`)
    controller.setting_aside = true
    aside.trial_under_way && abandon_trial!(aside)
    @async begin
        try
            wait(task)
        catch
        end
        controller.setting_aside = false
        choose()
        # Where the session went stays in sight beside what the choice says
        set_message!(controller, ui_label(:msg_set_aside;
                                          file = basename(something(aside.save_path, ""))) *
                                 " " * controller.message)
    end
    return true
end

"""
    close_dashboard!(close, controller) -> Bool

Closes the dashboard by calling `close()`. A session that has not ended and whose trial
loop runs — the dashboard's own, or a script's beside it ([`run_when_started!`](@ref)) —
is not left running without its controls: the first request only asks, and a second
within [`CONFIRM_WINDOW_S`](@ref) pauses the session and sets it aside, paused in its
file and continuable from Browse, abandoning a trial under way; the window then closes
once the dashboard's own loop has ended. Returns whether the window closes.
"""
function close_dashboard!(close::Function, controller::DashboardController)
    session = controller.session
    loop_runs = session !== nothing && session.state in (RUNNING, PAUSED) &&
                (is_running(controller) || !controller.owns_engine)
    if !loop_runs
        # A closing text still shown ends with the window
        session !== nothing && session.state == FINISHED &&
            session.shown_message !== nothing && end_message!(session)
        close()
        return true
    end
    confirmed!(controller, :close, ui_label(:confirm_close)) || return false
    session.state == RUNNING && pause!(session)
    controller.owns_engine && return after_setting_aside!(() -> (close(); true), controller)
    # A script's loop ends once the window is gone (`run_when_started!`)
    session.trial_under_way && abandon_trial!(session)
    close()
    return true
end

"""
    choose_setup!(controller, path) -> Bool

Prepares a new session from the setup in `path` — a template, or a dataset — for the
controller's participant ([`load_replication!`](@ref)), so the dashboard shows what it
will run. Returns whether it was prepared.
"""
function choose_setup!(controller::DashboardController, path::AbstractString)
    chosen = load_replication!(controller, path, controller.participant)
    controller.chosen = chosen ? String(path) : nothing
    chosen && report_obsolete_fields!(controller, path)
    return chosen
end

# A parameter the file sets and the stimulus program no longer has is left out; the
# operator is told, since a renamed parameter would otherwise lose its value unseen
function report_obsolete_fields!(controller::DashboardController, path::AbstractString)
    obsolete = try
        obsolete_stimulus_fields(read_json_document(String(path)))
    catch
        Pair{String, Any}[]
    end
    isempty(obsolete) && return nothing
    set_message!(controller, ui_label(:msg_obsolete_fields;
        fields = join(("$name = $(format_setting(value))" for (name, value) in obsolete), ", "),
        stimulus = stimulus_name(controller.session.stim_par)))
    return nothing
end

"""
    can_choose_participant(controller) -> Bool

Whether the operator chooses who the next session is for: before a session starts and
after it has ended, in a dashboard that runs its own sessions — except for a scenario's
run, whose participant the plan names.
"""
function can_choose_participant(controller::DashboardController)
    session = controller.session
    controller.owns_engine && controller.plan_run === nothing || return false
    return session === nothing || session.state in (FINISHED, ABORTED) ||
           (session.state == READY && session.save_path === nothing)
end

"""
    set_dashboard_participant!(controller, participant) -> controller

Sets who the next session is for, including a session prepared and not yet started
(the [`prepared_session`](@ref) too). A scenario's run keeps its plan's participant.
"""
function set_dashboard_participant!(controller::DashboardController,
                                    participant::AbstractString)
    controller.plan_run === nothing || return controller
    controller.participant = strip(participant)
    isempty(controller.participant) && return controller
    for session in (controller.session, controller.draft)
        if session !== nothing && session.state == READY && session.save_path === nothing
            session.participant_id = controller.participant
            notify_view(controller)
        end
    end
    return controller
end

"""
    open_previous_session!(controller, path) -> Bool

Opens the session saved in `path` as it is, with its trials, so the dashboard shows its
data and its parameters: a finished or stopped session is looked at, and Start New
Session runs a new one from it; an unfinished one is continued in its own file —
started if it never was, resumed otherwise. One whose run broke off without a pause
is opened paused, since no loop runs it. The participant of a new session defaults to
this one's. Returns whether it was opened.
"""
function open_previous_session!(controller::DashboardController, path::AbstractString)
    if is_running(controller)
        set_message!(controller, ui_label(:msg_finish_before_load))
        return false
    end
    session = try
        load_session(String(path))
    catch err
        set_message!(controller, ui_label(:msg_load_failed; error = sprint(showerror, err)))
        return false
    end
    session.state == RUNNING && (session.state = PAUSED)
    bind_session!(controller, session)
    controller.chosen = String(path)
    controller.participant = session.participant_id
    set_message!(controller, ui_label(:msg_opened; file = basename(String(path))))
    report_obsolete_fields!(controller, path)
    return true
end

"""
    choose_scenario!(controller, plan_path) -> Bool

Prepares the next run of the scenario plan in `plan_path` ([`prepare_next_run`](@ref)),
so the dashboard shows what Start will run: a new session, for the participant the plan
names, with the plan's parameters, which can still be changed before Start; or the
session an interrupted run left in its file, which runs on there. Started from the
dashboard, the run is written to the file the plan gives it, and its completion is
recorded beside the plan, as [`run_scenario!`](@ref) records it. A plan whose every run
is complete, or that cannot be run, is chosen with no session in hand, and the panel
says why. Returns whether a run was prepared.
"""
function choose_scenario!(controller::DashboardController, plan_path::AbstractString)
    if is_running(controller)
        set_message!(controller, ui_label(:msg_finish_before_load))
        return false
    end
    plan = abspath(String(plan_path))
    name = splitext(basename(plan))[1]
    run = try
        prepare_next_run(plan)
    catch err
        unbind_session!(controller)
        controller.plan = plan
        controller.chosen = nothing
        set_message!(controller, ui_label(:msg_plan_refused;
            error = err isa ArgumentError ? err.msg : sprint(showerror, err)))
        return false
    end
    if run === nothing
        unbind_session!(controller)
        controller.plan = plan
        controller.chosen = nothing
        set_message!(controller, ui_label(:msg_plan_complete; plan = name))
        return false
    end
    session = run.session
    # A run that broke off without a pause is continued paused, since no loop runs it
    session.state == RUNNING && (session.state = PAUSED)
    bind_session!(controller, session)
    controller.plan = plan
    controller.plan_run = run
    controller.chosen = session.save_path
    controller.participant = session.participant_id
    set_message!(controller, ui_label(run.kind === :start ? :msg_run_prepared : :msg_run_continues;
        position = run.position, total = run.total, plan = name, run = run.row.id,
        participant = session.participant_id, file = basename(run.row.destination)))
    run.kind === :start && report_obsolete_fields!(controller, run.row.source)
    return true
end

"""
    prepare_next_scenario_run!(controller) -> Bool

Prepares the next run of the plan whose run has just finished — the confirmation
between two runs of a scenario — which Start then runs ([`choose_scenario!`](@ref)).
Returns whether a run was prepared.
"""
function prepare_next_scenario_run!(controller::DashboardController)
    if !action_state(controller).can_prepare_next
        set_message!(controller, ui_label(:msg_cannot_prepare_next))
        return false
    end
    return choose_scenario!(controller, controller.plan)
end

"""
    start_new_session!(controller) -> Bool

Starts a new session of the experiment in hand once it has ended (or its stimulus
program changed): the [`prepared_session`](@ref), or else a replication for the
controller's participant, in a file of its own. Returns whether it was started.
"""
function start_new_session!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !action_state(controller).can_start_new
        set_message!(controller, ui_label(:msg_cannot_start_new))
        return false
    end
    next = controller.draft === nothing ? new_session_from(controller) : controller.draft
    refuse_start!(controller, next) && return false
    bind_session!(controller, next)
    return start_experiment!(controller)
end

# Refuses a start, before any file is written, while `unset_settings` or
# `check_parameters` object; the panel says why
function refuse_start!(controller::DashboardController, session::SessionContext)
    unset = unset_settings(session.method_instance)
    if !isempty(unset)
        set_message!(controller, ui_label(:msg_settings_unset;
                                          method = type_name(session.method_instance),
                                          settings = join(unset, ", ")))
        return true
    end
    try
        check_parameters(session)
        resolve_session_unit_conversions(session, load_rig())
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_cannot_start; error = err.msg))
        return true
    end
    return false
end

# A replication of the session in hand for the participant chosen
new_session_from(controller::DashboardController) =
    create_replicated_session(controller.session, isempty(controller.participant) ?
                                                  DEFAULT_PARTICIPANT_ID : controller.participant)

"""
    prepared_session(controller) -> Union{Nothing, SessionContext}

The replication that the first Parameters edit of an ended session prepares and Start
New Session runs, while the ended session stays in view. `nothing` when none is
prepared or the session in hand cannot be followed by a new one.
"""
prepared_session(controller::DashboardController) =
    controller.draft !== nothing && action_state(controller).can_start_new ?
    controller.draft : nothing

"""
    parameters_session(controller) -> Union{Nothing, SessionContext}

The session Parameters shows, Preview presents and Save as Template saves: the
[`prepared_session`](@ref), or the session in hand.
"""
parameters_session(controller::DashboardController) =
    something(prepared_session(controller), Some(controller.session))

"""
    can_edit_parameters(controller) -> Bool

Whether the Parameters view edits: in a dashboard running its own sessions, no loop
running, the session not started or ended (edits then go to [`prepared_session`](@ref)).
"""
can_edit_parameters(controller::DashboardController) =
    controller.owns_engine && !is_running(controller) && controller.session !== nothing &&
    (controller.session.state == READY || action_state(controller).can_start_new)

"""
    can_edit_reporting(controller) -> Bool

Whether the session's units can change: whenever no loop runs, an ended session
included — units change reports, not the record ([`set_unit_conversion!`](@ref)).
"""
can_edit_reporting(controller::DashboardController) =
    controller.owns_engine && !is_running(controller) && controller.session !== nothing

# Whether a line of the Parameters view changes how the session is reported, rather
# than what it measures
reporting_key(key::AbstractString) = startswith(key, "units.")

# The engine whose worker's stimuli can be chosen (`selectable_stimuli`): the one in
# hand, or the one a preview opened
connected_engine(controller::DashboardController) =
    something(controller.engine, controller.preview_engine, Some(nothing))

# A preview's engine was opened for the stimulus it showed, a worker's excepted: it
# presents every stimulus it declares
close_stale_preview!(controller::DashboardController) =
    controller.preview_engine isa RemoteEngine || close_preview!(controller)

# The session an edit changes: the one not started, else the prepared session or a new
# one (kept only if the edit is taken); units go to the session Parameters shows
function edit_target(controller::DashboardController, key::AbstractString)
    session = controller.session
    (reporting_key(key) || session.state == READY) && return parameters_session(controller)
    prepared = prepared_session(controller)
    return prepared === nothing ? new_session_from(controller) : prepared
end

# The edit changed a new session: the first such one is kept as the prepared session
function keep_prepared!(controller::DashboardController, target::SessionContext)
    (target === controller.session || target === controller.draft) && return nothing
    controller.draft = target
    set_message!(controller, ui_label(:msg_new_session_prepared;
                                      participant = target.participant_id))
    return nothing
end

"""
    edit_dashboard_parameter!(controller, key, text) -> Bool

Sets one parameter of the session in hand, which has not started, from the text the
operator typed in the Parameters view. `key` is that of the line
([`ParameterRow`](@ref)): `"ex_par.<field>"` or `"stim_par.<field>"`
([`set_parameters!`](@ref)), `"stimulus"` for the stimulus, by name,
`"levels.<variable>"` for the levels of a variable, `"tags"` for a comma-separated
list, `"feedback"` and `"timeout_s"` (seconds; empty for no limit), `"method"` for the
method's type and `"method.<setting>"` for one of its settings, `"variable.<n>"` for the stimulus parameter the n-th independent variable is
(empty to remove it) and `"variable.new"` for one more, `"task"` for the lower
asymptote the curve is fitted from, `"units.<variable>"` for a unit conversion as
[`parse_unit_conversion`](@ref) reads it (which also writes the entry into
`[units.<stimulus>]` in the project's settings), and `"messages.<field>"` for one of the message
options ([`set_messages!`](@ref)). For an ended session the edit goes to the
[`prepared_session`](@ref), units excepted. A value the parameter cannot take is
refused, with the reason in the panel. Returns whether it was set.
"""
function edit_dashboard_parameter!(controller::DashboardController, key::AbstractString,
                                   text::AbstractString)
    if !(reporting_key(key) ? can_edit_reporting(controller) : can_edit_parameters(controller))
        set_message!(controller, ui_label(:msg_parameters_fixed))
        return false
    end
    session = edit_target(controller, key)
    label = parameter_label(session, key)
    try
        if startswith(key, "units.")
            variable = Symbol(chop(key; head = length("units."), tail = 0))
            rig = session.state == READY ? load_rig() : session.rig
            conversion = parse_session_unit_conversion(session, variable, text, rig)
            check_unit_conversion(session, variable, conversion)
            entry = isempty(strip(text)) ? nothing : String(strip(text))
            write_settings!(UNITS_SECTION_PREFIX * stimulus_name(session.stim_par),
                            Dict{String, Any}(string(variable) => entry))
            set_unit_conversion!(session, variable, conversion)
        elseif key == "task"
            gamma = parse_setting_text(text)
            gamma isa Real || throw(ArgumentError("The task type is a lower asymptote, 0 or 0.5."))
            set_fit_gamma!(session, gamma)
        elseif startswith(key, "variable.")
            set_parameters!(session, edited_variables(session.ex_par, session.stim_par,
                                                      chop(key; head = length("variable."), tail = 0),
                                                      strip(text)))
        elseif key == "method"
            set_parameters!(session, Dict("method" => strip(text)))
        elseif key == "stimulus"
            set_parameters!(session, Dict("stimulus" => strip(text));
                            declared = connected_engine(controller))
            close_stale_preview!(controller)
        elseif startswith(key, "method.")
            name = Symbol(chop(key; head = length("method."), tail = 0))
            settings = Dict(method_settings(session.method_instance))
            haskey(settings, name) || throw(ArgumentError(
                "$(type_name(session.method_instance)) has no setting $name."))
            set_parameters!(session, Dict(key => method_setting_raw(settings[name], text)))
        elseif startswith(key, "levels.")
            name = Symbol(chop(key; head = length("levels."), tail = 0))
            index = findfirst(==(name), session.ex_par.indep_var_names)
            index === nothing && throw(ArgumentError("The design has no variable $name."))
            levels = parse_setting_text(text)
            levels = levels === nothing ? Any[] : levels isa AbstractVector ? levels : Any[levels]
            all(level -> level isa Real, levels) || throw(ArgumentError(
                "The levels of $name are numbers, as 1, 2, 4 or 0:0.5:2."))
            ranges = copy(session.ex_par.indep_var_ranges)
            ranges[index] = levels
            set_parameters!(session, Dict("ex_par.indep_var_ranges" => ranges))
        elseif key == "tags"
            session.tags = unique(String[strip(tag) for tag in split(text, ',')
                                         if !isempty(strip(tag))])
        elseif key == "feedback"
            set_feedback!(session, parse_setting_text(text) === true)
        elseif key == "timeout_s"
            seconds = parse_setting_text(text)
            seconds === nothing || seconds isa Real || throw(ArgumentError(
                "The response window is a number of seconds, or empty for none."))
            set_timeout!(session, seconds)
        elseif startswith(key, "messages.")
            field = chop(key; head = length("messages."), tail = 0)
            if field == "instructions"
                value = parse_setting_text(text) === true
            elseif field == "break_every"
                if isempty(strip(text))
                    value = 0
                else
                    val = parse_setting_text(text)
                    (val isa Integer && !(val isa Bool)) || throw(ArgumentError(
                        "Breaks come after every n trials: a whole number, or empty for none."))
                    value = Int(val)
                end
            elseif field == "break_after"
                if isempty(strip(text))
                    value = Int[]
                else
                    parsed = parse_setting_text(text)
                    items = parsed isa AbstractVector ? parsed : [parsed]
                    all(x -> x isa Integer && !(x isa Bool), items) || throw(ArgumentError(
                        "Breaks after trials must be a list of whole numbers."))
                    value = Int.(items)
                end
            elseif field == "break_waits_for"
                value = Symbol(strip(text))
            elseif field == "break_min_s"
                if isempty(strip(text))
                    value = 0.0
                else
                    val = parse_setting_text(text)
                    (val isa Real && !(val isa Bool)) || throw(ArgumentError(
                        "Minimum break duration must be a real number."))
                    value = Float64(val)
                end
            elseif field in ("break_text", "closing_text")
                value = String(text)
            else
                throw(ArgumentError("Unknown session message field: $field"))
            end
            set_messages!(session; Symbol(field) => value)
        else
            target, field = parameter_key(key)
            T = if target === :ex_par
                hasfield(ExperimentParameters, field) || throw(ArgumentError(
                    "`$key` names no parameter: ExperimentParameters has no field $field."))
                fieldtype(ExperimentParameters, field)
            else
                has_parameter(session.stim_par, field) || throw(ArgumentError(
                    "`$key` names no parameter: $(stimulus_name(session.stim_par)) has " *
                    "no parameter $field."))
                parameter_type(session.stim_par, field)
            end
            set_parameters!(session, Dict(key => raw_setting(T, text)))
        end
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_parameter_refused;
                                          error = replace(err.msg, "`$key`" => "`$label`")))
        return false
    end
    # The first change of an ended session says what it prepared; any other says what
    # changed, so that no earlier refusal stays in the panel
    preparing = session !== controller.session && session !== controller.draft
    keep_prepared!(controller, session)
    preparing || set_message!(controller, ui_label(:msg_parameter_changed; name = label))
    notify_view(controller)
    return true
end

# The name the Parameters line of `key` shows, for the panel's messages; the key
# itself when no line has it
function parameter_label(session::SessionContext, key::AbstractString)
    rows = try
        dashboard_setup_rows(session)
    catch err
        err isa ArgumentError || rethrow()
        return String(key)
    end
    for row in Iterators.flatten(values(rows))
        row.key == key || continue
        label = strip(row.label)
        return startswith(key, "levels.") ?
               chop(key; head = length("levels."), tail = 0) * " " * label : String(label)
    end
    return String(key)
end

"""
    set_dashboard_parameters!(controller, values) -> Bool

Changes the parameters of the session in hand before it starts, all of them or none
([`set_parameters!`](@ref)), by the keys a scenario row's overrides use:
`"stimulus"`, `"ex_par.<field>"`, `"stim_par.<field>"`, `"method"` and `"method.<setting>"`; for an
ended session, those of the [`prepared_session`](@ref). Returns whether the parameters
were changed; the panel says why not.
"""
function set_dashboard_parameters!(controller::DashboardController, values::AbstractDict)
    if controller.session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !can_edit_parameters(controller)
        set_message!(controller, ui_label(:msg_parameters_fixed))
        return false
    end
    session = edit_target(controller, "")
    try
        set_parameters!(session, Dict{String, Any}(String(key) => value
                                                   for (key, value) in values);
                        declared = connected_engine(controller))
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_parameter_refused; error = err.msg))
        return false
    end
    any(key -> String(key) == "stimulus", keys(values)) && close_stale_preview!(controller)
    set_message!(controller, ui_label(:msg_parameters_set;
                                      keys = join(sort!(String.(collect(keys(values)))), ", ")))
    keep_prepared!(controller, session)
    notify_view(controller)
    return true
end

# The design with one independent variable replaced, added or removed. A parameter
# made a variable starts with one level, the value it held, which the operator then
# extends; a variable removed leaves its parameter at the value it holds.
function edited_variables(ex_par::ExperimentParameters, stim_par::AbstractStimulusParameters,
                          which::AbstractString, field::AbstractString)
    names = copy(ex_par.indep_var_names)
    ranges = copy(ex_par.indep_var_ranges)
    function start(name::Symbol)
        has_parameter(stim_par, name) ||
            throw(ArgumentError("$(stimulus_name(stim_par)) has no parameter $name."))
        return Any[parameter_value(stim_par, name)]
    end
    if which == "new"
        isempty(field) && throw(ArgumentError("Choose the parameter the new variable is."))
        Symbol(field) in names && throw(ArgumentError("$field is a variable already."))
        push!(names, Symbol(field))
        push!(ranges, start(Symbol(field)))
    else
        index = something(tryparse(Int, which), 0)
        1 <= index <= length(names) || throw(ArgumentError("The design has no variable $which."))
        if isempty(field)
            length(names) > 1 || throw(ArgumentError(
                "An experiment varies at least one parameter; choose another instead."))
            deleteat!(names, index)
            deleteat!(ranges, index)
        elseif Symbol(field) != names[index]
            Symbol(field) in names && throw(ArgumentError("$field is a variable already."))
            names[index] = Symbol(field)
            ranges[index] = start(Symbol(field))
        end
    end
    return Dict("ex_par.indep_var_names" => names, "ex_par.indep_var_ranges" => ranges)
end

"""
    can_preview(controller) -> Bool

Whether the stimulus in hand can be previewed: by a dashboard that runs its own
sessions, while no loop runs and no preview is under way.
"""
can_preview(controller::DashboardController) =
    controller.owns_engine && controller.session !== nothing && !is_running(controller) &&
    (controller.preview_task === nothing || istaskdone(controller.preview_task))

"""
    preview_dashboard_stimulus!(controller, values::AbstractDict) -> Bool

Presents the stimulus Parameters shows ([`parameters_session`](@ref)) once
([`preview_stimulus`](@ref)), with
the design's variables, and the parameters the method sets, at `values` — text by
parameter name ([`preview_condition`](@ref)). The engine opens on the first preview, in
a task of its own as a session's does, and stays open for the next; a session's start
closes it. Returns whether the preview was started; its outcome comes as a message.
"""
function preview_dashboard_stimulus!(controller::DashboardController, values::AbstractDict)
    if !can_preview(controller)
        set_message!(controller, ui_label(:msg_cannot_preview))
        return false
    end
    session = parameters_session(controller)
    stimulus, vals = try
        preview_condition(session, values)
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_preview_refused; error = err.msg))
        return false
    end
    controller.preview_task = @async try
        activate_engine_backend!(session.engine_name)
        engine = controller.preview_engine
        if engine === nothing || type_name(engine) != session.engine_name ||
           !Base.invokelatest(isopen, engine)
            close_preview!(controller)
            engine = Base.invokelatest(restore_engine, session, load_display_config())
            controller.preview_engine = engine
        end
        Base.invokelatest(preview_stimulus, engine, stimulus, vals)
        set_message!(controller, ui_label(:msg_previewed))
    catch err
        set_message!(controller, ui_label(:msg_preview_failed; error = sprint(showerror, err)))
    end
    return true
end

"""
    preview_open(controller) -> Bool

Whether a preview's engine is open, its window still showing.
"""
# The engine's backend may be newer than the window's frame that asks, hence `invokelatest`
preview_open(controller::DashboardController) =
    controller.preview_engine !== nothing && Base.invokelatest(isopen, controller.preview_engine)

"""
    close_preview!(controller)

Closes the preview's engine, and its window with it.
"""
function close_preview!(controller::DashboardController)
    engine = controller.preview_engine
    controller.preview_engine = nothing
    engine === nothing || try
        Base.invokelatest(close_engine!, engine)
    catch err
        @warn "The preview's engine did not close cleanly" exception = err
    end
    return nothing
end

"""
    control_buttons(controller) -> Vector{Symbol}

The session controls the Control view shows, in one row, by the state of the session
in hand: `:start` before it starts; `:pause` or `:resume`, and `:stop`, while it runs;
`:start_new` once it has ended, or `:next_run` when it was a scenario's run — nothing
in a dashboard whose session a script runs, since that loop ended with it; and
`:continue_changed` with `:start_new` when its stimulus program has changed since it
was presented (`:continue_changed` alone for a scenario's run). Undo and Discard are
not among them: undo is Ctrl+Z, discarding the Delete key on a file in Browse, and both
are in the Session menu. Each is greyed out when [`action_state`](@ref) finds it
unavailable.
"""
function control_buttons(controller::DashboardController)
    session = controller.session
    (session === nothing || session.state == READY) && return [:start]
    session.state == RUNNING && return [:pause, :stop]
    # A changed stimulus program stopped the session: continue under it, or start anew
    controller.changed_stimulus === nothing || session.state != PAUSED ||
        return controller.plan_run === nothing ? [:continue_changed, :start_new] :
                                                 [:continue_changed]
    session.state == PAUSED && return [:resume, :stop]
    controller.owns_engine || return Symbol[]
    return controller.plan_run === nothing ? [:start_new] : [:next_run]
end

"""
    keyboard_control(controller) -> Union{Symbol, Nothing}

The control Enter or Space presses between sessions, so that a participant at the
dashboard's keyboard can go on by themselves: Start for a session prepared and not
started, and, after a scenario's run has finished, the preparation of the plan's next
run. `nothing` while neither is available — during a session the keys are answers.
"""
function keyboard_control(controller::DashboardController)
    session = controller.session
    session !== nothing && session.shown_message !== nothing && return nothing
    available = action_state(controller)
    available.can_start && return :start
    available.can_prepare_next && return :next_run
    return nothing
end

"""
    save_dashboard_template!(controller, name) -> Bool

Saves what the session Parameters shows runs ([`parameters_session`](@ref)) — without
its trials, its participant or its run state — as the template `name` in the templates
directory ([`resolve_templates_dir`](@ref)), where the Browse view offers it. An
existing template is never overwritten. Returns whether it was saved.
"""
function save_dashboard_template!(controller::DashboardController, name::AbstractString)
    session = parameters_session(controller)
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    end
    name = strip(name)
    if isempty(name) || any(c -> c in "/\\:", name)
        set_message!(controller, ui_label(:msg_template_name))
        return false
    end
    directory = resolve_templates_dir()
    filename = endswith(lowercase(name), ".json") ? name : name * ".json"
    if isfile(joinpath(directory, filename))
        set_message!(controller, ui_label(:msg_template_exists; name))
        return false
    end
    template = create_replicated_session(session, DEFAULT_PARTICIPANT_ID)
    path = save_session_checkpoint(template, directory; filename)
    controller.lists_stale = true
    set_message!(controller, ui_label(:msg_template_saved; path))
    return true
end

"""
    start_experiment!(controller) -> Bool

Starts the controlled session. When the controller owns the engine, the engine
is restored and the trial loop runs in a task of its own so the window stays
responsive; otherwise the session is only moved into `RUNNING` and the loop the
caller already owns picks it up.
"""
function start_experiment!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif is_running(controller)
        set_message!(controller, ui_label(:msg_already_running))
        return false
    elseif session.state != READY
        set_message!(controller, ui_label(:msg_only_ready_starts))
        return false
    end
    refuse_start!(controller, session) && return false

    if !controller.owns_engine
        start_session!(session, controller.engine)
        return true
    end

    set_message!(controller, ui_label(:msg_starting))
    controller.run_task = @async _run_owned_experiment!(controller, session)
    return true
end

"""
    continue_changed_stimulus!(controller) -> Bool

Continues the session in hand under its stimulus program as it is now, which the
operator has chosen after its continuation was refused ([`StimulusChangedError`](@ref)):
the session records the changed program and the first trial it presents. Returns
whether the session was continued.
"""
function continue_changed_stimulus!(controller::DashboardController)
    if !action_state(controller).can_continue_changed
        set_message!(controller, ui_label(:msg_cannot_continue_changed))
        return false
    end
    controller.changed_stimulus = nothing
    set_message!(controller, ui_label(:msg_continuing))
    session = controller.session
    controller.run_task = @async _run_owned_experiment!(controller, session;
                                                        accept_changed_stimulus = true)
    return true
end

function _run_owned_experiment!(controller::DashboardController, session::SessionContext;
                                accept_changed_stimulus::Bool = false)
    engine = nothing
    try
        # The backend loads here, in the run task, not in the window's frame; what it
        # defines is newer than this task, hence `invokelatest` (`run_restored!`)
        activate_engine_backend!(session.engine_name)
        # The preview's window gives way to the session's
        close_preview!(controller)
        engine = Base.invokelatest(restore_engine, session, load_display_config())
        controller.engine = engine
        # The session has its file from Start, where Browse lists it and it can be
        # discarded before its first trial is answered; a scenario's run has the one
        # its plan gives it
        run = controller.plan_run
        in_plan = run !== nothing && run.session === session
        if session.save_path === nothing
            in_plan ? begin_scenario_run!(run) :
                      save_session_checkpoint(session, resolve_data_dir())
        end
        controller.chosen = session.save_path
        # The engine is up: the start or continuation under way is no longer the news
        controller.message in (ui_label(:msg_starting), ui_label(:msg_continuing)) &&
            set_message!(controller, ui_label(:msg_session_runs))
        Base.invokelatest(run_experiment!, session, engine; accept_changed_stimulus,
                          keep_waiting = () -> !controller.setting_aside)
        if in_plan && session.state == FINISHED && complete_scenario_run!(run)
            finish_scenario_run!(controller, run)
        elseif controller.setting_aside
            # `after_setting_aside!` says where the session went
        elseif !is_discarded(session.save_path)
            # A discard has said where the file went, and the loop only ended after it
            set_message!(controller, ui_label(session.state == FINISHED ? :msg_finished :
                                              session.state != ABORTED ? :msg_interrupted :
                                              in_plan ? :msg_run_stopped : :msg_stopped))
        end
    catch err
        if err isa StimulusChangedError
            # A request may have reopened a finished session; no loop runs it now
            session.state == RUNNING && (session.state = PAUSED)
            controller.changed_stimulus = err
            set_message!(controller, ui_label(controller.plan_run === nothing ?
                                              :msg_stimulus_changed : :msg_stimulus_changed_run;
                                              recorded = err.recorded, current = err.current))
            return nothing
        end
        set_message!(controller, ui_label(:msg_failed; error = sprint(showerror, err)) *
                     (session.state == PAUSED ? ui_label(:msg_resume_continues) : ""))
        @error "Dashboard session failed" exception = (err, catch_backtrace())
    finally
        engine !== nothing && Base.invokelatest(close_engine!, engine)
        controller.engine = nothing
        notify_view(controller)
    end
    return nothing
end

# A scenario's run has finished and been recorded: the panel names the plan's next
# run, which Prepare Next Run prepares
function finish_scenario_run!(controller::DashboardController, run::ScenarioRun)
    states = try
        scenario_run_states(run.plan)
    catch err
        set_message!(controller, ui_label(:msg_plan_refused; error = sprint(showerror, err)))
        return nothing
    end
    index = findfirst(entry -> entry.second !== :complete, states)
    controller.next_run = index === nothing ? nothing : states[index].first.id
    set_message!(controller, index === nothing ?
                             ui_label(:msg_plan_finished; run = run.row.id) :
                             ui_label(:msg_run_complete; run = run.row.id,
                                      next = controller.next_run))
    return nothing
end

# Guarded delegations to the session API: a button press without a session
# reports the fact instead of throwing inside a widget callback.

"""
    pause_experiment!(controller) -> Bool

Pauses the running session; a trial under way still takes its answer. Returns whether
it was paused; the panel says why not.
"""
function pause_experiment!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !action_state(controller).can_pause
        set_message!(controller, ui_label(:msg_cannot_pause))
        return false
    end
    pause!(session)
    set_message!(controller, ui_label(:msg_paused))
    return true
end

"""
    end_dashboard_message!(controller) -> Bool

Ends the message currently shown to the participant, as the participant's key would.
Returns whether a message was ended; the panel says why not.
"""
function end_dashboard_message!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif session.shown_message === nothing
        set_message!(controller, ui_label(:msg_no_message_shown))
        return false
    end
    end_message!(session)
    set_message!(controller, ui_label(:msg_message_ended))
    return true
end

"""
    resume_experiment!(controller) -> Bool

Resumes a paused session. When the dashboard's own trial loop has stopped — an
error or Ctrl+C leaves the session paused with no loop running — the loop is
run again, and it continues the session where it stopped. Returns whether it was
resumed; the panel says why not.
"""
function resume_experiment!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !action_state(controller).can_resume
        set_message!(controller, ui_label(:msg_cannot_resume))
        return false
    elseif controller.owns_engine && !is_running(controller)
        set_message!(controller, ui_label(:msg_continuing))
        controller.run_task = @async _run_owned_experiment!(controller, session)
    else
        resume!(session)
        set_message!(controller, ui_label(:msg_resumed))
    end
    return true
end

"""
    undo_dashboard_trial!(controller) -> Bool

Guarded delegation to [`undo_last_trial!`](@ref). The outcome is reported in the
panel rather than on the terminal: an operator watching the dashboard window is
not necessarily watching the console the session is reporting to. Returns whether a
trial was undone.
"""
function undo_dashboard_trial!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    end
    if session.trial_under_way
        set_message!(controller, ui_label(:msg_undo_during_trial))
        return false
    end
    finished = session.state == FINISHED
    undone = undo_last_trial!(session)
    if undone === nothing
        set_message!(controller, ui_label(:msg_nothing_undone))
    elseif finished && session.state == RUNNING && !is_running(controller)
        # The undo reopened a finished session, whose loop has ended: it waits paused,
        # and Resume runs the loop again to present the trial anew
        session.state = PAUSED
        notify_session_listeners(session, :state_changed)
        set_message!(controller, ui_label(:msg_undone_reopened; trial = undone))
    else
        set_message!(controller, ui_label(:msg_undone; trial = undone))
    end
    return undone !== nothing
end

# The first press of an action the dashboard cannot take back only says what a
# second press will do; the second, within CONFIRM_WINDOW_S, confirms it
function confirmed!(controller::DashboardController, action::Symbol,
                    question::AbstractString)
    if controller.armed === action && time() - controller.armed_at <= CONFIRM_WINDOW_S
        controller.armed = nothing
        return true
    end
    controller.armed = action
    controller.armed_at = time()
    set_message!(controller, question)
    return false
end

"""
    stop_experiment!(controller) -> Bool

Ends the controlled session for good ([`abort!`](@ref)) once the operator has pressed
Stop twice ([`CONFIRM_WINDOW_S`](@ref)). Returns whether the session was stopped. A
trial under way that still awaits its answer is abandoned, unrecorded, as for a
stimulus presented at once — a participant who has left would otherwise keep the loop
waiting; one whose answer is in is recorded.
"""
function stop_experiment!(controller::DashboardController)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !action_state(controller).can_stop
        set_message!(controller, ui_label(:msg_cannot_stop))
        return false
    end
    confirmed!(controller, :stop, ui_label(:confirm_stop)) ||
        return false
    abort!(session)
    abandon_trial!(session)
    set_message!(controller, ui_label(:msg_stopped))
    return true
end

"""
    discard_dashboard_file!(controller, path) -> Bool

Sets the session or dataset file `path` aside ([`discard_session`](@ref)), which the
operator has confirmed: it moves into the discarded directory beside it and leaves the
library. When it is the file of the session in hand, that session is stopped first and
a trial under way abandoned, since nothing it could still record belongs to a
discarded session. Returns whether the file was set aside; the panel names where it
went.
"""
function discard_dashboard_file!(controller::DashboardController, path::AbstractString)
    session = controller.session
    in_hand = session !== nothing && session.save_path !== nothing &&
              abspath(session.save_path) == abspath(path)
    moved = try
        if in_hand
            moved_to = discard_session(session)
            abandon_trial!(session)
            moved_to
        else
            discard_session(String(path))
        end
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_discard_failed; error = err.msg))
        return false
    end
    controller.chosen == path && (controller.chosen = in_hand ? moved : nothing)
    target_abs = abspath(path)
    filter!(p -> abspath(p) != target_abs, controller.ticked)
    controller.lists_stale = true
    set_message!(controller, ui_label(:msg_discarded; path = moved))
    return true
end

# ── Ticks and relabelling ────────────────────────────────────────────────────

"""
    tick_session!(controller, path, on::Bool) -> controller

Adds or removes session file `path` from the controller's ticked list, keeping tick order.
"""
function tick_session!(controller::DashboardController, path::AbstractString, on::Bool)
    target = String(path)
    if on
        target in controller.ticked || push!(controller.ticked, target)
    else
        filter!(!=(target), controller.ticked)
    end
    return controller
end

"""
    clear_ticks!(controller) -> controller

Unticks all sessions.
"""
clear_ticks!(controller::DashboardController) = (empty!(controller.ticked); controller)

"""
    prune_ticks!(controller, entries) -> controller

Drops any path from `controller.ticked` that is no longer listed as a session in `entries`.
"""
function prune_ticks!(controller::DashboardController, entries::AbstractVector{LibraryEntry})
    listed = Set(entry.path for entry in entries if entry.kind === :session)
    filter!(path -> path in listed, controller.ticked)
    return controller
end

"""
    reread_library!(controller, directory = ".") -> Vector{LibraryEntry}

Reads the session library from disk, drops ticked paths that are no longer listed, and
clears `controller.lists_stale`.
"""
function reread_library!(controller::DashboardController, directory::AbstractString = ".")
    entries = browse_sessions(resolve_data_dir(String(directory)))
    prune_ticks!(controller, entries)
    controller.lists_stale = false
    return entries
end

# Tags present in every list, in the order of the first list
function shared_tags(tag_lists::AbstractVector{<:AbstractVector{<:AbstractString}})
    isempty(tag_lists) && return String[]
    common = String[]
    for tag in first(tag_lists)
        s = String(tag)
        s in common && continue
        all(tags -> s in tags, Iterators.drop(tag_lists, 1)) && push!(common, s)
    end
    return common
end

"""
    edit_ticked_labels!(controller, key, text) -> Bool

Changes a label (`"experiment_name"`, `"tags"`, or `"comment"`) across all ticked session
files via [`relabel_sessions!`](@ref). Marks `controller.lists_stale` so the lists are
reread, and reopens the session in hand if its file was relabelled and it has ended.
Refuses while a session loop is running, when nothing is ticked, or when one of the
ticked files belongs to an unfinished session in hand.
"""
function edit_ticked_labels!(controller::DashboardController, key::AbstractString,
                             text::AbstractString)
    if is_running(controller)
        set_message!(controller, ui_label(:msg_relabel_while_running))
        return false
    elseif isempty(controller.ticked)
        set_message!(controller, ui_label(:msg_relabel_none_ticked))
        return false
    end

    session = controller.session
    ticked_abs = Set(abspath.(controller.ticked))
    if session !== nothing && session.save_path !== nothing &&
       abspath(session.save_path) in ticked_abs &&
       !(session.state in (FINISHED, ABORTED))
        set_message!(controller, ui_label(:msg_relabel_unfinished;
                                          file = basename(session.save_path)))
        return false
    end

    rewritten = try
        if key == "experiment_name"
            relabel_sessions!(controller.ticked; experiment_name = text)
        elseif key == "tags"
            unique_paths = deduplicate_paths(controller.ticked)
            tag_lists = [String[String(t) for t in last(read_session_for_relabelling(p))["tags"]]
                         for p in unique_paths]
            shared = shared_tags(tag_lists)
            wanted = unique(String[String(strip(t)) for t in split(text, ',')
                                   if !isempty(strip(t))])
            to_add = String[t for t in wanted if !(t in shared)]
            to_remove = String[t for t in shared if !(t in wanted)]
            if isempty(to_add) && isempty(to_remove)
                set_message!(controller, ui_label(:msg_relabel_no_change))
                return true
            end
            relabel_sessions!(controller.ticked; add_tags = to_add, remove_tags = to_remove)
        elseif key == "comment"
            if isempty(strip(text))
                set_message!(controller, ui_label(:msg_comment_empty))
                return false
            end
            relabel_sessions!(controller.ticked; comment = text)
        else
            throw(ArgumentError("Cannot relabel `$key`."))
        end
    catch err
        err isa ArgumentError || rethrow()
        set_message!(controller, ui_label(:msg_relabel_failed; error = err.msg))
        return false
    end

    controller.lists_stale = true
    relabelled_abs = Set(abspath.(rewritten))
    if session !== nothing && session.save_path !== nothing &&
       session.state in (FINISHED, ABORTED) &&
       abspath(session.save_path) in relabelled_abs
        saved_participant = controller.participant
        open_previous_session!(controller, session.save_path)
        controller.participant = saved_participant
    end
    set_message!(controller, isempty(rewritten) ? ui_label(:msg_relabel_no_change) :
                 ui_label(:msg_relabel_done; count = length(rewritten)))
    notify_view(controller)
    return true
end

"""
    trial_actions(controller, trial) -> NamedTuple

Which of the corrections offered on one recorded trial — in the trial table and on
a point of the live plot — would do something now. Marking it an outlier needs a
trial that still counts. Presenting its condition again needs a session that can
still present one ([`can_present`](@ref)); replacing its answer also needs a trial
that still counts and no replacement of it already waiting. Presenting *now* also
needs a trial that awaits its answer, which is what is abandoned.
"""
function trial_actions(controller::DashboardController, trial::Integer)
    session = controller.session
    record = session === nothing ? nothing :
             findfirst(t -> t.trial_index == trial, session.history)
    counted = record !== nothing && session.history[record].is_valid
    presentable = record !== nothing && can_present(controller)
    return (
        can_mark_outlier = counted,
        can_repeat = presentable && counted &&
                     !any(request -> request.replaces == trial, session.operator_requests),
        can_add = presentable,
        can_now = presentable && session.trial_run !== nothing,
    )
end

"""
    can_present(controller) -> Bool

Whether the operator can ask for a stimulus of their choice now: a session that was
not stopped, whose method takes an operator's trial, and — when the session has
finished — a dashboard that runs the trial loop itself, since a script's loop has
ended with it.
"""
function can_present(controller::DashboardController)
    session = controller.session
    session === nothing && return false
    session.state == ABORTED && return false
    session.state == FINISHED && !controller.owns_engine && return false
    method = session.method_instance
    return plans_conditions(method) || isempty(adjusted_fields(method))
end

"""
    mark_dashboard_outlier!(controller, trial) -> Bool

Marks trial number `trial` an outlier through [`mark_outlier!`](@ref), and reports the
outcome in the panel. Returns whether a trial was marked.
"""
function mark_dashboard_outlier!(controller::DashboardController, trial::Integer)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif !any(t -> t.trial_index == trial, session.history)
        set_message!(controller, ui_label(:msg_no_such_trial; trial))
        return false
    end
    marked = mark_outlier!(session, trial)
    set_message!(controller, ui_label(marked ? :msg_outlier_marked : :msg_outlier_already;
                                      trial))
    return marked
end

"""
    add_dashboard_comment!(controller, text; trial = nothing) -> Bool

Adds the operator's comment `text` to the session in hand ([`add_comment!`](@ref)), about
trial number `trial` when one is named, and reports the outcome in the panel. Returns
whether the comment was added.
"""
function add_dashboard_comment!(controller::DashboardController, text::AbstractString;
                                trial::Union{Nothing, Integer} = nothing)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    elseif isempty(strip(text))
        set_message!(controller, ui_label(:msg_comment_empty))
        return false
    elseif trial !== nothing && !any(t -> t.trial_index == trial, session.history)
        set_message!(controller, ui_label(:msg_no_such_trial; trial))
        return false
    end
    add_comment!(session, text; trial)
    set_message!(controller, ui_label(:msg_comment_added))
    return true
end

"""
    repeat_dashboard_trial!(controller, trial; when = :after) -> Bool

Presents the condition of trial number `trial` again, its new answer taking the
place of the earlier one ([`repeat_trial!`](@ref)) — once the trial under way is
answered, or at once (`when = :now`), abandoning it — and reports the outcome in the
panel. Returns whether the trial was queued again.
"""
repeat_dashboard_trial!(controller::DashboardController, trial::Integer;
                        when::Symbol = :after) =
    request_from_dashboard!(controller, trial, when, :replace) do session, record
        repeat_trial!(session, trial; when)
    end

"""
    add_dashboard_trial!(controller, trial; when = :after) -> Bool

Presents the condition of trial number `trial` again, its answer added to the others
([`present_condition!`](@ref)), and reports the outcome in the panel. Returns whether
the condition was queued.
"""
add_dashboard_trial!(controller::DashboardController, trial::Integer;
                     when::Symbol = :after) =
    request_from_dashboard!(controller, trial, when, :add) do session, record
        present_condition!(session, record.indep_var_vals; when)
    end

"""
    present_dashboard_condition!(controller, vals; when = :after) -> Bool

Presents the condition `vals`, recorded values as `Trial.indep_var_vals` holds them,
its answer added to the others ([`present_condition!`](@ref)), and reports the
outcome in the panel. Returns whether the condition was queued.
"""
present_dashboard_condition!(controller::DashboardController, vals::AbstractVector{<:Real};
                             when::Symbol = :after) =
    request_from_dashboard!(controller, nothing, when, :condition) do session, _
        present_condition!(session, vals; when)
    end

# The guards, the message and the restart every request from the dashboard shares.
# `request(session, record)` makes the request; `record` is the trial it starts from.
function request_from_dashboard!(request::Function, controller::DashboardController,
                                 trial::Union{Nothing, Integer}, when::Symbol, kind::Symbol)
    session = controller.session
    if session === nothing
        set_message!(controller, no_session_text())
        return false
    end
    record = nothing
    if trial !== nothing
        index = findfirst(t -> t.trial_index == trial, session.history)
        if index === nothing
            set_message!(controller, ui_label(:msg_no_such_trial; trial))
            return false
        end
        record = session.history[index]
    end
    if !can_present(controller)
        set_message!(controller, ui_label(session.state == FINISHED ?
                                          :msg_finished_script : :msg_cannot_present))
        return false
    end

    abandoning = when === :now && session.trial_run !== nothing &&
                 can_abandon_presentation(session.trial_run.engine)
    reopening = session.state == FINISHED
    taken = request(session, record)
    if !taken
        set_message!(controller, ui_label(:msg_cannot_present))
        return false
    end
    key = Symbol("msg_", kind, abandoning ? "_now" : "_next")
    set_message!(controller, trial === nothing ? ui_label(key) : ui_label(key; trial))
    # A finished session the dashboard ran has no loop left to present the request
    reopening && controller.owns_engine && !is_running(controller) &&
        (controller.run_task = @async _run_owned_experiment!(controller, session))
    return true
end

# ── A script's own loop beside the dashboard ─────────────────────────────────

"""
    run_when_started!(session, engine, dashboard; kwargs...) -> session

Waits until the operator starts `session` from `dashboard`, the window
[`open_operator_dashboard`](@ref) returned for it, and then runs the session with
`run_experiment!(session, engine; kwargs...)`. Returns when the session ends, at once
when the window is closed before the session was started, and when the window is closed
while the session is paused: the session then stays paused in its file
([`close_dashboard!`](@ref)).

The loop runs in the calling task, so Ctrl+C reaches it and leaves the session
paused and continuable, as it does without a dashboard.
"""
function run_when_started!(session::SessionContext, engine::AbstractStimulusEngine,
                           dashboard; kwargs...)
    while session.state == READY && isopen(dashboard)
        sleep(0.05)
    end
    session.state == RUNNING || session.state == PAUSED || return session
    wanted = get(kwargs, :keep_waiting, () -> true)
    run_experiment!(session, engine; kwargs...,
                    keep_waiting = () -> isopen(dashboard) && wanted())
    return session
end
