# Session control commands. They are quiet: operator feedback comes from the
# session-event observers (console reporter, dashboard), not from ad-hoc prints,
# and a request that changes nothing is reported with `@warn`. What a
# caller needs to know about the outcome comes back as the return value.

"""
    start_session!(session::SessionContext, engine=nothing)

Opens a READY session: stamps its start time, records the machine it runs on
([`snapshot_environment`](@ref) — `engine` contributes the viewing conditions
when it can report them), the shortest response time the settings give its
response devices ([`load_input_config`](@ref)) and the rig's constants
([`load_rig`](@ref)), resolves any unit conversion formulas and `[units.<stimulus>]`
defaults against that rig and the session's stimulus, opens the random stream its
`rng_seed` describes, tells the method whether the task scores its answers
([`set_task_scored!`](@ref)), and hands the stream to the method's `initialize_method!`.
A method that lacks settings it needs ([`unset_settings`](@ref)), steps on answers
([`steps_on_answers`](@ref)) in a task that scores some conditions only
([`task_scoring`](@ref)), or a unit conversion formula that cannot be resolved, is
refused with an `ArgumentError`, and the session stays READY, unchanged.

A session resumed from a checkpoint does not pass through here: it is already
RUNNING, and its realized trial order is part of the saved method state, so
continuing it re-randomizes nothing and never resolves conversions again.
"""
function start_session!(session::SessionContext, engine=nothing)
    check_settings_set(session.method_instance)
    scoring = task_scoring(session.stim_par, session.ex_par)
    check_task_scoring(session.method_instance, session.stim_par, scoring)
    min_response_s = load_input_config().min_response_s
    rig = load_rig()
    resolved_units = resolve_session_unit_conversions(session, rig)
    session.start_time = time()
    session.environment = snapshot_environment(session, engine)
    session.min_response_s = min_response_s
    session.rig = rig
    merge!(session.unit_conversions, resolved_units)
    session.rng = Xoshiro(session.rng_seed)
    set_task_scored!(session.method_instance, scoring === :all)
    initialize_method!(session.method_instance, session.ex_par; rng = session.rng)
    session.state = RUNNING
    notify_session_listeners(session, :state_changed)
end

function pause!(session::SessionContext)
    if session.state == RUNNING
        session.state = PAUSED
        notify_session_listeners(session, :state_changed)
    else
        @warn "Cannot pause: the session is not RUNNING" state = session.state
    end
end

function resume!(session::SessionContext)
    if session.state == PAUSED
        session.state = RUNNING
        notify_session_listeners(session, :state_changed)
    else
        @warn "Cannot resume: the session is not PAUSED" state = session.state
    end
end

function abort!(session::SessionContext)
    session.state = ABORTED
    checkpoint_if_pinned(session)
    notify_session_listeners(session, :state_changed)
end

# The trial loop's way out when Ctrl+C or an error stops it. Unlike abort!, it
# is not the operator's decision to end the session, so the session stays
# continuable: PAUSED, checkpointed, and announced as `:interrupted` rather than
# as a pause somebody asked for. A session already ended keeps its state.
function interrupt!(session::SessionContext)
    session.state == RUNNING || session.state == PAUSED || return nothing
    session.state = PAUSED
    checkpoint_if_pinned(session)
    notify_session_listeners(session, :interrupted)
    return nothing
end

