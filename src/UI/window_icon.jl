# The dashboard's window icon. `assets/render.sh` renders `assets/icon.svg` into raw
# 8-bit RGBA rows, `assets/icon-<n>.rgba`, so reading it needs no image decoder.

const ASSET_DIRECTORY = normpath(joinpath(@__DIR__, "..", "..", "assets"))
const WINDOW_ICON_SIZES = (16, 32, 48)

# The dashboard window's class (X11) and application id (Wayland): the desktop finds
# the window's desktop entry, and with it the icon, by these names
const DESKTOP_WINDOW_CLASS = "PsychophysicsManager"
const DESKTOP_APP_ID = "psychophysicsmanager"

# One image per size, indexed `[row, column]` from the top-left, as GLFW.jl takes them
function window_icon_images()
    return map(collect(WINDOW_ICON_SIZES)) do n
        path = joinpath(ASSET_DIRECTORY, "icon-$n.rgba")
        bytes = read(path)
        length(bytes) == 4n^2 || error("$path holds $(length(bytes)) bytes, not a $n × $n RGBA image")
        return permutedims(reshape(collect(reinterpret(NTuple{4, UInt8}, bytes)), n, n))
    end
end

"""
    install_desktop_icon(; directory) -> String

Shows the package logo for the operator dashboard in the task bar and the window
switcher of a Linux desktop. GNOME draws a window's icon only from the desktop
entry that names its window class; this writes that entry,
`psychophysicsmanager.desktop`, into `directory` (by default the user's
`applications` directory) and returns its path. The entry is hidden from the
application menu. Run it once per user, and again after the package moves.
"""
function install_desktop_icon(; directory::AbstractString = joinpath(
        get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share")), "applications"))
    mkpath(directory)
    path = joinpath(directory, "$DESKTOP_APP_ID.desktop")
    write(path, """
        [Desktop Entry]
        Type=Application
        Name=PsychophysicsManager
        Comment=Psychophysical Experiment Manager operator dashboard
        Icon=$(joinpath(ASSET_DIRECTORY, "logo-256.png"))
        Exec=$(joinpath(Sys.BINDIR, "julia"))
        StartupWMClass=$DESKTOP_WINDOW_CLASS
        NoDisplay=true
        """)
    return path
end
