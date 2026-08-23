#
# Deadeye. Copyright (C) 2026 inulute.
# Licensed under the GNU General Public License v3.0. See LICENSE.
#
# Layout for the installer disk image, read by dmgbuild.
#
# dmgbuild rather than create-dmg or an AppleScript: it writes the .DS_Store that
# carries the window size, background and icon positions directly, instead of driving
# Finder. Finder cannot be scripted on a CI runner, so the AppleScript approach can
# only ever produce a styled image on somebody's desk.
#
# background.tiff is committed pre-rendered rather than built from background.svg at
# release time. Rendering the SVG needs cairo, which is a native library a runner does
# not ship, and dmgbuild itself is pure Python. Trading one committed binary for one
# fewer brew install on every release is worth it. Re-render after editing the SVG:
#
#   python3 -c "import cairosvg; [cairosvg.svg2png(url='assets/dmg/background.svg', \
#     write_to=o, output_width=660*s, output_height=400*s) for s,o in ((1,'/tmp/b1.png'),(2,'/tmp/b2.png'))]"
#   tiffutil -cathidpicheck /tmp/b1.png /tmp/b2.png -out assets/dmg/background.tiff
#
import os

app = os.environ.get("DMG_APP", "Deadeye.app")
# Paths are relative to the working directory, which is the repository root for both
# the release workflow and a local build. dmgbuild exec()s this file without setting
# __file__, so locating the background relative to the settings file is not an option.
background = os.environ.get("DMG_BACKGROUND", "assets/dmg/background.tiff")

files = [app]
symlinks = {"Applications": "/Applications"}

# 660x400 matches the artwork's viewBox exactly. Any disagreement here shows up as a
# background that is offset or cropped.
window_rect = ((240, 200), (660, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13

show_toolbar = False
show_statusbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
# Without this Finder is free to re-flow the icons and undo the positions below.
arrange_by = None

# The app sits on the radial lift painted into the background; Applications sits in
# the dashed plate. Both coordinates have to agree with the artwork.
icon_locations = {
    os.path.basename(app): (190, 205),
    "Applications":        (470, 205),
}

badge_icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
format = "UDZO"
volume_name = "Deadeye"
