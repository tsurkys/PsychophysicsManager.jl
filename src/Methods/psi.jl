# The Psi method (Kontsevich & Tyler 1999): a posterior over a grid of thresholds and
# slopes, and the level presented next the one whose answer is expected to leave it the
# least uncertain.

# The posterior of a Psi run, over every pair of a threshold and a log10 slope, with the
# probability of a positive answer at each level under each pair
struct PsiPosterior
    alphas::Vector{Float64}          # the threshold of each grid point
    log_slopes::Vector{Float64}      # its log10 slope
    positive::Matrix{Float64}        # grid points × levels: P(positive answer)
    uncertainty::Matrix{Float64}     # the binary entropy of each, in nats
    probability::Vector{Float64}     # the posterior, summing to 1
end

binary_entropy(q::Real) = (q > 0 ? -q * log(q) : 0.0) + (q < 1 ? -(1 - q) * log1p(-q) : 0.0)

function PsiPosterior(shape::PsychometricShape, alpha_range, beta_range, gamma, lambda,
                      stim_range)
    grid = [(alpha, log_slope) for log_slope in beta_range for alpha in alpha_range]
    positive = [psychometric_value(shape, x, alpha, exp10(log_slope), gamma, lambda)
                for (alpha, log_slope) in grid, x in stim_range]
    return PsiPosterior(first.(grid), last.(grid), positive, binary_entropy.(positive),
                        fill(1 / length(grid), length(grid)))
end

# Bayes' rule for an answer at the level `index` of the grid
function take_answer!(posterior::PsiPosterior, index::Int, positive::Bool)
    probability = posterior.probability
    for (point, q) in enumerate(view(posterior.positive, :, index))
        probability[point] *= positive ? q : 1 - q
    end
    probability ./= sum(probability)
    return posterior
end

# The entropy the posterior is expected to have after an answer at each level. It is
# what it has now less what the answer tells: the uncertainty of the answer, less the
# part of it that knowing the parameters would leave.
function expected_entropies(posterior::PsiPosterior)
    probability = posterior.probability
    now = sum(binary_entropy_term, probability)
    predicted = posterior.positive' * probability
    left = posterior.uncertainty' * probability
    return now .- binary_entropy.(predicted) .+ left
end

binary_entropy_term(p::Real) = p > 0 ? -p * log(p) : 0.0

# The level index to present next. Levels whose expected entropies differ by no more than
# rounding are treated as tied, and the first of them is taken.
function most_informative(posterior::PsiPosterior)
    entropies = expected_entropies(posterior)
    return findfirst(<=(minimum(entropies) + 1e-11), entropies)
end

posterior_mean(posterior::PsiPosterior, values::Vector{Float64}) =
    sum(posterior.probability .* values)

