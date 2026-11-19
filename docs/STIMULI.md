# Stimulus Systems (PsychophysicsManager.jl)

This document describes the example stimuli shipped with the package: marker
layouts, the two-interval Gabor patch, and the auditory filled-time stimulus. They
are examples and references for writing a stimulus program, not calibrated
instruments: how a stimulus is presented — calibration, luminance and contrast,
onset timing — is the responsibility of the stimulus program, and the status notes
below say what these examples do not do.

## 1. Overview
The system is divided into two parts:
1.  **`src/Stimuli/`**: Pure layout mathematics and rasterization — positions and pixels, no display (always available).
2.  **`ext/PsychophysicsManagerGLMakieExt/`**: Visual presentation using `GLMakie`. Load the backend first — `using GLMakie` — which activates the extension and registers `GeometryVisualEngine` as the default engine for `MarkerLayout` and `Gabor`.

## 2. Stimulus Parameters (`MarkerLayout`)

`MarkerLayout` describes a parametric layout of markers along an axis: the
`StimConfig` grammar composes reference and test segments, gaps, and filler runs,
which tilt, mirroring, and anchoring turn into concrete positions. It is
general enough for filled-space
(Oppel-Kundt) figures, Müller-Lyer variants, and plain length comparisons — the
type names the layout, not one paradigm.

Key fields:

### Layout Controls
*   `StimConfig`: A string defining the layout. Options: `r` (Reference), `t` (Test), `d` (Distractors), `-d` (distractors drawn backwards), `g` (Gap).
    *   Example: `"d r g t"` puts distractors first, then a reference dot, a gap, and finally a test dot.
    *   Anything else is an error, not a skipped token: `"d r T"` would otherwise draw a figure with no test segment and look like a valid stimulus.
*   `Ref`: Length/position of the reference part.
*   `Diff`: Difference added to the reference; the test segment (`t`) length is always derived as `Ref + Diff * DiffInvert` (there is no separate test-length parameter). `Diff = 0` is therefore physical equality, from which an adjustment's constant error is measured (`constant_errors`).
*   `DistrN`: Number of distractors.
*   `Step`: Distance between distractors (if 0, auto-calculated as `Ref/(DistrN+1)`).
*   `Angle`: Tilt of the distractor run, in units of half a degree (the legacy `stimul.m` formula): `Angle = 60` tilts it by 30°.
*   `StimMirror`: Reverses the layout axis, so the segments `StimConfig` lists left to right are drawn right to left. This is the left/right counterbalancing control an asymmetric figure needs — a genuine percept survives the mirror, a constant side preference does not — and it replaces writing a second `StimConfig` by hand (`"d r t"` mirrored is the figure `"t r -d"` draws). The main sequence keeps its order under the mirror, so segment 2 names the same segment either way: a response coding tied to the segment stays valid, while instructions naming a side (`"left"`/`"right"`) must follow the mirror.
*   `Anchor`: How the stimulus is positioned relative to the origin. One of the four below; a misspelt anchor is refused rather than silently placing the figure at the origin.
    *   `:first` (Default): Locked to the first element (matches original behavior).
    *   `:center`: Centered as a whole (bounding box of all points).
    *   `:middle`: Locked to the middle element of the main point sequence (e.g., the 2nd of 3 points).
    *   `:last`: Locked to the last element.

### Visual Controls (how the layout is drawn)
*   `Marker`: Shape of the points. `:rect` (for 'I' lines) is implemented; `:circle` is declared but the current engine still renders rectangles.
*   `MarkerSize`: Size in pixels, e.g., `(2, 30)` for a vertical line.
*   `Color`: Declared but not yet honoured — the engine currently always draws white.

> **Timing and calibration:** for single-frame marker layouts, `duration_ms` is
> not used yet (the stimulus stays on screen until a response or timeout arrives),
> and no display gamma/luminance calibration is applied — do not interpret pixel
> levels as photometrically calibrated luminance.

## 3. Example Usage (Adjustment Method)
```julia
stim_par = MarkerLayout(
    StimConfig = "d r t",
    Ref = 24.0,
    DistrN = 4,
    Marker = :rect,
    MarkerSize = (2, 30),
    Anchor = :first
)

# In an experiment, the 'Adjustment' method will vary 'stim_par.Diff';
# the rendered test segment length follows as Ref + Diff * DiffInvert.
```

## 3.1 Rendering the stimulus yourself

Both the positions and the pixels are produced by pure functions in the
headless core, so a custom engine does not have to re-derive the layout:

```julia
sx, sy, px, py = calculate_marker_layout(stim_par)   # positions, stimulus frame

canvas = zeros(Float32, 800, 600)                  # any matrix you own
render_stimulus!(canvas, stim_par; on = 1.0f0, off = 0.0f0)
```

