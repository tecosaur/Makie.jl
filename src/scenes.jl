struct SSAO
    """
    sets the range of SSAO. You may want to scale this up or
    down depending on the limits of your coordinate system
    """
    radius::Observable{Float32}

    """
    sets the minimum difference in depth required for a pixel to
    be occluded. Increasing this will typically make the occlusion
    effect stronger.
    """
    bias::Observable{Float32}

    """
    sets the (pixel) range of the blur applied to the occlusion texture.
    The texture contains a (random) pattern, which is washed out by
    blurring. Small `blur` will be faster, sharper and more patterned.
    Large `blur` will be slower and smoother. Typically `blur = 2` is
    a good compromise.
    """
    blur::Observable{Int32}
end

function Base.show(io::IO, ssao::SSAO)
    println(io, "SSAO:")
    println(io, "    radius: ", ssao.radius[])
    println(io, "    bias:   ", ssao.bias[])
    println(io, "    blur:   ", ssao.blur[])
end

function SSAO(; radius=nothing, bias=nothing, blur=nothing)
    defaults = theme(nothing, :SSAO)
    _radius = isnothing(radius) ? defaults.radius[] : radius
    _bias = isnothing(bias) ? defaults.bias[] : bias
    _blur = isnothing(blur) ? defaults.blur[] : blur
    return SSAO(_radius, _bias, _blur)
end

abstract type AbstractLight end

"""
A positional point light, shining at a certain color.
Color values can be bigger than 1 for brighter lights.
"""
struct PointLight <: AbstractLight
    position::Observable{Vec3f}
    radiance::Observable{RGBf}
end

"""
An environment Light, that uses a spherical environment map to provide lighting.
See: https://en.wikipedia.org/wiki/Reflection_mapping
"""
struct EnvironmentLight <: AbstractLight
    intensity::Observable{Float32}
    image::Observable{Matrix{RGBf}}
end

"""
A simple, one color ambient light.
"""
struct AmbientLight <: AbstractLight
    color::Observable{RGBf}
end

"""
    Scene TODO document this

## Constructors
$(SIGNATURES)

## Fields
$(FIELDS)
"""
mutable struct Scene <: AbstractScene
    "The parent of the Scene; if it is a top-level Scene, `parent == nothing`."
    parent::Union{Nothing, Scene}

    "[`Events`](@ref) associated with the Scene."
    events::Events

    "The current pixel area of the Scene."
    px_area::Observable{Rect2i}

    "Whether the scene should be cleared."
    clear::Observable{Bool}

    "The `Camera` associated with the Scene."
    camera::Camera

    "The controls for the camera of the Scene."
    camera_controls::AbstractCamera

    "The [`Transformation`](@ref) of the Scene."
    transformation::Transformation

    "The plots contained in the Scene."
    plots::Vector{AbstractPlot}

    theme::Attributes

    "Children of the Scene inherit its transformation."
    children::Vector{Scene}

    """
    The Screens which the Scene is displayed to.
    """
    current_screens::Vector{MakieScreen}

    # Attributes
    backgroundcolor::Observable{RGBAf}
    visible::Observable{Bool}
    ssao::SSAO
    lights::Vector{AbstractLight}
    deregister_callbacks::Vector{Observables.ObserverFunction}

    function Scene(
            parent::Union{Nothing, Scene},
            events::Events,
            px_area::Observable{Rect2i},
            clear::Observable{Bool},
            camera::Camera,
            camera_controls::AbstractCamera,
            transformation::Transformation,
            plots::Vector{AbstractPlot},
            theme::Attributes,
            children::Vector{Scene},
            current_screens::Vector{MakieScreen},
            backgroundcolor::Observable{RGBAf},
            visible::Observable{Bool},
            ssao::SSAO,
            lights::Vector{AbstractLight}
        )
        scene = new(
            parent,
            events,
            px_area,
            clear,
            camera,
            camera_controls,
            transformation,
            plots,
            theme,
            children,
            current_screens,
            backgroundcolor,
            visible,
            ssao,
            lights,
            Observables.ObserverFunction[]
        )
        finalizer(empty!, scene)
        return scene
    end
end

# on & map versions that deregister when scene closes!
function Observables.on(f, scene::Union{Combined,Scene}, observable::Observable; update=false, priority=0)
    to_deregister = on(f, observable; update=update, priority=priority)
    push!(scene.deregister_callbacks, to_deregister)
    return to_deregister
end

function Observables.onany(f, scene::Union{Combined,Scene}, observables...; priority=0)
    to_deregister = onany(f, observables...; priority=priority)
    append!(scene.deregister_callbacks, to_deregister)
    return to_deregister
end

