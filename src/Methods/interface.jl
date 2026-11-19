# The psychophysical method contract. Mandatory functions error by default;
# optional hooks have sensible fallbacks.

"""
    initialize_method!(method::AbstractPsychoMethod, ex_par::ExperimentParameters; rng)

Sets up the internal state of the method (e.g., shuffling trials, setting initial levels).

`rng` is the session's random stream, seeded from `session.rng_seed` so that a
run can be repeated (see [`draw_rng_seed`](@ref)). Every implementation must
accept the keyword; one that makes no random choice ignores it. A method that
randomizes *during* the run draws from `session.rng` instead, which
`get_next_trial_params` receives.
"""
function initialize_method!(method::AbstractPsychoMethod, ex_par::ExperimentParameters;
                            rng::AbstractRNG=Random.default_rng())
    error("Not implemented for $(typeof(method))")
end

"""
    get_next_trial_params(method::AbstractPsychoMethod, session::SessionContext) -> Vector{Float64}

Returns the current stimulus parameters determined by the method, as a vector
of values aligned with `session.ex_par.indep_var_names`.
"""
function get_next_trial_params(method::AbstractPsychoMethod, session::SessionContext)
    error("Not implemented for $(typeof(method))")
end

"""
    update_method_state!(method::AbstractPsychoMethod, response::Real)

Updates the method's internal state based on the participant's response.
Responses use the abstract coding -1/0/+1 for discrete input; adjustment-type
methods interpret ±1 as adjustment steps and 0 as confirmation.
"""
function update_method_state!(method::AbstractPsychoMethod, response::Real)
    error("Not implemented for $(typeof(method))")
end

"""
    update_method_state!(method::AbstractPsychoMethod, response::Real, correct::Union{Nothing, Bool})

The form the Core loop calls, adding how the response was scored
([`correct_answer`](@ref)); `correct` is `nothing` when the task defines no
right answer.

An adaptive method implements this form and advances on `correct` — the sign of
`response` is the participant's answer, not its correctness, so a method that
steps on the sign is a yes/no procedure and cannot run a two-interval or
n-alternative task. The default forwards to the two-argument form, so a method
that scores nothing needs only that one.
"""
update_method_state!(method::AbstractPsychoMethod, response::Real,
                     correct::Union{Nothing, Bool}) =
    update_method_state!(method, response)

"""
    timeout_result(method::AbstractPsychoMethod, session::SessionContext) -> Union{Real, Symbol}

What the method makes of a response window that closed with nothing answered.
The default is the sentinel `:timeout` itself: the trial is spent and
recorded unanswered, and the method is told only that no answer arrived
([`MISSING_RESPONSE`](@ref)), never that one was wrong.

Returning a number instead makes the Core treat the presentation as if the
participant had given that raw response — `0` re-presents the stimulus, a
response code counts as an answer and is scored against the task — so a method
that wants a timeout counted as a miss says so explicitly, in its own terms. A
method that must stop the session calls [`abort!`](@ref) on `session` and
returns the sentinel; the trial in progress is still recorded.

Timing out is an observation the apparatus makes; what it means for the
measurement is the method's to decide, which is why neither the engine nor the
Core scores it.
"""
timeout_result(::AbstractPsychoMethod, ::SessionContext) = :timeout

"""
    is_trial_finished(method::AbstractPsychoMethod) -> Bool

Returns true if the current trial is complete (e.g., after one response in Constant
Stimuli or after confirmation in Adjustment).
"""
function is_trial_finished(method::AbstractPsychoMethod)
    return true # Default for one-response-per-trial methods
end

"""
    is_experiment_finished(method::AbstractPsychoMethod) -> Bool

Returns true if all trials or stopping criteria for the whole experiment are met.
"""
function is_experiment_finished(method::AbstractPsychoMethod)
    error("Not implemented for $(typeof(method))")
end

# ── Optional hooks ───────────────────────────────────────────────────────────

