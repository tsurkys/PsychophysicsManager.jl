@testset "Marker layout" begin

    @testset "Main sequence positions" begin
        p = MarkerLayout(StimConfig = "r g t", Ref = 10.0, GapHor = 5.0,
                           Diff = 2.0, Anchor = :first)
        snapshot = deepcopy(p)
        sx, sy, px, py = calculate_marker_layout(p)
        # test segment length is derived: Ref + Diff * DiffInvert = 12
        @test px == [0.0, 10.0, 15.0, 27.0]
        @test all(py .== 0.0)
        @test isempty(sx)
        # Pure function: parameters are not mutated
        @test all(getfield(p, f) == getfield(snapshot, f)
                  for f in fieldnames(MarkerLayout))
    end

    @testset "Distractors" begin
        # Step 0 -> auto step Ref/(DistrN+1)
        p = MarkerLayout(StimConfig = "d r", Ref = 10.0, DistrN = 4,
                           Step = 0.0, Anchor = :first)
        sx, sy, px, py = calculate_marker_layout(p)
        @test sx == [2.0, 4.0, 6.0, 8.0]
        @test all(sy .== 0.0)
        @test px == [0.0, 10.0]
    end

    @testset "Anchoring" begin
        # :center centers the bounding box
        p = MarkerLayout(StimConfig = "r", Ref = 10.0, Anchor = :center)
        _, _, px, _ = calculate_marker_layout(p)
        @test px == [-5.0, 5.0]

        # :middle locks the middle element of the main sequence to the origin
        p = MarkerLayout(StimConfig = "r t", Ref = 10.0, Diff = 0.0, Anchor = :middle)
        _, _, px, _ = calculate_marker_layout(p)
        @test length(px) == 3
        @test px[2] == 0.0

        # :last locks the last element
        p = MarkerLayout(StimConfig = "r", Ref = 10.0, Anchor = :last)
        _, _, px, _ = calculate_marker_layout(p)
        @test px[end] == 0.0
    end

    @testset "Marker rasterization" begin
        # draw_marker! is the pixel primitive: stimulus-frame coordinates in,
        # a clipped block of canvas pixels out. No graphics backend involved.
        @testset "Block size and position" begin
            canvas = falses(10, 10)
            draw_marker!(canvas, 0, 0, 2, 2, true)
            # Origin maps to the canvas centre; an even size splits 1 px each way
            @test findall(canvas) == CartesianIndex.([(4, 4), (5, 4), (4, 5), (5, 5)])

            # An odd size extends one pixel further in the positive direction,
            # so the block is exactly width×height
            canvas = falses(10, 10)
            draw_marker!(canvas, 0, 0, 3, 1, true)
            @test findall(canvas) == CartesianIndex.([(4, 5), (5, 5), (6, 5)])

            # The stimulus frame is offset from the canvas centre, not its corner
            canvas = falses(10, 10)
            draw_marker!(canvas, 2, -3, 1, 1, true)
            @test findall(canvas) == [CartesianIndex(7, 2)]
        end

        @testset "Clipping at the canvas edges" begin
            canvas = falses(10, 10)
            # A 4-wide marker centred at x = -4 spans canvas columns -1..2;
            # only the two inside the canvas are drawn
            draw_marker!(canvas, -4, 0, 4, 1, true)
            @test findall(canvas) == CartesianIndex.([(1, 5), (2, 5)])

            # Entirely outside: no error, no pixels
            canvas = falses(10, 10)
            draw_marker!(canvas, 100, 0, 4, 4, true)
            @test !any(canvas)
            draw_marker!(canvas, 0, -100, 4, 4, true)
            @test !any(canvas)
        end

        @testset "Full stimulus render" begin
            # Two main-sequence markers 10 units apart, nothing else
            params = MarkerLayout(StimConfig = "r", Ref = 10.0, Anchor = :first,
                                    MarkerSize = (2, 2))
            canvas = falses(40, 40)
            render_stimulus!(canvas, params)
            @test count(canvas) == 8                       # 2 markers × 2×2 px
            @test all(canvas[19:20, 19:20])                # centred on x = 0
            @test all(canvas[29:30, 19:20])                # centred on x = 10

            # Distractors are rendered as well: 4 distractors + 2 main markers
            params = MarkerLayout(StimConfig = "d r", Ref = 10.0, DistrN = 4,
                                    Step = 0.0, Anchor = :first, MarkerSize = (1, 1))
            canvas = falses(40, 40)
            render_stimulus!(canvas, params)
            @test count(canvas) == 6

            # The canvas is cleared first: no pixels survive from the last trial
            fill!(canvas, true)
            render_stimulus!(canvas, params)
            @test count(canvas) == 6

            # Parameters are not mutated by rendering
            snapshot = deepcopy(params)
            render_stimulus!(canvas, params)
            @test all(getfield(params, f) == getfield(snapshot, f)
                      for f in fieldnames(MarkerLayout))
        end

        @testset "Canvas element type is the caller's choice" begin
            # The GLMakie engine passes RGBf values; a greyscale buffer works
            # exactly the same way, which is what keeps this testable headless
            canvas = zeros(Float32, 20, 20)
            params = MarkerLayout(StimConfig = "", Anchor = :first,
                                    MarkerSize = (2, 2))
            render_stimulus!(canvas, params; on = 0.75f0, off = 0.25f0)
            @test canvas[9:10, 9:10] == fill(0.75f0, 2, 2)
            @test canvas[1, 1] === 0.25f0
        end
    end

    @testset "Mirroring the whole figure" begin
        mirrored = MarkerLayout(StimConfig = "d r t", StimMirror = true,
                                      Ref = 240.0, DistrN = 4, Diff = 30.0,
                                      MarkerSize = (2, 30), Anchor = :center)
        # The same figure written by hand: the segments listed
        # in the other order, with the distractor run walking left from the
        # rightmost endpoint
        by_hand = MarkerLayout(StimConfig = "t r -d", Ref = 240.0, DistrN = 4,
                                     Diff = 30.0, MarkerSize = (2, 30), Anchor = :center)

        msx, _, mpx, _ = calculate_marker_layout(mirrored)
        hsx, _, hpx, _ = calculate_marker_layout(by_hand)
        @test sort(mpx) ≈ sort(hpx)
        @test sort(msx) ≈ sort(hsx)

        # …and the pixels agree, which is what the observer actually sees
        mirrored_canvas, hand_canvas = fill(false, 900, 200), fill(false, 900, 200)
        render_stimulus!(mirrored_canvas, mirrored)
        render_stimulus!(hand_canvas, by_hand)
        @test mirrored_canvas == hand_canvas
        @test any(mirrored_canvas)

        # The mirror is a reflection, not a reordering: segment 2 is the test
        # segment either way, so a response coding tied to the segment survives
        # it while one naming a side does not
        standard = MarkerLayout(StimConfig = "d r t", Ref = 240.0, DistrN = 4,
                                      Diff = 30.0, MarkerSize = (2, 30), Anchor = :center)
        @test segment_lengths(standard) ≈ [240.0, 270.0]
        @test segment_lengths(mirrored) ≈ [240.0, 270.0]
        @test segment_lengths(by_hand) ≈ [270.0, 240.0]   # the hand-written one does reorder

        # Mirroring twice is the identity, and an unmirrored figure is untouched
        _, _, spx, _ = calculate_marker_layout(standard)
        @test sort(mpx) ≈ sort(-spx)
        # Old session files carry no such field and must load unmirrored
        @test MarkerLayout().StimMirror == false
    end

    @testset "A layout that cannot mean what it says is refused" begin
        # Both of these would otherwise be accepted silently: an unknown token is
        # skipped (a figure without its test segment) and an unknown anchor falls
        # back to the origin (the whole figure shifted)
        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "d r T"))
        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "r t", Anchor = :centre))

        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "r", Ref = -10.0))
        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "d r", DistrN = -1))
        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "r", MarkerSize = (0, 30)))
        @test_throws ArgumentError calculate_marker_layout(
            MarkerLayout(StimConfig = "r", Marker = :square))

        # Ref = 0 stays legal: a layout may carry its length in Diff alone
        @test PsychophysicsManager.validate_marker_layout(
            MarkerLayout(StimConfig = "t", Ref = 0.0, Diff = 40.0)) isa
              MarkerLayout
    end

    @testset "Variable binding" begin
        p = MarkerLayout()
        # Integer fields are rounded, floats converted
        apply_variables!(p, [:DistrN, :Ref], [3.0, 24.0])
        @test p.DistrN === 3
        @test p.Ref === 24.0
        # Unknown names are skipped without error
        apply_variables!(p, [:no_such_field], [1.0])
    end

end