@inline function Base.map!(@nospecialize(f), scene::Union{Combined,Scene}, result::AbstractObservable, os...;
                           update::Bool=true)
    # note: the @inline prevents de-specialization due to the splatting
    callback = Observables.MapCallback(f, result, os)
    for o in os
        o isa AbstractObservable && on(callback, scene, o)
    end
    update && callback(nothing)
    return result
end

@inline function Base.map(f::F, scene::Union{Combined,Scene}, arg1::AbstractObservable, args...;
                          ignore_equal_values=false) where {F}
    # note: the @inline prevents de-specialization due to the splatting
    obs = Observable(f(arg1[], map(Observables.to_value, args)...); ignore_equal_values=ignore_equal_values)
    map!(f, scene, obs, arg1, args...; update=false)
    return obs
end

get_scene(scene::Scene) = scene

_plural_s(x) = length(x) != 1 ? "s" : ""

function Base.show(io::IO, scene::Scene)
    println(io, "Scene ($(size(scene, 1))px, $(size(scene, 2))px):")
    print(io, "  $(length(scene.plots)) Plot$(_plural_s(scene.plots))")

    if length(scene.plots) > 0
        print(io, ":")
        for (i, plot) in enumerate(scene.plots)
            print(io, "\n")
            print(io, "    $(i == length(scene.plots) ? '└' : '├') ", plot)
        end
    end

    print(io, "\n  $(length(scene.children)) Child Scene$(_plural_s(scene.children))")

    if length(scene.children) > 0
        print(io, ":")
        for (i, subscene) in enumerate(scene.children)
            print(io, "\n")
            print(io,"    $(i == length(scene.children) ? '└' : '├') Scene ($(size(subscene, 1))px, $(size(subscene, 2))px)")
        end
    end
end

function Scene(;
        px_area::Union{Observable{Rect2i}, Nothing} = nothing,
        events::Events = Events(),
        clear::Union{Automatic, Observable{Bool}, Bool} = automatic,
        transform_func=identity,
        camera::Union{Function, Camera, Nothing} = nothing,
        camera_controls::AbstractCamera = EmptyCamera(),
        transformation::Transformation = Transformation(transform_func),
        plots::Vector{AbstractPlot} = AbstractPlot[],
        children::Vector{Scene} = Scene[],
        current_screens::Vector{MakieScreen} = MakieScreen[],
        parent = nothing,
        visible = Observable(true),
        ssao = SSAO(),
        lights = automatic,
        theme = Attributes(),
        theme_kw...
    )
    m_theme = merge_without_obs!(current_default_theme(; theme_kw...), theme)

    bg = Observable{RGBAf}(to_color(m_theme.backgroundcolor[]); ignore_equal_values=true)

    wasnothing = isnothing(px_area)
    if wasnothing
        px_area = Observable(Recti(0, 0, m_theme.resolution[]); ignore_equal_values=true)
    end

    cam = camera isa Camera ? camera : Camera(px_area)
    _lights = lights isa Automatic ? AbstractLight[] : lights

    # if we have an opaque background, automatically set clear to true!
    if clear isa Automatic
        clear = Observable(alpha(bg[]) == 1 ? true : false)
    else
        clear = convert(Observable{Bool}, clear)
    end
    scene = Scene(
        parent, events, px_area, clear, cam, camera_controls,
        transformation, plots, m_theme,
        children, current_screens, bg, visible, ssao, _lights
    )
    camera isa Function && camera(scene)

    if wasnothing
        on(scene, events.window_area, priority = typemax(Int)) do w_area
            if !any(x -> x ≈ 0.0, widths(w_area)) && px_area[] != w_area
                px_area[] = w_area
            end
            return Consume(false)
        end
    end

    if lights isa Automatic
        lightposition = to_value(get(m_theme, :lightposition, nothing))
        if !isnothing(lightposition)
            position = if lightposition === :eyeposition
                scene.camera.eyeposition
            elseif lightposition isa Vec3
                m_theme.lightposition
            else
                error("Wrong lightposition type, use `:eyeposition` or `Vec3f(...)`")
            end
            push!(scene.lights, PointLight(position, RGBf(1, 1, 1)))
        end
        ambient = to_value(get(m_theme, :ambient, nothing))
        if !isnothing(ambient)
            push!(scene.lights, AmbientLight(ambient))
        end
    end

    return scene
end

function get_one_light(scene::Scene, Typ)
    indices = findall(x-> x isa Typ, scene.lights)
    isempty(indices) && return nothing
    if length(indices) > 1
        @warn("Only one light supported by backend right now. Using only first light")
    end
    return scene.lights[indices[1]]
end

get_point_light(scene::Scene) = get_one_light(scene, PointLight)
get_ambient_light(scene::Scene) = get_one_light(scene, AmbientLight)


