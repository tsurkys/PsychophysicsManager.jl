# One way to name an observer, so an experiment script never has to know which
# backend serves it or which extension provides that backend.

"""
    OBSERVER_CHANNELS

The channels [`model_observer`](@ref) accepts as an explicit `channel:model`
prefix. `:openrouter` and `:anthropic` are served by the model-observer
extension (`using HTTP, PNGFiles`).
"""
const OBSERVER_CHANNELS = (:simulated, :openrouter, :anthropic)

"""
    parse_observer_spec(spec) -> (channel::Symbol, model::String)

Splits an observer spec into the channel that serves it and the model name to
ask that channel for. See [`model_observer`](@ref) for the accepted forms.
"""
function parse_observer_spec(spec::AbstractString)
    text = strip(String(spec))
    isempty(text) && throw(ArgumentError("An observer spec must not be empty."))

    separator = findfirst(==(':'), text)
    if separator !== nothing
        channel = Symbol(text[1:prevind(text, separator)])
        model = String(text[nextind(text, separator):end])
        channel in OBSERVER_CHANNELS ||
            throw(ArgumentError("Unknown observer channel $(repr(String(channel))); " *
                                "use one of $(OBSERVER_CHANNELS)."))
        (channel === :simulated || !isempty(model)) ||
            throw(ArgumentError("$(channel): needs a model name, e.g. " *
                                "\"anthropic:claude-opus-5\"."))
        return channel, model
    end

    text == "simulated" && return :simulated, "simulated_observer"
    occursin('/', text) && return :openrouter, String(text)

    throw(ArgumentError("$(repr(text)) does not name an observer. Use a broker slug " *
                        "(\"anthropic/claude-opus-5\" → OpenRouter), a channel prefix " *
                        "(\"anthropic:claude-opus-5\" → the Claude Messages API), or " *
                        "\"simulated\". A bare model name is not guessed: the broker and " *
                        "the vendor's own API are different instruments."))
end

"""
    model_observer(spec; kwargs...) -> AbstractObserverBackend

The observer named by `spec`, constructed with `kwargs`:

| `spec` | Backend | Needs |
|---|---|---|
| `"simulated"` | [`SimulatedObserver`](@ref) | nothing — no network, no cost |
| `"anthropic/claude-opus-5"` (any `provider/model` slug) | `OpenRouterObserver` | `using HTTP, PNGFiles`; `OPENROUTER_API_KEY` |
| `"anthropic:claude-opus-5"` (channel prefix) | `ClaudeObserver` | `using HTTP, PNGFiles`; `ANTHROPIC_API_KEY` |

`"openrouter:<slug>"` and `"simulated:<anything>"` spell the channel out. A bare
model name — neither a slash nor a prefix — is rejected rather than assigned to
a channel.

Every networked channel takes `deliberation`, the experimental condition each of
them spells its own way (see [`DELIBERATION_LEVELS`](@ref)); remaining keywords
reach the backend unchanged.

```julia
backend = model_observer("simulated"; bias_per_distractor = 5.0, noise_sd = 12.0)
backend = model_observer("anthropic/claude-opus-5"; deliberation = :none)
backend = model_observer("anthropic:claude-opus-5"; deliberation = :low)
```

The networked channels validate their API key here, so a missing key stops the
run before a session is created rather than on the first trial.
"""
function model_observer(spec::AbstractString; kwargs...)
    channel, model = parse_observer_spec(spec)
    return model_observer(Val(channel), model; kwargs...)
end

model_observer(::Val{:simulated}, ::AbstractString; kwargs...) = SimulatedObserver(; kwargs...)

# Fallback for the channels the extension owns: reached only when it is not loaded.
model_observer(::Val{channel}, ::AbstractString; kwargs...) where {channel} =
    error("The $(channel) observer lives in a package extension that is not loaded. " *
          "Run `using HTTP, PNGFiles` first (install them with `] add HTTP PNGFiles`).")

"""
    DELIBERATION_LEVELS

How much thinking an observer is asked to do before it answers, ordered.

`:none` demands an immediate judgement; the graded levels let the model
deliberate first. This is an experimental condition, not a performance setting —
a model that cannot judge immediately cannot be measured in that condition at
all (see `docs/AI_OBSERVER.md`).

The experiment names the condition and the channel translates it: the broker
carries it as `reasoning`, the Claude API as `thinking` plus `effort`. Which of
the levels a given channel offers is its own business — see
[`check_deliberation`](@ref).
"""
const DELIBERATION_LEVELS = (:none, :minimal, :low, :medium, :high, :xhigh, :max)

"""
    check_deliberation(level, offered) -> level

`level`, or an error naming the conditions this channel can be asked for.

A level the channel cannot express is refused rather than rounded to a
neighbour: the data would then describe a condition other than the one the
experiment asked for, and nothing later could detect the substitution.
"""
function check_deliberation(level::Symbol, offered::Tuple)
    level in offered && return level
    throw(ArgumentError("deliberation = $(repr(level)) is not offered by this observer " *
                        "channel; it accepts $(offered)."))
end

"""
    refuse_vendor_deliberation(kwargs, names)

Rejects a channel's own name for the deliberation condition.

Passed alongside `deliberation`, such a keyword would reach the backend
constructor as a duplicate and silently win, leaving two names for one condition
and the experiment's word ignored.
"""
function refuse_vendor_deliberation(kwargs, names::Tuple)
    for name in names
        haskey(kwargs, name) &&
            throw(ArgumentError("Set the deliberation condition with `deliberation` " *
                                "(one of $(DELIBERATION_LEVELS)), not with `$name`, " *
                                "which names it the way this channel's API does."))
    end
    return nothing
end

"""
    require_api_key(name) -> String

The API key in `ENV[name]`, or an error naming the variable to export. Keys are
read from the environment only: `settings.toml` describes a machine and travels
with the experiment when it is copied or shared, and whether a given copy is
under version control is not something this package can know.
"""
function require_api_key(name::AbstractString)
    key = get(ENV, String(name), "")
    isempty(key) &&
        error("Set $name in the environment (`export $name=…`). An API key does not " *
              "belong in settings.toml, which is copied and shared with the experiment.")
    return String(key)
end
