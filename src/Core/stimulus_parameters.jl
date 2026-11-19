# A stimulus's parameters, by name. Whatever
# reads or sets a parameter goes through these functions, never through the fields of a
# stimulus type: a stimulus defined in Julia keeps its parameters in its fields, and the
# stimulus a remote worker declares (`WorkerStimulus`) in a list it owns.

"""
    parameter_names(stim_par) -> Vector{Symbol}

The parameters of a stimulus, in the order its author gave them: the fields of a Julia
stimulus type, or those a remote worker declares ([`WorkerStimulus`](@ref)).
"""
parameter_names(stim_par::AbstractStimulusParameters) = collect(fieldnames(typeof(stim_par)))

"""
    has_parameter(stim_par, name::Symbol) -> Bool

Whether the stimulus has the parameter `name`.
"""
has_parameter(stim_par::AbstractStimulusParameters, name::Symbol) =
    hasfield(typeof(stim_par), name)

"""
    parameter_value(stim_par, name::Symbol)

The value the stimulus holds for parameter `name`.
"""
parameter_value(stim_par::AbstractStimulusParameters, name::Symbol) = getfield(stim_par, name)

"""
    parameter_type(stim_par, name::Symbol) -> Type

The type a value of parameter `name` takes: a field's declared type, or for a parameter
a worker declares the kind of value it holds — `Real`, `Bool`, `String`, `Vector{Any}`,
or `Any` for one whose value is `nothing`.
"""
parameter_type(stim_par::AbstractStimulusParameters, name::Symbol) =
    fieldtype(typeof(stim_par), name)

"""
    numeric_parameters(stim_par) -> Vector{Symbol}

The parameters of `stim_par` that hold a number, in its own order ([`parameter_names`](@ref)).
"""
numeric_parameters(stim_par::AbstractStimulusParameters) =
    [name for name in parameter_names(stim_par)
     if parameter_type(stim_par, name) <: Real && !(parameter_type(stim_par, name) <: Bool)]

"""
    required_variables(stim_par) -> Vector{Pair{Symbol, Vector}}

The independent variables a design presenting `stim_par` cannot do without, each with
its levels: a session whose stimulus is chosen by name ([`set_parameters!`](@ref)) is
given them. Default: none.

```julia
PsychophysicsManager.required_variables(::MyTwoIntervalStimulus) = [:target_interval => [1, 2]]
```
"""
required_variables(::AbstractStimulusParameters) = Pair{Symbol, Vector}[]

"""
    set_parameter!(stim_par, name::Symbol, value) -> stim_par

Sets parameter `name` to `value`, converted as a field assignment converts it.
"""
set_parameter!(stim_par::AbstractStimulusParameters, name::Symbol, value) =
    (setproperty!(stim_par, name, value); stim_par)

"""
    stimulus_name(stim_par) -> String

What the stimulus is called where people read it, and in the `present` command a remote
worker receives (`_type`): its type's name, or the name a worker declares it under.
"""
stimulus_name(stim_par::AbstractStimulusParameters) = type_name(stim_par)

"""
    WorkerStimulus(stimulus, parameters)
    WorkerStimulus(stimulus; name = value, ...)

A stimulus that a remote worker presents and describes itself: the name
its `hello` reply declares it under and its parameters with their values, in the
worker's order. It needs no Julia type of its own, so a parameter added to a MATLAB or
Python stimulus needs no change on this side. [`worker_stimulus`](@ref) gives one with a
connected worker's defaults, and every session start completes it to what the worker
then declares.

A value is a number, `true` or `false`, text, a list of such values, or `nothing`, and a
parameter keeps the kind of value it holds: one holding a number takes numbers, one
holding `nothing` takes anything. A whole number is kept as an `Int`, as a session file
reads it back — JSON holds values, not Julia types. The worker validates the values;
PsychophysicsManager does not.

```julia
stimulus = WorkerStimulus("oppel_kundt"; Ref = 100, DistrN = 3, StimConfig = "r d t")
```
"""
mutable struct WorkerStimulus <: AbstractStimulusParameters
    stimulus::String
    parameters::Vector{Pair{Symbol, Any}}

    function WorkerStimulus(stimulus::AbstractString, parameters)
        isempty(stimulus) && throw(ArgumentError("A worker's stimulus needs a name."))
        list = Pair{Symbol, Any}[]
        for (name, value) in parameters
            key = Symbol(name)
            any(entry -> first(entry) === key, list) && throw(ArgumentError(
                "The stimulus $stimulus names its parameter $key twice."))
            push!(list, key => declared_value(stimulus, key, value))
        end
        return new(String(stimulus), list)
    end
end

WorkerStimulus(stimulus::AbstractString; parameters...) =
    WorkerStimulus(stimulus, collect(pairs(parameters)))

# A value as a declared parameter holds it: what JSON writes and reads back the same
function declared_value(stimulus::AbstractString, name::Symbol, value)
    value === nothing && return nothing
    value isa Bool && return value
    if value isa Real
        isfinite(value) || throw(ArgumentError(
            "$stimulus.$name cannot be $value: a session file holds finite numbers."))
        return isinteger(value) && typemin(Int) <= value <= typemax(Int) ? Int(value) :
                                                                           Float64(value)
    end
    value isa Union{AbstractString, Symbol} && return String(value)
    value isa Union{AbstractVector, Tuple} &&
        return Any[declared_value(stimulus, name, item) for item in value]
    throw(ArgumentError("$stimulus.$name cannot be $(repr(value)): a parameter holds a " *
                        "number, true or false, text, a list of these, or nothing."))
end

# The kind of value a declared parameter takes, from the value it holds
declared_kind(value) = value === nothing ? Any : value isa Bool ? Bool :
                       value isa Real ? Real : value isa AbstractString ? String : Vector{Any}

parameter_names(stim_par::WorkerStimulus) = first.(stim_par.parameters)
has_parameter(stim_par::WorkerStimulus, name::Symbol) =
    any(entry -> first(entry) === name, stim_par.parameters)
parameter_value(stim_par::WorkerStimulus, name::Symbol) =
    last(stim_par.parameters[declared_index(stim_par, name)])
parameter_type(stim_par::WorkerStimulus, name::Symbol) =
    declared_kind(parameter_value(stim_par, name))
stimulus_name(stim_par::WorkerStimulus) = stim_par.stimulus

function set_parameter!(stim_par::WorkerStimulus, name::Symbol, value)
    index = declared_index(stim_par, name)
    kind = declared_kind(last(stim_par.parameters[index]))
    stored = declared_value(stim_par.stimulus, name, value)
    kind === Any || declared_kind(stored) === kind || throw(ArgumentError(
        "$(stim_par.stimulus).$name takes a $(parameter_type_name(kind)), got " *
        "$(repr(value))."))
    stim_par.parameters[index] = name => stored
    return stim_par
end

function declared_index(stim_par::WorkerStimulus, name::Symbol)
    index = findfirst(entry -> first(entry) === name, stim_par.parameters)
    index === nothing && throw(ArgumentError(
        "The stimulus $(stim_par.stimulus) has no parameter $name; its parameters are " *
        "$(join(parameter_names(stim_par), ", "))."))
    return index
end