function Scene(
        parent::Scene;
        events=parent.events,
        px_area=nothing,
        clear=false,
        camera=nothing,
        camera_controls=parent.camera_controls,
        transformation=Transformation(parent),
        kw...
    )

    if camera !== parent.camera
        camera_controls = EmptyCamera()
    end
    child_px_area = px_area isa Observable ? px_area : Observable(Rect2i(0, 0, 0, 0); ignore_equal_values=true)
    child = Scene(;
        events=events,
        px_area=child_px_area,
        clear=convert(Observable{Bool}, clear),
        camera=camera,
        camera_controls=camera_controls,
        parent=parent,
        transformation=transformation,
        current_screens=copy(parent.current_screens),
        theme=theme(parent),
        kw...
    )
    if isnothing(px_area)
        map!(identity, child, child_px_area, parent.px_area)
    elseif !(px_area isa Observable) # observables are assumed to be already corrected against the parent to avoid double updates
        a = Rect2i(px_area)
        on(child, pixelarea(parent)) do p
            # make coordinates relative to parent
            return Rect2i(minimum(p) .+ minimum(a), widths(a))
        end
    end
    push!(parent.children, child)
    child.parent = parent
    return child
end

# legacy constructor
function Scene(parent::Scene, area; kw...)
    return Scene(parent; px_area=area, kw...)
end

# Base overloads for Scene
Base.parent(scene::Scene) = scene.parent
isroot(scene::Scene) = parent(scene) === nothing
rootparent(x) = rootparent(parent(x))
rootparent(x::Scene) = x

function root(scene::Scene)
    while !isroot(scene)
        scene = parent(scene)
    end
    scene
end
parent_or_self(scene::Scene) = isroot(scene) ? scene : parent(scene)

GeometryBasics.widths(scene::Scene) = widths(to_value(pixelarea(scene)))

Base.size(scene::Scene) = Tuple(widths(scene))
Base.size(x::Scene, i) = size(x)[i]
function Base.resize!(scene::Scene, xy::Tuple{Number,Number})
    resize!(scene, Recti(0, 0, xy))
end
Base.resize!(scene::Scene, x::Number, y::Number) = resize!(scene, (x, y))
function Base.resize!(scene::Scene, rect::Rect2)
    pixelarea(scene)[] = rect
end

# Just indexing into a scene gets you plot 1, plot 2 etc
Base.iterate(scene::Scene, idx=1) = idx <= length(scene) ? (scene[idx], idx + 1) : nothing
Base.length(scene::Scene) = length(scene.plots)
Base.lastindex(scene::Scene) = length(scene.plots)
getindex(scene::Scene, idx::Integer) = scene.plots[idx]
struct OldAxis end

zero_origin(area) = Recti(0, 0, widths(area))

function child(scene::Scene; camera, attributes...)
    return Scene(scene, lift(zero_origin, pixelarea(scene)); camera=camera, attributes...)
end

"""
Creates a subscene with a pixel camera
"""
function cam2d(scene::Scene)
    return child(scene, clear=false, camera=cam2d!)
end

function campixel(scene::Scene)
    return child(scene, clear=false, camera=campixel!)
end

function camrelative(scene::Scene)
    return child(scene, clear=false, camera=cam_relative!)
end

function getindex(scene::Scene, ::Type{OldAxis})
    for plot in scene
        isaxis(plot) && return plot
    end
    return nothing
end

function delete_scene!(scene::Scene)
    @warn "deprecated in favor of empty!(scene)"
    empty!(scene)
    return nothing
end

function Base.empty!(scene::Scene)
    foreach(empty!, copy(scene.children))
    # clear plots of this scene
    for plot in copy(scene.plots)
        delete!(scene, plot)
    end
    for screen in copy(scene.current_screens)
        delete!(screen, scene)
    end
    # clear all child scenes
    if !isnothing(scene.parent)
        filter!(x-> x !== scene, scene.parent.children)
    end
    scene.parent = nothing

    empty!(scene.current_screens)
    empty!(scene.children)
    empty!(scene.plots)
    empty!(scene.theme)
    disconnect!(scene.camera)
    scene.camera_controls = EmptyCamera()

    for field in [:backgroundcolor, :px_area, :visible]
        Observables.clear(getfield(scene, field))
    end
    for fieldname in (:rotation, :translation, :scale, :transform_func, :model)
        Observables.clear(getfield(scene.transformation, fieldname))
    end
    for obsfunc in scene.deregister_callbacks
        Observables.off(obsfunc)
    end
    empty!(scene.deregister_callbacks)
    return nothing
end


Base.push!(scene::Combined, subscene) = nothing # Combined plots add themselves uppon creation

function Base.push!(scene::Scene, plot::AbstractPlot)
    push!(scene.plots, plot)
    plot isa Combined || (plot.parent[] = scene)
    for screen in scene.current_screens
        insert!(screen, scene, plot)
    end
end

function Base.delete!(screen::MakieScreen, ::Scene, ::AbstractPlot)
    @warn "Deleting plots not implemented for backend: $(typeof(screen))"
