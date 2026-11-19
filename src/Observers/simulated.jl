# A model observer with a known psychometric rule. It answers from the stimulus
# *description*, not from the rendered pixels, and is therefore not a model of
# perception: it exists so that the whole chain — method, loop, checkpoints,
# aggregation, fit — can be exercised headlessly against a ground truth, and so
# that a networked observer has something to be compared with.

"""
    segment_lengths(params::MarkerLayout) -> Vector{Float64}

Lengths of the intervals between consecutive main-sequence positions of a marker
layout, in stimulus units. Distances are Euclidean, so the result is unaffected
by tilt, mirroring, or the chosen anchor.
"""
function segment_lengths(params::MarkerLayout)
    _, _, px, py = calculate_marker_layout(params)
    length(px) >= 2 ||
        throw(ArgumentError("Layout $(repr(params.StimConfig)) has no interval to compare."))
    return [hypot(px[i + 1] - px[i], py[i + 1] - py[i]) for i in 1:(length(px) - 1)]
end

"""
    SimulatedObserver(; bias_per_distractor=0.0, noise_sd=1.0, lapse_rate=0.0,
                      positive_interval=2, rng=Random.default_rng())

An observer that compares two intervals of a marker layout with a fixed bias and
Gaussian internal noise, so its threshold is known in advance.

The decision variable on each trial is

    d = (length[positive_interval] - length[other]) - bias_per_distractor * DistrN + noise

and the observer answers the task's `positive_option` when `d > 0`. With
`lapse_rate` > 0 it answers at random on that proportion of trials.

Sign convention: a positive `bias_per_distractor` means each distractor makes the
*other* interval look longer, so the positive interval has to be physically
longer to be judged equal. For the filled-space layout `"d r t"` — distractors
filling the reference interval, `Diff` extending the test interval — the point of
subjective equality therefore sits at `Diff = bias_per_distractor * DistrN`,
which is what a fit of the simulated data must recover.

`positive_interval` (1 or 2) says which interval the task's `positive_option`
names; keep it consistent with the wording and with the layout's drawing order.
"""
struct SimulatedObserver <: AbstractObserverBackend
    bias_per_distractor::Float64
    noise_sd::Float64
    lapse_rate::Float64
    positive_interval::Int
    rng::Random.AbstractRNG
end

function SimulatedObserver(; bias_per_distractor::Real = 0.0, noise_sd::Real = 1.0,
                           lapse_rate::Real = 0.0, positive_interval::Integer = 2,
                           rng::Random.AbstractRNG = Random.default_rng())
    noise_sd > 0 || throw(ArgumentError("noise_sd must be positive, got $noise_sd."))
    0.0 <= lapse_rate <= 1.0 ||
        throw(ArgumentError("lapse_rate must be in [0, 1], got $lapse_rate."))
    positive_interval in (1, 2) ||
        throw(ArgumentError("positive_interval must be 1 or 2, got $positive_interval."))
    return SimulatedObserver(Float64(bias_per_distractor), Float64(noise_sd),
                             Float64(lapse_rate), Int(positive_interval), rng)
end

function query_observer(observer::SimulatedObserver, question::ObserverQuestion)
    params = question.context.stim_par
    params isa MarkerLayout ||
        error("SimulatedObserver compares marker-layout intervals; it was given " *
              "$(typeof(params)). Implement query_observer for that stimulus type.")

    lengths = segment_lengths(params)
    length(lengths) == 2 ||
        throw(ArgumentError("SimulatedObserver needs exactly two intervals, " *
                            "$(repr(params.StimConfig)) produced $(length(lengths))."))

    other = observer.positive_interval == 1 ? 2 : 1
    difference = lengths[observer.positive_interval] - lengths[other]
    illusion = observer.bias_per_distractor * params.DistrN
    d = difference - illusion + observer.noise_sd * randn(observer.rng)

    lapsed = rand(observer.rng) < observer.lapse_rate
    positive = lapsed ? rand(observer.rng) < 0.5 : d > 0

    task = question.task
    choice = positive ? task.positive_option : negative_option(task)

    return ObserverAnswer(choice = choice, raw = choice, latency_s = 0.0,
                          metadata = Dict{String, Any}(
                              "backend" => "SimulatedObserver",
                              "decision_variable" => d,
                              "lapsed" => lapsed,
                          ))
end