`render_stimulus!` clears the canvas to `off` and draws every distractor and
main-sequence marker into it; `draw_marker!` is the single-marker primitive if
you need finer control. The canvas is indexed `canvas[x, y]` with the origin of
the stimulus frame at its centre, markers are clipped at the edges, and the
element type is yours to choose — the GLMakie engine passes a `Matrix{RGBf}`
with `on = RGBf(1,1,1)`, while tests use a small `Bool` matrix. `MarkerSize`
is honoured exactly: an odd size extends one pixel further in the positive
direction.

The Gabor of §6 is drawn through the same function, with a grey-level mapping
(`pixel`) in place of `on`/`off` and the frame of its sequence to draw
(`interval`).

## 4. Rendering and testing
*   **No Flickering**: High-performance GPU rendering via `GLMakie`.
*   **Reactive**: Changes to parameters are reflected instantly.
*   **Modular**: Pure coordinate, rasterization, and waveform generation can be tested without opening display or audio hardware — the exact pixels of a stimulus are verified against a small matrix in `test/test_marker_layout.jl`.

## 5. Auditory Filled-Time Stimulus

`TemporalOppelKundt` describes an auditory filled-time (divided-time)
analogue of the Oppel-Kundt stimulus. The standard configuration has two
adjacent intervals marked by three short tone bursts. The reference interval
contains equally spaced filler bursts and the comparison interval remains
empty. A positive `gap_ms` separates the intervals and adds a fourth boundary
burst.

The pure functions are always available:

* `temporal_oppel_kundt_onsets(params)` returns boundary and filler onset times.
* `generate_temporal_oppel_kundt_waveform(params)` returns a mono
  `Vector{Float32}` without opening an audio device.

Load `PortAudio` and `SampledSignals` to activate `AudioStimulusEngine`, which
duplicates the mono waveform to the default stereo output:

```julia
using PsychophysicsManager
using PortAudio, SampledSignals

params = TemporalOppelKundt(
    reference_interval_ms = 1000.0,
    comparison_interval_ms = 1600.0,
    filler_count = 6,
    filled_interval = :first,
    frequency_hz = 1000.0,
    burst_duration_ms = 30.0,
    ramp_duration_ms = 3.4,
    peak_amplitude = 0.1,
)

waveform = generate_temporal_oppel_kundt_waveform(params)
```

### Parameters

* `reference_interval_ms`: duration of the filled reference interval.
* `comparison_interval_ms`: duration of the empty comparison interval; this is
  the independent variable in the Constant Stimuli example.
* `filler_count`: number of equally spaced bursts inside the reference.
* `filled_interval`: `:first` or `:second`.
* `gap_ms`: silence between separated intervals; `0` makes them share a boundary.
* `frequency_hz`: frequency shared by all boundary and filler bursts.
* `burst_duration_ms`: duration of every burst.
* `ramp_duration_ms`: linear attack and release duration at each end.
* `peak_amplitude`: unitless digital peak amplitude per burst, in `[0, 1]`.
* `sample_rate_hz`: waveform and PortAudio stream sample rate.
* `leading_silence_ms`, `trailing_silence_ms`: silence included in the waveform.

The output device is a laboratory-machine setting rather than a stimulus
parameter. Configure its exact PortAudio name in `[audio] output_device` in
`settings.toml`; leave it blank to use the operating-system default output.
The selected device must support `sample_rate_hz`.

The implementation refuses invalid timing, Nyquist violations, and mixed
waveforms that exceed the digital range. It does not silently clip or normalize
the signal.

> **Calibration status:** `peak_amplitude` is not dB SPL. The output interface,
> amplifier, headphones, fit, and calibration procedure determine physical
> level at the ear. PortAudio device latency is also unmeasured, so the stored
> first-burst onset accounts for generated leading silence but remains an
> engine estimate rather than a verified acoustic onset.

