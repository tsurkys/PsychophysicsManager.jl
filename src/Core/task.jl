# What the observer was asked, and what an answer means. Kept in the Core and
# ahead of `SessionContext`, which owns one: the question and the response
# coding describe the measurement, not who performed it, so a person and a
# program are asked in the same terms.
#
# In psychophysics the participant is the *observer*, human or model alike.

"""
    ObserverTask(instructions, options, positive_option)

The question put to the observer, fixed for a whole session.

`options` are the only answers that count as a response; anything else is
unusable (see [`ModelObserverSource`](@ref)). `positive_option` maps to the raw
response `+1`, so `ConstantStimuli` records it as `1` and aggregated means
read directly as the proportion of that answer.

`instructions` are the verbatim wording, stored with the session because the
exact words are part of the method: two wordings are two conditions, not two
attempts at the same one.
"""
struct ObserverTask
    instructions::String
    options::Tuple{String, String}
    positive_option::String

    # Inner constructor: the default one would bypass validation when handed
    # arguments that are already `String`s.
    function ObserverTask(instructions::AbstractString,
                          options::Tuple{<:AbstractString, <:AbstractString},
                          positive_option::AbstractString)
        opts = (String(options[1]), String(options[2]))
        opts[1] == opts[2] &&
            throw(ArgumentError("The two options must differ, got $(repr(opts[1])) twice."))
        positive = String(positive_option)
        positive in opts ||
            throw(ArgumentError("positive_option $(repr(positive)) is not one of $(opts)."))
        isempty(strip(instructions)) &&
            throw(ArgumentError("Instructions must not be empty."))
        return new(String(instructions), opts, positive)
    end
end

"""
    length_comparison_task(; options=("left", "right"), positive_option="right")

The default two-alternative forced-choice task for a length comparison: the
observer is shown one image and names the segment that looks longer.

The wording withholds everything the stimulus does not show — no pixel counts,
no parameter values, no mention of an illusion — so that the answer comes from
the picture rather than from arithmetic, and it forbids declining: a
psychometric function needs a choice on every trial.
"""
function length_comparison_task(; options::Tuple{<:AbstractString, <:AbstractString} = ("left", "right"),
                                positive_option::AbstractString = "right")
    a, b = options
    instructions = """
    The image shows a horizontal figure made of short vertical line segments on a \
    dark background. Three of those segments are the endpoints of two adjoining \
    intervals: the $(a) interval runs from the leftmost endpoint to the middle one, \
    the $(b) interval from the middle endpoint to the rightmost one. Any further \
    segments between endpoints are part of the figure and are not endpoints.

    Judge which of the two intervals looks longer to you, going by how the image \
    appears rather than by counting pixels or reasoning about the construction.

    Answer with exactly one word: "$(a)" or "$(b)". You must choose one even when \
    they look equal or nearly equal — guess if you have to. Do not explain.
    """
    return ObserverTask(instructions, options, positive_option)
end

"""
    negative_option(task::ObserverTask) -> String

The option that is not the task's `positive_option`, i.e. the one coded `-1`.
"""
negative_option(task::ObserverTask) =
    task.options[1] == task.positive_option ? task.options[2] : task.options[1]

"""
    response_code(task::ObserverTask, choice::AbstractString) -> Int

Maps a chosen option onto the abstract response coding: `+1` for the task's
`positive_option`, `-1` for the other one. Throws for anything else — an
unrecognized answer is missing data and must not reach a method.
"""
function response_code(task::ObserverTask, choice::AbstractString)
    choice == task.positive_option && return 1
    choice in task.options && return -1
    throw(ArgumentError("$(repr(choice)) is not one of the task's options $(task.options)."))
end