"""
    Psi(; kwargs...)

The Psi adaptive method (Kontsevich & Tyler 1999). Presents the level that minimizes the
expected entropy of the posterior over threshold and slope over a uniform prior, so a
threshold is estimated in far fewer trials than a fixed grid needs.

Keywords, all optional:

- `trial_limit = 50`: trials the run presents.
- `stim_range`: the levels that may be presented. Defaults to the first declared
  independent variable's range, so an ordinary design needs no grid of its own.
- `alpha_range`: the threshold grid the posterior is defined over. Defaults to
  the stimulus range, which is the assumption that the threshold lies where the
  levels are.
- `beta_range = -1:0.05:1`: the slope grid, as base-10 logarithms of the slope.
- `lambda = 0.02`: the lapse rate.
- `gamma`: the guess rate. It defaults to 0.5 in a task with a correct answer —
  two-interval accuracy, where guessing already scores half — and to `lambda` in
  one without, where a lapse is as likely either way.
- `pf`: the psychometric function, one of [`PSYCHOMETRIC_FUNCTIONS`](@ref). It defaults
  to `:gumbel` in a task with a correct answer and to `:logistic` in one without.
  `:gumbel` and `:log_quick` are functions of the base-10 logarithm of an intensity, the
  others of the level itself, so a design whose levels are linear or go below zero,
  such as a contrast given as a proportion or a length difference, names one of the
  others; `:weibull` and `:quick` need positive thresholds and levels of 0 and above.
- `symmetric`: whether, with even odds drawn from the session's stream, the level
  presented is the one Psi chose mirrored about the current estimate (the grid
  point nearest to it), so that the levels fall on both sides of it. On by
  default in a task without a correct answer, where with a symmetric function
  and `gamma = lambda` the mirrored level tells as much, and a run of levels on
  one side would bias the answers; off in one with a correct answer, where the
  function is not symmetric about the threshold.

`stim_range` and `alpha_range` are filled from the design when they are left
empty, and stay filled: a replication of a Psi session repeats the grid the
session actually presented, not the design it was derived from.

It steps on whether the answer was **correct** ([`correct_answer`](@ref)). In a
task without a correct answer — a point of subjective equality — it steps on the
answer coded `+1`, its threshold is the level answered `+1` half the time, and
its trials are recorded `1`/`0`, as in [`Staircase`](@ref). A repeat
request (`0`) re-presents the same level and costs no trial. A presentation
nobody answered spends the trial without touching the posterior, so Psi chooses
as it did, with nothing learned from the silence.

A trial the operator asks for ([`present_condition!`](@ref)) at a level of the grid
is taken into the posterior as if Psi had chosen it, and does not count toward
`trial_limit`, so Psi's own sequence keeps its length. Its answer then shapes the
levels Psi chooses next.

The posterior is never written to the session file. What is written is the
levels presented and the answers given, from which it is rebuilt on load and after
an undo.

```julia
session = SessionContext("P01", ex_par, stim_par, Psi(trial_limit = 60))
```
"""
mutable struct Psi <: AbstractPsychoMethod
    # Configuration, all of it in the session file
    trial_limit::Int
    stim_range::Vector{Float64}
    alpha_range::Vector{Float64}
    beta_range::Vector{Float64}
    gamma::Union{Nothing, Float64}    # nothing: by the task (`guess_rate`)
    lambda::Float64
    pf::Union{Nothing, Symbol}        # nothing: by the task (`function_name`)
    symmetric::Union{Nothing, Bool}   # nothing: by the task (`mirrors`)
    scored::Union{Nothing, Bool}      # whether the task scores its answers (set_task_scored!)

    # What the posterior is rebuilt from
    levels::Vector{Float64}
    scores::Vector{Int}
    trials_spent::Int

    # Runtime
    extra_vals::Vector{Float64}   # further variables, drawn once per trial
    presented::Union{Nothing, Float64}  # the trial's level, drawn once, kept across a repeat
    repeat_requested::Bool
    posterior::Union{Nothing, PsiPosterior}   # rebuilt, never serialized

    function Psi(; trial_limit::Integer = 50,
                   stim_range = Float64[],
                   alpha_range = Float64[],
                   beta_range = collect(-1.0:0.05:1.0),
                   gamma::Union{Nothing, Real} = nothing,
                   lambda::Real = 0.02,
                   pf::Union{Nothing, Symbol} = nothing,
                   symmetric::Union{Nothing, Bool} = nothing)
        trial_limit >= 1 ||
            throw(ArgumentError("trial_limit must be at least 1, got $trial_limit."))
        gamma === nothing || 0.0 <= gamma < 1.0 ||
            throw(ArgumentError("gamma is a guess rate in [0, 1), got $gamma."))
        0.0 <= lambda < 1.0 ||
            throw(ArgumentError("lambda is a lapse rate in [0, 1), got $lambda."))
        isempty(beta_range) && throw(ArgumentError("beta_range must name a slope."))
        pf === nothing || psychometric_shape(pf)   # refuse an unknown name here, not mid-session
        return new(Int(trial_limit), Vector{Float64}(stim_range),
                   Vector{Float64}(alpha_range), Vector{Float64}(beta_range),
                   gamma === nothing ? nothing : Float64(gamma), Float64(lambda), pf,
                   symmetric, nothing,
                   Float64[], Int[], 0, Float64[], nothing, false, nothing)
    end
end

task_scored(method::Psi) = method.scored !== false
guess_rate(method::Psi) = something(method.gamma, task_scored(method) ? 0.5 : method.lambda)
function_name(method::Psi) = something(method.pf, task_scored(method) ? :gumbel : :logistic)
mirrors(method::Psi) = something(method.symmetric, !task_scored(method))

set_task_scored!(method::Psi, scored::Bool) = (method.scored = scored; method)

# The posterior before any answer; the same whether the run is starting or being rebuilt
# from a file
function prior_posterior(method::Psi)
    shape = psychometric_shape(function_name(method))
    if shape.logarithmic
        minimum(method.alpha_range) > 0 && minimum(method.stim_range) >= 0 ||
            throw(ArgumentError(
                "A :$(function_name(method)) function takes levels of 0 and above and a " *
                "positive threshold, and this Psi run's grid reaches " *
                "$(min(minimum(method.alpha_range), minimum(method.stim_range))). Pass " *
                "an `alpha_range` above 0, or name a function of the level itself."))
    end
    return PsiPosterior(shape, method.alpha_range, method.beta_range, guess_rate(method),
                        method.lambda, method.stim_range)
