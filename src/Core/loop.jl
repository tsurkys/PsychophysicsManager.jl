function run_next_trial!(session::SessionContext, stim_engine::AbstractStimulusEngine)
    if session.state == PAUSED
        return false
    elseif session.state != RUNNING
        @warn "Attempted to run a trial, but the session is not RUNNING" state = session.state
        return false
    end

    # A correction that moves the method's plan waits until this flag is down:
    # a dashboard runs this loop beside its buttons, and a plan changed under a
    # trial would present the trial twice, or be undone by the restore below
    session.trial_under_way = true
    session.trial_run = TrialRun(current_task(), stim_engine)
    finished = try
        run_recorded_trial!(session, stim_engine)
    catch e
        e isa TrialAbandoned || rethrow()
        nothing
    finally
        # Lowered with the flag, before the checkpoint below yields: a trial already
        # recorded is not abandoned
        session.trial_under_way = false
        session.trial_run = nothing
    end
    if finished === nothing
        # Not recorded, and the method restored: it presents the trial again after
        # the operator's
        notify_session_listeners(session, :trial_abandoned)
        return true
    end

    # 9. Save Checkpoint
    save_session_checkpoint(session, resolve_data_dir())
    notify_session_listeners(session, :trial_completed)

    if finished
        notify_session_listeners(session, :state_changed)
        return false
    end

    return true
end

# Presents one trial and records it; returns whether the experiment is finished
function run_recorded_trial!(session::SessionContext, stim_engine::AbstractStimulusEngine)
    # A trial is recorded whole or not at all. Until it is, an error or Ctrl+C
    # puts back what the trial changed, so the checkpoint written on the way
    # out holds the state between two trials and the trial is presented again
    # from its start. Left mid-trial, a method may have consumed an answer the
    # history never received: a skipped planned trial, or an estimate built on
    # a response nobody can find.
    before = (deepcopy(session.method_instance), deepcopy(session.stim_par),
              copy(session.rng))
    # An operator's request waits until its trial is recorded, so a trial that fails
    # leaves it waiting, and the plan it changed is restored with the method
    request = isempty(session.operator_requests) ? nothing : first(session.operator_requests)
    # Ctrl+C is taken only while the trial is presented: Julia may deliver it at
    # any allocation, and one between the trial's return and its record would
    # leave the method past an answer the history lacks. One arriving later
    # is delivered when the next trial begins, or when this block ends.
    return disable_sigint() do
        trial = try
            reenable_sigint(() -> request === nothing ?
                                  present_trial!(session, stim_engine) :
                                  present_requested_trial!(session, stim_engine, request))
        catch
            restore_fields!(session.method_instance, before[1])
            restore_fields!(session.stim_par, before[2])
            copy!(session.rng, before[3])   # in place: an interleaved view shares it
            rethrow()
        end

        # 8. Record the trial and advance the session state BEFORE
        #    checkpointing, so the on-disk snapshot reflects the true post-trial
        #    state: current_trial_idx is the index of the NEXT trial (a resumed
        #    session must not reuse the recorded index), and a completed
        #    experiment is saved as FINISHED.
        push!(session.history, trial)
        session.current_trial_idx += 1
        if trial.origin === :operator
            popfirst!(session.operator_requests)
            # The answer replaced is set aside only now that its replacement exists
            replaced = findfirst(t -> t.trial_index == request.replaces, session.history)
            replaced === nothing || (session.history[replaced].is_valid = false)
        end
        done = session_complete(session)
        # A session stopped during the trial that just ended stays stopped: the
        # plan being complete does not turn an abort into a normal finish
        done && session.state != ABORTED && (session.state = FINISHED)
        done
    end
end

# Puts every field of `snapshot` back into `target`, which stays the object its
# holders reference: a script keeps the method it built. A method or stimulus
# type is mutable field by field already — loading a session fills a method that
# way, and the loop binds variables into the stimulus.
function restore_fields!(target::T, snapshot::T) where {T}
    for name in fieldnames(T)
        isconst(T, name) || setfield!(target, name, getfield(snapshot, name))
    end
    return target
end

# A trial the operator asked for (`present_condition!`). A method with a plan takes
# the condition into it and presents it as its own trial; any other is passed by.
function present_requested_trial!(session::SessionContext,
                                  stim_engine::AbstractStimulusEngine,
                                  request::OperatorRequest)
    method = session.method_instance
    if !plans_conditions(method)
        trial = present_trial!(session, stim_engine; vals = request.vals)
    elseif take_condition!(method, request.vals; replacing = request.replaces !== nothing)
        trial = present_trial!(session, stim_engine)
        trial.indep_var_vals == request.vals || error(
            "$(type_name(method)) took the condition $(request.vals) into its plan but " *
            "presented $(trial.indep_var_vals): its take_condition! and " *
            "get_next_trial_params disagree.")
    else
        # Refused, with the method's warning: the method's own trial goes ahead,
        # unless the request reopened a session whose plan is complete
        popfirst!(session.operator_requests)
        is_experiment_finished(method) && error(
            "$(type_name(method)) refused the operator's condition $(request.vals), " *
            "and its own plan is complete, so there is no trial to present.")
        return present_trial!(session, stim_engine)
    end
    trial.origin = :operator
    return trial
