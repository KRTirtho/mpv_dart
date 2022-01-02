/// This module handles the communication with MPV over the IPC socket
/// created by the MPV player
/// It listens to the socket, parses the messages and forwards them to the
/// mpv module
/// It also offers methods for the communication with mpv

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eventify/eventify.dart';
import 'package:mpv_dart/src/error.dart';
import 'package:mpv_dart/src/ipc-interface/ipc_request.dart';

class IPCInterface extends EventEmitter {
  bool debug;
  Socket? socket;
  late ErrorHandler _errorHandler;

  IPCInterface({
    this.debug = false,
  }) {
    _errorHandler = ErrorHandler();
  }

  Map<dynamic, IPCRequest> ipcRequests = {};
  int messageId = 0;

  /// Thrown when the socket is closed by the other side\
  /// This function properly closes the socket by destroying it\
  /// Usually this will occur when MPV has crashed. The restarting is handled\
  /// by the mpv module, which will again recreate a socket
  ///
  /// `Event: close`
  void closeHandler() {
    if (debug) {
      print(
          '[MPV_DART]: Socket closed on the other side. This usually occurs when MPV has crashed');
    }
    // properly close the connection
    socket?.destroy();
    emit("socket:done");
  }

  /// Catches any error thrown by the socket and outputs it to the console
  /// if set to debug
  ///
  /// `Event: error`
  void errHandler(e) {
    if (debug) {
      print("[MPV_DART]: Socket Error occurred");
      print(e);
    }
    emit("socket:error");
  }

  /// Handles the data received by MPV over the ipc socket\
  /// MPV messages end with the \n character, this function splits it and
  /// for each message received
  ///
  /// Request messages sent from the module to MPV are either resolved or rejected
  /// Events are sent upward to the mpv module's event handler
  ///
  /// @param `data` - Data from the socket
  ///
  /// `Event: data`
  void dataHandler(Uint8List data) {
    // various messages might be fetched at once
    List<String> messages = utf8.decode(data).split('\n');

    // each message is emitted seperately
    messages.forEach((message) {
      // empty messages may occur
      if (message.isNotEmpty) {
        var msgMap = jsonDecode(message);
        if (debug) {
          print("[MPV_DART]: Received following data $message");
        }
        // if there was a request_id it was a request message
        if (msgMap["request_id"] != null) {
          // resolve promise
          if (msgMap["error"] == 'success') {
            // resolve the request
            ipcRequests[msgMap["request_id"]]?.complete(msgMap["data"]);
            // delete the ipcRequest object
            ipcRequests.remove(msgMap["request_id"]);
          }
          // reject promise
          else {
            // reject the message's promise
            ipcRequests[msgMap["request_id"]]?.completeError(msgMap["error"]);
            // delete the ipcRequest object
            ipcRequests.remove(msgMap["request_id"]);
          }
        }

        // events are handled the old-fashioned way
        else {
          emit('message', null, jsonDecode(message));
        }
      }
    });
  }

  /// starts the socket connection
  ///
  /// @param `socket` {String}
  Future<void> connect(String socketPath) async {
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );

      socket?.listen(
        (event) => dataHandler(event),
        onDone: () => closeHandler(),
        onError: (e) => errHandler(e),
      );

      if (debug) {
        print("[MPV_DART]: Connected to socket '${socket?.address}'");
      }
    } catch (e) {
      print(
          "[MPV_DART]: Failure while connecting to socket ${socket?.address}");
      rethrow;
    }
  }

  /// Sends a command in the correct JSON format to mpv
  ///
  /// @param `command` {String}\
  /// @param `args`  {List<String>}
  Future<T> command<T>(String command, {List args = const []}) {
    // command list for the JSON command {'command': commandList}
    List commandList = [command, ...args];
    // send it over the socket
    return send<T>(commandList);
  }

  quit() {
    socket?.destroy();
  }

  /// Sends message over the ipc socket and appends the \n character that
  /// is required to end all messages to mpv\
  /// Prints an error message if MPV is not running
  ///
  /// Not supposed to be used from outside
  ///
  /// @param `command` {String}
  Future<T> send<T>(List commands) async {
    Completer<T> completer = Completer<T>();
    // create the unique ID
    int requestId = messageId;
    messageId++;
    Map messageJson = {
      "command": commands,
      "request_id": requestId,
    };

    // create an ipcRequest object to store the required information for error messages
    // put the resolve function in the ipcRequests dictionary to call it later
    ipcRequests[requestId] =
        IPCRequest<T>(completer.complete, completer.completeError, commands);
    var data = jsonEncode(messageJson);
    try {
      if (debug) {
        print("[MPV_DART]: Writing following data to socket:\n$data");
      }
      socket?.write(data + "\n");
      // await socket?.flush();
    } catch (e, stackTrace) {
      completer.completeError(
        _errorHandler.errorMessage(
          8,
          data,
          args: ['send()'],
          errorMessage: jsonEncode([commands]),
        ),
      );
      print(e);
      print(stackTrace);
    }
    return completer.future;
  }

  /// Sets a certain property of mpv\
  /// Formats the message in the correct JSON format
  ///
  /// @param `property` {String}
  /// @param `value`
  ///
  Future<void> setProperty(String property, dynamic value) {
    // command list for the JSON command {'command': commandList}
    var commandList = ['set_property', property, value];
    // send it over the socket
    return send(commandList);
  }

  /// Adds to a certain property of mpv, for example volume\
  /// Formats the message in the correct JSON format
  ///
  /// @param `property` {String}
  /// @param `value` {number}
  ///
  Future<void> addProperty(String property, String value) {
    // command list for the JSON command {'command': commandList}
    var commandList = ['add', property, value];
    // send it over the socket
    return send(commandList);
  }

  /// Multiplies a certain property of mpv\
  /// Formats the message in the correct JSON format
  ///
  /// @param `property` {String}
  /// @param `value` {number}
  ///
  Future<void> multiplyProperty(String property, String value) {
    // command list for the JSON command {'command': commandList}
    var commandList = ['multiply', property, value];
    // send it over the socket
    return send(commandList);
  }

  /// Gets the value of a certain property of mpv\
  /// Formats the message in the correct JSON format
  ///
  /// The answer comes over a JSON message which triggers an event\
  /// Also resolved using promises
  ///
  /// @param `property` {String}
  /// @param `value` {number}
  ///
  Future<T> getProperty<T>(String property) {
    // command list for the JSON command {'command': commandList}
    var commandList = ['get_property', property];
    // send it over the socket
    return send<T>(commandList);
  }

  /// Some mpv properties can be cycled, such as mute or fullscreen,
  /// in which case this works like a toggle\
  /// Formats the message in the correct JSON format
  ///
  /// @param `property` {String}
  ///
  Future<void> cycleProperty(String property) {
    // command list for the JSON command {'command': commandList}
    var commandList = ['cycle', property];
    // send it over the socket
    return send(commandList);
  }

  /// Sends some arbitrary command to MPV
  ///
  /// @param `command` {String}
  ///
  Future<void> freeCommand(String command) async {
    try {
      socket?.write(command + '\n');
      await socket?.flush();
    } catch (error) {
      print(
          "[MPV_DART]: ERROR: MPV is not running - tried so send the message over socket '${socket?.address.toString()}");
    }
  }
}