end
function Base.delete!(screen::MakieScreen, ::Scene)
    # This may not be necessary for every backed
    @debug "Deleting scenes not implemented for backend: $(typeof(screen))"
end

function free(plot::AbstractPlot)
    for f in plot.deregister_callbacks
        Observables.off(f)
    end
    foreach(free, plot.plots)
    empty!(plot.plots)
    empty!(plot.deregister_callbacks)
    empty!(plot.attributes)
    free(plot.transformation)
    return
end

function Base.delete!(scene::Scene, plot::AbstractPlot)
    len = length(scene.plots)
    filter!(x -> x !== plot, scene.plots)
    if length(scene.plots) == len
        error("$(typeof(plot)) not in scene!")
    end
    for screen in scene.current_screens
        delete!(screen, scene, plot)
    end
    free(plot)
end

function Base.push!(scene::Scene, child::Scene)
    push!(scene.children, child)
    disconnect!(child.camera)
    observables = map([:view, :projection, :projectionview, :resolution, :eyeposition]) do field
        return lift(getfield(scene.camera, field)) do val
            getfield(child.camera, field)[] = val
            getfield(child.camera, field)[] = val
            return
        end
    end
    cameracontrols!(child, observables)
    child.parent = scene
    return scene
end

events(x) = events(get_scene(x))
events(scene::Scene) = scene.events
events(scene::SceneLike) = events(scene.parent)

camera(x) = camera(get_scene(x))
camera(scene::Scene) = scene.camera
camera(scene::SceneLike) = camera(scene.parent)

cameracontrols(x) = cameracontrols(get_scene(x))
cameracontrols(scene::Scene) = scene.camera_controls
cameracontrols(scene::SceneLike) = cameracontrols(scene.parent)

function cameracontrols!(scene::Scene, cam)
    scene.camera_controls = cam
    return cam
end
cameracontrols!(scene::SceneLike, cam) = cameracontrols!(parent(scene), cam)
cameracontrols!(x, cam) = cameracontrols!(get_scene(x), cam)

pixelarea(x) = pixelarea(get_scene(x))
pixelarea(scene::Scene) = scene.px_area
pixelarea(scene::SceneLike) = pixelarea(scene.parent)

plots(x) = plots(get_scene(x))
plots(scene::SceneLike) = scene.plots

"""
Fetches all plots sharing the same camera
"""
plots_from_camera(scene::Scene) = plots_from_camera(scene, scene.camera)
function plots_from_camera(scene::Scene, camera::Camera, list=AbstractPlot[])
    append!(list, scene.plots)
    for child in scene.children
        child.camera == camera && plots_from_camera(child, camera, list)
    end
    list
end

"""
Flattens all the combined plots and returns a Vector of Atomic plots
"""
function flatten_combined(plots::Vector, flat=AbstractPlot[])
    for elem in plots
        if (elem isa Combined)
            flatten_combined(elem.plots, flat)
        else
            push!(flat, elem)
        end
    end
    flat
end

function insertplots!(screen::AbstractDisplay, scene::Scene)
    for elem in scene.plots
        insert!(screen, scene, elem)
    end
    foreach(child -> insertplots!(screen, child), scene.children)
end

update_cam!(x, bb::AbstractCamera, rect) = update_cam!(get_scene(x), bb, rect)
update_cam!(scene::Scene, bb::AbstractCamera, rect) = nothing

function not_in_data_space(p)
    !is_data_space(to_value(get(p, :space, :data)))
end

function center!(scene::Scene, padding=0.01, exclude = not_in_data_space)
    bb = boundingbox(scene, exclude)
    bb = transformationmatrix(scene)[] * bb
    w = widths(bb)
    padd = w .* padding
    bb = Rect3f(minimum(bb) .- padd, w .+ 2padd)
    update_cam!(scene, bb)
    scene
end

parent_scene(x) = parent_scene(get_scene(x))
parent_scene(x::Combined) = parent_scene(parent(x))
parent_scene(x::Scene) = x

Base.isopen(x::SceneLike) = events(x).window_open[]

function is2d(scene::SceneLike)
    lims = data_limits(scene)
    lims === nothing && return nothing
    return is2d(lims)
end
is2d(lims::Rect2) = true
is2d(lims::Rect3) = widths(lims)[3] == 0.0

#####
##### Figure type
#####

struct Figure
    scene::Scene
    layout::GridLayoutBase.GridLayout
    content::Vector
    attributes::Attributes
    current_axis::Ref{Any}

    function Figure(args...)
        f = new(args...)
        current_figure!(f)
        f
    end
end

struct FigureAxisPlot
    figure::Figure
    axis
    plot::AbstractPlot
end

const FigureLike = Union{Scene, Figure, FigureAxisPlot}
