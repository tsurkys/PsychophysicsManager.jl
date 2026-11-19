"""
    Adjustment

Participant adjusts a stimulus parameter via ±1 responses, confirming with 0.
Fields:

- `dep_var`: The stimulus parameter name being adjusted (auto-applied to `stim_par`).
- `dep_range`: Allowed values supplied as a numeric vector or range. Integer
  values remain integers (useful for discrete pixel adjustments); other real
  values are normalized to `Float64`. Responses ±1 step through the sorted
  values, clamping at edges. Value spacing dictates step sizes.
- `init_interval`: Optional `(lo, hi)` bounds. Trials start at a random
  `dep_range` value within this interval. If omitted, trials resume from the
  last adjusted value.
- `init_vals`: Logs the starting value of each trial for bias analysis.

`dep_var` and `dep_range` have no default ([`unset_settings`](@ref)).
"""
const AdjustmentValue = Union{Int, Float64}

mutable struct Adjustment <: AbstractPsychoMethod
    # Configuration
    dep_var::Union{Nothing, Symbol}
    dep_range::Vector{AdjustmentValue}
    init_interval::Union{Nothing, Tuple{AdjustmentValue, AdjustmentValue}}

    # Runtime state
    trial_table::Vector{Vector{Float64}}
    order::Vector{Int}
    current_trial::Int
    range_idx::Int
    init_vals::Vector{AdjustmentValue}
    needs_init::Bool
    confirmed::Bool
end

function _normalize_adjustment_value(value, name::AbstractString, index=nothing)
    location = index === nothing ? name : "$name[$index]"
    value isa Real || throw(ArgumentError("$location must be a real number, got $(typeof(value))"))
    isfinite(value) || throw(ArgumentError("$location must be finite, got $value"))

    normalized = try
        value isa Integer ? Int(value) : Float64(value)
    catch e
        e isa InexactError || e isa OverflowError || rethrow()
        throw(ArgumentError("$location cannot be represented as Int or Float64: $value"))
    end
    isfinite(normalized) || throw(ArgumentError(
        "$location cannot be represented as a finite Int or Float64: $value"))
    return normalized
end

function _normalize_dep_range(dep_range)
    dep_range isa AbstractVector || throw(ArgumentError(
        "dep_range must be a numeric vector or range, got $(typeof(dep_range))"))

    values = AdjustmentValue[]
    sizehint!(values, length(dep_range))
    for (index, value) in pairs(dep_range)
        push!(values, _normalize_adjustment_value(value, "dep_range", index))
    end
    return values
end

function _normalize_init_interval(init_interval)
    init_interval === nothing && return nothing
    init_interval isa Tuple && length(init_interval) == 2 || throw(ArgumentError(
        "init_interval must be nothing or a two-value tuple, got $init_interval"))

    lo = _normalize_adjustment_value(init_interval[1], "init_interval", 1)
    hi = _normalize_adjustment_value(init_interval[2], "init_interval", 2)
    lo <= hi || throw(ArgumentError("init_interval lower bound must not exceed its upper bound"))
    return (lo, hi)
end

function Adjustment(;
    dep_var::Union{Nothing, Symbol} = nothing,
    dep_range = AdjustmentValue[],
    init_interval = nothing,
)
    return Adjustment(
        dep_var,
        _normalize_dep_range(dep_range),
        _normalize_init_interval(init_interval),
        Vector{Float64}[],
        Int[],
        1,
        1,
        AdjustmentValue[],
        true,
        false,
    )
end

function initialize_method!(method::Adjustment, ex_par::ExperimentParameters;
                            rng::AbstractRNG=Random.default_rng())
    check_settings_set(method)
    issorted(method.dep_range) || sort!(method.dep_range)
    method.trial_table = build_trial_table(ex_par)
    method.order = shuffle(rng, 1:length(method.trial_table))
    method.current_trial = 1
    method.range_idx = 1
    method.init_vals = AdjustmentValue[]
    method.needs_init = true
    method.confirmed = false
end

function get_next_trial_params(method::Adjustment, session::SessionContext)
    if method.needs_init
        initialize_trial_value!(method, session.stim_par, session.rng)
    end
    idx = method.order[method.current_trial]
    return method.trial_table[idx]
end

# Pick the starting value of a new trial: random within init_interval,
# otherwise the value currently held by the stimulus parameters. The draw is
# made from the session's stream (`session.rng`), so a seed reproduces the
# starting values of every trial, not only the first.
function initialize_trial_value!(method::Adjustment,
                                 stim_par::AbstractStimulusParameters,
                                 rng::AbstractRNG=Random.default_rng())
    if method.init_interval !== nothing
        lo, hi = method.init_interval
        candidates = findall(v -> lo <= v <= hi, method.dep_range)
        isempty(candidates) && error("init_interval ($lo, $hi) contains no dep_range values")
        method.range_idx = rand(rng, candidates)
    else
        current = has_parameter(stim_par, method.dep_var) ?
            Float64(parameter_value(stim_par, method.dep_var)) : method.dep_range[1]
        method.range_idx = argmin(abs.(method.dep_range .- current))
    end
    push!(method.init_vals, method.dep_range[method.range_idx])
    method.needs_init = false
    method.confirmed = false
