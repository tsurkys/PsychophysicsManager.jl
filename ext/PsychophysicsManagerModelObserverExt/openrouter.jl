# OpenRouter backend: one API key, one request shape, many model families — the
# same stimulus, instructions and forced-choice schema put to Claude, GPT, Gemini
# or an open-weight model, so a difference in the data is a difference between
# models rather than between the harnesses around them.
#
# A broker routes, though: the same slug may be served by different upstream
# providers. Routing is pinned by construction — see `allow_fallbacks` and
# `require_parameters` below.

const OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

"""
    OPENROUTER_DEFAULT_MAX_EDGE

Default longest-edge guard for images sent through OpenRouter.

Resizing behaviour belongs to whichever upstream provider serves the request and
is not knowable from this side. The default is the documented Claude limit; treat
it as unverified for any other route and confirm per model in the pilot.
"""
const OPENROUTER_DEFAULT_MAX_EDGE = 2576

"""
    OpenRouterObserver(; model="anthropic/claude-opus-5", reasoning=:none, ...)

A model observer backed by OpenRouter's OpenAI-compatible chat completions API.

Each trial is one stateless request carrying the rendered stimulus as a PNG data
URI and the task's instructions, answered under a JSON schema that admits only
the task's two options.

Keyword arguments:

- `model`: an OpenRouter model slug, `"provider/model-name"` — e.g.
  `"anthropic/claude-opus-5"`, `"openai/gpt-5"`, `"google/gemini-2.5-pro"`.
  Pin an exact version rather than a floating alias: a slug that silently moves
  to a new release makes two sessions incomparable.
- `reasoning`: `:none` (default) asks for an immediate judgement with reasoning
  genuinely off; `:minimal`, `:low`, `:medium`, `:high`, `:xhigh` or `:max` let
  the model deliberate first. An experimental manipulation, not a performance
  knob.
- `provider_order`: upstream providers to try, most preferred first, or
  `nothing` to let OpenRouter choose. Pin it when a measurement has to be
  repeatable.
- `allow_fallbacks`: `false` by default, so a request either runs where it was
  pinned or fails — a silent reroute mid-session would change the instrument
  without changing the record.
- `require_parameters`: `true` by default, so the request is only routed to
  endpoints that honour every parameter sent, including the forced-choice
  schema. Without it a provider may ignore `response_format` and answer in
  prose, which this design counts as missing data.
- `api_key`: read from `ENV["OPENROUTER_API_KEY"]` by default.
- `transport`: the function that performs the request, replaceable in tests so
  the request shape can be checked without a network.

Whatever these settle on is held for the whole session: a substituted model or a
mid-session reroute stops the run (see [`enforce_pinned_route!`](@ref)) rather
than being recorded.

`temperature` is exposed here — many models reachable through the broker accept
it, unlike the direct Claude API — but defaults to unset, so nothing is claimed
about a model's sampling unless it is deliberately set. It is the one available
handle on response variability, which a psychometric function needs.
"""
Base.@kwdef struct OpenRouterObserver <: AbstractObserverBackend
    model::String = "anthropic/claude-opus-5"
    api_key::String = get(ENV, "OPENROUTER_API_KEY", "")
    reasoning::Symbol = :none
    temperature::Union{Nothing, Float64} = nothing
    max_tokens::Int = 1024
    provider_order::Union{Nothing, Vector{String}} = nothing
    allow_fallbacks::Bool = false
    require_parameters::Bool = true
    max_image_edge::Int = OPENROUTER_DEFAULT_MAX_EDGE
    endpoint::String = OPENROUTER_ENDPOINT
    timeout_s::Float64 = 180.0
    transport::Function = openrouter_transport
    # Fixed by the first reply and checked against every later one; see
    # `enforce_pinned_route!`. Not a setting — do not pass it.
    served_by::Base.RefValue{Union{Nothing, String}} = Ref{Union{Nothing, String}}(nothing)
end

"""
    OPENROUTER_REASONING_LEVELS

What the broker's `reasoning.effort` accepts, which is every deliberation
condition this package names — so the vocabulary is [`DELIBERATION_LEVELS`](@ref)
itself rather than a second copy of it.
"""
const OPENROUTER_REASONING_LEVELS = DELIBERATION_LEVELS

