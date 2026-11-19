"""
    CurveFit

A fitted psychometric curve: `alpha` is the threshold (where the curve's own function
puts its location), `beta` the slope, `gamma` the guess rate (floor) and `lambda` the
lapse rate (ceiling gap).

`model` names the function that was fitted ([`PSYCHOMETRIC_FUNCTIONS`](@ref)). Every fit
is a maximum-likelihood one, of the counts behind the proportions.

`se_alpha`, `se_beta` and the two intervals are `NaN` unless the fit was
bootstrapped (`n_bootstrap` says how often). A threshold without a spread is an
estimate, not a measurement, so read the two together.
"""
struct CurveFit
    model::Symbol
    alpha::Float64
    beta::Float64
    gamma::Float64
    lambda::Float64
    se_alpha::Float64
    se_beta::Float64
    ci_alpha::Tuple{Float64, Float64}
    ci_beta::Tuple{Float64, Float64}
    n_bootstrap::Int
    converged::Bool
end

# A fit with no spread
CurveFit(model::Symbol, alpha, beta, gamma, lambda, converged) =
    CurveFit(model, alpha, beta, gamma, lambda,
             NaN, NaN, (NaN, NaN), (NaN, NaN), 0, converged)

"""
    has_interval(fit::CurveFit) -> Bool

Whether the fit carries a confidence interval on its threshold.
"""
has_interval(fit::CurveFit) = fit.n_bootstrap > 0 && !isnan(first(fit.ci_alpha))

"""
    curve_value(fit::CurveFit, x::Real) -> Float64

The fitted curve at `x`, by the fit's own `model`.
"""
curve_value(fit::CurveFit, x::Real) =
    psychometric_value(fit.model, x, fit.alpha, fit.beta, fit.gamma, fit.lambda)

"""
    psychometric_proportions(aggregated_data, on::Symbol) -> (source, proportions)

What a psychometric curve is fitted to at each condition: `source = :correct`
for the proportion correct, `:response` for the mean response. `on = :auto`
chooses the proportion correct when every condition was scored, because the mean
response of a two-interval task is its response bias rather than its
measurement. Both fits and the plot resolve `on` here, so they cannot disagree
about what was measured.
"""
function psychometric_proportions(aggregated_data::Vector{AggregatePoint}, on::Symbol)
    scored = all(point -> point.proportion_correct !== nothing, aggregated_data)
    source = on === :auto ? (scored ? :correct : :response) : on
    source in (:correct, :response) || throw(ArgumentError(
        "on is :auto, :correct or :response, got :$on."))
    source === :correct && !scored && throw(ArgumentError(
        "Fitting the proportion correct needs every condition scored, and this " *
        "session has conditions without a correct answer. Fit `on = :response`, " *
        "or give the stimulus a `correct_answer` method."))

    proportions = source === :correct ?
                  [Float64(point.proportion_correct) for point in aggregated_data] :
                  [point.mean_response for point in aggregated_data]
    return source, proportions
end

# The range a free lapse rate is fitted within (Wichmann & Hill 2001)
const LAPSE_RATE_RANGE = (0.0, 0.06)

"""
    fit_psychometric_curve(aggregated_data; gamma = 0.0, lambda = 0.0, on = :auto) -> CurveFit
    fit_psychometric_curve(aggregated_data, model::Symbol; gamma = 0.0, lambda = 0.0,
                           on = :auto, lapse_free = false, bootstrap = 400, level = 0.95,
                           rng = Random.default_rng()) -> CurveFit

Fits a psychometric function by maximum likelihood: the threshold and the slope under
which the answers counted at each level are the most probable. Without a `model` the
function is the logistic and the fit reports no interval, which is the quick fit the live
plot redraws after every trial; `model` names any of [`PSYCHOMETRIC_FUNCTIONS`](@ref).

Gamma (guess rate, the floor) and lambda (lapse rate, the ceiling's gap) are held fixed
and default to 0, so the curve spans the full 0–1 proportion range — the natural choice
for comparison judgements ("which was longer") and yes/no proportions. Pass
`gamma = 0.5` for two-alternative forced-choice *accuracy*, where guessing floors
performance at 50 %. `lapse_free` fits the lapse rate too, within 0 to 0.06 (Wichmann &
Hill 2001), in place of `lambda`; it needs data above the curve's knee to be worth doing.

`on` chooses what is fitted: with `:auto` the proportion correct when every condition
was scored, and the mean response otherwise ([`psychometric_proportions`](@ref)).
Either has to be the proportion of a choice, between 0 and 1; the settings of an
adjustment are not. The fit reads the *counts* behind the proportions, which say how
much evidence is under each point.

`bootstrap` is the number of simulated experiments behind the standard errors and the
`level` interval of the threshold and the slope (a parametric bootstrap: the fitted
observer answers the same numbers of trials at the same levels, and each simulation is
fitted as the data were), `0` for none; `rng` draws them, so an interval can be
reproduced.

`converged` is `false` when the data do not determine a curve: fewer than two
levels, a threshold further outside the levels than they span, or answers that a
step or a constant describes as well as any curve — a step between two
neighbouring levels or with one level on it, proportions that do not change — so
that no slope is singled out. A fit that does not converge is not bootstrapped.

```julia
fit = fit_psychometric_curve(get_aggregated_data(session), :weibull; gamma = 0.5)
fit.alpha, fit.ci_alpha
```
"""
fit_psychometric_curve(aggregated_data::Vector{AggregatePoint}; gamma::Real = 0.0,
                       lambda::Real = 0.0, on::Symbol = :auto) =
    fit_psychometric_curve(aggregated_data, :logistic; gamma, lambda, on, bootstrap = 0)

