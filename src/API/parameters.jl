# Changing the parameters of a session that has not started. A scenario run's
# overrides and the dashboard's Parameters view both come through here, so each
# refuses what the other refuses.

"""
    set_parameters!(session::SessionContext, values::AbstractDict; declared = nothing) -> session

Sets parameters of a session that has not started. Each key names one,
`"ex_par.<field>"` of the design or `"stim_par.<parameter>"` of the stimulus,
`"stimulus"` for the stimulus itself (a name in [`selectable_stimuli`](@ref), `declared`
as there),
`"method"` for the method's type (a name in the method registry, built with no
arguments, then [`fill_stimulus_settings`](@ref)) or `"method.<setting>"` for one of
its settings ([`method_settings`](@ref)),
and each value is given as a session file or a scenario plan writes it — a number, a
string, a list — and converted to the type the field or parameter takes
(`coerce_field`, [`parameter_type`](@ref)).

A stimulus chosen by name starts from its defaults, and the session takes the engine it
is registered with ([`register_stimulus!`](@ref)). An independent variable stays, with
its levels, where the new stimulus has a numeric parameter of that name; the others are
replaced by one, its first numeric parameter that is free, at its default; and the
variables the stimulus cannot do without ([`required_variables`](@ref)) are added. A
method whose adjusted parameter the new stimulus lacks starts again as if chosen by name.

Nothing is changed unless every value is accepted: the design is rebuilt through its
constructor and the method through its own ([`with_method_settings`](@ref)), so what
they refuse is refused here; the stimulus is checked by [`validate_stimulus`](@ref),
as described and at every level a variable gives the field it sets; a stimulus that
scores answers ([`correct_answer`](@ref)) must score every condition of the design; a
method that adjusts a field must find it in the stimulus, and one that steps on answers
([`steps_on_answers`](@ref)) a stimulus that declares a correct answer for every
condition or for none. A refusal is an
`ArgumentError` naming the parameter. [`check_parameters`](@ref) makes the same checks
on the parameters as they are.

A session that has started is refused: its parameters are what it measured.
"""
function set_parameters!(session::SessionContext, values::AbstractDict; declared = nothing)
    ex_par, stimulus, method, engine_name =
        checked_parameters(session, values; declared = declared)
    session.ex_par = ex_par
    if typeof(stimulus) === typeof(session.stim_par)
        # In place: whoever holds the stimulus holds the session's
        restore_fields!(session.stim_par, stimulus)
    else
        session.stim_par = stimulus
    end
    session.engine_name = engine_name
    session.method_instance = method
    return session
end

"""
    check_parameters(session::SessionContext; declared = nothing) -> session

The checks of [`set_parameters!`](@ref) on the parameters as they are, changing
nothing; an `ArgumentError` names what is refused.
"""
check_parameters(session::SessionContext; declared = nothing) =
    (checked_parameters(session, Dict{String, Any}(); declared = declared); session)

