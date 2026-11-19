# Binding experiment variables into stimulus parameter fields. Called by the
# Core loop before each presentation:
# the method decides the values, this file writes them into the stimulus.

"""
    set_converted!(stim_par, name::Symbol, val)

Sets parameter `name` to `val`, converted to the type the parameter takes
([`parameter_type`](@ref); integer fields are rounded, e.g. `DistrN`).
"""
function set_converted!(stim_par::AbstractStimulusParameters, name::Symbol, val)
    T = parameter_type(stim_par, name)
    converted = T <: Integer ? round(T, val) : convert(T, val)
    set_parameter!(stim_par, name, converted)
    return stim_par
end

"""
    apply_variables!(stim_par, names::Vector{Symbol}, vals::AbstractVector{<:Real})

Binds independent variable values to same-named stimulus parameters.
Names without a matching parameter are skipped (engines may still consume them
directly from the `indep_var_vals` argument of `present_stimulus`).
"""
function apply_variables!(stim_par::AbstractStimulusParameters, names::Vector{Symbol}, vals::AbstractVector{<:Real})
    for (name, val) in zip(names, vals)
        has_parameter(stim_par, name) && set_converted!(stim_par, name, val)
    end
    return stim_par
end
