# The two steps every networked backend shares: getting the request out, and
# turning the model's constrained JSON reply into a choice.

"""
    post_json(endpoint, headers, body, timeout_s) -> (status::Int, payload::String)

One POST, with failures reported rather than thrown: a network or protocol error
comes back as status `0` and the error text. Whether that is worth retrying is
the response source's decision, not the transport's, so nothing here raises.
"""
function post_json(endpoint::AbstractString, headers, body::AbstractString, timeout_s::Real)
    try
        response = HTTP.post(endpoint, headers, body;
                             status_exception = false,
                             readtimeout = round(Int, timeout_s),
                             retry = false)
        return (Int(response.status), String(response.body))
    catch err
        return (0, sprint(showerror, err))
    end
end

"""
    choice_from_json(question, text, latency_s, metadata, unusable) -> ObserverAnswer

Reads the forced choice out of the model's reply.

Each failure is named separately — unparseable, field missing, not one of the
options — because "the trial produced no answer" is not a useful record. A schema
constrains a cooperative model but guarantees nothing, so the answer is
re-checked against the task's own options here.
"""
function choice_from_json(question::ObserverQuestion, text::AbstractString,
                          latency_s::Float64, metadata::Dict{String, Any}, unusable)
    answer = try
        JSON3.read(text)
    catch
        return unusable("unparseable_choice")
    end
    haskey(answer, :longer) || return unusable("missing_choice_field")

    choice = String(answer.longer)
    choice in question.task.options || return unusable("choice_not_an_option")

    return ObserverAnswer(choice = choice, raw = text, latency_s = latency_s,
                          metadata = metadata)
end

"""
    forced_choice_schema(question::ObserverQuestion) -> Dict{String, Any}

The JSON schema both backends constrain the answer with: one required field
naming one of the task's two options, and nothing else permitted.
"""
function forced_choice_schema(question::ObserverQuestion)
    return Dict{String, Any}(
        "type" => "object",
        "properties" => Dict{String, Any}(
            "longer" => Dict{String, Any}("type" => "string",
                                          "enum" => collect(question.task.options)),
        ),
        "required" => ["longer"],
        "additionalProperties" => false,
    )
end
