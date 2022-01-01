import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eventify/eventify.dart';
import 'package:mpv_dart/src/error.dart';
import 'package:mpv_dart/src/ipc-interface/ipc_interface.dart';
import 'utils.dart' as utils;
import 'package:path/path.dart' as path;

class MPVEvents {
  static String crashed = 'crashed';
  static String quit = 'quit';
  static String stopped = 'stopped';
  static String started = 'started';
  static String paused = 'paused';
  static String resumed = 'resumed';
  static String seek = 'seek';
  static String status = 'status';
  static String timeposition = 'timeposition';
}

enum AudioFlag {
  select,
  auto,
  cached,
}

enum SeekMode {
  absolute,
  relative,
  appendPlay,
}

enum LoadMode {
  replace,
  append,
  appendPlay,
}

enum FileFormat {
  full,
  stripped,
}

class MPVPlayer extends EventEmitter {
  List<String> mpvArgs;
  bool debug;
  bool verbose;
  String socketURI = "";
  bool audioOnly;
  bool autoRestart;
  int timeUpdate;
  String? binary;
  late IPCInterface socket;
  late ErrorHandler _errorHandler;

  Process? _mpvPlayer;

  MPVPlayer({
    this.mpvArgs = const [],
    this.debug = false,
    this.verbose = false,
    this.socketURI = '/tmp/MPV_Dart.sock',
    this.audioOnly = false,
    this.autoRestart = true,
    this.timeUpdate = 1,
    this.binary,
  }) {
    socketURI =
        Platform.isWindows ? '\\\\.\\pipe\\mpvserver' : '/tmp/MPV_Dart.sock';

    mpvArgs = utils.mpvArguments(audioOnly, mpvArgs);

    socket = IPCInterface(debug: debug);

    _errorHandler = ErrorHandler();
  }

  double? currentTimePos;
  Map observedProperties = {};
  bool running = false;

  Timer? _timepositionListenerId;

  // loads a file into mpv
  // mode
  // replace          replace current video
  // append          append to playlist
  // append-play  append to playlist and play, if the playlist was empty
  //
  // options
  // further options
  Future<void> load(String source,
      {mode = 'replace', List<String> options = const []}) async {
    // check if this was called via load() or append() for error handling purposes
    String caller = utils.getCaller();

    // reject if mpv is not running
    if (!running) {
      throw (_errorHandler.errorMessage(8, caller, args: [
        source,
        mode,
        options
      ], options: {
        'replace': 'Replace the currently playing title',
        'append': 'Append the title to the playlist',
        'append-play':
            'Append the title and when it is the only title in the list start playback'
      }));
    }

    // MPV accepts various protocols, but the all start with <protocol>://, leave this input as it is
    // if it's a file, transform the path into the absolute filepath, such that it can be played
    // by any mpv instance, started in any working directory
    // also checks if the protocol is supported by mpv and throws an error otherwise
    String? sourceProtocol = utils.extractProtocolFromSource(source);
    if (sourceProtocol != null && !utils.validateProtocol(sourceProtocol)) {
      throw (_errorHandler.errorMessage(9, caller,
          args: [source, mode, options],
          errorMessage:
              'See https://mpv.io/manual/stable/#protocols for supported protocols'));
    }
    source = sourceProtocol != null ? source : path.absolute(source);

    _initCommandObserverSocket() async {
      Completer completer = Completer();
      Socket observeSocket = await Socket.connect(
        InternetAddress(socketURI, type: InternetAddressType.unix),
        0,
      );

      await command(
        'loadfile',
        [
          source,
          mode,
          options.join(","),
        ],
      );
      // get the playlist size
      int playlistSize = await getPlaylistSize();

      // if the mode is append resolve the promise because nothing
      // will be output by the mpv player
      // checking whether this source can be played or not is done when
      // the source is played
      if (mode == LoadMode.append && !completer.isCompleted) {
        observeSocket.destroy();
        completer.complete();
      }
      // if the mode is append-play and there are already songs in the playlist
      // resolve the promise since nothing will be output
      if (mode == LoadMode.appendPlay &&
          playlistSize > 1 &&
          !completer.isCompleted) {
        observeSocket.destroy();
        completer.complete();
      }

      // timeout
      int timeout = 0;
      // check if the source was started
      bool started = false;

      observeSocket.listen((event) {
        // increase timeout
        timeout += 1;
        // parse the messages from the socket
        List<String> messages = utf8.decode(event).split('\n');
        // check every message
        for (var message in messages) {
          // ignore empty messages
          if (message.isNotEmpty) {
            Map msgMap = jsonDecode(message);
            if (msgMap.containsKey("event")) {
              if (msgMap["event"] == 'start-file') {
                started = true;
              }
              // when the file has successfully been loaded resolve the promise
              else if (msgMap["event"] == 'file-loaded' &&
                  started &&
                  !completer.isCompleted) {
                observeSocket.destroy();
                // resolve the promise
                completer.complete();
              }
              // when the track has changed we don't need a seek event
              else if (msgMap["event"] == 'end-file' && started) {
                observeSocket.destroy();
                completer.completeError(
                    _errorHandler.errorMessage(0, caller, args: [source]));
              }
            }
          }
        }
      });

      // reject the promise if it took to long until the playback-restart happens
      // to prevent having sockets listening forever
      if (timeout > 10) {
        observeSocket.destroy();
        completer.completeError(
            _errorHandler.errorMessage(5, caller, args: [source]));
      }
    }

    await _initCommandObserverSocket();
  }

