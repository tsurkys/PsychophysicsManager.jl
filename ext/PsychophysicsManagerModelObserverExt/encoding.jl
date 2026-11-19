# Turning a presentation buffer into something a model can be shown. Shared by
# every backend: the encoding is part of the stimulus, not of the transport.

"""
    frame_to_png(frame::AbstractMatrix) -> Vector{UInt8}

Encodes a presentation buffer as an 8-bit grayscale PNG.

The canvas is indexed `canvas[x, y]` with `y` increasing upwards (what the
layout's `image!` expects), while a PNG's first row is the top of the picture, so
the buffer is transposed and flipped: the model sees the figure the same way up a
participant does.
"""
function frame_to_png(frame::AbstractMatrix)
    rows = reverse(permutedims(frame), dims = 1)
    gray = map(v -> v > zero(v) ? 0xff : 0x00, rows)
    buffer = IOBuffer()
    PNGFiles.save(buffer, gray)
    return take!(buffer)
end

"""
    frame_to_data_uri(frame::AbstractMatrix) -> String

The same PNG as a `data:` URI, which is how OpenAI-compatible APIs carry an
inline image.
"""
frame_to_data_uri(frame::AbstractMatrix) =
    "data:image/png;base64," * base64encode(frame_to_png(frame))

"""
    require_frame(question::ObserverQuestion) -> AbstractMatrix

The rendered presentation, or an error naming the fix. A networked observer must
never be asked to judge a presentation it was not shown.
"""
function require_frame(question::ObserverQuestion)
    frame = question.context.frame
    frame === nothing &&
        error("This observer needs the rendered presentation, but the engine reported " *
              "no frame. Present with OffscreenVisualEngine (or another engine whose " *
              "`last_frame` returns its buffer).")
    return frame
end

"""
    warn_if_resampled(width, height, limit)

Warns when a presentation is larger than the receiving API accepts unresized. A
larger raster is downscaled server-side, which for a figure built from 2-pixel
markers changes the stimulus rather than its quality. Warned about rather than
resized here: the fix is a smaller canvas, chosen by the experimenter.
"""
function warn_if_resampled(width::Integer, height::Integer, limit::Integer)
    if max(width, height) > limit
        @warn "Presentation is larger than the API accepts unresized; it will be " *
              "downscaled server-side and the model will not see the rendered pixels. " *
              "Render into a smaller canvas." size = (width, height) limit = limit
    end
    return nothing
end
