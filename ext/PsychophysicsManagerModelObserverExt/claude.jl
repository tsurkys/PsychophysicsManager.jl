# Claude Messages API backend: the direct channel, with no broker between the
# experiment and the model.

"""
    CLAUDE_MAX_UNRESAMPLED_EDGE

Longest image edge the Messages API accepts without resizing.
"""
const CLAUDE_MAX_UNRESAMPLED_EDGE = 2576

const CLAUDE_ENDPOINT = "https://api.anthropic.com/v1/messages"
const CLAUDE_API_VERSION = "2023-06-01"

"""
    ClaudeObserver(; model="claude-opus-5", thinking=:disabled, ...)

A model observer backed by the Claude Messages API.

Each trial is one stateless request carrying the rendered stimulus as a PNG and
the task's instructions, answered under a JSON schema that admits only the task's
two options.

Keyword arguments:

- `model`: model id, e.g. `"claude-opus-5"`, `"claude-sonnet-5"`, `"claude-haiku-4-5"`.
- `thinking`: `:disabled` (default) asks for an immediate judgement; `:adaptive`
  lets the model deliberate first. This is an experimental manipulation, not a
  performance knob — record which one produced the data.
- `effort`: `nothing` (server default, `"high"`) or one of `"low"`, `"medium"`,
  `"high"`, `"xhigh"`, `"max"`. Disabled thinking is only accepted at `"high"`
  or below.
- `api_key`: read from `ENV["ANTHROPIC_API_KEY"]` by default.
- `transport`: the function that performs the request, replaceable in tests so
  the request shape can be checked without a network.

`model` is held for the whole session: a reply from anything else stops the run
(see [`enforce_pinned_model!`](@ref)) rather than being recorded.

Sampling temperature is not exposed: current Claude models reject `temperature`,
`top_p` and `top_k`, so response variability cannot be dialled in — measure it
with a pilot (see `docs/AI_OBSERVER.md`).
"""
Base.@kwdef struct ClaudeObserver <: AbstractObserverBackend
    model::String = "claude-opus-5"
    api_key::String = get(ENV, "ANTHROPIC_API_KEY", "")
    thinking::Symbol = :disabled
    effort::Union{Nothing, String} = nothing
    max_tokens::Int = 1024
    endpoint::String = CLAUDE_ENDPOINT
    api_version::String = CLAUDE_API_VERSION
    timeout_s::Float64 = 120.0
    transport::Function = claude_transport
end

"""
    CLAUDE_DELIBERATION

The deliberation conditions this API offers. `:minimal` is absent: the Messages
API grades thinking from `"low"` upwards, and an experiment asking for a level
it does not have is refused rather than served the nearest one.
"""
const CLAUDE_DELIBERATION = (:none, :low, :medium, :high, :xhigh, :max)

# `model_observer("anthropic:claude-opus-5"; …)` — the channel prefix, not a slug:
# this is the vendor's own API, with no broker between the experiment and the
# model. Here the experiment's `deliberation` becomes a `thinking` mode and,
# above `:none`, the effort it is spent at.
function model_observer(::Val{:anthropic}, model::AbstractString;
                        api_key::AbstractString = require_api_key("ANTHROPIC_API_KEY"),
                        deliberation::Symbol = :none, kwargs...)
    refuse_vendor_deliberation(kwargs, (:thinking, :effort))
    level = check_deliberation(deliberation, CLAUDE_DELIBERATION)
    return ClaudeObserver(; model = String(model), api_key = String(api_key),
                          thinking = level === :none ? :disabled : :adaptive,
                          effort = level === :none ? nothing : String(level),
                          kwargs...)
end

"""
    claude_deliberation(observer) -> String

The deliberation condition this observer realizes, read back from the two
request fields it was translated into.

Read back rather than stored: a stored level would sit beside the fields that
actually go into the request and could disagree with them, and the translation in
`model_observer(::Val{:anthropic}, …)` loses nothing — `:none` is the only level
served with thinking disabled.
"""
claude_deliberation(observer::ClaudeObserver) =
    observer.thinking === :disabled ? "none" :
    observer.effort === nothing ? "server-default" : observer.effort

function describe_backend(observer::ClaudeObserver)
    return Dict{String, Any}(
        "backend" => "ClaudeObserver",
        "model" => observer.model,
        "deliberation" => claude_deliberation(observer),
        "thinking" => String(observer.thinking),
        "effort" => observer.effort === nothing ? "server-default" : observer.effort,
        "max_tokens" => observer.max_tokens,
        "endpoint" => observer.endpoint,
        "anthropic_version" => observer.api_version,
        "conversation_history" => "none (one stateless request per trial)",
        "response_format" => "json_schema (forced choice)",
        "sampling_parameters" => "none (temperature/top_p/top_k are rejected by current models)",
    )
end

