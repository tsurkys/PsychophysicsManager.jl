mutable struct ConstantStimuli <: AbstractPsychoMethod
    trial_table::Vector{Vector{Float64}}
    order::Vector{Int}
    current_idx::Int
    repeat_requested::Bool   # participant asked to see the stimulus again (response 0)

    function ConstantStimuli()
        new(Vector{Float64}[], Int[], 1, false)
    end
end

function initialize_method!(method::ConstantStimuli, ex_par::ExperimentParameters;
                            rng::AbstractRNG=Random.default_rng())
    method.trial_table = build_trial_table(ex_par)
    method.order = shuffle(rng, 1:length(method.trial_table))
    method.current_idx = 1
    method.repeat_requested = false
end

function get_next_trial_params(method::ConstantStimuli, session::SessionContext)
    idx = method.order[method.current_idx]
    return method.trial_table[idx]
end

function update_method_state!(method::ConstantStimuli, response::Real)
    if response == 0
        # 0 (Enter) means "present the stimulus again", not an answer
        method.repeat_requested = true
    else
        method.repeat_requested = false
        method.current_idx += 1
    end
end

is_trial_finished(method::ConstantStimuli) = !method.repeat_requested

get_trial_result(::ConstantStimuli, last_response::Real) = binary_answer(last_response)

function revert_method_state!(method::ConstantStimuli, trial::Trial)
    method.current_idx = max(1, method.current_idx - 1)
    return true
end

plans_conditions(::ConstantStimuli) = true

take_condition!(method::ConstantStimuli, vals::AbstractVector; replacing::Bool) =
    place_condition!(method.order, method.trial_table, method.current_idx, vals; replacing)

function is_experiment_finished(method::ConstantStimuli)
    return method.current_idx > length(method.order)
end

planned_trial_count(method::ConstantStimuli) =
    isempty(method.order) ? nothing : length(method.order)
remaining_trial_count(method::ConstantStimuli) =
    isempty(method.order) ? nothing : length(method.order) - method.current_idx + 1