"""
    apply_method_state!(method::AbstractPsychoMethod, stim_par::AbstractStimulusParameters)

Optional hook called by the Core before every stimulus presentation. Methods that
own a stimulus parameter (e.g. the adjusted variable of `Adjustment`) push
its current value into `stim_par` here. Default: does nothing.
"""
apply_method_state!(method::AbstractPsychoMethod, stim_par::AbstractStimulusParameters) = nothing

"""
    adjusted_fields(method::AbstractPsychoMethod) -> Vector{Symbol}

The stimulus fields the method sets during a run through
[`apply_method_state!`](@ref). A saved session holds such a field at the value its
run stopped on, which describes the run rather than the design, so combining sessions
does not compare it ([`COMBINING_CHECKS`](@ref)). Default: none.

A method that sets exactly one field records that field's value as its response, as an
adjustment does: a unit conversion declared for the field converts the responses too
([`set_unit_conversion!`](@ref)).
"""
adjusted_fields(method::AbstractPsychoMethod) = Symbol[]

"""
    get_trial_result(method::AbstractPsychoMethod, last_response::Real) -> Real

Value recorded as `Trial.response` when a trial completes. Default: the last raw
response. Adjustment-type methods return the confirmed adjusted value instead.
"""
get_trial_result(method::AbstractPsychoMethod, last_response::Real) = last_response

# The binary coding of a two-way judgement: −1 → 0,
# +1 → 1, so that a condition's mean response is the proportion answered +1. A
# response that answers nothing passes through: recoding it would file a presentation
# nobody answered as a "no".
binary_answer(response::Real) = is_answer(response) ? (response > 0 ? 1 : 0) : response

"""
    set_task_scored!(method::AbstractPsychoMethod, scored::Bool) -> method

Tells the method, before its run starts ([`start_session!`](@ref)), whether the
session's stimulus declares a correct answer for every condition
([`task_scoring`](@ref)). A method that steps on whether an answer was correct
steps, in a task that has none — a point of subjective equality — on the answer coded
`+1` instead, and records its trials as `1`/`0` so that a condition's mean response is
the proportion answered `+1` ([`answer_score`](@ref)). Default: does nothing.
"""
set_task_scored!(method::AbstractPsychoMethod, ::Bool) = method

"""
    answer_score(scored::Bool, response, correct) -> Union{Nothing, Bool}

What a method that steps on answers learns from one: in a scored task whether it was
correct, in a task without a correct answer whether it was the answer coded `+1`.
`nothing` for a response that answers nothing ([`is_answer`](@ref)). A scored task that
meets a presentation without a correct answer is refused.
"""
function answer_score(scored::Bool, response::Real, correct::Union{Nothing, Bool})
    is_answer(response) || return nothing
    scored || return response > 0
    correct === nothing && throw(ArgumentError(
        "The task scores its answers, but this presentation has no correct answer to " *
        "score it against."))
    return correct
end

# The same, read back from a recorded trial: its score, or the recorded answer, which a
# task without a correct answer codes 1/0 (`binary_answer`)
recorded_score(scored::Bool, trial::Trial) =
    scored ? trial.correct :
    trial.response isa Real && !isnan(trial.response) ? trial.response > 0 : nothing

"""
    revert_method_state!(method::AbstractPsychoMethod, trial::Trial) -> Bool

Optional hook called by `undo_last_trial!` so the method can re-queue the
undone trial. Returns `true` when the state was reverted. The default warns
and returns `false`, which makes `undo_last_trial!` cancel the correction:
undo is transactional — a trial the method cannot re-queue is never
invalidated (that would silently shorten the planned measurement).

An implementation that refuses must say why with a `@warn` of its own, as the
default does: the command reports only that nothing was undone, because only the
method knows what stopped it.
"""
function revert_method_state!(method::AbstractPsychoMethod, trial::Trial)
    @warn "$(type_name(method)) does not support reverting; the undo is cancelled."
    return false