end

# Steps 1–7 of a trial: present until the method ends the trial, score, give
# feedback, and return the Trial to record. Nothing here touches the history.
# Given `vals`, the trial presents that condition past the method, which is told the
# outcome only at the end (`absorb_operator_trial!`).
function present_trial!(session::SessionContext, stim_engine::AbstractStimulusEngine;
                        vals::Union{Nothing, Vector{Float64}} = nothing)
    method = session.method_instance
    passed_by = vals !== nothing
    local response, resp_time, correct, unanswered, expected
    onset = time()             # provisional; replaced below by the first presentation
    onset_source = :estimated
    start_value = nothing
    first_presentation = true

    # Inner presentation loop. For one-response methods (constant stimuli,
    # staircase) it runs once; adjustment methods keep it running until the
    # participant confirms, and stimulus-repeat requests re-enter it too.
    while true
        # 1. Method decides what to present
        passed_by || (vals = get_next_trial_params(method, session))
        apply_variables!(session.stim_par, session.ex_par.indep_var_names, vals)
        passed_by || apply_method_state!(method, session.stim_par)
        first_presentation && (start_value = adjusted_start_value(session))

        # 2. Engine renders once; reporting the response and timing is
        #    optional — every field may come back as `nothing`. An
        #    engine that captures input is told the response window first, so
        #    a deadline the operator changed applies from this trial on.
        set_response_timeout!(stim_engine, session.timeout_s)
        # Only a trial's first presentation keeps presses back for a moment: the
        # steps that follow within it must follow a held key
        guarded = first_presentation && session.min_response_s > 0
        set_min_response_time!(stim_engine, guarded ? session.min_response_s : 0.0)
        t_before = time()
        pres = normalize_presentation(
            present_stimulus(stim_engine, session.stim_par, vals))

        if first_presentation
            # The trial's recorded onset is its FIRST presentation's onset —
            # engine-reported when available, otherwise the pre-call estimate
            onset = something(pres.onset, t_before)
            onset_source = pres.onset === nothing ? :estimated : :engine
            first_presentation = false
        end

        # 3. Render-only engines leave the response to the active source. The
        #    context is assembled only on this path, so an engine that reports
        #    its own response pays nothing for it.
        response = pres.response
        resp_time = pres.timestamp_response
        if response === nothing
            context = TrialContext(session, vals, last_frame(stim_engine);
                                   earliest_response = guarded ?
                                       onset + session.min_response_s : nothing)
            (response, t_arrival) = request_response(ACTIVE_RESPONSE_SOURCE[], context)
            resp_time === nothing && (resp_time = t_arrival)
        end
        resp_time === nothing && (resp_time = time())

        # 4. A window that closed with nothing answered is an observation, and
        #    what it means for the measurement belongs to the method. A
        #    method that answers with a number is taken at its word and the
        #    presentation proceeds as if the participant had given it; one that
        #    leaves the sentinel standing gets the missing response every method
        #    already knows, while the trial keeps the sentinel in the record.
        response === :timeout && !passed_by && (response = timeout_result(method, session))
        unanswered = response === :timeout
        unanswered && (response = MISSING_RESPONSE)

        # 5. Score the raw response — the code the participant gave, before any
        #    recoding a method applies to it — and let the method consume both.
        #    A response that answers nothing leaves the presentation unscored,
        #    exactly as a task with no right answer does.
        expected = correct_answer(session.stim_par, trial_variables(session.ex_par, vals))
        correct = expected === nothing || !is_answer(response) ? nothing :
                  response == expected
        if passed_by
            # 0 asks to see the stimulus again; anything else, a missing response
            # included, ends the trial
            response == 0 || break
        else
            update_method_state!(method, response, correct)
            is_trial_finished(method) && break
        end

        # Intra-trial notification: a raw response was consumed but the trial
        # continues (live views can show e.g. the current adjusted value).
        # A UI signal only — no checkpoint; the concluding response is
        # announced by :trial_completed instead.
        notify_session_listeners(session, :response_registered)
    end

    # The answer is in: abandoning the trial now would only discard it
    session.trial_run = nothing

    # 6. Tell the participant how the trial went, while it is still the trial
    #    they remember. A trial the task did not score has nothing to report.
    session.feedback && correct !== nothing && present_feedback(stim_engine, correct)
    passed_by && absorb_operator_trial!(method, vals, response, correct)

    # 7. The confirmed result of the trial — scored as the concluding
    #    presentation was, the earlier ones having been repeat requests or
    #    adjustment steps
    trial = Trial(
        session.current_trial_idx,
        onset,
        resp_time,
        Float64.(vals),
        # A trial nobody answered records the sentinel itself: recoding it
        # through the method would turn the absence of a response into one. A
        # trial presented past the method records the answer as the task's own
        # trials do — 1/0 where there is no correct answer — so that one column
        # holds one coding.
        unanswered ? :timeout :
        passed_by ? (expected === nothing ? binary_answer(response) : response) :
        get_trial_result(method, response),
        true,
        onset_source,
        correct,
        :method,
        start_value
    )
    return trial