"""
    undo_last_trial!(session::SessionContext) -> Union{Nothing, Int}

Marks the last valid trial as invalid (non-destructive soft delete) and asks
the method to revert its state so the trial is re-queued. Returns the index of
the undone trial, or `nothing` when nothing was undone.

The operation is transactional: if the method cannot revert
(`revert_method_state!` returns `false`, announcing why), the undo is cancelled
and the trial stays valid. If the session was already FINISHED, it is reopened
(set back to RUNNING) so the re-queued trial can be run, e.g. by calling
`run_experiment!` again.

A trial the operator asked for and the Core presented past the method
([`present_condition!`](@ref)) is taken back from the method by
[`forget_operator_trial!`](@ref) instead, and its condition is presented again next.

While a trial is under way — a dashboard's button pressed as the participant looks
at a stimulus — nothing is undone: pause, let the trial be answered, and undo then,
or repeat the trial by its number ([`repeat_trial!`](@ref)).
"""
function undo_last_trial!(session::SessionContext)
    refuse_during_trial(session, "undo") && return nothing
    idx = findlast(t -> t.is_valid, session.history)
    if idx === nothing
        @warn "Nothing to undo: the session has no valid trials"
        return nothing
    end

    trial = session.history[idx]
    method = session.method_instance
    # Transactional: revert the method FIRST; if it cannot re-queue the trial
    # (returns false), cancel the whole correction — invalidating a trial the
    # method still counts as done would shorten the planned measurement.
    if trial.origin === :operator && !plans_conditions(method)
        forget_operator_trial!(method, trial) === true || return nothing
        pushfirst!(session.operator_requests,
                   OperatorRequest(copy(trial.indep_var_vals), nothing))
    else
        revert_method_state!(method, trial) === true || return nothing
    end
    trial.is_valid = false

    reopened = session.state == FINISHED && !session_complete(session)
    reopened && (session.state = RUNNING)
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    reopened && notify_session_listeners(session, :state_changed)
    notify_session_listeners(session, :history_changed)
    return trial.trial_index
end

"""
    present_condition!(session::SessionContext, vals; when = :after) -> Bool

Presents the condition `vals` — one value per independent variable, as
`Trial.indep_var_vals` records them — and adds its answer to the others. The record
marks the trial as the operator's (`Trial.origin`), and the analysis counts it as any
other. Returns whether the request was taken.

`when = :after` presents it once the trial under way, if any, has been answered.
`when = :now` abandons the trial under way, as Ctrl+C does: it is not recorded, and
the method presents it again right after the operator's. A trial whose answer is
already in is not abandoned, nor one an engine cannot interrupt
([`can_abandon_presentation`](@ref)); the condition is then presented next.

The condition is one the design declares or one the session has presented. A method
with a plan made in advance takes it into the plan ([`take_condition!`](@ref)): a copy
still waiting there is moved forward, so the session keeps its length, and the
condition is inserted otherwise. Any other method is passed by: the Core presents the
condition, collects one answer (`0` asks to see it again) and tells the method the
outcome ([`absorb_operator_trial!`](@ref)) — Psi takes it into its posterior, a
staircase keeps its own sequence. Such a trial does not count toward the method's
own number of trials.

Requests are presented before the method's next trial — in the order made, a request
`:now` ahead of the others — and are not saved: a session interrupted before a
requested trial was presented continues without it. A `FINISHED` session is reopened,
so the trial can be run with `run_experiment!`; an `ABORTED` one is final.
"""
present_condition!(session::SessionContext, vals::AbstractVector{<:Real};
                   when::Symbol = :after) =
    request_presentation!(session, OperatorRequest(Float64.(vals), nothing), when)

"""
    repeat_trial!(session::SessionContext, trial_idx::Int; when = :after) -> Bool

Presents the condition of recorded trial `trial_idx` again, its new answer taking the
place of the earlier one — once the trial under way, if any, has been answered, or at
once (`when = :now`, as for [`present_condition!`](@ref)). The original is marked
invalid (soft delete: the history keeps it) when the new trial is recorded, not
before, so a session stopped in between loses no answer. Returns whether the trial was
queued again.

It works with every method, as [`present_condition!`](@ref) does, except that a
method with a plan inserts the condition rather than moving a waiting copy forward:
the plan grows by one. A trial already invalid is refused, since it has no answer to
replace, and so is one already waiting to be replaced.
"""
function repeat_trial!(session::SessionContext, trial_idx::Int; when::Symbol = :after)
    idx = findfirst(t -> t.trial_index == trial_idx, session.history)
    if idx === nothing
        @warn "Cannot repeat a trial: the session has no such trial" trial = trial_idx
        return false
    end
    trial = session.history[idx]
    if !trial.is_valid
        @warn "Trial $trial_idx is already invalid, so it has no answer to replace; an " *
              "undone trial is presented again already." trial = trial_idx
        return false
    elseif any(request -> request.replaces == trial_idx, session.operator_requests)
        @warn "Trial $trial_idx is already waiting to be replaced." trial = trial_idx
        return false
    end
    return request_presentation!(session,
                                 OperatorRequest(copy(trial.indep_var_vals), trial_idx), when)