end

function initialize_method!(method::Psi, ex_par::ExperimentParameters;
                            rng::AbstractRNG = Random.default_rng())
    if isempty(method.stim_range)
        isempty(ex_par.indep_var_ranges) && throw(ArgumentError(
            "Psi needs levels to present: declare an independent variable " *
            "or pass `stim_range`."))
        method.stim_range = sort(unique(Float64.(ex_par.indep_var_ranges[1])))
    end
    isempty(method.alpha_range) && (method.alpha_range = copy(method.stim_range))

    empty!(method.levels)
    empty!(method.scores)
    empty!(method.extra_vals)
    method.presented = nothing
    method.trials_spent = 0
    method.repeat_requested = false
    method.posterior = prior_posterior(method)
    return method
end

function restore_method_state!(method::Psi)
    isempty(method.stim_range) && return method   # never started; nothing to rebuild

    method.presented = nothing
    method.posterior = prior_posterior(method)
    for (level, score) in zip(method.levels, method.scores)
        take_answer!(method.posterior, grid_index(method.stim_range, level), score == 1)
    end
    return method
end

# A level replayed from a session file has been through JSON, so it is matched
# to the grid by proximity rather than by identity; a level that belongs to no
# grid point at all is a file that does not describe this method's design.
function grid_index(grid::Vector{Float64}, level::Float64)
    isempty(grid) && throw(ArgumentError("The stimulus grid is empty."))
    distance, idx = findmin(abs.(grid .- level))
    tolerance = length(grid) == 1 ? 1.0e-9 :
                maximum(abs.(diff(grid))) / 2 + 1.0e-9
    distance <= tolerance || throw(ArgumentError(
        "The recorded level $level is not on this method's stimulus grid " *
        "($(first(grid)) … $(last(grid))). The session file was written by a " *
        "run configured differently."))
    return idx
end

# The level the posterior points to
suggested_level(method::Psi) = method.stim_range[most_informative(method.posterior)]

# The level Psi chose or, in a symmetric run and with even odds, the grid point nearest
# its mirror image about the current estimate.
# Before the first answer there is no estimate to mirror about.
function next_level(method::Psi, rng::AbstractRNG)
    level = suggested_level(method)
    mirrors(method) || return level
    estimate = method_threshold(method)
    (isfinite(estimate) && rand(rng, Bool)) || return level
    return method.stim_range[argmin(abs.(method.stim_range .- (2estimate - level)))]
end

function get_next_trial_params(method::Psi, session::SessionContext)
    method.presented === nothing && (method.presented = next_level(method, session.rng))
    return [method.presented; draw_further_variables!(method.extra_vals, session)]
end

function update_method_state!(method::Psi, response::Real,
                              correct::Union{Nothing, Bool})
    score = answer_score(task_scored(method), response, correct)
    if score === nothing
        method.repeat_requested = response == 0
        method.repeat_requested && return nothing
        # Nobody answered. The posterior is untouched, so Psi chooses as it did;
        # the trial is still spent, or a backend that keeps failing would run
        # forever.
        method.trials_spent += 1
        empty!(method.extra_vals)
        method.presented = nothing
        return nothing
    end

    method.repeat_requested = false
    index = grid_index(method.stim_range, something(method.presented, suggested_level(method)))
    push!(method.levels, method.stim_range[index])
    push!(method.scores, score ? 1 : 0)
    take_answer!(method.posterior, index, score)
    method.trials_spent += 1
    empty!(method.extra_vals)
    method.presented = nothing
    return nothing
end

update_method_state!(::Psi, ::Real) = throw(ArgumentError(
    "Psi consumes the response with its score " *
    "(`update_method_state!(method, response, correct)`), which is what the Core " *
    "loop calls."))

get_trial_result(method::Psi, last_response::Real) =
    task_scored(method) ? last_response : binary_answer(last_response)

is_trial_finished(method::Psi) = !method.repeat_requested

is_experiment_finished(method::Psi) = method.trials_spent >= method.trial_limit

fresh_instance(method::Psi) =
    Psi(; trial_limit = method.trial_limit,
          stim_range = copy(method.stim_range),
          alpha_range = copy(method.alpha_range),
          beta_range = copy(method.beta_range),
          gamma = method.gamma, lambda = method.lambda, pf = method.pf,
          symmetric = method.symmetric)

