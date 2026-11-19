using Statistics
using StatsFuns: tdistinvcdf

"""
    AggregatePoint

Summary data for a single stimulus condition.
`vals`: Full condition vector, aligned with `ex_par.indep_var_names`.
`level`: Convenience alias for `vals[1]` — the x-axis value in the common
         single-variable case.
`n`: Total number of valid trials.
`mean_response`: Mean of the recorded responses (a proportion for binary data).
`sd`: Standard deviation of the responses — for an adjustment, the variable error.
`sem`: Standard error of the mean.
`ci_lo`, `ci_hi`: The mean's confidence interval at [`CI_LEVEL`](@ref): the
         [`wilson_interval`](@ref) when the data record a choice (a method that adjusts
         no stimulus field and every response is 0 or 1, defined for a single trial too),
         and Student's t with `n - 1` degrees of freedom otherwise (`NaN` for a single
         trial, which has none).
`proportion_correct`: Share of the condition's scored trials that were answered
         correctly, or `nothing` when none of them was scored (`Trial.correct`).
`correct_ci_lo`, `correct_ci_hi`: The [`wilson_interval`](@ref) at [`CI_LEVEL`](@ref)
         of `proportion_correct` over the condition's scored trials; both `NaN` when none
         was scored.

`sd` and `sem` are `0` for a single trial, as a single value spreads nowhere.
"""
struct AggregatePoint
    vals::Vector{Float64}
    level::Float64
    n::Int
    mean_response::Float64
    sd::Float64
    sem::Float64
    ci_lo::Float64
    ci_hi::Float64
    proportion_correct::Union{Nothing, Float64}
    correct_ci_lo::Float64
    correct_ci_hi::Float64
end

"""
    CI_LEVEL

The mass of the confidence interval an [`AggregatePoint`](@ref) carries (0.95).
"""
const CI_LEVEL = 0.95

"""
    wilson_interval(successes::Real, n::Integer; level::Real = CI_LEVEL) -> Tuple{Float64, Float64}

The Wilson score confidence interval for a binomial proportion `successes / n` at mass
`level`. Unlike Student's t on 0/1 responses — which gives 0 of 20 the degenerate
interval `[0, 0]` and lets 19 of 20 pass `1` — the Wilson interval stays within `[0, 1]`,
gives a non-zero upper bound at zero successes, and is defined for a single trial.
"""
function wilson_interval(successes::Real, n::Integer; level::Real = CI_LEVEL)
    n >= 1 || throw(ArgumentError("n must be at least 1, got $n."))
    0 <= successes <= n || throw(ArgumentError(
        "successes must be between 0 and n ($n), got $successes."))
    0 < level < 1 || throw(ArgumentError(
        "level must be strictly between 0 and 1, got $level."))

    nf = Float64(n)
    z = normal_quantile((1 + level) / 2)
    p = successes / nf
    z2_n = z^2 / nf
    denom = 1 + z2_n
    centre = (p + z2_n / 2) / denom
    half = z * sqrt(p * (1 - p) / nf + z2_n / (4 * nf)) / denom
    lo = successes == 0 ? 0.0 : centre - half
    hi = successes == n ? 1.0 : centre + half
    return (Float64(lo), Float64(hi))
end

# ── Units ─────────────────────────────────────────────────────

# The variable a trial's response is a value of: the one field the method adjusts.
# A method that adjusts none records a code — a choice, a detection — with no unit.
function response_variable(method::AbstractPsychoMethod)
    fields = adjusted_fields(method)
    return length(fields) == 1 ? only(fields) : nothing
end

"The name a variable's values are shown under: its conversion's label, or its own name."
variable_label(session::SessionContext, variable::Symbol) =
    haskey(session.unit_conversions, variable) ?
    session.unit_conversions[variable].label : string(variable)

"The name the responses are shown under when they are converted, or `nothing`."
function response_label(session::SessionContext)
    variable = response_variable(session.method_instance)
    variable === nothing && return nothing
    conversion = get(session.unit_conversions, variable, nothing)
    return conversion === nothing ? nothing : conversion.label
