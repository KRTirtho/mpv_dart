class IPCRequest<T> {
  Function(T) messageResolve;
  Function(Object) messageReject;
  dynamic args;
  String? caller;
  IPCRequest(this.messageResolve, this.messageReject, this.args) {}

  complete(T value) {
    // get the stack trace and look for the mpv function calls
    // const stackMatch  = new Error().stack.match(/mpv.\w+\s/g);
    // get the last mpv function as the relevant caller for error handling
    // this.caller = stackMatch ? stackMatch[stackMatch.length-1].slice(4, -1) + "()" : null;
    messageResolve(value);
  }

  completeError(Object err) {
    // const errHandler = new ErrorHandler();
    // const errMessage = errHandler.errorMessage(3, this.caller, this.args, err);
    messageReject(err);
  }
}
