using GLMakie.Makie: getscreen

function project_sp(scene, point)
    point_px = Makie.project(scene, point)
    offset = Point2f(minimum(pixelarea(scene)[]))
    return point_px .+ offset
end

@testset "unit tests" begin
    GLMakie.closeall()
    @testset "Window handling" begin
        # Without previous windows/figures everything should be empty/unassigned
        @test isempty(GLMakie.ALL_SCREENS)
        @test isempty(GLMakie.SCREEN_REUSE_POOL)
        @test isempty(GLMakie.SINGLETON_SCREEN)

        # A raw screen should be tracked in GLFW_WINDOWS
        screen = GLMakie.Screen(resolution = (100, 100), visible = false)
        @test isopen(screen)
        @test GLMakie.ALL_SCREENS == Set([screen])
        @test isempty(GLMakie.SCREEN_REUSE_POOL)
        @test isempty(GLMakie.SINGLETON_SCREEN)

        # A displayed figure should create a singleton screen and leave other
        # screens untouched
        fig, ax, splot = scatter(1:4);
        screen2 = display(fig)
        @test screen !== screen2
        @test GLMakie.ALL_SCREENS == Set([screen, screen2])
        @test GLMakie.SINGLETON_SCREEN == [screen2]
        @test isempty(GLMakie.SCREEN_REUSE_POOL)

        # TODO overload getscreen for figure
        @test getscreen(ax.scene) === screen2

        # closing screens should just free it and put it in SCREEN_REUSE_POOL
        close(screen)
        @test !isopen(screen) && isopen(screen2)
        @test GLMakie.ALL_SCREENS == Set([screen, screen2])
        @test GLMakie.SINGLETON_SCREEN == [screen2]
        @test length(GLMakie.SCREEN_REUSE_POOL) == 1

        close(screen2)
        @test !isopen(screen) && !isopen(screen2)
        @test GLMakie.SINGLETON_SCREEN == [screen2]
        @test GLMakie.SCREEN_REUSE_POOL == Set([screen])
        @test GLMakie.ALL_SCREENS == Set([screen, screen2])

        # assure we correctly close screen and remove it from plot
        @test getscreen(ax.scene) === nothing
        @test !events(ax.scene).window_open[]
        @test isempty(events(ax.scene).window_open.listeners)

        # Test singleton screen replacement
        fig, ax, p = scatter(1:4);
        screen = display(fig)
        ptr = deepcopy(screen.glscreen.handle)
        @test isopen(screen) && (screen === GLMakie.SINGLETON_SCREEN[1])
        fig2, ax2, p2 = scatter(4:-1:1);
        screen2 = display(fig2)
        @test isopen(screen2) && (screen2 === GLMakie.SINGLETON_SCREEN[])
        @test screen === screen2
        @test screen2.glscreen.handle == ptr
        close(screen2)
    end

    @testset "Pick a plot element or plot elements inside a rectangle" begin
        N = 100000
        fig, ax, splot = scatter(1:N, 1:N)
        limits!(ax, 99990,100000, 99990,100000)
        screen = display(GLMakie.Screen(visible = false), fig)
        # we don't really need the color buffer here, but this should be the best way right now to really
        # force a full render to happen
        GLMakie.Makie.colorbuffer(screen)
        # test for pick a single data point (with idx > 65535)
        point_px = project_sp(ax.scene, Point2f(N-1,N-1))
        plot,idx = pick(ax.scene, point_px)
        @test idx == N-1

        # test for pick a rectangle of data points (also with some indices > 65535)
        rect = Rect2f(99990.5,99990.5,8,8)
        origin_px = project_sp(ax.scene, Point(origin(rect)))
        tip_px = project_sp(ax.scene, Point(origin(rect) .+ widths(rect)))
        rect_px = Rect2i(round.(origin_px), round.(tip_px .- origin_px))
        picks = unique(pick(ax.scene, rect_px))

        # objects returned in plot_idx should be either grid lines (i.e. LineSegments) or Scatter points
        @test all(pi-> pi[1] isa Union{LineSegments,Scatter, Makie.Mesh}, picks)
        # scatter points should have indices equal to those in 99991:99998
        scatter_plot_idx = filter(pi -> pi[1] isa Scatter, picks)
        @test Set(last.(scatter_plot_idx)) == Set(99991:99998)
        GLMakie.destroy!(screen)
    end
end