  // AUDIO MODULE START ====>

  // add audio track
  // file path to the audio file
  // flag select / auto /cached
  // title subtitle title in the UI
  // lang subitlte language
  Future<void> addAudioTrack(
      String file, AudioFlag? flag, String? title, String? lang) {
    List<String> args = [file];
    // add the flag if specified
    if (flag != null) {
      String flagValue;
      switch (flag) {
        case AudioFlag.auto:
          flagValue = 'auto';
          break;
        case AudioFlag.cached:
          flagValue = 'cached';
          break;
        default:
          flagValue = 'select';
      }
      args = [...args, flagValue];
    }

    // add the title if specified
    if (title != null) {
      args = [...args, title];
    }

    // add the language if specified
    if (lang != null) {
      args = [...args, lang];
    }

    // finally add the argument
    return command<void>('audio-add', args);
  }

  // delete the audio track specified by the id
  Future<void> removeAudioTrack(String id) {
    return command<void>('audio-remove', [id]);
  }

  // selects the audio track
  Future<void> selectAudioTrack(String id) {
    return socket.setProperty('audio', id);
  }

  // cycles through the audio track
  Future<void> cycleAudioTracks() {
    return socket.cycleProperty('audio');
  }

  // adjusts the timing of the audio track
  Future<void> adjustAudioTiming(int seconds) {
    return socket.setProperty('audio-delay', seconds);
  }

  // adjust the playback speed
  // factor  0.01 - 100
  Future<void> speed(double factor) {
    return socket.setProperty('speed', factor);
  }
  // AUDIO MODULE END ====>

  // COMMANDS MODULE START ====>
  // will send a get request for the specified property
  // if no idea is provided this will return a promise
  // if an id is provied the answer will come via a 'getrequest' event containing the id and data
  Future<T> getProperty<T>(property) {
    return socket.getProperty<T>(property);
  }

  // set a property specified by the mpv API
  Future<void> setProperty(property, value) {
    return socket.setProperty(property, value);
  }

  // sets all properties defined in the properties Json object
  Future<void> setMultipleProperties(Map properties) async {
    // check if the player is running
    if (running) {
      return await Future.forEach<MapEntry>(properties.entries,
          (element) async {
        return await socket.setProperty(element.key, element.value);
      });
    } else {
      throw _errorHandler.errorMessage(8, utils.getCaller());
    }
  }

  // adds the value to the property
  Future<void> addProperty(property, value) {
    return socket.addProperty(property, value);
  }

  // multiplies the specified property by the value
  Future<void> multiplyProperty(property, value) {
    return socket.multiplyProperty(property, value);
  }

  // cycles a arbitrary property
  Future<void> cycleProperty(property) {
    return socket.cycleProperty(property);
  }

  // send a command with arguments to mpv
  Future<T> command<T>(String command, List args) {
    return socket.command<T>(command, args: args);
  }

  // sends a command specified by a JSON object to mpv
  Future<void> commandJSON(Map command) {
    return socket.freeCommand(jsonEncode(command));
  }

  // send a freely writeable command to mpv.
  // the required trailing \n will be added
  Future<void> freeCommand(String command) {
    return socket.freeCommand(command);
  }

