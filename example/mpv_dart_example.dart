import 'package:mpv_dart/mpv_dart.dart';

const mpvSocket = '/tmp/dart-mpv.sock';

void main() async {
  try {
    MPVPlayer mpvPlayer = MPVPlayer(
      audioOnly: true,
      debug: true,
      verbose: true,
      mpvArgs: [
        "--ytdl-raw-options-set=format=140,http-chunk-size=300000",
        "--script-opts=ytdl_hook-ytdl_path=yt-dlp",
      ],
    );
    await mpvPlayer.start();
    await mpvPlayer.load("ytdl://www.youtube.com/watch?v=Fp8msa5uYsc");

    mpvPlayer.on(MPVEvents.started, null, (ev, context) {
      print("MPV STARTED PLAYING");
    });

    mpvPlayer.on(MPVEvents.status, null, (ev, context) {
      print("MPV STATUS CHANGE: ${ev.eventData}");
    });

    mpvPlayer.on(MPVEvents.timeposition, null, (ev, context) {
      print("MPV TIMEPOSITION ${ev.eventData}");
    });
  } catch (e, stackTrace) {
    print(e);
    print(stackTrace);
  }
}