@testset "emtpy!(fig)" begin
    GLMakie.closeall()
    fig = Figure()
    ax = Axis(fig[1,1])
    heatmap!(ax, rand(4, 4))
    lines!(ax, 1:5, rand(5); linewidth=3)
    text!(ax, [Point2f(2)], text=["hi"])
    screen = display(fig)
    empty!(fig)
    @test screen in fig.scene.current_screens
    @testset "all got freed" begin
        for (_, _, robj) in screen.renderlist
            for (k, v) in robj.uniforms
                if v isa GLMakie.GPUArray
                    @test v.id == 0
                end
            end
            @test robj.vertexarray.id == 0
        end
    end
    ax = Axis(fig[1,1])
    heatmap!(ax, rand(4, 4))
    lines!(ax, 1:5, rand(5); linewidth=3)
    text!(ax, [Point2f(2)], text=["hi"])
    @testset "no freed object after replotting" begin
        for (_, _, robj) in screen.renderlist
            for (k, v) in robj.uniforms
                if v isa GLMakie.GPUArray
                    @test v.id != 0
                end
            end
            @test robj.vertexarray.id != 0
        end
    end
    close(screen)
    @test isempty(screen.renderlist)
end

@testset "empty!(ax)" begin
    GLMakie.closeall()
    fig = Figure()
    ax = Axis(fig[1,1])
    hmp = heatmap!(ax, rand(4, 4))
    lp = lines!(ax, 1:5, rand(5); linewidth=3)
    tp = text!(ax, [Point2f(2)], text=["hi"])
    screen = display(fig)

    @test ax.scene.plots == [hmp, lp, tp]

    robjs = map(x-> screen.cache[objectid(x)], [hmp, lp, tp.plots...])

    empty!(ax)

    tex_atlas = GLMakie.get_texture!(GLMakie.gl_texture_atlas())
    for robj in robjs
        for (k, v) in robj.uniforms
            if (v isa GLMakie.GPUArray) && (v !== tex_atlas)
                @test v.id == 0
            end
        end
        @test robj.vertexarray.id == 0
    end

    heatmap!(ax, rand(4, 4))
    lines!(ax, 1:5, rand(5); linewidth=3)
    text!(ax, [Point2f(2)], text=["hi"])
    @testset "no freed object after replotting" begin
        for (_, _, robj) in screen.renderlist
            for (k, v) in robj.uniforms
                if v isa GLMakie.GPUArray
                    @test v.id != 0
                end
            end
            @test robj.vertexarray.id != 0
        end
    end
    close(screen)
    @test isempty(screen.renderlist)
end

@testset "closing" begin
    # Closing let to multiple errors/segfaults because of incorrect clean ups:
    # https://github.com/MakieOrg/Makie.jl/issues/2371
    @testset "closing and redisplaying" begin
        GLMakie.closeall()
        fig = Figure()
        ax = Axis(fig[1,1]) # only happens with axis
        # lines!(ax, 1:5, rand(5); linewidth=5) # but doesn't need a plot
        screen = display(fig)
        GLMakie.closeall()
        display(fig)
        @test true # test for no errors for now
    end

    @testset "closing and redisplaying + resizing" begin
        GLMakie.closeall()
        fig = Figure()
        ax = Axis(fig[1,1]) # only happens with axis
        screen = display(fig)
        close(screen)
        screen = display(fig)
        resize!(fig, 800,601)
        @test true # test for no errors for now
        # GLMakie.destroy!(screen)
    end
end

@testset "destroying singleton screen" begin
    screen = display(scatter(1:4))
    GLMakie.destroy!(screen)
    screen = display(scatter(1:4))
    @test isopen(screen) # shouldn't run into double closing a destroyed window
    GLMakie.destroy!(screen)
end

@testset "stresstest multi displays" begin
    GLMakie.closeall()
    screens = map(1:10) do i
        fig = Figure(resolution=(500, 500))
        rng  = Random.MersenneTwister(0)
        ax, pl = image(fig[1, 1], 0..1, 0..1, rand(rng, 1000, 1000))
        scatter!(ax, rand(rng, Point2f, 1000), color=:red)
        lines!(ax, rand(rng, Point2f, 1000), transparency=true)

        ax3d, pl = mesh(fig[1, 2], Sphere(Point3f(0), 1))
        meshscatter!(ax3d, rand(rng, Point3f, 100), color=:red)

        heatmap(fig[2, 1], rand(rng, 100, 100))
        surface(fig[2, 2], 0..1, 0..1, rand(rng, 1000, 1000) ./ 2)

        display(GLMakie.Screen(visible=false), fig)
    end

    images = map(Makie.colorbuffer, screens)
    @test all(x-> x ≈ first(images), images)

    @test Base.summarysize(screens) / 10^6 > 300
    foreach(close, screens)

    for screen in screens
        @test !isopen(screen)

        @test isempty(screen.screen2scene)
        @test isempty(screen.screens)
        @test isempty(screen.renderlist)
        @test isempty(screen.cache)
        @test isempty(screen.cache2plot)

        @test isempty(screen.window_open.listeners)
        @test isempty(screen.render_tick.listeners)

        @test screen.root_scene === nothing
        @test screen.rendertask === nothing
        @test (Base.summarysize(screen) / 10^6) < 1.2
    end
    # All should go to pool after close
    @test all(x-> x in GLMakie.SCREEN_REUSE_POOL, screens)

    GLMakie.closeall()
    # now every screen should be gone
    @test isempty(GLMakie.SCREEN_REUSE_POOL)
end