  // observe a property for changes
  // will be added to event for property changes
  Future<T> observeProperty<T>(String propertyKey) {
    // create the id assigned with this property
    // +1 because time-pos (which has the id 0) is not included in this object
    int prop_id = observedProperties.length + 1;
    // store the id into the hash map, such that it can be retrieved later if
    // the property should be unobserved
    observedProperties[propertyKey] = prop_id;
    return command<T>('observe_property', [prop_id, propertyKey]);
  }

  // stop observing a property
  Future<T> unobserveProperty<T>(String propertyKey) {
    // retrieve the id associated with this property
    var prop_id = observedProperties[propertyKey];
    observedProperties.remove(prop_id);
    return socket.command<T>('unobserve_property', args: [prop_id.toString()]);
  }
  // COMMANDS MODULE END ====>

  // CONTROLS MODULE START ====>
  Future<void> togglePause() {
    return cycleProperty('pause');
  }

  // pause
  Future<void> pause() {
    return setProperty('pause', true);
  }

  // resume
  Future<void> resume() {
    return setProperty('pause', false);
  }

  Future<void> play() async {
    var idle = await getProperty<bool>('idle-active');
    var playlistSize = await getPlaylistSize();
    // get the filename of the first item in the playlist for error handling purposes
    var fname = await getProperty('playlist/0/filename');

    bool started = false;

    if (idle && playlistSize > 0) {
      Socket observeSocket = await Socket.connect(
          InternetAddress(socketURI, type: InternetAddressType.unix), 0);

      await setProperty('playlist-pos', 0);

      observeSocket.listen((event) {
        var messages = utf8.decode(event).split("\n");
        for (var message in messages) {
          if (message.isNotEmpty) {
            Map messageMap = jsonDecode(message);
            if (messageMap.containsKey("event")) {
              if (messageMap["event"] == 'start-file') {
                started = true;
              }
              // when the file has successfully been loaded resolve the promise
              else if (messageMap["event"] == 'file-loaded' && started) {
                observeSocket.destroy();
                // resolve the promise
                return;
              }
              // when the track has changed we don't need a seek event
              else if (messageMap["event"] == 'end-file' && started) {
                observeSocket.destroy();
                // return reject();
                throw _errorHandler.errorMessage(0, 'play()', args: [fname]);
              }
            }
          }
        }
      });
    }
    // if mpv is not idle and has files queued just set the pause state to false
    else {
      await setProperty('pause', false);
    }
  }

  Future<void> stop() {
    return command('stop', []);
  }

  Future<void> volume(value) {
    return setProperty('volume', value);
  }

  Future<void> adjustVolume(value) {
    return addProperty('volume', value);
  }

  // mute
  // bool set
  // 	true mutes
  // 	false unmutes
  // 	Not setting set toggles the mute state
  Future<void> mute(bool? should) {
    return should != null ? setProperty('mute', should) : cycleProperty('mute');
  }

  Future<void> seek(double seconds, SeekMode mode) async {
    // tracks if the seek event has been emitted
    bool seekEventStarted = false;

    Socket observeSocket = await Socket.connect(
        InternetAddress(socketURI, type: InternetAddressType.unix), 0);

    String modeStr;
    switch (mode) {
      case SeekMode.absolute:
        modeStr = "absolute";
        break;
      case SeekMode.relative:
        modeStr = "relative";
        break;
      default:
        modeStr = "append-play";
    }

    await command<Map>('seek', [seconds.toString(), modeStr, 'exact']);

    observeSocket.listen((event) {
      var messages = utf8.decode(event).split("\n");
      for (var message in messages) {
        if (message.isNotEmpty) {
          Map messageMap = jsonDecode(message);
          if (messageMap.containsKey("event")) {
            if (messageMap["event"] == 'seek') {
              seekEventStarted = true;
            }
            // resolve the promise if the playback-restart event was fired
            else if (seekEventStarted &&
                messageMap["event"] == 'playback-restart') {
              observeSocket.destroy();
            }
          }
        }
      }
    });
  }

  // go to position of the song
  Future<void> goToPosition(double seconds) {
    return seek(seconds, SeekMode.absolute);
  }