end

"A trial's condition vector in the units the session declares, as the analysis groups it."
function converted_values(session::SessionContext, values::AbstractVector)
    return Float64[get(session.unit_conversions, name, identity)(x)
                   for (name, x) in zip(session.ex_par.indep_var_names, values)]
end

"The conversion of the variable the responses are values of, or `identity`."
function response_conversion(session::SessionContext)
    variable = response_variable(session.method_instance)
    return variable === nothing ? identity : get(session.unit_conversions, variable, identity)
end

"""
    converted_observations(data; converted = true) -> Vector{Tuple{Vector{Float64}, Float64, Union{Nothing, Bool}}}

The valid trials that recorded a number, each as its condition vector, its response
and its correctness, in the units the data declares (or the recorded values when
`converted = false`). Each trial is converted by its own session, since the members
of a set may have measured on different apparatus.
"""
function converted_observations(session::SessionContext; converted::Bool = true)
    convert_response = converted ? response_conversion(session) : identity
    # A trial with no response to average — a closed response window, a model
    # observer that failed — is left out rather than counted as a value: one such
    # trial would otherwise make the whole condition's mean NaN, and `n` must count
    # what the mean was computed from.
    return [(converted ? converted_values(session, t.indep_var_vals) : Float64.(t.indep_var_vals),
             Float64(convert_response(t.response)), t.correct)
            for t in session.history
            if t.is_valid && t.response isa Real && !isnan(t.response)]
end

converted_observations(set::AnalysisSet; converted::Bool = true) =
    [observation for member in set.sessions
     for observation in converted_observations(member; converted)]

"""
    kept_variables(data, collapse) -> Vector{Symbol}

The independent variables an analysis keeps when it pools the trials over the variables
`collapse` names (a name or a list of them): every variable of the design but those.
A name the design does not declare is refused, and so is pooling over every variable.
"""
function kept_variables(data::SessionOrSet, collapse)
    names = design_session(data).ex_par.indep_var_names
    pooled = pooled_variables(collapse)
    unknown = setdiff(pooled, names)
    isempty(unknown) || throw(ArgumentError(
        "The design has no variable $(join(unknown, ", ")) to pool over; its variables are " *
        "$(join(names, ", "))."))
    kept = filter(!in(pooled), names)
    isempty(kept) && !isempty(pooled) && throw(ArgumentError(
        "Pooling over every variable leaves no condition to report; keep at least one."))
    return kept
end

# The variables `collapse` names, as a list: it may be one name or several
pooled_variables(collapse) = collapse isa Symbol ? [collapse] : Symbol.(collect(collapse))

# Where the kept variables sit in a trial's condition vector
kept_positions(data::SessionOrSet, collapse) =
    [findfirst(==(name), design_session(data).ex_par.indep_var_names)
     for name in kept_variables(data, collapse)]

# A method that adjusts no field records a binary answer; the look at the responses
# keeps Student's t for a method of a user's own that records a rating instead
is_choice_data(data::SessionOrSet, observations) =
    isempty(adjusted_fields(design_session(data).method_instance)) &&
    all(((_, r, _),) -> r == 0 || r == 1, observations)

