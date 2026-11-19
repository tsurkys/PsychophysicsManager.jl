# Built-in headless engine: emulates both the display and the participant, so
# a full session runs without any hardware. For a render-only engine driven by
# a deterministic script, pair a real engine with `ScriptedResponseSource`.

struct EmulatorEngine <: AbstractStimulusEngine end

function initialize_engine(::Type{EmulatorEngine}, stim_params::AbstractStimulusParameters, config::DisplayConfig)
    return EmulatorEngine()
end

function present_stimulus(engine::EmulatorEngine, stim_params::AbstractStimulusParameters, indep_var_vals::AbstractVector{<:Number})
    # We simulate stimulus drawing; the emulator models a fully reporting
    # engine (response + onset + response timestamp)
    t_onset = time()

    # Random response strategy:
    r = rand()
    if r < 0.2
        resp = 0 # 20% chance to confirm (for adjustment)
    elseif r < 0.6
        resp = 1 # 40% chance for +1
    else
        resp = -1 # 40% chance for -1
    end

    return PresentationResult(response = resp, onset = t_onset,
                              timestamp_response = time())
end