function fit_psychometric_curve(aggregated_data::Vector{AggregatePoint}, model::Symbol;
                                gamma::Real = 0.0, lambda::Real = 0.0,
                                on::Symbol = :auto,
                                lapse_free::Bool = false,
                                bootstrap::Integer = 400,
                                level::Real = 0.95,
                                rng::AbstractRNG = Random.default_rng())
    0 < level < 1 ||
        throw(ArgumentError("level is the interval's mass in (0, 1), got $level."))
    bootstrap >= 0 ||
        throw(ArgumentError("bootstrap is a number of simulations, got $bootstrap."))
    shape = psychometric_shape(model)
    gamma, lambda = Float64(gamma), Float64(lambda)
    unfitted = CurveFit(model, 0.0, 0.0, gamma, lambda, false)
    length(aggregated_data) < 2 && return unfitted

    levels = [point.level for point in aggregated_data]
    _, proportions = psychometric_proportions(aggregated_data, on)
    counts = [point.n for point in aggregated_data]
    for (level, proportion) in zip(levels, proportions)
        0 <= proportion <= 1 || throw(ArgumentError(
            "A psychometric curve is fitted to the proportions of a choice, and the " *
            "mean response at level $level is $proportion."))
    end
    shape.logarithmic && minimum(levels) < 0 && throw(ArgumentError(
        "A :$model curve is a function of levels of 0 and above, and this data has a " *
        "level of $(minimum(levels)). Fit a function of the level itself, such as " *
        ":logistic or :gumbel."))

    lapse = lapse_free ? LAPSE_RATE_RANGE : (lambda, lambda)
    estimate = maximum_likelihood(shape, levels, proportions .* counts, counts, gamma, lapse)
    estimate === nothing && return unfitted
    alpha = shape.logarithmic ? exp(estimate.location) : estimate.location
    (estimate.converged && bootstrap > 0) ||
        return CurveFit(model, alpha, estimate.slope, gamma, estimate.lapse,
                        estimate.converged)

    simulated = bootstrap_estimates(shape, levels, counts, gamma, lapse, estimate,
                                    Int(bootstrap), rng)
    tail = (1 - level) / 2
    bounds(column) = (quantile(view(simulated, :, column), tail),
                      quantile(view(simulated, :, column), 1 - tail))
    return CurveFit(model, alpha, estimate.slope, gamma, estimate.lapse,
                    std(view(simulated, :, 1)), std(view(simulated, :, 2)),
                    bounds(1), bounds(2), Int(bootstrap), true)
end

