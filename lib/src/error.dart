class ErrorHandler {
  Map messageDict = {};
  ErrorHandler() {
    messageDict = {
      0: 'Unable to load file or stream',
      1: 'Invalid argument',
      2: 'Binary not found',
      3: 'ipcCommand invalid',
      4: 'Unable to bind IPC socket',
      5: 'Timeout',
      6: 'MPV is already running',
      7: 'Could not send IPC message',
      8: 'MPV is not running',
      9: 'Unsupported protocol'
    };
  }

  /// creates the error message JSON object
  ///
  /// @param `errorCode` - the errorCode for the error\
  /// @param `method` - method this error is created/raised from\
  /// @param `args` (optional) - arguments that method was called with\
  /// @param `errorMessage` (optional) - specific error message\
  /// @param `options` (options) - valid arguments for the method that raised the error	of the form
  /// ```
  /// {
  /// 	'argument1': 'foo',
  /// 	'argument2': 'bar'
  /// }
  /// ```
  ///
  /// @return - JSON error object
  errorMessage(int errorCode, String method,
      {List? args, String? errorMessage, Map? options}) {
    // basic error object
    Map errorObject = {
      'errcode': errorCode,
      'verbose': messageDict[errorCode],
      'method': method,
    };

    // add arguments if available
    if (args != null) {
      errorObject['arguments'] = args;
    }

    // add error Message if available
    if (errorMessage != null) {
      errorObject["errmessage"] = errorMessage;
    }

    // add argument options if available
    if (options != null) {
      errorObject["options"] = options;
    }

    // stack trace
    errorObject["stackTrace"] = Error().stackTrace;

    return errorObject;
  }
}