end

# Hands an operator's request to the trial loop, which takes it up before its next
# trial (`run_recorded_trial!`): applied there, it never changes the plan under a
# trial under way. Not checkpointed — the request is runtime-only, and a file
# that said RUNNING over a finished plan would have nothing to present.
function request_presentation!(session::SessionContext, request::OperatorRequest,
                               when::Symbol)
    when in (:after, :now) || throw(ArgumentError("when is :after or :now, got :$when."))
    if session.state == ABORTED
        @warn "Cannot present a condition: the session was aborted"
        return false
    end
    names = session.ex_par.indep_var_names
    length(request.vals) == length(names) || throw(ArgumentError(
        "A condition gives one value per independent variable ($(join(names, ", "))), " *
        "got $(request.vals)."))
    declared = all(any(level -> level isa Real && level == value, range)
                   for (range, value) in zip(session.ex_par.indep_var_ranges, request.vals))
    declared || any(t -> t.indep_var_vals == request.vals, session.history) ||
        throw(ArgumentError("$(request.vals) is neither a condition the design declares " *
                            "nor one the session has presented."))
    method = session.method_instance
    if !plans_conditions(method) && !isempty(adjusted_fields(method))
        @warn "$(type_name(method)) sets the stimulus during its trial, so a trial cannot " *
              "be presented past it, and it plans no conditions to take one into."
        return false
    end

    if when === :now
        pushfirst!(session.operator_requests, request)
        abandon_trial!(session)
    else
        push!(session.operator_requests, request)
    end
    if session.state == FINISHED
        session.state = RUNNING
        notify_session_listeners(session, :state_changed)
    end
    return true
end

# Abandons the trial under way, as Ctrl+C does: the loop's task is resumed with
# `TrialAbandoned` wherever it waits — or, for an engine that ends its presentation at
# the Core's request, raises it there once the presentation has ended — the trial's
# restore runs, and nothing is recorded. Returns whether a trial was abandoned.
function abandon_trial!(session::SessionContext)
    run = session.trial_run
    (run === nothing || run.task === current_task() || istaskdone(run.task)) && return false
    if !can_abandon_presentation(run.engine)
        @warn "$(type_name(run.engine)) cannot interrupt the presentation under way, so " *
              "the trial is not abandoned; the chosen condition is presented right after it."
        return false
    end
    abandon_presentation!(run.engine) || schedule(run.task, TrialAbandoned(); error = true)
    discard_pending_responses!(ACTIVE_RESPONSE_SOURCE[])
    return true
end

"""
    session_trial_total(session) -> Union{Int, Nothing}

The trials the session will have presented: those presented, the method's remaining
ones ([`remaining_trial_count`](@ref)) and the operator's requests waiting to pass it
by. A trial the method does not count — an operator's, an undone one — raises the
total rather than passing it. Falls back to [`planned_trial_count`](@ref), and before
the start of a method that plans its conditions, to the design's trials.
"""
function session_trial_total(session::SessionContext)
    method = session.method_instance
    remaining = remaining_trial_count(method)
    if remaining === nothing
        planned = planned_trial_count(method)
        (planned === nothing && session.state == READY && plans_conditions(method)) ||
            return planned
        # The plan is drawn at the start; until then it is the design, every condition
        # repeated
        return try
            length(build_trial_table(session.ex_par))
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
    end
    # A planning method takes a request into its plan only when presenting it
    waiting = plans_conditions(method) ? 0 : length(session.operator_requests)
    return session.current_trial_idx - 1 + max(remaining, 0) + waiting