# `model_observer("anthropic/claude-opus-5"; …)`: the key is resolved here so a
# missing one stops the run before a session exists, not on the first trial, and
# the experiment's `deliberation` becomes this API's `reasoning`.
function model_observer(::Val{:openrouter}, model::AbstractString;
                        api_key::AbstractString = require_api_key("OPENROUTER_API_KEY"),
                        deliberation::Symbol = :none, kwargs...)
    refuse_vendor_deliberation(kwargs, (:reasoning,))
    return OpenRouterObserver(; model = String(model), api_key = String(api_key),
                              reasoning = check_deliberation(deliberation,
                                                             OPENROUTER_REASONING_LEVELS),
                              kwargs...)
end

function describe_backend(observer::OpenRouterObserver)
    return Dict{String, Any}(
        "backend" => "OpenRouterObserver",
        "model" => observer.model,
        # The condition under the name every channel shares, beside the request
        # field that carries it.
        "deliberation" => String(observer.reasoning),
        "reasoning_effort" => String(observer.reasoning),
        "temperature" => observer.temperature === nothing ? "unset" : observer.temperature,
        "max_tokens" => observer.max_tokens,
        "provider_order" => observer.provider_order === nothing ? "broker-chosen" :
                            observer.provider_order,
        "allow_fallbacks" => observer.allow_fallbacks,
        "require_parameters" => observer.require_parameters,
        "max_image_edge" => observer.max_image_edge,
        "endpoint" => observer.endpoint,
        "conversation_history" => "none (one stateless request per trial)",
        "response_format" => "json_schema strict (forced choice)",
    )
end

"""
    build_openrouter_request(observer, question) -> String

The JSON body of one trial's request, built separately from the transport so the
exact bytes sent to the model can be inspected and tested.
"""
function build_openrouter_request(observer::OpenRouterObserver, question::ObserverQuestion)
    observer.reasoning in OPENROUTER_REASONING_LEVELS ||
        throw(ArgumentError("reasoning must be one of $(OPENROUTER_REASONING_LEVELS), " *
                            "got $(repr(observer.reasoning))."))

    frame = require_frame(question)
    width, height = size(frame)
    warn_if_resampled(width, height, observer.max_image_edge)

    body = Dict{String, Any}(
        "model" => observer.model,
        # `max_tokens`, not the documented-as-preferred `max_completion_tokens`:
        # with `require_parameters` on, routing filters against each endpoint's
        # declared parameter list, and the Google endpoints declare `max_tokens`
        # only — the newer name makes every endpoint drop out with a 404.
        "max_tokens" => observer.max_tokens,
        # One user turn, rebuilt every trial: no history, so the model cannot see
        # earlier stimuli or its own earlier answers.
        "messages" => [Dict{String, Any}(
            "role" => "user",
            "content" => [
                Dict{String, Any}("type" => "image_url",
                                  "image_url" => Dict{String, Any}(
                                      "url" => frame_to_data_uri(frame))),
                Dict{String, Any}("type" => "text", "text" => question.task.instructions),
            ],
        )],
        "response_format" => Dict{String, Any}(
            "type" => "json_schema",
            "json_schema" => Dict{String, Any}(
                "name" => "forced_choice",
                # Providers with a native strict mode then enforce the schema
                # rather than treating it as a hint.
                "strict" => true,
                "schema" => forced_choice_schema(question),
            ),
        ),
        # `effort: "none"` genuinely disables reasoning. `exclude: true` would
        # only hide it while the model still deliberates — a different condition.
        "reasoning" => Dict{String, Any}("effort" => String(observer.reasoning)),
        "provider" => Dict{String, Any}(
            "allow_fallbacks" => observer.allow_fallbacks,
            "require_parameters" => observer.require_parameters,
        ),
    )

    observer.provider_order === nothing ||
        (body["provider"]["order"] = observer.provider_order)
    observer.temperature === nothing ||
        (body["temperature"] = observer.temperature)

    return JSON3.write(body)
end

function openrouter_transport(observer::OpenRouterObserver, body::AbstractString)
    headers = [
        "Authorization" => "Bearer " * observer.api_key,
        "Content-Type" => "application/json",
        # Optional; asks the broker to surface routing details in the response.
        # Nothing here depends on it — routing is pinned in the request instead.
        "X-OpenRouter-Metadata" => "enabled",
    ]
    return post_json(observer.endpoint, headers, body, observer.timeout_s)
end