# The design, stimulus and method `values` make of the session's, checked, or a refusal
function checked_parameters(session::SessionContext, values::AbstractDict; declared = nothing)
    session.state == READY || throw(ArgumentError(
        "The session has started, so its parameters are what it measured and stay as " *
        "they are; prepare a new session to measure with others."))
    design = Dict{Symbol, Any}(name => getfield(session.ex_par, name)
                               for name in fieldnames(ExperimentParameters))
    stimulus = deepcopy(session.stim_par)
    method = session.method_instance
    keys_given = sort!(collect(String.(keys(values))))
    engine_name = session.engine_name
    restarted = false

    if "stimulus" in keys_given
        stimulus = chosen_stimulus(values["stimulus"], declared)
        engine_name = chosen_engine_name(stimulus)
        numeric = numeric_parameters(stimulus)
        kept = [index for (index, name) in enumerate(design[:indep_var_names])
                if name in numeric]
        names = design[:indep_var_names][kept]
        ranges = Any[design[:indep_var_ranges][index] for index in kept]
        adjusted = filter(field -> has_parameter(stimulus, field), adjusted_fields(method))
        required = required_variables(stimulus)
        free = [name for name in numeric
                if !(name in names) && !(name in adjusted) && !(name in first.(required))]
        if length(kept) < length(design[:indep_var_names]) && !isempty(free)
            push!(names, first(free))
            push!(ranges, Any[parameter_value(stimulus, first(free))])
        end
        for (name, levels) in required
            name in names && continue
            push!(names, name)
            push!(ranges, collect(Any, levels))
        end
        design[:indep_var_names] = names
        design[:indep_var_ranges] = ranges
        # The method's values were in the units of a parameter the stimulus lacks
        if !("method" in keys_given) && length(adjusted) < length(adjusted_fields(method))
            method = chosen_method(type_name(method))
            restarted = true
        end
    end

    if "method" in keys_given
        method = chosen_method(values["method"])
    end
    method_changes = Dict{Symbol, Any}(Symbol(chop(key; head = length("method."), tail = 0)) =>
                                       values[key]
                                       for key in keys_given if startswith(key, "method."))
    isempty(method_changes) || (method = with_method_settings(method, method_changes))
    for key in keys_given
        (key in ("method", "stimulus") || startswith(key, "method.")) && continue
        target, field = parameter_key(key)
        T = if target === :ex_par
            hasfield(ExperimentParameters, field) || throw(ArgumentError(
                "`$key` names no parameter: ExperimentParameters has no field $field."))
            fieldtype(ExperimentParameters, field)
        else
            has_parameter(stimulus, field) || throw(ArgumentError(
                "`$key` names no parameter: $(stimulus_name(stimulus)) has no parameter " *
                "$field."))
            parameter_type(stimulus, field)
        end
        raw = values[key]
        value = try
            coerce_field(T, raw)
        catch
            nothing
        end
        (value isa T || (value === nothing && Nothing <: T)) || throw(ArgumentError(
            "`$key` cannot be $(repr(raw)): it takes a $(parameter_type_name(T))."))
        target === :ex_par ? (design[field] = value) : set_parameter!(stimulus, field, value)
    end

    ex_par = ExperimentParameters(design[:experiment_name], design[:indep_var_names],
                                  design[:indep_var_ranges], design[:repeats])
    ("method" in keys_given || "stimulus" in keys_given) &&
        (method = fill_stimulus_settings(method, stimulus, ex_par))
    validate_stimulus(stimulus)
    for (name, levels) in zip(ex_par.indep_var_names, ex_par.indep_var_ranges)
        has_parameter(stimulus, name) || continue
        for level in levels
            presented = deepcopy(stimulus)
            try
                set_parameter!(presented, name, convert(parameter_type(presented, name), level))
                validate_stimulus(presented)
            catch err
                err isa Union{ArgumentError, InexactError, MethodError} || rethrow()
                throw(ArgumentError("Level $level of $name cannot be presented: " *
                                    (err isa ArgumentError ? err.msg : sprint(showerror, err))))
            end
        end
    end

    # Started again, the method found nothing of the new stimulus to adjust
    restarted && isempty(adjusted_fields(method)) && throw(ArgumentError(
        "$(type_name(method)) adjusts a stimulus parameter, and " *
        "$(stimulus_name(stimulus)) has none it can adjust."))
    for field in adjusted_fields(method)
        has_parameter(stimulus, field) || throw(ArgumentError(
            "$(type_name(method)) adjusts $field, which $(stimulus_name(stimulus)) does " *
            "not have."))
    end
    # A design the stimulus cannot score is refused here, not mid-run
    answers = map(Iterators.product(ex_par.indep_var_ranges...)) do condition
        try
            correct_answer(stimulus, trial_variables(ex_par, Float64[condition...]))
        catch err
            err isa ArgumentError || rethrow()
            throw(ArgumentError("$(stimulus_name(stimulus)) cannot score the condition " *
                                "$(join(condition, ", ")): $(err.msg)"))
        end
    end
    check_task_scoring(method, stimulus, scoring_kind(answers))
    return ex_par, stimulus, method, engine_name
