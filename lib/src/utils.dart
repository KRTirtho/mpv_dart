import 'dart:async';

import 'dart:io';

List<String> mpvArguments(bool audio_only, List<String>? userInputArgs) {
  // determine the IPC argument

  // default Arguments
  // --idle always run in the background
  // --msg-level=all=no,ipc=v  sets IPC socket related messages to verbose and
  // silence all other messages to avoid buffer overflow
  var defaultArgs = ['--idle', '--msg-level=all=no,ipc=v'];
  //  audio_only option aditional arguments
  // --no-video  no video will be displayed
  // --audio-display  prevents album covers embedded in audio files from being displayed
  if (audio_only) {
    defaultArgs = [
      ...defaultArgs,
      ...['--no-video', '--no-audio-display']
    ];
  }

  // add the user specified arguments if specified
  if (userInputArgs != null) {
    // concats the arrays removing duplicates
    defaultArgs = <String>{...defaultArgs, ...userInputArgs}.toList();
  }

  return defaultArgs;
}

Future<void> checkMpvBinary(String? binary) async {
  Completer completer = Completer();
  if (binary != null) {
    try {
      FileStat stat = await FileStat.stat(binary);
      if (stat.type != FileSystemEntityType.notFound) {
        completer.complete();
      }
    } catch (e) {
      completer
          .completeError(Exception("[MPV_DART]: Failed checking mpv binary"));
    }
  } else {
    completer.complete();
  }
  return completer.future;
}

List<String> observedProperties(bool audioOnlyOption) {
  // basic observed properties
  const List<String> basicObserved = [
    'mute',
    'pause',
    'duration',
    'volume',
    'filename',
    'path',
    'media-title',
    'playlist-pos',
    'playlist-count',
    'loop',
  ];

  // video related properties (not required in audio-only mode)
  const List<String> observedVideo = ['fullscreen', 'sub-visibility'];

  return audioOnlyOption ? basicObserved : basicObserved + observedVideo;
}

/// searches the function stack for the topmost mpv function that was called and returns it
///
/// @return
/// name of the topmost mpv function on the function stack with added ()
/// example: mute(), load() ...
String getCaller() {
  // get the top most caller of the function stack for error message purposes
  RegExp regExp = RegExp(r"#\d*.*\w+\.?\w*.*\(");
  RegExp garbage = RegExp(r"#?\d?\s*[^\w^\d^\.]*");
  var stackStr = StackTrace.current.toString();
  var stackMatch = regExp.allMatches(stackStr).toList().asMap().entries.map(
      (m) => "${m.key}. ${m.value.group(0)?.replaceAll(garbage, "").trim()}()");
  var caller = "[${stackMatch.join(", ")}]";
  return caller;
}

String? extractProtocolFromSource(String source) {
  return !source.contains('://') ? null : source.split('://')[0];
}

/// checks if a given protocol is supported\
/// @param protocol - protocol string, e.g. "http"
bool validateProtocol(String protocol) {
  return [
    "appending",
    "av",
    "bd",
    "cdda",
    "dvb",
    "dvd",
    "edl",
    "fd",
    "fdclose",
    "file",
    "hex",
    "http",
    "https",
    "lavf",
    "memory",
    "mf",
    "null",
    "slice",
    "smb",
    "udp",
    "ytdl"
  ].contains(protocol);
}

/// takes an options list consisting of strings of the following pattern\
/// `option=value` => e.g `["option1=value1", "option2=value2"]`\
/// and formats into a JSON object such that the mpv JSON api accepts it\
///   => `{"option1": "value1", "option2": "value2"}`\
/// @param `options` - list of options
///
/// @returns  correctly formatted JSON object with the options
Map formatOptions(List<String> options) {
  // JSON Options object
  Map optionJSON = {};
  // each options is of the form options=value and has to be splited
  List splitted = [];
  // iterate through every options
  for (int i = 0; i < options.length; i++) {
    // Splits only on the first = character
    splitted = options[i].split("=");
    optionJSON[splitted[0]] = splitted[1];
  }
  return optionJSON;
}