end

"""
    planned_valid_trials(session) -> Union{Int, Nothing}

The valid trials the session will have counted when it ends, as far as is known now:
those valid now plus those still to come, or `nothing` for an open-ended method. An
undone trial is presented again and leaves the count as it was; a trial marked as an
outlier is not presented again and lowers it by one; an operator's added trial raises it.
"""
function planned_valid_trials(session::SessionContext)
    total = session_trial_total(session)
    total === nothing && return nothing
    return count(t -> t.is_valid, session.history) + total - (session.current_trial_idx - 1)
end

# Nothing is left to present: the method has finished and no operator's request waits
session_complete(session::SessionContext) =
    is_experiment_finished(session.method_instance) && isempty(session.operator_requests)

# A correction that moves the method's plan is refused while the loop is between a
# trial's start and its record
function refuse_during_trial(session::SessionContext, action::AbstractString)
    session.trial_under_way || return false
    @warn "A trial is under way, so nothing is done ($action). Pause, let the trial " *
          "be answered, and $action then."
    return true
end

"""
    mark_outlier!(session::SessionContext, trial_idx::Int) -> Bool

Marks one recorded trial invalid (soft delete) and refreshes the pinned
checkpoint. Returns whether this call changed anything: a trial that is already
invalid is left as it is.
"""
function mark_outlier!(session::SessionContext, trial_idx::Int)
    idx = findfirst(t -> t.trial_index == trial_idx, session.history)
    if idx === nothing
        @warn "Cannot mark an outlier: the session has no such trial" trial = trial_idx
        return false
    end

    session.history[idx].is_valid || return false
    session.history[idx].is_valid = false
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :history_changed)
    return true
end

"""
    add_comment!(session, text; trial = nothing) -> SessionComment

Adds the operator's note `text` to the session,
stamped with the time it is written; `trial` names the trial it is about, when it is
about one. Comments are kept in the session file and written into its exports. They
describe the session and change nothing in it, so one may be added at any time — while
it runs, and after it has ended. A comment added while a trial is under way is saved
with that trial; otherwise the pinned checkpoint is refreshed at once.
"""
function add_comment!(session::SessionContext, text::AbstractString;
                      trial::Union{Nothing, Integer} = nothing)
    note = strip(text)
    isempty(note) && throw(ArgumentError("A comment needs some text."))
    trial === nothing || any(t -> t.trial_index == trial, session.history) ||
        throw(ArgumentError("The session has no trial $trial to comment on."))
    comment = SessionComment(time(), trial === nothing ? nothing : Int(trial), String(note))
    push!(session.comments, comment)
    # Mid-trial the method's state is half-way through the trial; the trial's own
    # checkpoint, moments later, writes the comment with a consistent state
    session.trial_under_way || checkpoint_if_pinned(session)
    notify_session_listeners(session, :comment_added)
    return comment
end

"""
    set_fit_gamma!(session, gamma) -> session

Sets the lower asymptote this session's psychometric curve is fitted from (see
[`DEFAULT_FIT_GAMMA`](@ref)) and refreshes the pinned checkpoint, so a session
reopened later is fitted the way the operator declared it.

`gamma` must lie in `[0, 1)`: it is a proportion, and an asymptote at or above
1 would leave the curve no room to rise.
"""
function set_fit_gamma!(session::SessionContext, gamma::Real)
    0.0 <= gamma < 1.0 ||
        throw(ArgumentError("fit_gamma must be in [0, 1), got $gamma."))
    session.fit_gamma == Float64(gamma) && return session
    session.fit_gamma = Float64(gamma)
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    # Not :state_changed — the lifecycle state is untouched, and reporting it
    # as one would reprint the session banner in the middle of a run
    notify_session_listeners(session, :settings_changed)
    return session
end

