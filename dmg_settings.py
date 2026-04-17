application = "build/Build/Products/Release/KnockMac.app"
appname = "KnockMac"

format = "ULFO"
size = "50M"
filesystem = "APFS"

files = [application]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    "KnockMac.app": (170, 180),
    "Applications": (480, 180),
}

window_rect = ((200, 200), (650, 400))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 14
