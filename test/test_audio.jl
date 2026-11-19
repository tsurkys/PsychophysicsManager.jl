@testset "Temporal Oppel-Kundt stimulus" begin
    params = TemporalOppelKundt(
        reference_interval_ms = 1000.0,
        comparison_interval_ms = 1200.0,
        filler_count = 6,
        leading_silence_ms = 250.0,
        trailing_silence_ms = 50.0,
    )

    onsets = temporal_oppel_kundt_onsets(params)
    @test onsets.boundary_ms == [0.0, 1000.0, 2200.0]
    @test length(onsets.filler_ms) == 6
    @test onsets.filler_ms ≈ collect(1:6) .* (1000.0 / 7)

    reversed = deepcopy(params)
    reversed.filled_interval = :second
    reversed_onsets = temporal_oppel_kundt_onsets(reversed)
    @test reversed_onsets.boundary_ms == [0.0, 1200.0, 2200.0]
    @test reversed_onsets.filler_ms ≈ 1200.0 .+ collect(1:6) .* (1000.0 / 7)

    separated = deepcopy(params)
    separated.gap_ms = 1500.0
    separated_onsets = temporal_oppel_kundt_onsets(separated)
    @test separated_onsets.boundary_ms == [0.0, 1000.0, 2500.0, 3700.0]

    waveform = generate_temporal_oppel_kundt_waveform(params)
    expected_samples = ceil(
        Int,
        (250.0 + 2200.0 + params.burst_duration_ms + 50.0) *
        params.sample_rate_hz / 1000,
    )
    @test eltype(waveform) == Float32
    @test length(waveform) == expected_samples
    @test all(iszero, @view waveform[1:round(Int, 0.25 * params.sample_rate_hz)])
    @test 0.99 * params.peak_amplitude < maximum(abs, waveform) <= params.peak_amplitude
    @test waveform[round(Int, 0.25 * params.sample_rate_hz) + 1] == 0.0f0

    bound = deepcopy(params)
    apply_variables!(bound, [:comparison_interval_ms], [1600.0])
    @test bound.comparison_interval_ms == 1600.0

    @test_throws ArgumentError generate_temporal_oppel_kundt_waveform(
        TemporalOppelKundt(filler_count = -1),
    )
    @test_throws ArgumentError generate_temporal_oppel_kundt_waveform(
        TemporalOppelKundt(filled_interval = :middle),
    )
    @test_throws ArgumentError generate_temporal_oppel_kundt_waveform(
        TemporalOppelKundt(ramp_duration_ms = 20.0),
    )
    @test_throws ArgumentError generate_temporal_oppel_kundt_waveform(
        TemporalOppelKundt(sample_rate_hz = 1500),
    )

    @test haskey(PsychophysicsManager.STIMULUS_REGISTRY, :TemporalOppelKundt)
    @test close_engine!(EmulatorEngine()) === nothing
end

@testset "Temporal Oppel-Kundt persistence" begin
    mktempdir() do directory
        ex_par = ExperimentParameters(
            "AudioPersistence",
            :comparison_interval_ms,
            [800.0, 1000.0, 1200.0],
            2,
        )
        params = TemporalOppelKundt(
            reference_interval_ms = 750.0,
            comparison_interval_ms = 900.0,
            filler_count = 4,
            filled_interval = :second,
            gap_ms = 200.0,
            peak_amplitude = 0.08,
        )
        session = SessionContext(
            "Audio_Save_Test",
            ex_par,
            params,
            ConstantStimuli(),
        )

        path = save_session_checkpoint(session, directory; filename = "audio.json")
        loaded = load_session(path)

        @test loaded.stim_par isa TemporalOppelKundt
        @test loaded.stim_par.reference_interval_ms == 750.0
        @test loaded.stim_par.comparison_interval_ms == 900.0
        @test loaded.stim_par.filler_count == 4
        @test loaded.stim_par.filled_interval == :second
        @test loaded.stim_par.gap_ms == 200.0
        @test loaded.stim_par.peak_amplitude == 0.08
    end
end