  // loop
  // int/string times
  // 	number n - loop n times
  // 	'inf' 	 - loop infinitely often
  // 	'no'	 - switch loop to off
  //
  // if times is not set, this method will toggle the loop state, if any looping is set, either 'inf' or a fixed number it will be switched off
  Future<void> loop(times) async {
    // if times was set, use it. Times can be any number > 0, 'inf' and 'no'
    if (times != null) {
      return setProperty('loop', times);
    }
    // if times was not set, net loop toggle the mute property
    else {
      // get the loop status
      // if any loop status was set, either 'inf' or a fixed number, switch loop to off
      // if no loop status was set, switch it on to 'inf'
      var loop_status = await getProperty('loop');
      return setProperty('loop', loop_status == null ? 'inf' : 'no');
    }
  }
  // CONTROLS MODULE END ====>

  // INFORMATION MODULE START =====>
  // Shows if the player is muted
  //
  // @return {promise}
  Future<bool> isMuted() {
    return getProperty<bool>('mute');
  }

  // Shows if the player is paused
  //
  // @return {promise}
  Future<bool> isPaused() {
    return getProperty<bool>('pause');
  }

  // Shows if the current title is seekable or not
  // Not fully buffered streams are not for example
  //
  // @return {promise}
  Future<bool> isSeekable() {
    return getProperty<bool>('seekable');
  }

  // Duration of the currently playing song if available
  //
  // @return {promise}
  Future<double> getDuration() {
    return getProperty<double>('duration');
  }

  // Current time position of the currently playing song
  //
  // @return {promise}
  Future<double> getTimePosition() {
    return getProperty<double>('time-pos');
  }

  // Current time position (in percent) of the currently playing song
  //
  // @return {promise}
  Future<double> getPercentPosition() {
    return getProperty<double>('percent-pos');
  }

  // Remaining time for the currently playing song, if available
  //
  // @return {promise}
  Future<double> getTimeRemaining() {
    return getProperty<double>('time-remaining');
  }

  // Returns the available metadata for the current track. The output is very dependant
  // on the loaded file
  //
  // @return {promise}
  Future<Map> getMetadata() {
    return getProperty<Map>('metadata');
  }

  // Title of the currently playing song. Might be unavailable
  //
  // @return {promise}
  Future<String> getTitle() {
    return getProperty<String>('media-title');
  }

  // Returns the artist of the current song if available
  //
  // @return {promise}
  Future getArtist() async {
    var metadata = await getMetadata();
    return metadata["artist"];
  }

  // Returns the album title of the current song if available
  //
  // @return {promise}
  Future getAlbum() async {
    var metadata = await getMetadata();
    return metadata["album"];
  }

  // Returns the year of the current song if available
  //
  // @return {promise}
  Future getYear() async {
    var metadata = await getMetadata();
    return metadata["date"];
  }

  // Returns the filename / url of the current track
  //
  // full     - full path or url
  // stripped - stripped path missing the base
  //
  // @return {promise}
  Future<String> getFilename({FileFormat format = FileFormat.full}) {
    // get the information
    return getProperty<String>(
        format == FileFormat.stripped ? 'filename' : 'path');
  }

  // INFORMATION MODULE END =====>

  // EVENT MODULE START =====>
  // When the MPV is closed (either quit by the user or has crashed),
  // this handler is called
  //
  // If quit by the user, the quit event is emitted, does not occur
  // when the quit() method was used

  // If crashed the crashed event is emitted and if set to auto_restart, mpv
  // is restarted right away
  //
  // Event: close
  closeHandler() {
    // Clear all the listeners of this module
    // mpvPlayer.removeAllListeners('close');
    // mpvPlayer.removeAllListeners('error');
    // mpvPlayer.removeAllListeners('message');
    _timepositionListenerId?.cancel();

    // destroy the socket because a new one will be created
    socket.socket?.destroy();

    // unset the running flag
    running = false;

    // restart if auto restart enabled
    if (autoRestart) {
      if (debug || verbose) {
        print('[MPV_Dart]: MPV Player has crashed, tying to restart');
      }

      // restart mpv
      start().then((val) {
        // emit crashed event
        emit(MPVEvents.crashed);
        if (debug || verbose) {
          print('[MPV_Dart]: Restarted MPV Player');
        }
      })
          // report the error if one occurs
          .catchError((error) {
        print(error);
      });
    }
    // disabled auto restart
    else {
      // emit crashed event
      emit(MPVEvents.crashed);
      if (debug || verbose) {
        print('[MPV_Dart]: MPV Player has crashed');
      }
    }
  }