end

# A method chosen by its type's name: one the registry holds and can build with no
# arguments. An interleaved run is not chosen this way, since it needs its tracks.
function chosen_method(name)
    type = get(METHOD_REGISTRY, Symbol(string(name)), nothing)
    (type === nothing || type === Interleaved) && throw(ArgumentError(
        "No method $name can be chosen: the methods are " *
        "$(join(selectable_methods(), ", "))."))
    return type()
end

"""
    selectable_methods() -> Vector{String}

The methods a session's method can be chosen among: the registered types that can be
built with no arguments, an interleaved run excepted.
"""
function selectable_methods()
    names = String[]
    for (name, type) in METHOD_REGISTRY
        type === Interleaved && continue
        try
            type()
            push!(names, string(name))
        catch
        end
    end
    return sort!(names)
end

# A stimulus chosen by its name, with its defaults: one a connected worker declares, or
# one the registry holds and can build with no arguments
function chosen_stimulus(name, declared)
    for stimulus in declared_list(declared)
        stimulus.stimulus == string(name) && return deepcopy(stimulus)
    end
    type = get(STIMULUS_REGISTRY, Symbol(string(name)), nothing)
    if type !== nothing
        try
            return type()
        catch
        end
    end
    throw(ArgumentError(
        "No stimulus $name can be chosen: the stimuli are " *
        "$(join(selectable_stimuli(; declared), ", "))."))
end

# The engine that presents a chosen stimulus, named without loading its backend
function chosen_engine_name(stimulus::AbstractStimulusParameters)
    name = stimulus_engine_name(stimulus)
    name === nothing || return string(name)
    # Registered without an engine: a `default_engine_type` method written for the type
    type = try
        default_engine_type(stimulus)
    catch
        throw(ArgumentError(
            "No engine is known for $(stimulus_name(stimulus)): register it with " *
            "`register_stimulus!` and the engine that presents it."))
    end
    return string(nameof(type))
end

"""
    selectable_stimuli(; declared = nothing) -> Vector{String}

The stimuli a session's stimulus can be chosen among by name: the registered types that
can be built with no arguments, and those a connected worker declares — `declared` is the
`RemoteEngine` connected to it, or the [`WorkerStimulus`](@ref) list themselves.
"""
function selectable_stimuli(; declared = nothing)
    names = String[stimulus.stimulus for stimulus in declared_list(declared)]
    for (name, type) in STIMULUS_REGISTRY
        try
            type()
            push!(names, string(name))
        catch
        end
    end
    return sort!(unique!(names))
end

declared_list(::Nothing) = WorkerStimulus[]
declared_list(stimuli::AbstractVector{WorkerStimulus}) = stimuli
declared_list(engine::RemoteEngine) = engine.stimuli
declared_list(::AbstractStimulusEngine) = WorkerStimulus[]

function parameter_key(key::AbstractString)
    parts = split(key, '.')
    (length(parts) == 2 && parts[1] in ("ex_par", "stim_par") && !isempty(parts[2])) ||
        throw(ArgumentError("`$key` names no parameter: a parameter is " *
                            "\"ex_par.<field>\" or \"stim_par.<field>\"."))
    return Symbol(parts[1]), Symbol(parts[2])
end

# A field's type as an operator reads it: what is expected, not how Julia spells it
function parameter_type_name(T::Type)
    T isa Union && return parameter_type_name(T.a === Nothing ? T.b : T.a) * " or nothing"
    T === Bool && return "true or false value"
    T <: Integer && return "whole number"
    T <: Real && return "number"
    T <: Symbol && return "name"
    T <: AbstractString && return "text"
    T <: Tuple && return "list of $(length(fieldtypes(T))) values"
    T <: AbstractVector && return "list of values"
    return string(T)
end