# The maximum-likelihood location (on the function's axis), slope and lapse rate of
# `shape` for `positives` of `counts` answers at `levels`, with the lapse rate within the
# pair `lapse` (equal ends hold it fixed); `converged` says whether the data determine
# them. `nothing` when the levels do not span a range.
function maximum_likelihood(shape::PsychometricShape, levels, positives, counts,
                            gamma::Float64, lapse::Tuple{Float64, Float64})
    axis = [axis_value(shape, x) for x in levels]
    measured = sort(unique(filter(isfinite, axis)))
    length(measured) < 2 && return nothing
    low, high = first(measured), last(measured)
    span = high - low
    gap = minimum(diff(measured))
    steepness = shape.steepness

    # Where the search looks: a threshold within the levels' span of them, and a slope
    # between that of a curve a thousand spans wide and that of one six times narrower
    # than the smallest gap between two levels — a logistic rises from 12 % to 88 % of
    # its height over 4/β, and two levels on the rise hold β · gap under 14 even at a
    # thousand answers each. Another function's slope is scaled by its steepness.
    location_bounds = (low - span, high + span)
    log_slope_bounds = log.((0.004 / span, 25 / gap) ./ steepness)
    cost(location, slope, lapse_rate) =
        negative_log_likelihood(shape, location, slope, gamma, lapse_rate,
                                axis, positives, counts)

    # The likelihood has no single valley when gamma or lambda is not 0, and far from
    # the data it is flat, so the descent starts from the best point of a grid over
    # thresholds and over slopes of either sign — with a free lapse rate, from the best
    # point at each of four lapse rates, since a high one and a steep slope can make a
    # valley of their own
    free_lapse = lapse[1] < lapse[2]
    starts = map(free_lapse ? range(lapse[1], lapse[2]; length = 4) : [lapse[1]]) do lapse_rate
        start, start_cost = (0.0, 0.0, lapse_rate), Inf
        for location in range(low - span / 2, high + span / 2; length = 41),
            slope in exp.(range(log(0.4 / span / steepness), log(12 / gap / steepness);
                                length = 24)),
            side in (1, -1)
            value = cost(location, side * slope, lapse_rate)
            value < start_cost &&
                ((start, start_cost) = ((location, side * slope, lapse_rate), value))
        end
        start, start_cost
    end
    filter!(start -> isfinite(last(start)), starts)
    isempty(starts) && return (location = 0.0, slope = 0.0, lapse = lapse[1],
                               converged = false)

    # The slope is searched on a logarithmic scale and keeps the sign the grid found; a
    # free lapse rate as lapse[1] + (lapse[2] − lapse[1]) sin²u, which keeps it in its
    # range with no wall for the simplex to stall against
    lapse_at(u) = lapse[1] + (lapse[2] - lapse[1]) * sin(u)^2
    inside(location, log_slope) =
        location_bounds[1] <= location <= location_bounds[2] &&
        log_slope_bounds[1] <= log_slope <= log_slope_bounds[2]
    best, best_cost, closed, direction = Float64[], Inf, false, 1.0
    for ((location, slope, lapse_rate), _) in starts
        side = sign(slope)
        initial, steps = [location, log(abs(slope))], [span / 20, 0.25]
        if free_lapse
            push!(initial, asin(sqrt((lapse_rate - lapse[1]) / (lapse[2] - lapse[1]))))
            push!(steps, 0.25)
        end
        point, value, settled = descend(initial, steps) do point
            inside(point[1], point[2]) ?
                cost(point[1], side * exp(point[2]),
                     free_lapse ? lapse_at(point[3]) : lapse[1]) : Inf
        end
        value < best_cost && ((best, best_cost, closed, direction) = (point, value, settled, side))
    end
    location, log_slope = best[1], best[2]

    # An estimate resting on a bound is the bound's, not the data's
    margin = 0.01
    within = location_bounds[1] + margin * span < location < location_bounds[2] - margin * span &&
             log_slope_bounds[1] + margin < log_slope < log_slope_bounds[2] - margin
    # A step or a constant is the limit of ever steeper or ever flatter curves. Where
    # one of them is as likely as the curve found, the likelihood only rises towards it
    # — soon by less than floating point shows, so the search stops on the way — and
    # the answers single out no slope.
    limit = limiting_log_likelihood(gamma, lapse, axis, positives, counts)
    determined = -best_cost > limit + 1e-6
    return (location = location, slope = direction * exp(log_slope),
            lapse = free_lapse ? lapse_at(best[3]) : lapse[1],
            converged = closed && within && determined)
end

# Parametric bootstrap (Efron & Tibshirani 1993; Wichmann & Hill 2001b): `count`
# experiments in which the observer `fitted` answers `counts` trials at `levels`, each
# fitted as the data were. Returns their thresholds and slopes as the columns of a matrix;
# a simulation whose answers determine no curve keeps the estimate the search ended on.
function bootstrap_estimates(shape::PsychometricShape, levels, counts, gamma, lapse,
                             fitted, count::Int, rng::AbstractRNG)
    probabilities = [gamma + (1 - gamma - fitted.lapse) *
                             rise_at(shape, axis_value(shape, x), fitted.location,
                                     fitted.slope) for x in levels]
    simulated = Matrix{Float64}(undef, count, 2)
    positives = zeros(length(levels))
    for row in 1:count
        for (i, (probability, n)) in enumerate(zip(probabilities, counts))
            positives[i] = sum(rand(rng) < probability for _ in 1:n; init = 0)
        end
        estimate = maximum_likelihood(shape, levels, positives, counts, gamma, lapse)
        simulated[row, 1] = shape.logarithmic ? exp(estimate.location) : estimate.location
        simulated[row, 2] = estimate.slope
    end
    return simulated
