## MPV Dart

[MPV](https://mpv.io) Player's JSON-IPC binding for Dart (Flutter Supported)

### Installation
Install in your Dart/Flutter project with:
```bash
$ dart pub add dart_mpv
```

```bash
$ flutter pub add dart_mpv
```

> **mpv_dart** requires **mpv player** to be installed in your System. To learn how to install for your operating system, go [here](https://mpv.io/installation/)

### Usage

Create an MPVPlayer instance
```dart
import 'package:mpv_dart/mpv_dart.dart';

void main() async {
    MPVPlayer player = MPVPlayer();
    // start the native player process
    await player.start();

    // load any file/url
    await player.load("ytdl://www.youtube.com/watch?v=Fp8msa5uYsc")
   
   // adjust volume (percentage)
   await player.volume(50);
}
```

## Changelog
Too see changes go [here](/CHANGELOG.md)