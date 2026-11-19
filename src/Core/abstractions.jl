# Root abstract types shared by all modules. Included first so that every
# module (Core, Methods, Stimuli, IO) can reference them in field and
# signature annotations.

abstract type AbstractPsychoMethod end
abstract type AbstractStimulusEngine end
abstract type AbstractStimulusParameters end

"""
    type_name(x) -> String

Short type name without module qualification (e.g. `"Adjustment"`).
Used for engine/method identification in session files and filenames.
"""
type_name(x) = string(nameof(typeof(x)))