end

# log likelihood of `k` of `n` binary answers positive, each with probability `q`;
# 0 · log 0 is 0: an answer never given says nothing about its probability
binomial_log_likelihood(k, n, q) =
    (k > 0 ? k * log(q) : 0.0) + (k < n ? (n - k) * log1p(-q) : 0.0)

# The largest log likelihood among the curves a psychometric function tends to and never
# is: a constant anywhere between its floor and its ceiling (β → 0), and a step up or
# down between them with at most one level on it, at any height (β → ±∞). A free lapse
# rate puts the ceiling where the answers on its side of the step do, within its range.
function limiting_log_likelihood(gamma, lapse, axis, positives, counts)
    distinct = sort(unique(axis))
    n = [sum(counts[axis .== t]) for t in distinct]
    k = [sum(positives[axis .== t]) for t in distinct]
    floor, top = gamma, 1 - lapse[1]
    ceiling(range) = isempty(range) ? top :
                     clamp(sum(k[range]) / sum(n[range]), 1 - lapse[2], top)
    at(height, range) = sum(binomial_log_likelihood(k[i], n[i], height) for i in range;
                            init = 0.0)

    best = at(clamp(sum(k) / sum(n), floor, top), eachindex(k))
    for on in eachindex(k)
        before, after = 1:on - 1, on + 1:lastindex(k)
        p = k[on] / n[on]
        rising, falling = ceiling(after), ceiling(before)
        up = at(floor, before) + at(rising, after) +
             binomial_log_likelihood(k[on], n[on], clamp(p, floor, rising))
        down = at(falling, before) + at(floor, after) +
               binomial_log_likelihood(k[on], n[on], clamp(p, floor, falling))
        best = max(best, up, down)
    end
    return best
end

# −log likelihood of `positives` of `counts` binary answers at the points `axis` of the
# function's axis, under the curve of `shape` at `location` with `slope`
function negative_log_likelihood(shape::PsychometricShape, location, slope, gamma, lapse,
                                 axis, positives, counts)
    total = 0.0
    for (t, k, n) in zip(axis, positives, counts)
        probability = gamma + (1 - gamma - lapse) * rise_at(shape, t, location, slope)
        total -= binomial_log_likelihood(k, n, probability)
    end
    return total
end

# The simplex below, started again from where it closed until that no longer improves
# on it: a simplex can close on a point that is not a minimum, its corners fallen into a
# line (Lagarias et al. 1998)
function descend(f, start::Vector{Float64}, steps::Vector{Float64}; restarts::Int = 10)
    point, value, closed = nelder_mead(f, start, steps)
    for _ in 1:restarts
        closed || break
        next, next_value, closed = nelder_mead(f, point, steps)
        improved = next_value < value - 1e-12
        point, value = next_value <= value ? (next, next_value) : (point, value)
        improved || break
    end
    return point, value, closed
end

# Minimises `f` by the downhill simplex of Nelder & Mead (1965; reflection 1,
# expansion 2, contraction ½, shrinkage ½) from `start`, the first simplex reaching
# `steps` along each axis. Returns the best point, its value, and whether the simplex
# closed to `tolerance` of those steps. `f` may return `Inf` where it is not defined.
function nelder_mead(f, start::Vector{Float64}, steps::Vector{Float64};
                     tolerance::Float64 = 1e-9, max_iterations::Int = 2000)
    n = length(start)
    simplex = [copy(start) for _ in 0:n]
    for axis in 1:n
        simplex[axis + 1][axis] += steps[axis]
    end
    values = map(f, simplex)
    for _ in 1:max_iterations
        order = sortperm(values)
        simplex, values = simplex[order], values[order]
        extent = maximum(maximum(abs.(point .- simplex[1]) ./ steps) for point in simplex[2:end])
        extent < tolerance && return simplex[1], values[1], true

        centroid = sum(simplex[1:n]) / n
        reflected = centroid + (centroid - simplex[end])
        f_reflected = f(reflected)
        if f_reflected < values[1]
            expanded = centroid + 2 * (centroid - simplex[end])
            f_expanded = f(expanded)
            simplex[end], values[end] = f_expanded < f_reflected ? (expanded, f_expanded) :
                                                                   (reflected, f_reflected)
        elseif f_reflected < values[n]
            simplex[end], values[end] = reflected, f_reflected
        else
            # Towards the better of the worst point and its reflection
            toward = f_reflected < values[end] ? reflected : simplex[end]
            contracted = centroid + 0.5 * (toward - centroid)
            f_contracted = f(contracted)
            if f_contracted < min(f_reflected, values[end])
                simplex[end], values[end] = contracted, f_contracted
            else
                for i in 2:(n + 1)
                    simplex[i] = simplex[1] + 0.5 * (simplex[i] - simplex[1])
                    values[i] = f(simplex[i])
                end
            end
        end
    end
    best = argmin(values)
    return simplex[best], values[best], false