end

"""
    method_settings(method::AbstractPsychoMethod) -> Vector{Pair{Symbol, Any}}

The settings a method was given, as `name => value` in the names its constructor
takes them under: what the Parameters view lists and edits. Default: none, and the
view lists the fields in which the method differs from one built with no arguments.
"""
method_settings(::AbstractPsychoMethod) = Pair{Symbol, Any}[]

"""
    with_method_settings(method::AbstractPsychoMethod, settings::AbstractDict{Symbol}) -> AbstractPsychoMethod

A new method of the same type, not started, with `settings` — values as a session
file writes them — in place of the method's own ([`method_settings`](@ref)), built
by its constructor, so that a setting it refuses is refused with an
`ArgumentError`. The default refuses every setting.
"""
function with_method_settings(method::AbstractPsychoMethod, settings::AbstractDict{Symbol})
    isempty(settings) && return fresh_instance(method)
    throw(ArgumentError("$(type_name(method)) has no setting $(first(keys(settings)))."))
end

"""
    dependent_settings(method::AbstractPsychoMethod) -> Vector{Symbol}

The settings ([`method_settings`](@ref)) that describe a dependent variable the method
sets itself — the stimulus field first, then what bounds it — which the Parameters
view lists under the dependent variable rather than under the method. Default: none,
the dependent variable being the participant's answer.
"""
dependent_settings(::AbstractPsychoMethod) = Symbol[]

"""
    steps_on_answers(method::AbstractPsychoMethod) -> Bool

Whether the method chooses its next level from each answer — whether it was correct
in a scored task, the answer coded `+1` in one without a correct answer
([`set_task_scored!`](@ref)) — so that it cannot run a task whose stimulus declares a
correct answer ([`correct_answer`](@ref)) for some conditions only. Checked when the
method is chosen for a session. Default: `false`.
"""
steps_on_answers(::AbstractPsychoMethod) = false

"""
    unset_settings(method::AbstractPsychoMethod) -> Vector{Symbol}

The settings the method still needs; a session does not start while any is unset
([`start_session!`](@ref)). Settings tied to a stimulus parameter have no method
default. Default: none.
"""
unset_settings(::AbstractPsychoMethod) = Symbol[]

# The refusal of a method that steps on answers for a task that scores some of them
function check_task_scoring(method::AbstractPsychoMethod, stim_par::AbstractStimulusParameters,
                            scoring::Symbol)
    steps_on_answers(method) && scoring === :some && throw(ArgumentError(
        "$(type_name(method)) steps on each answer — on whether it was correct where " *
        "the task has a correct answer, on its direction where it has none — and " *
        "$(stimulus_name(stim_par)) declares a correct answer for some conditions only."))
    return nothing
end

# The refusal of a start while the method lacks settings it needs
function check_settings_set(method::AbstractPsychoMethod)
    unset = unset_settings(method)
    isempty(unset) || throw(ArgumentError(
        "$(type_name(method)) needs $(join(unset, " and ")) set before a session can start."))
    return nothing
end

"""
    fill_stimulus_settings(method, stimulus, ex_par) -> AbstractPsychoMethod

The method chosen by name for a session ([`set_parameters!`](@ref)), its unset
stimulus-parameter setting filled with the stimulus's first numeric parameter that is
not an independent variable ([`numeric_parameters`](@ref)); values in that parameter's
units stay unset. Default: the method unchanged.
"""
fill_stimulus_settings(method::AbstractPsychoMethod, ::AbstractStimulusParameters,
                       ::ExperimentParameters) = method

# A setting's value in the type its constructor takes, or a refusal naming it
function setting_value(T::Type, name::Symbol, value)
    refusal() = ArgumentError(
        "`$name` cannot be $(repr(value)): it takes a $(parameter_type_name(T)).")
    # A value that does not convert is refused, not taken for an unset one
    converted = try
        coerce_field(T, value)
    catch
        throw(refusal())
    end
    converted isa T || throw(refusal())
    return converted