"""
    set_feedback!(session, on::Bool) -> session

Declares whether the participant is told, after every scored trial, whether the
answer was correct, and refreshes the pinned checkpoint.

The Core reports the outcome through the engine's [`present_feedback`](@ref)
hook; a trial the task did not score has none to report. A training session runs
with feedback and a measurement session without it, and the flag is persisted
because that difference changes what the data measures and would otherwise
survive only in the script that collected it.
"""
function set_feedback!(session::SessionContext, on::Bool)
    session.feedback == on && return session
    session.feedback = on
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :settings_changed)
    return session
end

"""
    set_timeout!(session, timeout_s::Union{Nothing, Real}) -> session

Declares how long the participant has to answer each presentation, `nothing`
waiting indefinitely, and refreshes the pinned checkpoint.

A window that closes with nothing answered is recorded as the response
`:timeout`; the method decides what that means for the measurement
([`timeout_result`](@ref)). The setting is persisted because a session that
hurried the participant measures something different from one that did not, and
enforcing it is left to whoever owns the input device — the response source or
an engine that captures its own responses.
"""
function set_timeout!(session::SessionContext, timeout_s::Union{Nothing, Real})
    timeout_s === nothing || timeout_s > 0 || throw(ArgumentError(
        "A response window must be positive, got $timeout_s seconds."))
    window = timeout_s === nothing ? nothing : Float64(timeout_s)
    session.timeout_s == window && return session
    session.timeout_s = window
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :settings_changed)
    return session
end

"""
    set_messages!(session::SessionContext;
                  instructions=nothing, break_every=nothing, break_after=nothing,
                  break_waits_for=nothing, break_min_s=nothing,
                  break_text=nothing, closing_text=nothing) -> SessionContext

Declares when messages are shown to the participant between trials and what they say,
and refreshes the pinned checkpoint.

Only the keywords given change; unspecified keywords keep the session's current values.

# Arguments
- `instructions`: whether to show the task's instructions before the first trial.
  Throws an `ArgumentError` if set to `true` while the session has no task (`session.task === nothing`).
- `break_every`: a break after every `n` recorded trials; 0 = none.
- `break_after`: recorded-trial counts after which a break is shown.
- `break_waits_for`: who dismisses the break: `:participant` or `:operator`.
- `break_min_s`: minimum display time before a participant's key dismisses the break.
- `break_text`: message shown during a break.
- `closing_text`: message shown after the last trial (`""` = none).

A break falls only between trials, never between intra-trial adjustment steps. During a break,
the session lifecycle state is `PAUSED`. Breaks are counted by recorded trials, so an undo
never brings a break back and a resumed session does not repeat one. Sessions answered by
a model observer are shown no messages.
"""
function set_messages!(session::SessionContext;
                       instructions::Union{Nothing, Bool} = nothing,
                       break_every::Union{Nothing, Integer} = nothing,
                       break_after::Union{Nothing, AbstractVector{<:Integer}} = nothing,
                       break_waits_for::Union{Nothing, Symbol} = nothing,
                       break_min_s::Union{Nothing, Real} = nothing,
                       break_text::Union{Nothing, AbstractString} = nothing,
                       closing_text::Union{Nothing, AbstractString} = nothing)
    cur = session.messages
    new_instructions = instructions === nothing ? cur.instructions : instructions
    new_break_every = break_every === nothing ? cur.break_every : break_every
    new_break_after = break_after === nothing ? cur.break_after : break_after
    new_break_waits_for = break_waits_for === nothing ? cur.break_waits_for : break_waits_for
    new_break_min_s = break_min_s === nothing ? cur.break_min_s : break_min_s
    new_break_text = break_text === nothing ? cur.break_text : break_text
    new_closing_text = closing_text === nothing ? cur.closing_text : closing_text

    if new_instructions && session.task === nothing
        throw(ArgumentError("Cannot show instructions: the instructions are the task's wording. Call set_task! first."))
    end

    new_messages = SessionMessages(
        instructions = new_instructions,
        break_every = new_break_every,
        break_after = new_break_after,
        break_waits_for = new_break_waits_for,
        break_min_s = new_break_min_s,
        break_text = new_break_text,
        closing_text = new_closing_text,
    )

    session.messages == new_messages && return session
    session.messages = new_messages
    checkpoint_if_pinned(session)
    notify_session_listeners(session, :settings_changed)
    return session