end


"""
    print_psychometric_summary(data; gamma=design_session(data).fit_gamma, lambda=0.0,
                               on=:auto, model=nothing, collapse=(), kwargs...) -> CurveFit

Prints the proportion of positive responses per level and the fitted curve's
threshold, and returns the fit, for one session or for the sessions of an
[`AnalysisSet`](@ref) pooled together. The headless counterpart of
[`print_adjustment_summary`](@ref) for a Constant Stimuli or staircase session.

A session whose task declares a correct answer ([`correct_answer`](@ref)) gets a
further column with the proportion correct, which for a two-interval or
n-alternative task is the measurement and the proportion of positive responses
is only the response bias; the curve is fitted to the proportion correct unless
`on = :response` says otherwise.

The threshold `alpha` of the logistic is the curve's midpoint, which sits at
`p = 0.5` for a proportion-of-choice paradigm (`gamma = 0`, the default — the point
of subjective equality) and at `p = 0.75` for forced-choice accuracy scored with
`gamma = 0.5`; the label printed says where the fitted function puts it. Without a
`model` no confidence interval is reported, so read a single threshold as an estimate
without a spread; with one, the further keywords are
[`fit_psychometric_curve`](@ref)'s.

`collapse` pools the trials over a counterbalancing variable ([`get_aggregated_data`](@ref)):
a two-interval design records which interval held the target, and its threshold is
read from one point per level, `collapse = :target_interval`.
"""
function print_psychometric_summary(data::SessionOrSet;
                                    gamma::Real = design_session(data).fit_gamma,
                                    lambda::Real = 0.0,
                                    on::Symbol = :auto,
                                    model::Union{Nothing, Symbol} = nothing,
                                    collapse = (),
                                    kwargs...)
    aggregated = get_aggregated_data(data; collapse)
    if isempty(aggregated)
        println("\nNo valid trials to fit.")
        return CurveFit(something(model, :logistic), 0.0, 0.0, Float64(gamma),
                        Float64(lambda), false)
    end

    # The proportion correct is a different measurement from the proportion of
    # positive responses, and only a task that declares a correct answer has one
    if any(point -> point.proportion_correct !== nothing, aggregated)
        print_condition_table(data, "PSYCHOMETRIC SUMMARY", aggregated,
                              ("Proportion", "n", "Correct"),
                              point -> (round(point.mean_response, digits = 3), point.n,
                                        point.proportion_correct === nothing ? "" :
                                        round(point.proportion_correct, digits = 3));
                              collapse)
    else
        print_condition_table(data, "PSYCHOMETRIC SUMMARY", aggregated,
                              ("Proportion", "n"),
                              point -> (round(point.mean_response, digits = 3), point.n);
                              collapse)
    end

    model === nothing && !isempty(kwargs) && throw(ArgumentError(
        "$(join(string.(keys(kwargs)), ", ")) belongs to the fit of a named function; " *
        "pass `model` (e.g. `:logistic`) to use it, or drop the keyword."))
    fit = model === nothing ?
          fit_psychometric_curve(aggregated; gamma = gamma, lambda = lambda, on = on) :
          fit_psychometric_curve(aggregated, model; gamma = gamma, lambda = lambda,
                                 on = on, kwargs...)
    if fit.converged
        midpoint = curve_value(fit, fit.alpha)
        interval = has_interval(fit) ?
                   "  [$(round(first(fit.ci_alpha), digits = 2)), " *
                   "$(round(last(fit.ci_alpha), digits = 2))]" : ""
        println("Threshold (p = $(round(midpoint, digits = 2))): " *
                "$(round(fit.alpha, digits = 2))$interval   " *
                "slope β = $(round(fit.beta, digits = 4))")
    else
        println("The data do not determine a curve. A near-deterministic observer turns " *
                "it into a step: sample the levels more finely around the transition.")
    end
    # An adaptive method's own estimate stands beside the fitted one
    data isa SessionContext && is_adaptive(data.method_instance) &&
        print_method_estimates(data)
    return fit
end