end

# Where a trial's adjustment begins: the field the method adjusts, as the trial's first
# presentation shows it. A method that adjusts no single field has no starting value.
function adjusted_start_value(session::SessionContext)
    variable = response_variable(session.method_instance)
    (variable === nothing || !has_parameter(session.stim_par, variable)) && return nothing
    return Float64(parameter_value(session.stim_par, variable))
end

# Shows a message and returns whether it ended while still wanted — dismissed by the
# participant, or by nobody when no one is there to see it
function show_message!(session::SessionContext, engine::AbstractStimulusEngine,
                       kind::Symbol, text::String;
                       dismissible::Bool, min_s::Real = 0.0,
                       wanted::Function = () -> true)::Bool
    msg_ref = Ref{ParticipantMessage}()
    keep_waiting_fn = () -> (isassigned(msg_ref) && session.shown_message === msg_ref[] && wanted())
    message = ParticipantMessage(kind, text, dismissible, Float64(min_s), keep_waiting_fn)
    msg_ref[] = message
    session.shown_message = message
    notify_session_listeners(session, :message_changed)
    dismissed = false
    try
        present_message(engine, message)
        dismissed = message.keep_waiting()
    finally
        if session.shown_message === message
            session.shown_message = nothing
        end
        notify_session_listeners(session, :message_changed)
    end
    return dismissed
end