  // Parses the messages emittet from the ipcInterface. They are all JSON objects
  // sent directly by MPV
  //
  // The different events
  // 		idle:			  MPV stopped playing
  // 		playback-restart: MPV started playing
  // 		pause:			  MPV has paused
  // 		resume: 		  MPV has resumed
  // 		property-change   One (or more) of the properties have changed
  // are handled. They are then turned into events of this module
  //
  // This handler also handles the properties requested via the getProperty methpd
  //
  // @param message {Object}
  // JSON message from MPV
  //
  // Event: message
  messageHandler(Map message) {
    // handle MPV event messages
    if (message.containsKey("event")) {
      // Handle the different event types
      switch (message["event"]) {
        case 'idle':
          if (verbose) {
            print('Event: stopped');
          }
          // emit stopped event
          emit(MPVEvents.stopped);
          break;
        case 'playback-restart':
          if (verbose) {
            print('Event: start');
          }
          // emit play event
          emit(MPVEvents.started);
          break;
        case 'pause':
          if (verbose) {
            print('Event: pause');
          }
          // emit paused event
          emit(MPVEvents.paused);
          break;
        case 'unpause':
          if (verbose) {
            print('Event: unpause');
          }
          // emit unpaused event
          emit(MPVEvents.resumed);
          break;
        case 'seek':
          if (verbose) {
            print('Event: seek');
          }
          // socket to watch for the change after a seek has happened
          late Socket observeSocket;
          // start seek position
          var seekStartTimePos = currentTimePos;
          // timeout tracker
          int timeout = 0;
          // promise to watch the socket output

          Future<Map> initMPVTempSocket() async {
            Completer<Map> completer = Completer<Map>();
            // connect a tempoary socket to the mpv player
            observeSocket = await Socket.connect(
                InternetAddress(socketURI, type: InternetAddressType.unix), 0);

            observeSocket.listen((Uint8List event) {
              // increase timeout
              timeout += 1;
              // print(data.toJSON());
              List<String> messages = utf8.decode(event).split("\n");
              // check every message
              messages.forEach((message) {
                // ignore empty messages
                if (message.isNotEmpty) {
                  Map msgMap = jsonDecode(message);
                  if (msgMap.containsKey("event")) {
                    // after the seek is finished the playback-restart event is emitted
                    if (msgMap["event"] == 'playback-restart') {
                      // resolve the promise
                      completer.complete(
                          {"start": seekStartTimePos, "end": currentTimePos});
                    }
                    // when the track has changed we don't need a seek event
                    else if (msgMap["event"] == 'tracks-changed') {
                      completer.completeError('Track changed after seek');
                    }
                  }
                }
              });
              // reject the promise if it took to long until the playback-restart happens
              // to prevent having sockets listening forever
              if (timeout > 10) {
                completer.completeError('Seek event timeout');
              }
            });

            return completer.future;
          }
          initMPVTempSocket()
              // socket destruction and event emittion
              .then((times) {
            observeSocket.destroy();
            emit(MPVEvents.seek, (times));
          })
              // handle any rejection of the promise
              .catchError((status) {
            observeSocket.destroy();
            if (debug) {
              print(status);
            }
          });
          break;
        // observed properties
        case 'property-change':
          // time position events are handled seperately
          if (message["name"] == 'time-pos') {
            // set the current time position
            currentTimePos = message["data"];
          } else {
            // emit a status event
            emit(MPVEvents.status,
                {'property': message["name"], 'value': message["data"]});
            // output if verbose
            if (verbose) {
              print('[MPV_Dart]: Event: status');
              print(
                  '[MPV_Dart]: Property change: {$message["name"]} - ${message["data"]}');
            }
          }
          break;
        // Default
        default:
          break;
      }
    }
  }
  // EVENT MODULE END =====>

  // START_STOP MODULE START =====>
  // =========================================================
  // CHECKING IF THERE IS A MPV INSTANCE RUNNING ON THE SOCKET
  // =========================================================

