# Console session reporter. All operator-facing terminal
# output about a running session flows through this one detachable session
# event listener instead of ad-hoc printlns inside API commands and the loop.
# It works headless, is exception-isolated like every listener, and is never
# serialized.

const _REPORT_LEVEL_RANK = Dict(:session => 1, :trials => 2, :steps => 3)

mutable struct ConsoleReporter
    level::Symbol
    last_state::SessionState
    banner_shown::Bool
    keys::Bool   # the participant answers with the keys of the engine's window
end

_rank(r::ConsoleReporter) = _REPORT_LEVEL_RANK[r.level]

function _print_session_banner(r::ConsoleReporter, s::SessionContext)
    r.banner_shown && return nothing
    r.banner_shown = true
    total = planned_trial_count(s.method_instance)
    done = length(s.history)
    plan = total === nothing ? "open-ended" : "planned $total trials"
    resumed = done > 0 ? " ─ resuming after trial $done" : ""
    # The seed is printed because it is the only way to repeat this run: it is
    # not derivable from anything else the operator sees
    println("── $(s.ex_par.experiment_name) ─ $(s.participant_id) ─ " *
            "$(type_name(s.method_instance)) ─ $plan$resumed ─ seed $(s.rng_seed)")
    r.keys && println("   Keys: ", join(("$key $meaning" for (key, meaning) in
                                          response_key_guide(s; label = english_label)),
                                         " · "))
    return nothing
end

_trial_counts(s::SessionContext) = begin
    invalid = count(t -> !t.is_valid, s.history)
    invalid == 0 ? "$(length(s.history)) trials" :
                   "$(length(s.history)) trials ($invalid invalid)"
end

_checkpoint_note(s::SessionContext) =
    s.save_path === nothing ? "not saved" : "saved: $(s.save_path)"

# Nothing is appended for a trial the task did not score, so an operator never
# reads the absence of a mark as a wrong answer
_correctness_mark(t::Trial) =
    t.correct === true ? " ✓" : t.correct === false ? " ✗" : ""

function _report_event!(r::ConsoleReporter, s::SessionContext, event::Symbol)
    if event == :state_changed
        previous = r.last_state
        r.last_state = s.state
        if s.state == RUNNING
            if previous == FINISHED
                println("── Session reopened: the undone trial is queued again.")
            elseif previous == PAUSED && r.banner_shown
                println("── Resumed.")
            else
                _print_session_banner(r, s)
            end
        elseif s.state == PAUSED
            println("── Paused. Awaiting resume…")
        elseif s.state == ABORTED
            println("── ABORTED ─ $(_trial_counts(s)) ─ $(_checkpoint_note(s))")
        elseif s.state == FINISHED
            println("── FINISHED ─ $(_trial_counts(s)) ─ $(_checkpoint_note(s))")
        end
    elseif event == :interrupted
        r.last_state = s.state
        println("── Interrupted ─ $(_trial_counts(s)) ─ $(_checkpoint_note(s))")
        println("   The session is paused: ", s.save_path === nothing ?
                "run_experiment! on it continues it." :
                "run_experiment!(load_session($(repr(s.save_path)))) continues it.")
    elseif event == :trial_abandoned && _rank(r) >= _REPORT_LEVEL_RANK[:trials]
        println("[$(s.current_trial_idx)] abandoned before its answer; not recorded")
    elseif event == :trial_completed && _rank(r) >= _REPORT_LEVEL_RANK[:trials]
        t = s.history[end]
        rt = round(t.timestamp_response - t.timestamp_onset; digits = 2)
        total = session_trial_total(s)
        position = total === nothing ? "$(t.trial_index)" : "$(t.trial_index)/$total"
        println("[$position] $(describe_trial(s.method_instance, s.ex_par, t)) " *
                "(RT $rt s)$(_correctness_mark(t))" *
                (t.origin === :operator ? " · operator's choice" : ""))
    elseif event == :comment_added
        comment = s.comments[end]
        println("── Comment", comment.trial === nothing ? "" : " on trial $(comment.trial)",
                ": ", comment.text)
    elseif event == :response_registered && _rank(r) >= _REPORT_LEVEL_RANK[:steps]
        state = describe_method_state(s.method_instance)
        state === nothing || println("    step: $state")
    end
    return nothing
end

"""
    attach_console_reporter!(session; level=:trials, keys=false) -> Union{Nothing, Function}

Subscribes a console reporter to the session's events and returns the
listener (pass it to `detach_listener!` to remove it). With `keys`, the session
banner is followed by what each response key means in the session's task
([`response_key_guide`](@ref)). Levels:

- `:silent`  — attaches nothing and returns `nothing`;
- `:session` — session banner, state changes, and the finish line only;
- `:trials`  — plus one line per completed trial (condition, result, RT);
- `:steps`   — plus intra-trial steps for methods that expose them via
  `describe_method_state` (e.g. the current value while adjusting).

`run_experiment!` attaches one automatically (keyword `report`), with `keys` when
its engine [`reads_response_keys`](@ref), and detaches it when the loop ends, so
manual attachment is only needed around
`run_next_trial!`-style custom loops.
"""
function attach_console_reporter!(session::SessionContext; level::Symbol = :trials,
                                  keys::Bool = false)
    level == :silent && return nothing
    haskey(_REPORT_LEVEL_RANK, level) || throw(ArgumentError(
        "Unknown report level :$level (use :silent, :session, :trials or :steps)"))

    reporter = ConsoleReporter(level, session.state, false, keys)
    listener = (s, event) -> _report_event!(reporter, s, event)
    on_session_event!(listener, session)

    # A session that is already RUNNING (e.g. resumed from a checkpoint, or
    # started by a dashboard button) gets its banner immediately; a READY
    # one gets it on the start transition.
    session.state == RUNNING && _print_session_banner(reporter, session)
    return listener
end

"""
    detach_listener!(session, listener)

Removes a listener previously registered with `on_session_event!` (accepts
`nothing` as a no-op, matching the `:silent` return of
`attach_console_reporter!`).
"""
detach_listener!(session::SessionContext, listener::Function) =
    (filter!(l -> l !== listener, session.listeners); nothing)
detach_listener!(::SessionContext, ::Nothing) = nothing