"""
    run_experiment!(session::SessionContext, engine::AbstractStimulusEngine; on_trial_end=nothing, poll_interval=0.1, report=:trials, accept_changed_stimulus=false, keep_waiting=() -> true)

Main execution loop that runs trials until the session state changes from RUNNING or PAUSED.
`on_trial_end`: Optional callback function called after each trial.
`poll_interval`: Time in seconds to sleep between iterations when paused.
`keep_waiting`: asked while paused; `false` ends the loop as Ctrl+C does.
`report`: console reporting level (`:silent`, `:session`, `:trials`, `:steps`)
— see `attach_console_reporter!`; the reporter is detached when the loop ends.

Between trials, the loop presents messages configured by [`set_messages!`](@ref): instructions
before the first trial, breaks after scheduled trial counts, and a closing message after the
final trial. An engine that does not show messages hands them to the active response source.
Sessions answered by a model observer are shown no messages.

A READY session is started, and a PAUSED one is resumed: calling the loop is the
decision to go on. Ctrl+C or an error inside the loop leaves the session PAUSED and
checkpointed, losing at most the trial in progress, which is presented again from
its start; the error is rethrown, Ctrl+C returns the session. Either way the session
continues with `run_experiment!` — in the same process, or after `load_session`.
Only [`abort!`](@ref) ends a session for good.

A session is continued only under the stimulus program that presented it
([`stimulus_identity`](@ref)): when that program has changed, the session is left as
it is and a [`StimulusChangedError`](@ref) names both. `accept_changed_stimulus = true`
continues it deliberately, and the session records the changed program and the first
trial it presents.

A stimulus a remote worker declares ([`WorkerStimulus`](@ref)) is completed to what the
worker declares now ([`complete_parameters!`](@ref)): a parameter it no longer declares
stops the run with its name before anything changes, and one it declares that the
session lacks is presented with its default — recorded, for a session that has
presented trials, in `session.environment` as `stimulus_parameters_added_from_trial_<n>`.
"""
function run_experiment!(session::SessionContext, engine::AbstractStimulusEngine;
                         on_trial_end=nothing, poll_interval=0.1, report::Symbol=:trials,
                         accept_changed_stimulus::Bool=false,
                         keep_waiting::Function=() -> true)
    # A session that is continued is checked before anything about it changes; one that
    # has ended is not run at all
    (session.state == RUNNING || session.state == PAUSED) &&
        confirm_stimulus!(session, engine; accept = accept_changed_stimulus)
    session.state in (READY, RUNNING, PAUSED) && confirm_parameters!(session, engine)
    # Record the engine used for this session for reproducibility
    session.engine_name = type_name(engine)

    # Resumed before the reporter attaches, so that its banner names the trial
    # the session continues after
    session.state == PAUSED && resume!(session)
    reporter = attach_console_reporter!(session; level=report,
                                        keys=reads_response_keys(engine))

    if session.state == READY
        start_session!(session, engine)
    end

    # A Julia script run without -i exits on Ctrl+C instead of throwing, which
    # would end the session without the catch below. Base sets that for exactly
    # this case and offers no way to read the flag back, so the same test
    # decides what to restore.
    script = !isinteractive() && !isempty(PROGRAM_FILE)
    script && Base.exit_on_sigint(false)
    instructions_done = false
    try
        while session.state == RUNNING || session.state == PAUSED
            if session.state == RUNNING
                if !instructions_done
                    due = session.messages.instructions && session.task !== nothing &&
                          isempty(session.history) && reads_messages(ACTIVE_RESPONSE_SOURCE[])
                    if due
                        show_message!(session, engine, :instructions, session.task.instructions;
                                      dismissible = true, wanted = () -> session.state == RUNNING)
                        instructions_done = session.state == RUNNING
                        if session.state != RUNNING
                            continue
                        end
                    else
                        instructions_done = true
                    end
                end

                n_before = length(session.history)
                success = run_next_trial!(session, engine)

                # Fire whenever a trial was recorded — including the FINAL
                # trial, for which run_next_trial! returns false ("stop
                # looping"), not "no trial happened"
                if length(session.history) > n_before
                    if on_trial_end !== nothing
                        on_trial_end(session)
                    end
                    if session.state == RUNNING && breaks_scheduled(session.messages) &&
                       break_due(session.messages, session.history[end].trial_index) &&
                       reads_messages(ACTIVE_RESPONSE_SOURCE[])
                        pause!(session)
                        dismissed = show_message!(session, engine, :break, session.messages.break_text;
                                                  dismissible = session.messages.break_waits_for === :participant,
                                                  min_s = session.messages.break_min_s,
                                                  wanted = () -> session.state == PAUSED && keep_waiting())
                        if session.messages.break_waits_for === :participant && dismissed && session.state == PAUSED
                            resume!(session)
                        end
                    end
                end

                if session.state == FINISHED && !isempty(strip(session.messages.closing_text)) &&
                   reads_messages(ACTIVE_RESPONSE_SOURCE[])
                    show_message!(session, engine, :closing, session.messages.closing_text;
                                  dismissible = true, wanted = () -> session.state == FINISHED)
                end

                if !success && session.state != PAUSED && session.state != RUNNING
                    break
                end
            else
                # PAUSED state: wait, unless the caller lets the session go
                keep_waiting() || (interrupt!(session); break)
                sleep(poll_interval)
            end

            # Allow GUI events to process
            yield()
        end
    catch e
        e isa InterruptException ||
            @error "Experiment crashed" exception=(e, catch_backtrace())
        interrupt!(session)   # PAUSED and checkpointed; the reporter says how to go on
        e isa InterruptException || rethrow(e)
    finally
        script && Base.exit_on_sigint(true)
        detach_listener!(session, reporter)
    end

    return session
end

# A worker's stimulus is presented with exactly the parameters its worker declares now.
# One it adds to a session that has presented trials is recorded with the first
# trial presented with it, since the trials before were not.
function confirm_parameters!(session::SessionContext, engine::AbstractStimulusEngine)
    added = complete_parameters!(session.stim_par, engine)
    isempty(added) && return session
    values = join(("$name = $(repr(parameter_value(session.stim_par, name)))"
                   for name in added), ", ")
    session.state == READY ||
        (session.environment["stimulus_parameters_added_from_trial_" *
                             "$(session.current_trial_idx)"] = values)
    @warn "$(stimulus_name(session.stim_par)) is presented with $values: its program " *
          "declares them and the session did not set them."
    return session
end

"""
    run_experiment!(session::SessionContext; on_trial_end=nothing, poll_interval=0.1, config::Union{DisplayConfig, Nothing}=nothing, report=:trials, accept_changed_stimulus=false)

High-level overload of run_experiment! that automatically initializes the default engine
for the stimulus parameters and loads display configuration from settings.toml.
"""
function run_experiment!(session::SessionContext; on_trial_end=nothing, poll_interval=0.1,
                         config=nothing, report::Symbol=:trials,
                         accept_changed_stimulus::Bool=false)
    # 1. Determine Engine Type
    engine_type = default_engine_type(session.stim_par)

    # 2. Load Configuration if not provided
    d_config = config === nothing ? load_display_config() : config

    # 3. Initialize Engine
    engine = initialize_engine(engine_type, session.stim_par, d_config)

    # 4. Run standard loop. This overload owns the engine it initialized.
    try
        return run_experiment!(session, engine;
                               on_trial_end=on_trial_end,
                               poll_interval=poll_interval,
                               report=report, accept_changed_stimulus)
    finally
        close_engine!(engine)
    end
end