  Future<bool> _isInstanceRunning() async {
    Completer<bool> completer = Completer<bool>();
    try {
      Socket sock = await Socket.connect(
          InternetAddress(socketURI, type: InternetAddressType.unix), 0);

      sock.listen(
        (event) {
          Map res = jsonDecode(utf8.decode(event));
          completer.complete(res.containsKey("data") &&
              res.containsKey("error") &&
              res["error"] == "success");
          sock.destroy();
        },
      );

      sock.writeln(jsonEncode({
        'command': ['get_property', 'mpv-version']
      }));

      await sock.flush();
    } catch (e) {
      completer.complete(false);
    }
    return completer.future;
  }

  Future<void> _createMPVSubProcess(
    String ipcCommand,
    List<String> mpv_args,
  ) async {
    Completer completer = Completer();

    // check if mpv could be started succesffuly
    // add the ipcCommand to the arguments
    mpvArgs.add(ipcCommand + '=' + socketURI);
    // spawns the mpv player

    _mpvPlayer = await Process.start(
        binary != null ? binary! : 'mpv', [...mpvArgs, ...mpv_args]);
    // callback to listen to stdout + stderr to see, if MPV could bind the IPC socket
    stdCallback(event) {
      RegExp successRegexp =
          RegExp("Listening to IPC (socket|pipe)", multiLine: true);
      RegExp failRegexp =
          RegExp("Could not bind IPC (socket|pipe)", multiLine: true);
      var data = utf8.decode(event);
      print("[MPV SUBPROCESS DATA]: ${data}");
      if (successRegexp.hasMatch(data)) {
        // mpvPlayer.stdout.removeListener
        // mpvPlayer.stderr.removeListener
        completer.complete();
      } else if (failRegexp.hasMatch(data)) {
        // mpvPlayer.stdout.removeListener
        // mpvPlayer.stderr.removeListener
        completer.completeError(
          _errorHandler.errorMessage(4, 'startStop()', args: [socketURI]),
        );
      }
    }

    // listen to stdout to check if the IPC socket is ready
    _mpvPlayer?.stdout.listen(stdCallback);
    // in some cases on windows, if you pipe your output to a file or another command, the messages that
    // are usually output via stdout are output via stderr instead. That's why it's required to listen
    // for the same messages on stderr as well
    _mpvPlayer?.stderr.listen(stdCallback);

    return completer.future;
  }

  Future<void> _checkMPVIdleMode() async {
    Completer completer = Completer<bool>();

    // check if mpv went into idle mode and is ready to receive commands
    // Set up the socket connection
    await socket.connect(socketURI);
    // socket to check for the idle event to check if mpv fully loaded and
    // actually running
    Socket observeSocket = await Socket.connect(
        InternetAddress(socketURI, type: InternetAddressType.unix), 0);

    observeSocket.writeln(jsonEncode({
      'command': ['get_property', 'idle-active']
    }));
    await observeSocket.flush();
    if (debug || verbose) print('[MPV_Dart] sending stimulus');

    observeSocket.listen((event) {
      // parse the messages from the socket
      List<String> messages = utf8.decode(event).split('\n');
      // check every message
      messages.forEach((message) {
        // ignore empty messages
        if (message.isNotEmpty) {
          Map msgMap = jsonDecode(message);
          // check for the relevant events to see, if mpv has finished loading
          // idle, idle-active (different between mpv versions)
          //     usually if no special options were added and mpv will go into idle state
          // file-loaded
          //     for the rare case that somebody would pass files as input via the command line
          //     through the constructor. In that case mpv never goes into idle mode
          if (msgMap.containsKey("event") &&
              ['idle', 'idle-active', 'file-loaded']
                  .contains(msgMap["event"]) &&
              !completer.isCompleted) {
            if (debug || verbose) print('[MPV_Dart] idling');
            observeSocket.destroy();
            completer.complete(true);
          }
          // check our stimulus response
          // Check for our stimulus with idle-active
          if (msgMap.containsKey("data") &&
              msgMap.containsKey("data") &&
              msgMap["error"] == 'success' &&
              !completer.isCompleted) {
            if (debug || verbose)
              print('[MPV_Dart] stimulus received ${msgMap["data"]}');
            observeSocket.destroy();
            completer.complete(true);
          }
        }
      });
    });
    return completer.future;
  }

