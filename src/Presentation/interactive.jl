# Built-in headless engine: renders the stimulus as text and reads one response
# from the console, so methods can be exercised without a graphics backend.

mutable struct InteractiveEngine <: AbstractStimulusEngine
    console::ConsoleResponseSource       # keeps its prompt across a closed window
    timeout_s::Union{Nothing, Float64}   # response window, set by the Core

    InteractiveEngine() = new(ConsoleResponseSource(), nothing)
end

# This engine reads the console itself, so the Core tells it the session's
# response window instead of a response source
set_response_timeout!(engine::InteractiveEngine, timeout_s) =
    (engine.timeout_s = timeout_s; nothing)

function initialize_engine(::Type{InteractiveEngine}, stim_params::AbstractStimulusParameters, config::DisplayConfig)
    println("  [InteractiveEngine] Initialized. Awaiting console input.")
    println("  [InteractiveEngine] Guide: 1 (Increase/Seen), -1 (Decrease/Not Seen), 0 (Confirm)")
    return InteractiveEngine()
end

"""
    present_stimulus(engine::InteractiveEngine, stim_params::AbstractStimulusParameters, indep_var_vals::AbstractVector{<:Number})

Text-mode "presentation": prints the independent variable values and the
current stimulus parameters, then waits for one response from the console — no
longer than the session's response window, which is reported as `:timeout`.
"""
function present_stimulus(engine::InteractiveEngine, stim_params::AbstractStimulusParameters, indep_var_vals::AbstractVector{<:Number})
    println("\nSTIMULUS  vars: $(indep_var_vals)")
    par_str = join(["$n=$(parameter_value(stim_params, n))" for n in parameter_names(stim_params)], ", ")
    println("          params: $par_str")
    return _await_console_response(engine.console, engine.timeout_s)
end