end

# The method's settings with `changes` in place of the corresponding ones
merged_settings(method::AbstractPsychoMethod, changes::AbstractDict{Symbol}) =
    merge(Dict{Symbol, Any}(method_settings(method)), changes)

"""
    plans_conditions(method::AbstractPsychoMethod) -> Bool

Whether the method presents conditions from a plan made in advance, as constant
stimuli and adjustment do. Such a method takes a condition the operator asks for into
its plan ([`take_condition!`](@ref)) and presents it as its own trial. Any other
method is passed by: the Core presents the operator's condition itself and tells the
method the outcome afterwards ([`absorb_operator_trial!`](@ref)). Default: `false`.

A method whose trial is an interaction of its own, as an adjustment's is, cannot be
passed by, so it plans its conditions or takes no operator's trial at all.
"""
plans_conditions(::AbstractPsychoMethod) = false

"""
    take_condition!(method::AbstractPsychoMethod, vals::AbstractVector; replacing::Bool) -> Bool

Called by the trial loop, before a trial the operator asked for, on a method that
[`plans_conditions`](@ref): makes the condition `vals` the next one the method
presents, and returns `true` when it did. When the new answer is added to the
others (`replacing = false`), a copy of the condition still waiting in the plan is
moved forward, so the plan keeps its length; when the answer takes the place of a
recorded one, or no copy is waiting, the condition is inserted and the plan grows by
one. Returning `false`, with a warning, drops the request. The default refuses.
"""
function take_condition!(method::AbstractPsychoMethod, vals::AbstractVector;
                         replacing::Bool)
    @warn "$(type_name(method)) plans no conditions, so it cannot take $vals into a plan."
    return false
end

"""
    absorb_operator_trial!(method::AbstractPsychoMethod, vals, response, correct)

Called after a trial the operator asked for, which the Core presented past a method
that does not plan its conditions ([`plans_conditions`](@ref)): `vals` is the condition,
`response` the raw answer and `correct` how it was scored (`nothing` when unscored or
unanswered). A method that can take an answer it did not ask for into its estimate
does so here. The default does nothing: the trial is recorded and analysed with the
others all the same, and the method's own sequence and its count of trials are not
affected.
"""
absorb_operator_trial!(::AbstractPsychoMethod, vals, response, correct) = nothing

"""
    forget_operator_trial!(method::AbstractPsychoMethod, trial::Trial) -> Bool

Called by [`undo_last_trial!`](@ref) for a trial the operator asked for, which the
Core presented past the method: takes back whatever
[`absorb_operator_trial!`](@ref) took in. Returning `false`, with a warning, cancels
the undo. The default returns `true`, having taken nothing in.
"""
forget_operator_trial!(::AbstractPsychoMethod, ::Trial) = true

# Places the condition `vals` at position `next` of a planned method's `order`, the
# rule `take_condition!` states: a waiting copy is moved forward unless the answer
# replaces another, and the condition is inserted otherwise
function place_condition!(order::Vector{Int}, trial_table::Vector{Vector{Float64}},
                          next::Int, vals::AbstractVector; replacing::Bool)
    waiting = replacing ? nothing : findnext(i -> trial_table[i] == vals, order, next)
    if waiting !== nothing
        insert!(order, next, popat!(order, waiting))
        return true
    end
    index = findfirst(==(vals), trial_table)
    if index === nothing
        @warn "$vals is not a condition of this method's plan, so it is not presented."
        return false
    end
    insert!(order, next, index)
    return true
end

"""
    restore_method_state!(method::AbstractPsychoMethod) -> method

Rebuilds whatever a method keeps outside the session file, called once after a
saved method's fields are read back. The default does nothing, which is
right for every method whose state *is* its fields.

A method that owns a library object — an adaptive method's posterior, say —
cannot be checkpointed field by field, and a file full of one library version's
internals would not be readable by the next. Such a method stores the levels it
presented and the answers it got, and rebuilds the object here by replaying
them. Replaying is also what makes `revert_method_state!` possible: drop the
last answer and rebuild.
"""
restore_method_state!(method::AbstractPsychoMethod) = method