  // Starts the MPV player process
  //
  // After MPV is started the function listens to the spawned MPV child proecesses'
  // stdout for see whether it could create and bind the IPC socket or not.
  // If possible an ipcInterface is created to handle the socket communication
  //
  // Observes the properties defined in the observed object
  // Sets up the event handlers
  //
  // mpv_args
  // 	arguments that are passed to mpv on start up
  //
  // @return
  // Promise that is resolved when everything went fine or rejected when an
  // error occured
  //
  Future<void> start({List<String> mpv_args = const []}) async {
    // check if mpv is already running

    if (running) {
      throw _errorHandler.errorMessage(6, 'start()');
    }

    // see if there's already an mpv instance running on the specified socket

    bool instance_running = await _isInstanceRunning();

    // these steps are only necessary if a new MPV instance is created, if the module is hooking into an existing
    // one, there's no need to start a new instance
    if (!instance_running) {
      // =========================
      // STARTING NEW MPV INSTANCE
      // =========================

      // check if the binary is actually available
      await utils.checkMpvBinary(binary);
      // check for the corrrect ipc command
      const ipcCommand = "--input-ipc-server";

      await _createMPVSubProcess(ipcCommand, mpv_args);
      await _checkMPVIdleMode();
      instance_running = true;
    }
    // if the module is hooking into an existing instance of MPV, we still ned to set up the
    // socket connection for the module
    else {
      await socket.connect(socketURI);
      if (debug || verbose) {
        print("[MPV_Dart]: Detected running MPV instance at ${socketURI}");
        print(
            '[MPV_Dart]: Hooked into existing MPV instance without starting a new one');
      }
    }

    // ============================================
    // SETTING UP THE PROPERTIES AND EVENT LISTENER
    // ============================================

    // set up the observed properties

    // sets the Interval to emit the current time position
    await observeProperty(
      'time-pos', /* 0 */
    );

    _timepositionListenerId =
        Timer.periodic(Duration(seconds: timeUpdate * 1000), (timer) async {
      bool paused = await isPaused().catchError((err) {
        if (debug) {
          print(
              '[MPV_Dart] timeposition listener cannot retrieve isPaused $err');
        }
        if (err.code == 8) {
          // mpv is not running but the interval was not cleaned out
          timer.cancel();
          return true;
        } else {
          throw err; // This error is not catcheable, maybe provide a function in options to catch these
        }
      });
      if (!paused && currentTimePos != null) {
        emit(MPVEvents.timeposition, currentTimePos);
      }
    });

    // Observe all the properties defined in the observed JSON object
    List<Future> observePromises = [];

    utils
        .observedProperties(audioOnly)
        .forEach((property) => observePromises.add(observeProperty(property)));

    // wait for all observe commands to finish
    await Future.wait(observePromises);

    // ### Events ###

    // events linked to the mpv instance can only be set up, if mpv was started by node js itself
    // it's not possible for an mpv instance started from a different process
    if (!instance_running) {
      // RECURSIVE METHOD (KEEP AN EYE)
      closeHandler();
    }
    // if the module is hooking into an existing and running instance of mpv we need an event listener
    // that is attached directly to the net socket, to clear the interval for the time position
    else {
      socket.on("socket:done", null, (e, c) {
        _timepositionListenerId?.cancel();
        // it's kind of impossible to tell if an external instance was properly quit or has crashed
        // that's why both events are emitted
        emit(MPVEvents.crashed);
        emit(MPVEvents.quit);
      });
    }

    // Handle the JSON messages received from MPV via the ipcInterface
    socket.on('message', null, (message, c) {
      messageHandler(message.eventData as Map);
    });

    // set the running flag
    running = true;

    // resolve this promise
    return;
  }

  // Quits the MPV player
  //
  // All event handlers are unbound (thus preventing the close event from
  // restarting MPV
  // The socket is destroyed
  Future<void> quit() async {
    // Clear all the listeners of this module
    // this.mpvPlayer.removeAllListeners('close');
    // this.mpvPlayer.removeAllListeners('error');
    // this.mpvPlayer.removeAllListeners('message');
    _timepositionListenerId?.cancel();
    // send the quit message to MPV
    await command("quit", []);
    // Quit the socket
    socket.quit();
    // unset the running flag
    running = false;
  }

  // Shows whether mpv is running or not
  //
  // @return {boolean}
  isRunning() {
    return running;
  }
  // START_STOP MODULE END =====>

  // PLAYLIST MODULE START ======>
  Future<int> getPlaylistSize() {
    return getProperty<int>('playlist-count');
  }
  // PLAYLIST MODULE START ======>
}