"""
    get_aggregated_data(data; collapse = (), converted = true) -> Vector{AggregatePoint}

Aggregates the valid trials of a session, or of every session of an
[`AnalysisSet`](@ref) pooled together, per unique stimulus condition. The grouping
key is the FULL independent-variable vector, so multi-variable designs are never
collapsed across a dimension unless `collapse` names the variables to pool over — a
counterbalancing variable, such as which interval of a two-interval task held the
target, which a threshold is not measured per. The points' `vals` then hold the kept
variables ([`kept_variables`](@ref)). Points are sorted lexicographically by the
condition vector.

Levels and responses are in the units the data declares
([`set_unit_conversion!`](@ref)), or the recorded values when `converted = false`.
Each trial is converted before it is averaged, so under a logarithmic conversion a
mean is the mean of the converted values.
"""
function get_aggregated_data(data::SessionOrSet; collapse = (), converted::Bool = true)
    observations = converted_observations(data; converted)
    isempty(observations) && return AggregatePoint[]
    keep = kept_positions(data, collapse)
    observations = [(vals[keep], response, correct) for (vals, response, correct) in observations]

    if isempty(observations)
        return AggregatePoint[]
    end

    choice = is_choice_data(data, observations)
    unique_conditions = sort(unique(first.(observations)))
    results = AggregatePoint[]

    for cond in unique_conditions
        responses = [r for (c, r, _) in observations if c == cond]
        n = length(responses)
        m = mean(responses)
        sd = n > 1 ? std(responses) : 0.0
        sem = sd / sqrt(n)
        if choice
            ci_lo, ci_hi = wilson_interval(sum(responses), n)
        else
            half = n > 1 ? tdistinvcdf(n - 1, (1 + CI_LEVEL) / 2) * sem : NaN
            ci_lo, ci_hi = m - half, m + half
        end

        scored = Bool[k for (c, _, k) in observations if c == cond && k !== nothing]
        proportion_correct = isempty(scored) ? nothing : mean(scored)
        correct_ci_lo, correct_ci_hi = isempty(scored) ? (NaN, NaN) :
                                       wilson_interval(count(scored), length(scored))

        level = isempty(cond) ? NaN : cond[1]
        push!(results, AggregatePoint(copy(cond), level, n, m, sd, sem, ci_lo, ci_hi,
                                      proportion_correct, correct_ci_lo, correct_ci_hi))
    end

    return results
end

"""
    smoothed_means(aggregated; window = 3, values = mean responses) -> Vector{Float64}

A curve through the condition means that assumes no model: each mean averaged with its neighbours along the first variable — a
moving average over `window` levels, narrower at the ends — among the conditions that
share the other variables. In the order of `aggregated`. `values` smooths another
per-condition value instead, such as the proportion correct.
"""
function smoothed_means(aggregated::Vector{AggregatePoint}; window::Integer = 3,
                        values::AbstractVector{<:Real} =
                            [point.mean_response for point in aggregated])
    length(values) == length(aggregated) || throw(ArgumentError(
        "values gives $(length(values)) numbers for $(length(aggregated)) conditions."))
    window >= 1 && isodd(window) || throw(ArgumentError(
        "window is an odd number of levels, got $window."))
    reach = window ÷ 2
    smoothed = similar(aggregated, Float64)
    for others in unique(point.vals[2:end] for point in aggregated)
        members = sort!(findall(point -> point.vals[2:end] == others, aggregated);
                        by = index -> aggregated[index].level)
        for (position, index) in enumerate(members)
            span = members[max(position - reach, 1):min(position + reach, end)]
            smoothed[index] = mean(values[neighbour] for neighbour in span)
        end
    end
    return smoothed
end

# ── Headless text reports ────────────────────────────────────────────────────
# Every summary prints the same table — one row per condition, then as many
# value columns as it has to show — and differs only in what those columns
# hold, so an aggregation mode added to `AggregatePoint` has one place to
# appear in.

"The x-axis name of the data: the variables it keeps, or `Condition` when it has none."
function condition_header(data::SessionOrSet; collapse = ())
    session = design_session(data)
    isempty(session.ex_par.indep_var_names) && return "Condition"
    return join((variable_label(session, name) for name in kept_variables(data, collapse)),
                ", ")
end

"The row label of one condition: the level itself, or the full vector in a multi-variable design."
condition_label(point) =
    length(point.vals) == 1 ? string(point.level) : "(" * join(point.vals, ", ") * ")"

# The condition column is wider than the value columns, and the last column is
# left unpadded so no line ends in trailing blanks
_table_row(label, cells::Tuple) =
    join((rpad(label, 11), (rpad(c, 10) for c in Base.front(cells))..., last(cells)),
         " | ")

