"""
    Staircase(n_down = nothing; trial_limit = nothing)

Simple n-down / 1-up staircase over the sorted values of the first declared
independent variable, starting at the highest one.

In a task with a correct answer ([`correct_answer`](@ref)) it steps down after
`n_down` correct answers and up after a wrong one; `n_down` defaults to 2, which
converges on about 71 % correct. In a task without one — a point of subjective
equality — the answer coded `+1` steps it down and the other up, and `n_down`
defaults to 1, so it converges on the level answered `+1` half the time, and its
trials are recorded `1`/`0` ([`set_task_scored!`](@ref)).

`levels` is the list the staircase walks, defaulting to the first declared
independent variable's range. A track of an interleaved run carries its own,
because the design declares one list and its tracks measure different ones.

`trial_limit` is the number of trials the staircase runs. Left `nothing` it
falls back to `ex_par.repeats`, which is all a session that declares no limit of
its own says about its length. A repeat request (`0`) does not count against it;
a missing response ([`MISSING_RESPONSE`](@ref)) does, and is recorded unscored.

Every *further* declared variable is drawn uniformly from its own range, once
per trial, from the session's stream: a 2IFC design declares
`[:contrast, :target_interval]` with the level list and `[1, 2]` as their
ranges, and the drawn side reaches `correct_answer` through the trial's
variables and the session file through `Trial.indep_var_vals`.
"""
mutable struct Staircase <: AbstractPsychoMethod
    declared_levels::Union{Nothing, Vector{Float64}}  # nothing: take the design's
    available_levels::Vector{Float64}
    current_idx::Int
    n_down::Union{Nothing, Int} # answers needed to step down; nothing: by the task
    scored::Union{Nothing, Bool} # whether the task scores its answers (start_session!)
    correct_count::Int
    declared_trial_limit::Union{Nothing, Int}
    trial_limit::Int            # the working limit initialize_method! resolved
    current_trial::Int
    repeat_requested::Bool      # participant asked to see the stimulus again
    extra_vals::Vector{Float64} # drawn once per trial, kept across a repeat

    function Staircase(n_down::Union{Nothing, Integer} = nothing;
                             trial_limit::Union{Nothing, Integer} = nothing,
                             levels = nothing)
        n_down === nothing || n_down >= 1 ||
            throw(ArgumentError("n_down must be at least 1, got $n_down."))
        trial_limit === nothing || trial_limit >= 1 ||
            throw(ArgumentError("trial_limit must be at least 1, got $trial_limit."))
        levels === nothing || !isempty(levels) ||
            throw(ArgumentError("levels must name at least one level to present."))
        limit = trial_limit === nothing ? nothing : Int(trial_limit)
        declared = levels === nothing ? nothing : sort(Vector{Float64}(levels))
        return new(declared, Float64[], 1, n_down === nothing ? nothing : Int(n_down),
                   nothing, 0, limit, 0, 1, false, Float64[])
    end
end

task_scored(method::Staircase) = method.scored !== false
steps_down(method::Staircase) = something(method.n_down, task_scored(method) ? 2 : 1)

set_task_scored!(method::Staircase, scored::Bool) = (method.scored = scored; method)

function initialize_method!(method::Staircase, ex_par::ExperimentParameters;
                            rng::AbstractRNG=Random.default_rng())
    method.available_levels = method.declared_levels !== nothing ?
                              copy(method.declared_levels) :
                              sort(Float64.(ex_par.indep_var_ranges[1]))
    # Start at the top (easiest) level
    method.current_idx = length(method.available_levels)
    method.trial_limit = something(method.declared_trial_limit, ex_par.repeats)
    method.current_trial = 1
    method.correct_count = 0
    method.repeat_requested = false
    empty!(method.extra_vals)
end

get_next_trial_params(method::Staircase, session::SessionContext) =
    [method.available_levels[method.current_idx];
     draw_further_variables!(method.extra_vals, session)]

function update_method_state!(method::Staircase, response::Real,
                              correct::Union{Nothing, Bool})
    score = answer_score(task_scored(method), response, correct)
    if score === nothing
        # The two non-answers are different requests. A repeat request is the
        # participant asking to see the same stimulus again, so the trial is
        # still ahead; a missing response is missing data, so the trial
        # is spent and recorded unscored — repeating it instead would leave a
        # backend that keeps failing re-presenting the same trial forever.
        method.repeat_requested = response == 0
        method.repeat_requested && return nothing
        method.current_trial += 1
        empty!(method.extra_vals)
        return nothing
    end

    method.repeat_requested = false
    if score
        method.correct_count += 1
        if method.correct_count >= steps_down(method)
            # Go down (harder)
            if method.current_idx > 1
                method.current_idx -= 1
            end
            method.correct_count = 0
        end
    else
        # Incorrect -> Go up (easier) immediately
        if method.current_idx < length(method.available_levels)
            method.current_idx += 1
        end
        method.correct_count = 0
    end
    method.current_trial += 1
    empty!(method.extra_vals)
    return nothing
end

update_method_state!(::Staircase, ::Real) = throw(ArgumentError(
    "Staircase consumes the response with its score " *
    "(`update_method_state!(method, response, correct)`), which is what the Core " *
    "loop calls."))

get_trial_result(method::Staircase, last_response::Real) =
    task_scored(method) ? last_response : binary_answer(last_response)

steps_on_answers(::Staircase) = true

is_trial_finished(method::Staircase) = !method.repeat_requested

function is_experiment_finished(method::Staircase)
    return method.current_trial > method.trial_limit
end

method_settings(method::Staircase) = Pair{Symbol, Any}[
    :n_down => method.n_down, :trial_limit => method.declared_trial_limit,
    :levels => method.declared_levels]

function with_method_settings(method::Staircase, changes::AbstractDict{Symbol})
    settings = merged_settings(method, changes)
    return Staircase(setting_value(Union{Nothing, Int}, :n_down, settings[:n_down]);
                           trial_limit = setting_value(Union{Nothing, Int}, :trial_limit,
                                                       settings[:trial_limit]),
                           levels = setting_value(Union{Nothing, Vector{Float64}}, :levels,
                                                  settings[:levels]))
end

fresh_instance(method::Staircase) =
    Staircase(method.n_down; trial_limit = method.declared_trial_limit,
                    levels = method.declared_levels)

planned_trial_count(method::Staircase) =
    method.trial_limit > 0 ? method.trial_limit : nothing
remaining_trial_count(method::Staircase) =
    method.trial_limit > 0 ? method.trial_limit - method.current_trial + 1 : nothing

describe_method_state(method::Staircase) =
    isempty(method.available_levels) ? nothing :
    "level $(method.available_levels[method.current_idx])"