end

"""
    end_message!(session::SessionContext) -> Bool

Ends the message currently shown to the participant, as the participant's key would.

For a break it calls [`resume!`](@ref); for instructions or a closing message it sets
`session.shown_message = nothing`. Returns whether a message was shown.
"""
function end_message!(session::SessionContext)
    message = session.shown_message
    message === nothing && return false
    if message.kind === :break
        resume!(session)
    else
        session.shown_message = nothing
    end
    return true
end

"""
    set_unit_conversion!(session, variable::Symbol,
                         conversion::Union{Nothing, UnitConversion}) -> session

Declares the units `variable` is reported in (see [`UnitConversion`](@ref)), or
removes its conversion when `conversion` is `nothing`, and refreshes the pinned
checkpoint.

`variable` is an independent variable, or the stimulus field an adjustment sets,
whose confirmed value is the trial's response. The recorded values never change:
plots, summaries and exports show them converted, and a trial export keeps the
recorded column beside the converted one. A conversion can therefore be declared
after the session has run, and a replication inherits it.

A logarithmic conversion is refused when a value the design presents, or the
session has recorded, is not positive.
"""
function check_unit_conversion(session::SessionContext, variable::Symbol,
                               conversion::Union{Nothing, UnitConversion})
    convertible = convertible_variables(session)
    variable in convertible || throw(ArgumentError(
        "$variable is neither an independent variable nor the field the method " *
        "adjusts, so no value of it is reported; this session can convert " *
        "$(isempty(convertible) ? "nothing" : join(convertible, ", "))."))
    if conversion !== nothing && conversion.form === :log10
        offending = [x for x in known_values(session, variable) if !(x > 0)]
        isempty(offending) || throw(ArgumentError(
            "\"$(conversion.label)\" is a logarithmic conversion, and $variable takes " *
            "the value $(first(offending)), which is not positive."))
    end
    return nothing
end

function set_unit_conversion!(session::SessionContext, variable::Symbol,
                              conversion::Union{Nothing, UnitConversion})
    check_unit_conversion(session, variable, conversion)
    get(session.unit_conversions, variable, nothing) == conversion && return session
    if conversion === nothing
        delete!(session.unit_conversions, variable)
    else
        session.unit_conversions[variable] = conversion
    end
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :settings_changed)
    return session
end

# The names a unit formula may use (the rig's constants and the stimulus's fixed numeric
# parameters), those it may not (variables, adjusted fields) and those it may not
# because the rig and the stimulus both name them
function unit_formula_context(session::SessionContext, rig::AbstractDict)
    rig_constants = Dict{Symbol, Float64}()
    for (key, value) in rig
        name = string(key)
        name == "name" && continue
        value isa Real && !(value isa Bool) && (rig_constants[Symbol(name)] = Float64(value))
    end
    unavailable = union(session.ex_par.indep_var_names,
                        adjusted_fields(session.method_instance))
    stim_constants = Dict{Symbol, Float64}()
    for name in numeric_parameters(session.stim_par)
        name in unavailable && continue
        value = parameter_value(session.stim_par, name)
        value isa Real && !(value isa Bool) && (stim_constants[name] = Float64(value))
    end
    ambiguous = Symbol[name for name in keys(rig_constants) if haskey(stim_constants, name)]
    constants = merge(rig_constants, stim_constants)
    for name in ambiguous
        delete!(constants, name)
    end
    for name in unavailable
        delete!(constants, name)
    end
    return (constants = constants, unavailable = unavailable, ambiguous = ambiguous)
end

function parse_session_unit_conversion(session::SessionContext, variable::Symbol,
                                       text::AbstractString, rig::AbstractDict)
    ctx = unit_formula_context(session, rig)
    return parse_unit_conversion(variable, text;
                                 constants = ctx.constants,
                                 unavailable = ctx.unavailable,
                                 ambiguous = ctx.ambiguous)
end

