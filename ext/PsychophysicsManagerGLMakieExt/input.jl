# Keyboard input of the stimulus window: the one place that translates a Makie
# key press into the abstract response coding. Other input devices belong in this
# file too. The channel the presses go into, and the
# wait on it, are the core's (`ChannelResponseSource`, `await_channel_response`).

"""
    response_from_key(key) -> Union{Int, Nothing}

Maps a Makie keyboard button to the abstract response coding used throughout
the package: `-1` and `+1` for the two directional answers, `0` for confirm.
Returns `nothing` for every key that is not a response key.
"""
function response_from_key(key)
    key == Keyboard.left && return -1
    key == Keyboard.right && return 1
    (key == Keyboard.enter || key == Keyboard.space) && return 0
    return nothing
end

"""
    attach_response_keys!(figure, channel) -> figure

Makes `figure`'s window a response device: every response key press (and key
repeat, so holding a key keeps adjusting) offers one `(response, timestamp)` pair
to `channel` ([`PsychophysicsManager.offer_response!`](@ref)). The window must have focus.
"""
function attach_response_keys!(figure, channel::Channel{Tuple{Int, Float64}})
    on(events(figure).keyboardbutton) do event
        if event.action == Keyboard.press || event.action == Keyboard.repeat
            value = response_from_key(event.key)
            value === nothing || offer_response!(channel, value)
        end
    end
    return figure
end