"""
    print_condition_table(data, title, aggregated, value_headers, value_cells; collapse = ())

Prints `aggregated` as a table under `title`. `value_cells(point)` returns the
values of one row, as many as `value_headers` names and in the same order. `collapse`
is what the points were pooled over.
"""
function print_condition_table(data::SessionOrSet, title::AbstractString,
                               aggregated::Vector{AggregatePoint},
                               value_headers::NTuple{N, String}, value_cells;
                               collapse = ()) where {N}
    println("\n" * "="^40)
    println("      $title")
    println("-"^40)
    println(_table_row(condition_header(data; collapse), value_headers))
    println("-"^40)
    for point in aggregated
        println(_table_row(condition_label(point), value_cells(point)))
    end
    println("="^40)
    return nothing
end

"""
    constant_errors(data; collapse = ()) -> Vector{Union{Nothing, Float64}}

The constant error of an adjustment per condition, in the order of
[`get_aggregated_data`](@ref): the mean deviation of the settings from the point of
physical equality the stimulus declares ([`physical_equality`](@ref)), in the declared
units of the adjusted value — the mean setting's deviation, unless the conditions pool
trials over a variable the point depends on. `nothing` for a condition whose stimulus
declares no such point, and for every condition of a method that adjusts no single field.
"""
function constant_errors(data::SessionOrSet; collapse = ())
    field = response_variable(design_session(data).method_instance)
    aggregated = get_aggregated_data(data; collapse)
    field === nothing && return Union{Nothing, Float64}[nothing for _ in aggregated]
    keep = kept_positions(data, collapse)
    sessions = data isa AnalysisSet ? data.sessions : [data]
    return Union{Nothing, Float64}[constant_error(sessions, field, keep, point)
                                   for point in aggregated]
end

# Each setting's deviation from the point of equality of the stimulus as it was
# presented, in the units of the session that presented it, over the trials the
# point's mean was computed from
function constant_error(sessions, field::Symbol, keep::Vector{Int}, point::AggregatePoint)
    deviations = Float64[]
    for session in sessions
        to_unit = get(session.unit_conversions, field, identity)
        for trial in session.history
            trial.is_valid && trial.response isa Real && !isnan(trial.response) || continue
            converted_values(session, trial.indep_var_vals)[keep] == point.vals || continue
            equality = physical_equality(session.stim_par, field,
                                         trial_variables(session.ex_par, trial.indep_var_vals))
            equality === nothing && return nothing
            push!(deviations, Float64(to_unit(trial.response)) - Float64(to_unit(equality)))
        end
    end
    return isempty(deviations) ? nothing : mean(deviations)
end

"""
    print_adjustment_summary(data; collapse = ())

Prints a text-based summary table of adjustment results to the terminal, for one
session or for the sessions of an [`AnalysisSet`](@ref) pooled together, pooled over the
variables `collapse` names ([`get_aggregated_data`](@ref)). Works headless (no plotting
backend required).
"""
function print_adjustment_summary(data::SessionOrSet; collapse = ())
    aggregated = get_aggregated_data(data; collapse)
    if isempty(aggregated)
        println("No data.")
        return nothing
    end

    errors = constant_errors(data; collapse)
    spread(point) = (round(point.mean_response, digits = 2), round(point.sd, digits = 2),
                     round(point.sem, digits = 2),
                     isnan(point.ci_hi) ? "–" :
                     "±" * string(round(point.ci_hi - point.mean_response, digits = 2)))
    ci = "$(round(Int, 100 * CI_LEVEL))% CI"
    if all(!isnothing, errors)
        error_of = IdDict(zip(aggregated, errors))
        print_condition_table(data, "EXPERIMENT RESULTS", aggregated,
                              ("Mean", "SD", "SEM", ci, "CE"),
                              point -> (spread(point)..., round(error_of[point], digits = 2));
                              collapse)
    else
        print_condition_table(data, "EXPERIMENT RESULTS", aggregated,
                              ("Mean", "SD", "SEM", ci), spread; collapse)
    end
    interval_name = is_choice_data(data, converted_observations(data)) ? "Wilson" : "Student's t"
    println("SD: the variable error; $ci: the mean's confidence interval ($interval_name)" *
            (all(!isnothing, errors) ?
             "; CE: constant error, the mean setting's deviation from physical equality" : ""))
    label = response_label(design_session(data))
    label === nothing || println("Values in: $label")
    println()
    return nothing