end

function update_method_state!(method::Adjustment, response::Real)
    if isnan(response)
        # Nobody is adjusting any more (a closed response window, a model
        # observer that failed): the trial ends where it stands, unconfirmed.
        # Adjustment reads 0 as the participant's confirmation, so a missing
        # response cannot be forwarded to it.
        method.confirmed = true
        method.needs_init = true
        method.current_trial += 1
        return method
    end

    if response == 0
        # Confirmation: the trial is complete
        method.confirmed = true
        method.needs_init = true
        method.current_trial += 1
    else
        new_idx = method.range_idx + Int(sign(response))
        if new_idx < 1 || new_idx > length(method.dep_range)
            @info "Adjustment reached the edge of the dependent variable range."
        else
            method.range_idx = new_idx
        end
    end
    return method
end

is_trial_finished(method::Adjustment) = method.confirmed

function is_experiment_finished(method::Adjustment)
    return method.current_trial > length(method.order)
end

# Push the current adjusted value into the stimulus parameters before drawing.
function apply_method_state!(method::Adjustment, stim_par::AbstractStimulusParameters)
    if has_parameter(stim_par, method.dep_var)
        set_converted!(stim_par, method.dep_var, method.dep_range[method.range_idx])
    end
    return nothing
end

adjusted_fields(method::Adjustment) =
    method.dep_var === nothing ? Symbol[] : [method.dep_var]

unset_settings(method::Adjustment) =
    Symbol[name for (name, unset) in ((:dep_var, method.dep_var === nothing),
                                      (:dep_range, isempty(method.dep_range))) if unset]

function fill_stimulus_settings(method::Adjustment, stimulus::AbstractStimulusParameters,
                                ex_par::ExperimentParameters)
    method.dep_var === nothing || return method
    offered = [name for name in numeric_parameters(stimulus)
               if !(name in ex_par.indep_var_names)]
    isempty(offered) && return method
    return with_method_settings(method, Dict{Symbol, Any}(:dep_var => first(offered)))
end

# The recorded result of an adjustment trial is the confirmed value, not the
# confirmation keypress.
# The value the participant confirmed — unless nobody confirmed one, in which
# case the trial records the missing response rather than the value the
# adjustment happened to stand at when it ended.
get_trial_result(method::Adjustment, last_response::Real) =
    isnan(last_response) ? last_response : method.dep_range[method.range_idx]

function revert_method_state!(method::Adjustment, trial::Trial)
    method.current_trial = max(1, method.current_trial - 1)
    isempty(method.init_vals) || pop!(method.init_vals)
    method.needs_init = true
    return true
end

plans_conditions(::Adjustment) = true

# The operator's trial draws its own starting value when it begins, and init_vals
# records it beside the others
take_condition!(method::Adjustment, vals::AbstractVector; replacing::Bool) =
    place_condition!(method.order, method.trial_table, method.current_trial, vals; replacing)

method_settings(method::Adjustment) = Pair{Symbol, Any}[
    :dep_var => method.dep_var, :dep_range => method.dep_range,
    :init_interval => method.init_interval]

dependent_settings(::Adjustment) = [:dep_var, :dep_range, :init_interval]

function with_method_settings(method::Adjustment, changes::AbstractDict{Symbol})
    settings = merged_settings(method, changes)
    return Adjustment(
        dep_var = setting_value(Union{Nothing, Symbol}, :dep_var, settings[:dep_var]),
        dep_range = setting_value(Vector{Any}, :dep_range, settings[:dep_range]),
        init_interval = setting_value(Union{Nothing, Tuple{Float64, Float64}},
                                      :init_interval, settings[:init_interval]))
end

fresh_instance(method::Adjustment) = Adjustment(
    dep_var = method.dep_var,
    dep_range = copy(method.dep_range),
    init_interval = method.init_interval,
)

planned_trial_count(method::Adjustment) =
    isempty(method.order) ? nothing : length(method.order)
remaining_trial_count(method::Adjustment) =
    isempty(method.order) ? nothing : length(method.order) - method.current_trial + 1

# The trial result is the confirmed value of the adjusted variable — name it
function describe_trial(method::Adjustment, ex_par::ExperimentParameters, trial::Trial)
    conds = join(("$n=$v" for (n, v) in zip(ex_par.indep_var_names, trial.indep_var_vals)), ", ")
    return "$conds → $(method.dep_var) = $(trial.response)"
end

# The value the participant is adjusting right now (":steps" reporter level)
describe_method_state(method::Adjustment) =
    isempty(method.dep_range) ? nothing :
    "$(method.dep_var) = $(method.dep_range[method.range_idx])"