The defaults and executable example are based on the stimulus construction in
T. Surkys, *Filled space and filled time illusions vary similarly with analogous
stimulus parameters*, Scientific Reports 15, 39498 (2025),
[doi:10.1038/s41598-025-23643-2](https://doi.org/10.1038/s41598-025-23643-2):
1 s reference interval, six fillers, 1000 Hz, 30 ms bursts, and 3.4 ms ramps.
The executable temporal Oppel-Kundt example uses `peak_amplitude = 0.5`, half
of the available digital peak range (approximately -6.02 dBFS), instead of
claiming to reproduce the article's calibrated physical level. This value is
not a hearing-safety guarantee; begin hardware setup at low output gain and
calibrate before participant use. The generic `TemporalOppelKundt`
constructor retains the lower `0.1` default for newly constructed stimuli.

## 6. Two-Interval Gabor Patch

`Gabor` is the stimulus of a two-interval forced-choice (2IFC) contrast
detection task: a sinusoidal grating in a Gaussian window, shown in one of two
intervals. A trial runs

1. a blank lead-in at the mean grey (`leading_blank_ms`),
2. interval 1 (`interval_ms`),
3. a blank pause (`isi_ms`),
4. interval 2 (`interval_ms`),
5. a blank screen until the participant answers.

During each interval four small black marks frame the place the patch appears
in, so that the interval without it can be told from the pause. The participant
names the interval: ← for the first (`-1`), → for the second (`+1`), Enter or
Space to see the pair again (`0`). A key pressed while the sequence is still
running is discarded, because it cannot be an answer about an interval not yet
shown, and a response window set with `set_timeout!` opens when the second
interval ends.

Which interval holds the patch is an independent variable of the design, so that
it is drawn per trial and recorded with the trial; a design that leaves it out
is refused at the first trial:

```julia
design = ExperimentParameters("Contrast_2IFC", [:contrast, :target_interval],
                              [10 .^ range(-2, 0; length = 21), [1, 2]], 1)
```

`correct_answer` scores every trial against it, so an adaptive method steps on
accuracy and `print_psychometric_summary` fits the proportion correct. Contrast
is a linear quantity here, which decides the psychometric function a Psi run
may assume (`pf = :weibull`; see `Psi`). The executable version is
`examples/run_contrast_threshold.jl`.

### Parameters

* `contrast`: peak Michelson contrast of the carrier at the window centre, as a
  proportion in `[0, 1]`.
* `cycles_per_px`: carrier frequency in cycles per pixel, below the Nyquist
  limit `0.5`. Cycles per degree would need the viewing distance, which
  PsychophysicsManager does not know, and a value given in those units is refused rather
  than aliased.
* `orientation_deg`: `0` draws vertical bars; a positive angle turns them
  counterclockwise on the screen.
* `phase_deg`: carrier phase at the window centre; `0` puts a bright bar there.
* `sigma_px`: standard deviation of the Gaussian window.
* `size_px`: side of the square the patch is drawn in, at least `6 * sigma_px`
  so that the window has faded before the square's edge.
* `mean_luminance`: grey level of the background and of the patch mean, in
  `(0, 1)`. A contrast whose peaks would pass white is refused, not clipped.
* `target_interval`: `1` or `2`, bound from the design every trial.
* `interval_ms`, `isi_ms`, `leading_blank_ms`: the duration of each interval, of
  the pause between them, and of the lead-in.

`render_stimulus!(canvas, params; interval, pixel)` draws one frame of the
sequence into any matrix you own: `interval = 1` or `2` is that interval, with
the patch when it is the target interval, `interval = 0` is the blank, and the
default is the frame that holds the patch. `pixel` maps a grey level in `[0, 1]`
to the canvas element type — the identity for a real-valued canvas,
`g -> RGBf(g, g, g)` in the GLMakie engine. The canvas convention is that of
§3.1, with y pointing up as displayed.

> **Calibration and timing status:**
>
> * `contrast` is digital: a proportion of the framebuffer's grey level.
>   Luminance contrast is what the display makes of it through its gamma, which
>   is neither measured nor corrected — near mid-grey a display with gamma 2.2
>   shows about twice the digital contrast.
> * The window has 8 bits per channel. At `mean_luminance = 0.5` one grey step
>   is about 0.8 % contrast: a lower contrast is drawn as a pattern at most one
>   step deep, shaped by rounding rather than by the stimulus, and a contrast of
>   a few per cent in a handful of steps. Human Gabor detection thresholds can
>   lie below 1 %, so a threshold near that range is bounded by the display
>   rather than by the observer.
> * Durations are slept, not counted in frames. GLMakie's render loop takes a
>   new frame on its own ticks (30 per second by default, not synchronised to
>   the display refresh), so every frame appears up to one tick late and an
>   interval lasts its nominal duration only to within about a tick. The engine
>   refuses an interval or a pause shorter than two ticks, which might not be
>   drawn at all.
> * The recorded onset is the moment the first interval was handed to the
>   render loop, so a reaction time measured from it includes both intervals
>   and the pause between them.

## 7. Registering Stimuli and Custom Engines

### Registering a Stimulus

Register custom stimulus parameters with `register_stimulus!`, associating the engine that presents them and any backend package required:

```julia
using PsychophysicsManager
register_stimulus!(MyStimulus;
    engine = :MyEngine,
    backend = [:MyBackendPackage],
    description = "Short description of the stimulus")
```

This registers the stimulus type and records the engine that presents it, so that `default_engine_type` resolves it once the backend is loaded. A type that builds with no arguments (`MyStimulus()`) is listed by `selectable_stimuli` and chosen by name in the dashboard, which then lists its parameters in the order the type declares them. A stimulus whose design cannot do without a variable — the interval that holds the target, say — names it, and a session choosing the stimulus is given it:

```julia
PsychophysicsManager.required_variables(::MyStimulus) = [:target_interval => [1, 2]]
```

### Registering a Custom Engine

After defining a concrete engine subtype, make saved sessions using it
restorable through `restore_engine` with these lines:

```julia
using PsychophysicsManager
struct MyEngine <: AbstractStimulusEngine end
register_engine_type!(MyEngine)
```

The engine must also implement the `initialize_engine` and `present_stimulus`
contracts before it can run an experiment. Register it immediately after its
definition (or from an extension's `__init__`) so `restore_engine` can resolve
its saved type name.