# The conversions a start sets (D51): a formula resolved anew with `rig`, and the
# project's `[units.<stimulus>]` entry for a variable without one; the session is not
# changed, and the first refusal names its variable
function resolve_session_unit_conversions(session::SessionContext, rig::AbstractDict,
                                          directory::AbstractString = ".")
    convertible = convertible_variables(session)
    resolved = Dict{Symbol, UnitConversion}()
    ctx = nothing
    defaults = nothing
    for variable in convertible
        existing = get(session.unit_conversions, variable, nothing)
        if existing !== nothing
            isempty(existing.formula) && continue
            ctx === nothing && (ctx = unit_formula_context(session, rig))
            conversion = try
                c = parse_unit_formula(variable, existing.label, existing.formula;
                                       constants = ctx.constants,
                                       unavailable = ctx.unavailable,
                                       ambiguous = ctx.ambiguous)
                check_unit_conversion(session, variable, c)
                c
            catch err
                err isa ArgumentError || rethrow()
                throw(ArgumentError("Unit conversion for $variable: $(err.msg)"))
            end
            resolved[variable] = conversion
        else
            if defaults === nothing
                defaults = load_unit_defaults(stimulus_name(session.stim_par), directory)
            end
            haskey(defaults, variable) || continue
            text = defaults[variable].text
            ctx === nothing && (ctx = unit_formula_context(session, rig))
            conversion = try
                c = parse_unit_conversion(variable, text;
                                          constants = ctx.constants,
                                          unavailable = ctx.unavailable,
                                          ambiguous = ctx.ambiguous)
                c === nothing || check_unit_conversion(session, variable, c)
                c
            catch err
                err isa ArgumentError || rethrow()
                throw(ArgumentError("Unit conversion for $variable: $(err.msg)"))
            end
            conversion === nothing || (resolved[variable] = conversion)
        end
    end
    return resolved
end

function convertible_variables(session::SessionContext)
    variables = copy(session.ex_par.indep_var_names)
    response = response_variable(session.method_instance)
    response === nothing || push!(variables, response)
    return variables
end

# The values of `variable` the session presents or has recorded. The adjusted
# field's range is the method's own, so for the response only what was recorded is
# known; a later value the conversion cannot take fails when it is converted.
function known_values(session::SessionContext, variable::Symbol)
    index = findfirst(==(variable), session.ex_par.indep_var_names)
    index === nothing &&
        return [t.response for t in session.history if t.response isa Real && !isnan(t.response)]
    return vcat(Real[x for x in session.ex_par.indep_var_ranges[index] if x isa Real],
                [t.indep_var_vals[index] for t in session.history])
end

"""
    set_task!(session, task::ObserverTask) -> session

Records what the observer was asked and what the response coding means (see
[`ObserverTask`](@ref)), and refreshes the pinned checkpoint.

Without it a session keeps a column of responses whose meaning survives only in
the script that produced them — as true of a person pressing an arrow key as of
a model answering "right". [`run_observer_experiment!`](@ref) sets it from the
source it installs; a session run by a person is given its task here.
"""
function set_task!(session::SessionContext, task::ObserverTask)
    session.task === task && return session
    session.task = task
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :settings_changed)
    return session
end

"""
    set_observer_metadata!(session, metadata::AbstractDict) -> session

Records who answered this session when the participant was a program: the
backend, the model and the settings it was queried with (see
`observer_provenance`). Refreshes the pinned checkpoint, so the description
travels with the data rather than with the script that ran it.

What the observer was *asked* is not here but in `session.task`, which a human
session carries too. Sessions answered by a person leave this empty, and that
asymmetry is the point: a model observer's data must be identifiable as such
long after the run, because nothing else in the file distinguishes it from a
human participant's.
"""
function set_observer_metadata!(session::SessionContext, metadata::AbstractDict)
    session.observer_metadata = Dict{String, Any}(metadata)
    checkpoint_if_pinned(session)   # keep the on-disk snapshot in sync
    notify_session_listeners(session, :settings_changed)
    return session
end
