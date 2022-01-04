## 0.0.1

- JSON IPC based bindings for [MPV](https://mpv.io) player
- Starts mpv sub process for JSON-IPC socket with `start`
- `load` file/network URL string
- `MPVEvents`
- loads playlist with `loadPlaylist`
- Control for `play|pause|next|prev|volume|mute|shuffle|playlistMove|loopPlaylist`
- Audio/Video/Subtitle Load/Remove/Control Support
- Get/Set/Observe/Cycle any viable [Property](https://mpv.io/manual/stable/#properties) arbitrarily with `getProperty|setProperty|observeProperty|cycleProperty`
- Send [commands](https://mpv.io/manual/stable/#list-of-input-commands) independently with `command` or use the defined ones
- Documentation & Code created by **[@KRTirtho](https://github.com/KRTirtho)**