function parse_openrouter_answer(question::ObserverQuestion, status::Int,
                                 payload::AbstractString, latency_s::Float64)
    metadata = Dict{String, Any}("backend" => "OpenRouterObserver",
                                 "http_status" => status,
                                 "image_size" => collect(size(question.context.frame)))
    unusable(reason) = ObserverAnswer(choice = nothing, raw = payload, latency_s = latency_s,
                                      metadata = merge(metadata,
                                                       Dict{String, Any}("failure" => reason)))

    status == 200 || return unusable(status == 0 ? "transport_error" : "http_$(status)")

    parsed = try
        JSON3.read(payload)
    catch
        return unusable("unparseable_response")
    end

    # A broker can answer 200 with an error object in the body
    haskey(parsed, :error) && return unusable("api_error")

    # Which model actually served the request; with fallbacks enabled this can
    # differ from the one asked for, and the data must say which it was.
    haskey(parsed, :model) && (metadata["responding_model"] = String(parsed.model))
    haskey(parsed, :id) && (metadata["generation_id"] = String(parsed.id))
    haskey(parsed, :provider) && (metadata["provider"] = String(parsed.provider))
    if haskey(parsed, :usage)
        usage = parsed.usage
        for key in (:prompt_tokens, :completion_tokens, :total_tokens, :cost, :is_byok)
            haskey(usage, key) && usage[key] !== nothing && (metadata[String(key)] = usage[key])
        end
    end

    (haskey(parsed, :choices) && !isempty(parsed.choices)) ||
        return unusable("no_choices")
    first_choice = parsed.choices[1]

    if haskey(first_choice, :finish_reason) && first_choice.finish_reason !== nothing
        finish_reason = String(first_choice.finish_reason)
        metadata["finish_reason"] = finish_reason
        # A filtered or truncated completion is missing data: whatever text came
        # with it is not an answer to the question that was asked.
        finish_reason == "content_filter" && return unusable("content_filter")
        finish_reason == "length" && return unusable("truncated")
    end

    (haskey(first_choice, :message) && haskey(first_choice.message, :content) &&
     first_choice.message.content !== nothing) || return unusable("no_content")

    text = String(first_choice.message.content)
    isempty(strip(text)) && return unusable("empty_content")

    return choice_from_json(question, text, latency_s, metadata, unusable)
end

"""
    enforce_pinned_route!(observer, answer) -> answer

Stops the run when the broker did not answer from where it was told to.

Two substitutions can change the instrument without changing anything the data
would show: the broker can serve a model other than the slug asked for, and
unless `provider_order` pins one it chooses the upstream provider per request.
Neither is recorded and continued — a session measured by two instruments cannot
be repaired afterwards.

The first reply fixes `served_by`; every later reply must match it. A reply
carrying no routing fields is left alone: a missing field is not evidence of a
substitution, and such a reply is already handled as an unusable answer.
"""
function enforce_pinned_route!(observer::OpenRouterObserver, answer::ObserverAnswer)
    responded = get(answer.metadata, "responding_model", nothing)
    responded === nothing || responded == observer.model ||
        error("OpenRouter answered as model $(repr(responded)), but this session is " *
              "pinned to $(repr(observer.model)). The measurement stopped rather than " *
              "mixing two models. Rerun asking for the slug the broker actually serves.")

    provider = get(answer.metadata, "provider", nothing)
    provider === nothing && return answer

    if observer.served_by[] === nothing
        observer.served_by[] = provider
    elseif observer.served_by[] != provider
        error("OpenRouter rerouted mid-session: this run began on provider " *
              "$(repr(observer.served_by[])) and this request was served by " *
              "$(repr(provider)). The trials collected so far were not all measured " *
              "by the same instrument. Rerun with " *
              "`provider_order = [$(repr(observer.served_by[]))]` to hold the route.")
    end
    return answer
end

function query_observer(observer::OpenRouterObserver, question::ObserverQuestion)
    isempty(observer.api_key) &&
        error("OpenRouterObserver has no API key. Export OPENROUTER_API_KEY, or pass " *
              "`api_key` explicitly. Do not put it in settings.toml.")

    body = build_openrouter_request(observer, question)
    started = time()
    status, payload = observer.transport(observer, body)
    latency = time() - started

    return enforce_pinned_route!(observer,
                                 parse_openrouter_answer(question, status, payload, latency))
end
