# A render-only engine that rasterizes every frame of the two-interval sequence
# and remembers which interval the bound stimulus put the patch in
struct GaborProbeEngine <: PsychophysicsManager.AbstractStimulusEngine
    canvas::Matrix{Float64}
    bound::Vector{Int}
end

function PsychophysicsManager.present_stimulus(engine::GaborProbeEngine, stim_par::Gabor,
                                    ::AbstractVector{<:Number})
    foreach(interval -> render_stimulus!(engine.canvas, stim_par; interval), 0:2)
    push!(engine.bound, stim_par.target_interval)
    return nothing
end

# An observer who sees every patch at or above `threshold` and none below it
struct ContrastThresholdObserver <: AbstractResponseSource
    threshold::Float64
end

function PsychophysicsManager.request_response(observer::ContrastThresholdObserver,
                                    context::TrialContext)
    contrast, target = context.indep_var_vals
    seen = target == 1 ? -1 : 1
    return (contrast >= observer.threshold ? seen : -seen, time())
end

@testset "Gabor stimulus" begin
    cue_pixels = 4 * PsychophysicsManager.GABOR_CUE_PX^2

    @testset "The blank, the empty interval and the patch" begin
        p = Gabor(contrast = 0.8, sigma_px = 8.0, size_px = 48, target_interval = 2)
        canvas = zeros(Float32, 96, 80)

        render_stimulus!(canvas, p; interval = 0)
        @test all(==(0.5f0), canvas)

        # The interval without the patch shows only the marks that frame it
        render_stimulus!(canvas, p; interval = 1)
        @test count(==(0f0), canvas) == cue_pixels
        @test count(!=(0.5f0), canvas) == cue_pixels

        # The default frame is the one that holds the patch
        render_stimulus!(canvas, p)
        @test count(!=(0.5f0), canvas) > cue_pixels
    end

    @testset "Contrast and phase at the window centre" begin
        p = Gabor(contrast = 0.4, sigma_px = 8.0, size_px = 48, cycles_per_px = 0.05)
        canvas = zeros(101, 81)
        center = (round(Int, 101 / 2), round(Int, 81 / 2))

        render_stimulus!(canvas, p)
        @test canvas[center...] ≈ 0.5 * (1 + 0.4)
        @test canvas[1, 1] == 0.5

        # Half a cycle of phase puts a dark bar where the bright one was
        p.phase_deg = 180
        render_stimulus!(canvas, p)
        @test canvas[center...] ≈ 0.5 * (1 - 0.4)

        # Without contrast only the marks differ from the mean
        p.contrast = 0.0
        render_stimulus!(canvas, p)
        @test count(!=(0.5), canvas) == cue_pixels
    end

    @testset "Orientation" begin
        p = Gabor(contrast = 0.5, sigma_px = 6.0, size_px = 36, cycles_per_px = 0.1)
        vertical = render_stimulus!(zeros(64, 64), p)

        # A quarter turn draws horizontal bars: the vertical pattern transposed
        p.orientation_deg = 90
        @test render_stimulus!(zeros(64, 64), p) ≈ permutedims(vertical)

        # A positive angle turns the bars counterclockwise with y pointing up, so
        # at 45° the bar through the centre runs down to the right
        p.orientation_deg = 45
        tilted = render_stimulus!(zeros(64, 64), p)
        on_bar = 0.5 * (1 + 0.5 * exp(-50 / (2 * 6.0^2)))
        @test tilted[32 + 5, 32 - 5] ≈ on_bar
        @test !isapprox(tilted[32 + 5, 32 + 5], on_bar; atol = 1e-3)
    end

    @testset "A patch larger than the canvas is clipped" begin
        small = render_stimulus!(zeros(20, 20), Gabor(sigma_px = 8.0, size_px = 48))
        @test small[10, 10] ≈ 0.5 * (1 + 0.5)
        @test count(==(0.0), small) == 0      # the marks fall outside
    end

    @testset "Rendering leaves the parameters as they were" begin
        p = Gabor()
        snapshot = deepcopy(p)
        foreach(interval -> render_stimulus!(zeros(300, 300), p; interval), 0:2)
        @test all(getfield(p, f) == getfield(snapshot, f) for f in fieldnames(Gabor))
    end

    @testset "A Gabor that would be drawn as something else is refused" begin
        canvas = zeros(200, 200)
        for bad in (Gabor(contrast = 1.5), Gabor(contrast = -0.1),
                    Gabor(mean_luminance = 0.0),
                    Gabor(mean_luminance = 0.7, contrast = 0.5),
                    Gabor(cycles_per_px = 0.5), Gabor(cycles_per_px = 4.0),
                    Gabor(orientation_deg = NaN), Gabor(phase_deg = Inf),
                    Gabor(sigma_px = 0.0), Gabor(sigma_px = 30.0),
                    Gabor(target_interval = 3), Gabor(interval_ms = 0.0),
                    Gabor(isi_ms = 0.0), Gabor(leading_blank_ms = -1.0))
            @test_throws ArgumentError render_stimulus!(canvas, bad)
        end
        @test_throws ArgumentError render_stimulus!(canvas, Gabor(); interval = 3)
    end

    @testset "The correct answer names the interval that held the patch" begin
        p = Gabor()
        @test correct_answer(p, (contrast = 0.1, target_interval = 1.0)) == -1
        @test correct_answer(p, (contrast = 0.1, target_interval = 2.0)) == 1
        # A design that fixes the interval in the stimulus is refused
        @test_throws ArgumentError correct_answer(p, (contrast = 0.1,))
    end

    @testset "A two-interval session binds, scores and stores the interval" begin
        mktempdir() do dir
            levels = 10.0 .^ range(-2, 0; length = 9)
            ex_par = ExperimentParameters("Gabor2IFC", [:contrast, :target_interval],
                                          [levels, [1, 2]], 1)
            session = SessionContext("G", ex_par, Gabor(sigma_px = 4.0, size_px = 24),
                                     Staircase(2; trial_limit = 40);
                                     rng_seed = UInt64(99))
            engine = GaborProbeEngine(zeros(64, 64), Int[])
            cd(dir) do
                write("settings.toml", "[storage]\ndata_dir = \"out\"\n")
                with_response_source(ContrastThresholdObserver(0.1)) do
                    run_experiment!(session, engine; report = :silent)
                end
            end

            @test session.state == FINISHED
            @test length(session.history) == 40
            # The drawn interval reached the stimulus field before every presentation
            @test engine.bound == [Int(t.indep_var_vals[2]) for t in session.history]
            @test Set(engine.bound) == Set([1, 2])
            @test all(t.correct === (t.indep_var_vals[1] >= 0.1) for t in session.history)
            # Two correct answers step down and a wrong one steps up, so the run
            # ends alternating around the lowest contrast the observer sees
            @test all(0.05 <= t.indep_var_vals[1] <= 0.2 for t in session.history[end-9:end])

            loaded = load_session(save_session_checkpoint(session, dir))
            @test loaded.stim_par isa Gabor
            @test all(getfield(loaded.stim_par, f) == getfield(session.stim_par, f)
                      for f in fieldnames(Gabor))
            @test [t.correct for t in loaded.history] == [t.correct for t in session.history]
        end
    end
end