"""
    fresh_instance(method::AbstractPsychoMethod) -> AbstractPsychoMethod

A new instance carrying the same configuration but no runtime state. Used by
`replicate_experiment`. Default: the no-argument constructor. Methods with
configuration fields must override this to preserve them.
"""
fresh_instance(method::AbstractPsychoMethod) = typeof(method)()

"""
    planned_trial_count(method::AbstractPsychoMethod) -> Union{Int, Nothing}

Total number of trials the method plans to run, when it is known in advance
(after `initialize_method!`). Used for progress displays ("trial 3/12").
Default: `nothing` (open-ended or not yet initialized).
"""
planned_trial_count(::AbstractPsychoMethod) = nothing

"""
    remaining_trial_count(method::AbstractPsychoMethod) -> Union{Int, Nothing}

Trials of its own the method has still to present, for [`session_trial_total`](@ref).
Default: `nothing` (unknown).
"""
remaining_trial_count(::AbstractPsychoMethod) = nothing

"""
    describe_trial(method, ex_par, trial) -> String

One-line operator-facing description of a completed trial, used by the
console reporter and free for custom UIs. The default names every
independent variable and shows the recorded response; methods may override
it to phrase the result in their own terms.
"""
function describe_trial(method::AbstractPsychoMethod, ex_par::ExperimentParameters, trial::Trial)
    conds = join(("$n=$v" for (n, v) in zip(ex_par.indep_var_names, trial.indep_var_vals)), ", ")
    return "$conds → $(trial.response)"
end

"""
    describe_method_state(method::AbstractPsychoMethod) -> Union{Nothing, String}

Current intra-trial state worth showing to the operator (e.g. the value the
participant is adjusting right now). Consumed by the `:steps` level of the
console reporter on every `:response_registered` event. Default: `nothing`
(the method has no observable intra-trial state).
"""
describe_method_state(::AbstractPsychoMethod) = nothing

# ── Shared helpers ───────────────────────────────────────────────────────────

"""
    draw_further_variables!(cache::Vector{Float64}, session::SessionContext) -> cache

The values of every declared variable after the first, drawn uniformly from its
own range and cached until the caller clears it.

An adaptive method chooses the level of the first variable and nothing else, so
the rest of the design has to come from somewhere: a two-interval task declares
`[:contrast, :target_interval]`, and which interval holds the target is drawn
per trial from the session's stream — that is what reaches
[`correct_answer`](@ref) and the session file.

The draw is cached because a trial may be presented more than once: a repeat
request must show the participant the *same* stimulus again, not a new draw.
Methods therefore call this on every presentation and `empty!` the cache when
the trial is over.
"""
function draw_further_variables!(cache::Vector{Float64}, session::SessionContext)
    isempty(cache) || return cache
    for choices in Iterators.drop(session.ex_par.indep_var_ranges, 1)
        push!(cache, Float64(rand(session.rng, choices)))
    end
    return cache
end

"""
    build_trial_table(ex_par::ExperimentParameters) -> Vector{Vector{Float64}}

Full factorial of all independent variable ranges, repeated `ex_par.repeats`
times. Each entry is a value vector aligned with `ex_par.indep_var_names`.
"""
function build_trial_table(ex_par::ExperimentParameters)
    combs = collect(Iterators.product(ex_par.indep_var_ranges...))
    base_trials = [Float64.(collect(c)) for c in vec(combs)]
    # Independent copies per repeat (`repeat` would alias the inner vectors):
    # a consumer mutating one value vector must not corrupt sibling trials
    return [copy(t) for _ in 1:ex_par.repeats for t in base_trials]
end