end

# ── Reaction times ───────────────────────────────────────────────────────────

"""
    ReactionTimePoint

The reaction times of one condition: its condition vector and first level in the
declared units, the number of trials timed, their median and mean in seconds, and
how many of them were timed from an onset the core estimated rather than one the
engine reported (`Trial.onset_source`), which makes a coarser reaction time.
"""
struct ReactionTimePoint
    vals::Vector{Float64}
    level::Float64
    n::Int
    median_s::Float64
    mean_s::Float64
    estimated::Int
end

"""
    reaction_times(data) -> Vector{ReactionTimePoint}

The reaction times per condition of a session, or of the sessions of an
[`AnalysisSet`](@ref) pooled together: from each valid, answered trial's onset to
its response. A trial presented more than once — a repeat request, an adjustment's
steps — is timed from its first presentation to its concluding response.

A session answered by a program is refused: its request latency is transport and
inference, not a reaction time.
"""
function reaction_times(data::SessionOrSet)
    sessions = data isa AnalysisSet ? data.sessions : [data]
    any(answered_by_program, sessions) && throw(ArgumentError(
        "A session answered by a program has no reaction times: its latency is the " *
        "request's, not a participant's."))

    timed = [(converted_values(session, trial.indep_var_vals),
              trial.timestamp_response - trial.timestamp_onset,
              trial.onset_source === :estimated)
             for session in sessions for trial in session.history
             if trial.is_valid && trial.response isa Real && !isnan(trial.response)]
    points = ReactionTimePoint[]
    for condition in sort(unique(first.(timed)))
        times = [rt for (c, rt, _) in timed if c == condition]
        estimated = count(e for (c, _, e) in timed if c == condition)
        push!(points, ReactionTimePoint(condition, isempty(condition) ? NaN : condition[1],
                                        length(times), median(times), mean(times), estimated))
    end
    return points
end

"""
    print_reaction_times(data)

Prints the reaction times per condition ([`reaction_times`](@ref)) of a session or a
set as a table, in milliseconds, with the trials timed from an estimated onset
counted. Works headless.
"""
function print_reaction_times(data::SessionOrSet)
    points = reaction_times(data)
    if isempty(points)
        println("No timed trials.")
        return nothing
    end
    println("\n" * "="^40)
    println("      REACTION TIMES (ms)")
    println("-"^40)
    println(_table_row(condition_header(data), ("Median", "Mean", "Trials", "Estimated")))
    println("-"^40)
    for point in points
        println(_table_row(condition_label(point), (round(1000 * point.median_s, digits = 1),
                                   round(1000 * point.mean_s, digits = 1),
                                   point.n, point.estimated)))
    end
    println("="^40)
    any(point -> point.estimated > 0, points) &&
        println("Estimated: trials timed from an onset the core estimated, not the engine's.")
    println()
    return nothing
end

# ── Yes/no detection ─────────────────────────────────────────────────────────

"""
    DetectionSummary

The signal-detection counts of a yes/no task and what follows from them: the hit and
false-alarm rates as observed, and the sensitivity `d_prime` and criterion `criterion`
(c) computed from the rates after the log-linear correction (`correction`).
"""
struct DetectionSummary
    hits::Int
    misses::Int
    false_alarms::Int
    correct_rejections::Int
    hit_rate::Float64
    false_alarm_rate::Float64
    d_prime::Float64
    criterion::Float64
    correction::Symbol
end

