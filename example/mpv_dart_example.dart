import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eventify/eventify.dart';
import 'package:logger/logger.dart';
import 'package:mpv_dart/src/ipc-interface/ipc_interface.dart';
import 'package:mpv_dart/src/mpv.dart';

const MPV_SOCKET = '/tmp/dart-mpv.sock';

void main() async {
  Logger logger = Logger();
  func() async {
    try {
      EventEmitter mpvEvents = EventEmitter();
      // starting mpv thread
      final mpvPlayer = await Process.start(
        "mpv",
        [
          "--idle",
          "--msg-level=all=no,ipc=v",
          "--no-video",
          "--no-audio-display",
          "--input-ipc-server=$MPV_SOCKET",
          "--ytdl-raw-options-set=format=140,http-chunk-size=300000",
          "--script-opts=ytdl_hook-ytdl_path=yt-dlp"
        ],
      );

      print("MPV PLAYER Started");

      mpvPlayer.stdout.listen((event) {
        RegExp successRegexp =
            RegExp("Listening to IPC (socket|pipe)", multiLine: true);
        RegExp failRegexp =
            RegExp("Could not bind IPC (socket|pipe)", multiLine: true);
        var data = utf8.decode(event);
        print("[MPV SUBPROCESS DATA]: ${data}");
        if (successRegexp.hasMatch(data)) {
          mpvEvents.emit("connection");
        } else if (failRegexp.hasMatch(data)) {
          mpvEvents.emit("failed");
        }
      });

      mpvPlayer.stderr.listen((event) {
        print("[MPV SUBPROCESS ERROR]: ${utf8.decode(event)}");
      });

      mpvEvents.on("connection", null, (ev, context) async {
        try {
          IPCInterface ipcInterface = IPCInterface(debug: true);
          await ipcInterface.connect(MPV_SOCKET);
          final data = await ipcInterface.command<Map>(
            "loadfile",
            args: ["ytdl://www.youtube.com/watch?v=Fp8msa5uYsc"],
          );
          print("[IPCRequest DATA] $data");
          await ipcInterface.setProperty("pause", false);
        } catch (e) {
          print("[Init IPCInterface Error]: $e");
        }
      });
    } catch (error) {
      print(error);
    }
  }

  // func();

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
  } catch (e) {
    print(e);
  }
}


      // var internetAddress =
      //     InternetAddress(MPV_SOCKET, type: InternetAddressType.unix);

      // Socket socket = await Socket.connect(internetAddress, 0);

      // print("Socket Connected");

      // socket.listen((event) {
      //   String message = utf8.decode(event);
      //   print("[EVENT DATA]: $message");
      // }, onDone: () {
      //   print("Socket Closes");
      //   socket.destroy();
      // }, onError: (e) {
      //   print("Socket Error");
      // });

      // var requestId = 0;
      // socket.writeln(jsonEncode({
      //   "command": ["loadfile", "ytdl://www.youtube.com/watch?v=M11SvDtPBhA"],
      //   "request_id": requestId++,
      // }));
      // socket.writeln(jsonEncode({
      //   "command": ["set_property", "pause", false],
      //   "request_id": requestId++
      // }));

      // await socket.flush();