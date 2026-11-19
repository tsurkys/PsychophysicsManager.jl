# Type registries. Session files identify concrete types by
# name; these registries map the names back to types when loading, replacing
# module reflection. Built-in types are registered at the bottom of
# PsychophysicsManager.jl; package extensions register theirs in their `__init__`;
# users register custom types right after defining them.

const METHOD_REGISTRY   = Dict{Symbol, Type}()
const STIMULUS_REGISTRY = Dict{Symbol, Type}()
const ENGINE_REGISTRY   = Dict{Symbol, Type}()
const ENGINE_BACKEND_HINTS = Dict{Symbol, Vector{Symbol}}()
const STIMULUS_ENGINES  = Dict{Symbol, Symbol}()
const STIMULUS_DESCRIPTIONS = Dict{Symbol, String}()

# Registries key on the short type name (that is what session files store).
# Re-registering the same name with a DIFFERENT type changes how existing
# files load, so it is allowed but loudly announced.
function _register_type!(registry::Dict{Symbol, Type}, T::Type)
    name = nameof(T)
    if haskey(registry, name) && registry[name] !== T
        @warn "Type name '$name' is already registered to $(registry[name]) and is being " *
              "overwritten with $T. Saved sessions naming '$name' will now load as the new type."
    end
    registry[name] = T
    return T
end

"""
    register_method_type!(T)

Makes a custom `AbstractPsychoMethod` subtype loadable from session files.
Call once after defining the type.
"""
register_method_type!(T::Type{<:AbstractPsychoMethod}) = _register_type!(METHOD_REGISTRY, T)

"""
    register_stimulus_type!(T)

Makes a custom `AbstractStimulusParameters` subtype loadable from session files.
Call once after defining the type.
"""
register_stimulus_type!(T::Type{<:AbstractStimulusParameters}) = _register_type!(STIMULUS_REGISTRY, T)

"""
    register_stimulus!(T; engine, backend = Symbol[], description = "")

Registers a stimulus type with the engine that presents it, named so that the engine is
known before its backend is loaded: `engine` is the engine type's name, `backend` the
packages that load it ([`register_engine_backend!`](@ref)), and `description` a line the
dashboard shows with the stimulus. A type that builds with no arguments is then chosen
by name ([`selectable_stimuli`](@ref)). Call once after defining the type.

```julia
register_stimulus!(MyStimulus; engine = :GeometryVisualEngine, backend = [:GLMakie],
                   description = "Two flashes, the second displaced")
```
"""
function register_stimulus!(T::Type{<:AbstractStimulusParameters};
                            engine::Symbol,
                            backend::Union{Symbol, Vector{Symbol}} = Symbol[],
                            description::AbstractString = "")
    register_stimulus_type!(T)
    STIMULUS_ENGINES[nameof(T)] = engine
    STIMULUS_DESCRIPTIONS[nameof(T)] = String(description)
    packages = backend isa Symbol ? [backend] : backend
    isempty(packages) || register_engine_backend!(engine, packages)
    return T
end

# What a stimulus was registered with: its engine's name, or `nothing` for a type
# registered without one, and its description
stimulus_engine_name(stim_par::AbstractStimulusParameters) =
    get(STIMULUS_ENGINES, nameof(typeof(stim_par)), nothing)
stimulus_description(stim_par::AbstractStimulusParameters) =
    get(STIMULUS_DESCRIPTIONS, nameof(typeof(stim_par)), "")

"""
    register_engine_type!(T)

Makes a custom `AbstractStimulusEngine` subtype restorable via `restore_engine`.
Call once after defining the type (extensions do this when their backend loads).
"""
register_engine_type!(T::Type{<:AbstractStimulusEngine}) = _register_type!(ENGINE_REGISTRY, T)

"""
    register_engine_backend!(engine_name::Symbol, packages::Vector{Symbol})

Associates a saved engine name with the packages that activate its backend. Register
the hint alongside a custom engine so `run_session_from_file` can load the backend
before restoring a session that names that engine.
"""
function register_engine_backend!(engine_name::Symbol, packages::Vector{Symbol})
    if haskey(ENGINE_BACKEND_HINTS, engine_name) &&
       ENGINE_BACKEND_HINTS[engine_name] != packages
        @warn "Engine backend hint '$engine_name' is already registered to " *
              "$(ENGINE_BACKEND_HINTS[engine_name]) and is being overwritten with $packages."
    end
    ENGINE_BACKEND_HINTS[engine_name] = copy(packages)
    return engine_name
end

"""
    activate_engine_backend!(engine_name::String)

Loads the packages registered for `engine_name` so that its
engine type is available before a saved session naming it is restored. A name
that is already registered needs nothing.
"""
function activate_engine_backend!(engine_name::String)
    engine_symbol = Symbol(engine_name)
    haskey(ENGINE_REGISTRY, engine_symbol) && return nothing

    packages = get(ENGINE_BACKEND_HINTS, engine_symbol, nothing)
    packages === nothing && error(
        "Stimulus engine '$engine_name' is not registered and has no backend hint. " *
        "Load and register its engine type, then register its backend with " *
        "PsychophysicsManager.register_engine_backend!(:$engine_symbol, [:YourBackendPackage]).",
    )

    for package in packages
        try
            # Resolve in Main's environment: backend packages are the USER'S
            # dependencies. Weakdeps are not loadable from the package's own
            # context, so resolving via @__MODULE__ would fail even with the
            # backend installed.
            Base.require(Main, package)
        catch err
            error("Stimulus engine '$engine_name' requires backend package '$package', " *
                  "which could not be loaded. Install it in the active environment and retry. " *
                  "Original error: $(sprint(showerror, err))")
        end
    end

    haskey(ENGINE_REGISTRY, engine_symbol) || error(
        "Backend packages $(packages) were loaded, but stimulus engine '$engine_name' " *
        "was not registered. Ensure the backend calls PsychophysicsManager.register_engine_type! " *
        "for that engine.",
    )
    return nothing
end

function registered_type(registry::Dict{Symbol, Type}, kind::String, name::Symbol, hint::String)
    haskey(registry, name) && return registry[name]
    known = join(sort!(string.(collect(keys(registry)))), ", ")
    error("Unknown $kind type '$name'. Registered types: $known. $hint")
end