"""
    detection_summary(data) -> DetectionSummary

Hits, misses, false alarms and correct rejections of a yes/no detection task, for a
session or the sessions of an [`AnalysisSet`](@ref) pooled together, with d′ and c.

"Yes" is the response `+1`. Whether the stimulus was present follows from the scored
answer ([`correct_answer`](@ref)): "yes" is correct exactly when it was there. Only
valid, answered, scored trials count, and a task that scores none is refused.

d′ and c are computed from rates corrected log-linearly (Hautus, 1995: half a trial added
to the hits and to the false alarms, one to each total), so that a rate of 0 or 1 gives
a finite value; the rates reported are the observed ones.
"""
function detection_summary(data::SessionOrSet)
    sessions = data isa AnalysisSet ? data.sessions : [data]
    scored = [(trial.response == 1, trial.correct) for session in sessions
              for trial in session.history
              if trial.is_valid && trial.response isa Real && is_answer(trial.response) &&
                 trial.correct !== nothing]
    isempty(scored) && throw(ArgumentError(
        "Detection needs trials scored against a correct answer, and this data has none: " *
        "the stimulus must declare `correct_answer` (\"yes\" correct when it was present)."))

    hits = count(((yes, correct),) -> yes && correct, scored)
    misses = count(((yes, correct),) -> !yes && !correct, scored)
    false_alarms = count(((yes, correct),) -> yes && !correct, scored)
    rejections = count(((yes, correct),) -> !yes && correct, scored)
    present, absent = hits + misses, false_alarms + rejections
    (present == 0 || absent == 0) && throw(ArgumentError(
        "Detection needs trials with the stimulus present and trials with it absent; " *
        "this data has $present and $absent."))

    corrected_hit = (hits + 0.5) / (present + 1)
    corrected_false_alarm = (false_alarms + 0.5) / (absent + 1)
    z_hit, z_false_alarm = normal_quantile(corrected_hit), normal_quantile(corrected_false_alarm)
    return DetectionSummary(hits, misses, false_alarms, rejections,
                            hits / present, false_alarms / absent,
                            z_hit - z_false_alarm, -(z_hit + z_false_alarm) / 2,
                            :loglinear)
end

"""
    print_detection_summary(data)

Prints [`detection_summary`](@ref): the four counts, the observed rates, and d′ and c
with the correction they were computed under. Works headless.
"""
function print_detection_summary(data::SessionOrSet)
    summary = detection_summary(data)
    println("\n" * "="^40)
    println("      DETECTION (yes = +1)")
    println("-"^40)
    println("Hits $(summary.hits), misses $(summary.misses), false alarms " *
            "$(summary.false_alarms), correct rejections $(summary.correct_rejections)")
    println("Hit rate $(round(summary.hit_rate, digits = 3)), false-alarm rate " *
            "$(round(summary.false_alarm_rate, digits = 3))")
    println("d′ $(round(summary.d_prime, digits = 3)), c $(round(summary.criterion, digits = 3))" *
            " (log-linear correction, Hautus 1995)")
    println("="^40)
    println()
    return summary
end

# The standard normal quantile by Acklam's rational approximation, relative error
# below 1.2e-9: enough for d′, and no dependency for one function
function normal_quantile(p::Real)
    0 < p < 1 || throw(DomainError(p, "a probability strictly between 0 and 1 is needed"))
    a = (-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2,
         1.383577518672690e2, -3.066479806614716e1, 2.506628277459239e0)
    b = (-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2,
         6.680131188771972e1, -1.328068155288572e1)
    c = (-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838e0,
         -2.549732539343734e0, 4.374664141464968e0, 2.938163982698783e0)
    d = (7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996e0,
         3.754408661907416e0)
    tail(q) = (((((c[1]q + c[2])q + c[3])q + c[4])q + c[5])q + c[6]) /
              ((((d[1]q + d[2])q + d[3])q + d[4])q + 1)
    p < 0.02425 && return tail(sqrt(-2log(p)))
    p > 1 - 0.02425 && return -tail(sqrt(-2log(1 - p)))
    q = p - 0.5
    r = q^2
    return (((((a[1]r + a[2])r + a[3])r + a[4])r + a[5])r + a[6])q /
           (((((b[1]r + b[2])r + b[3])r + b[4])r + b[5])r + 1)
end