planned_trial_count(method::Psi) = method.trial_limit
remaining_trial_count(method::Psi) = method.trial_limit - method.trials_spent

steps_on_answers(::Psi) = true

method_settings(method::Psi) = Pair{Symbol, Any}[
    :trial_limit => method.trial_limit, :stim_range => method.stim_range,
    :alpha_range => method.alpha_range, :beta_range => method.beta_range,
    :gamma => method.gamma, :lambda => method.lambda, :pf => method.pf,
    :symmetric => method.symmetric]

function with_method_settings(method::Psi, changes::AbstractDict{Symbol})
    settings = merged_settings(method, changes)
    grid(name) = setting_value(Vector{Float64}, name, something(settings[name], Float64[]))
    return Psi(; trial_limit = setting_value(Int, :trial_limit, settings[:trial_limit]),
                 stim_range = grid(:stim_range), alpha_range = grid(:alpha_range),
                 beta_range = grid(:beta_range),
                 gamma = setting_value(Union{Nothing, Float64}, :gamma, settings[:gamma]),
                 lambda = setting_value(Float64, :lambda, settings[:lambda]),
                 pf = setting_value(Union{Nothing, Symbol}, :pf, settings[:pf]),
                 symmetric = setting_value(Union{Nothing, Bool}, :symmetric,
                                           settings[:symmetric]))
end

function revert_method_state!(method::Psi, trial::Trial)
    method.trials_spent == 0 && return false
    # Only an answered trial reached the posterior; an unanswered one spent a trial
    # and nothing else, so undoing it must not drop the answer before it
    score = recorded_score(task_scored(method), trial)
    score === nothing ||
        remove_answer!(method, first(trial.indep_var_vals), score) || return false
    method.trials_spent -= 1
    return true
end

# Takes a trial's answer out and replays the rest. Its entry is the last with its level
# and score: a later one is a trial still counted (an outlier), and the posterior does
# not depend on the order of its answers.
function remove_answer!(method::Psi, level::Real, score::Bool)
    position = findlast(i -> isapprox(method.levels[i], level) &&
                             method.scores[i] == Int(score), eachindex(method.levels))
    position === nothing && return false
    deleteat!(method.levels, position)
    deleteat!(method.scores, position)
    restore_method_state!(method)
    return true
end

# The operator's trial enters the posterior as the levels Psi chose do, so a session
# reloaded from its file replays it with them. `trials_spent` is not touched: the
# trial is not one of Psi's own.
function absorb_operator_trial!(method::Psi, vals, response, correct)
    score = !is_answer(response) ? nothing : task_scored(method) ? correct : response > 0
    score === nothing && return nothing     # unanswered or unscored: nothing learned
    index = grid_position(method, first(vals))
    if index === nothing
        @warn "Level $(first(vals)) is not on this Psi run's stimulus grid, so its " *
              "answer is recorded but not taken into the posterior."
        return nothing
    end
    push!(method.levels, method.stim_range[index])
    push!(method.scores, score ? 1 : 0)
    take_answer!(method.posterior, index, score)
    return nothing
end

function forget_operator_trial!(method::Psi, trial::Trial)
    score = recorded_score(task_scored(method), trial)
    score === nothing && return true
    index = grid_position(method, first(trial.indep_var_vals))
    index === nothing && return true        # never taken in
    return remove_answer!(method, method.stim_range[index], score)
end

# A level is on the grid when it is one of its points, not merely near one: an answer
# at another level would be taken in at the wrong one
grid_position(method::Psi, level::Real) =
    findfirst(point -> isapprox(point, level), method.stim_range)

"""
    method_threshold(method::Psi) -> Float64

The posterior mean of the threshold after the trials run so far, in the units of
the levels presented — in a task without a correct answer, the point of subjective
equality. `NaN` before the first answer.
"""
method_threshold(method::Psi) =
    method.posterior === nothing || isempty(method.levels) ? NaN :
    posterior_mean(method.posterior, method.posterior.alphas)

# A report shows the method's own threshold beside the fitted one
method_estimate(method::Psi) = method_threshold(method)

function describe_method_state(method::Psi)
    method.posterior === nothing && return nothing
    estimate = method_threshold(method)
    level = something(method.presented, suggested_level(method))
    return isnan(estimate) ? "level $level" :
           "level $level, threshold ≈ $(round(estimate; digits = 3))"
end