"""
    build_claude_request(observer::ClaudeObserver, question::ObserverQuestion) -> String

The JSON body of one trial's request, built separately from the transport so the
exact bytes sent to the model can be inspected and tested.
"""
function build_claude_request(observer::ClaudeObserver, question::ObserverQuestion)
    frame = require_frame(question)
    width, height = size(frame)
    warn_if_resampled(width, height, CLAUDE_MAX_UNRESAMPLED_EDGE)
    image = base64encode(frame_to_png(frame))

    body = Dict{String, Any}(
        "model" => observer.model,
        "max_tokens" => observer.max_tokens,
        # One user turn, rebuilt every trial: no history, so the model cannot see
        # earlier stimuli or its own earlier answers.
        "messages" => [Dict{String, Any}(
            "role" => "user",
            "content" => [
                Dict{String, Any}("type" => "image",
                                  "source" => Dict{String, Any}("type" => "base64",
                                                                "media_type" => "image/png",
                                                                "data" => image)),
                Dict{String, Any}("type" => "text", "text" => question.task.instructions),
            ],
        )],
        "output_config" => Dict{String, Any}(
            "format" => Dict{String, Any}(
                "type" => "json_schema",
                "schema" => forced_choice_schema(question),
            ),
        ),
    )

    if observer.thinking === :adaptive
        body["thinking"] = Dict{String, Any}("type" => "adaptive")
    elseif observer.thinking === :disabled
        body["thinking"] = Dict{String, Any}("type" => "disabled")
    else
        throw(ArgumentError("thinking must be :disabled or :adaptive, got $(repr(observer.thinking))."))
    end

    observer.effort === nothing || (body["output_config"]["effort"] = observer.effort)

    return JSON3.write(body)
end

"""
    claude_transport(observer, body) -> (status::Int, payload::String)

Default transport: one POST to the Messages API. Network and protocol failures
are returned as a status of `0` and a message rather than thrown, so the retry
policy stays in `ModelObserverSource`.
"""
function claude_transport(observer::ClaudeObserver, body::AbstractString)
    headers = [
        "x-api-key" => observer.api_key,
        "anthropic-version" => observer.api_version,
        "content-type" => "application/json",
    ]
    return post_json(observer.endpoint, headers, body, observer.timeout_s)
end

function parse_claude_answer(question::ObserverQuestion, status::Int,
                             payload::AbstractString, latency_s::Float64)
    metadata = Dict{String, Any}("backend" => "ClaudeObserver",
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

    haskey(parsed, :model) && (metadata["responding_model"] = String(parsed.model))
    haskey(parsed, :id) && (metadata["request_id"] = String(parsed.id))
    if haskey(parsed, :usage)
        usage = parsed.usage
        for key in (:input_tokens, :output_tokens, :cache_read_input_tokens)
            haskey(usage, key) && (metadata[String(key)] = usage[key])
        end
    end
    stop_reason = haskey(parsed, :stop_reason) && parsed.stop_reason !== nothing ?
                  String(parsed.stop_reason) : ""
    isempty(stop_reason) || (metadata["stop_reason"] = stop_reason)

    # A refusal is missing data: the schema does not hold, so `content` must not
    # be read as an answer (this check has to come before touching it).
    stop_reason == "refusal" && return unusable("refusal")

    haskey(parsed, :content) || return unusable("no_content")
    text = ""
    for block in parsed.content
        if haskey(block, :type) && String(block.type) == "text" && haskey(block, :text)
            text = String(block.text)
            break
        end
    end
    isempty(text) && return unusable("no_text_block")

    return choice_from_json(question, text, latency_s, metadata, unusable)
end

"""
    enforce_pinned_model!(observer, answer) -> answer

Stops the run when the reply came from a model other than the one asked for.

The same reasoning as [`enforce_pinned_route!`](@ref), with no provider to pin:
this is the vendor's own API.

One resolution is not a substitution: an alias answers under its dated release,
so `"claude-opus-5"` replying as `"claude-opus-5-20260201"` is the same model. A
date suffix is therefore accepted and anything else after the name — a size, a
variant — is not. Pinning the dated id outright avoids the question.
"""
function enforce_pinned_model!(observer::ClaudeObserver, answer::ObserverAnswer)
    responded = get(answer.metadata, "responding_model", nothing)
    (responded === nothing || responded == observer.model) && return answer

    suffix = chopprefix(responded, observer.model)
    resolved_alias = suffix != responded && length(suffix) > 1 &&
                     suffix[1] == '-' && all(isdigit, suffix[2:end])
    resolved_alias && return answer

    error("The Claude API answered as model $(repr(responded)), but this session " *
          "is pinned to $(repr(observer.model)). The measurement stopped rather " *
          "than mixing two models. Rerun asking for the id that actually answered.")
end

function query_observer(observer::ClaudeObserver, question::ObserverQuestion)
    isempty(observer.api_key) &&
        error("ClaudeObserver has no API key. Export ANTHROPIC_API_KEY, or pass " *
              "`api_key` explicitly. Do not put it in settings.toml.")

    body = build_claude_request(observer, question)
    started = time()
    status, payload = observer.transport(observer, body)
    latency = time() - started

    return enforce_pinned_model!(observer,
                                 parse_claude_answer(question, status, payload, latency))
end
