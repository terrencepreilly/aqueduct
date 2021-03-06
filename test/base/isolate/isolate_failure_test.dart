import 'package:test/test.dart';
import 'package:aqueduct/aqueduct.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:io';
import '../../helpers.dart';

void main() {
  setUpAll(() {
    justLogEverything();
  });

  tearDownAll(() {
    new Logger("aqueduct").clearListeners();
  });

  group("Failures", () {
    test(
        "Application start fails and logs appropriate message if request stream doesn't open",
            () async {
          var crashingApp = new Application<CrashSink>();

          try {
            crashingApp.configuration.options = {"crashIn": "constructor"};
            await crashingApp.start(consoleLogging: true);
            expect(true, false);
          } on ApplicationStartupException catch (e) {
            expect(e.toString(), contains("TestException: constructor"));
          }

          try {
            crashingApp.configuration.options = {"crashIn": "addRoutes"};
            await crashingApp.start(consoleLogging: true);
            expect(true, false);
          } on ApplicationStartupException catch (e) {
            expect(e.toString(), contains("TestException: addRoutes"));
          }

          try {
            crashingApp.configuration.options = {"crashIn": "willOpen"};
            await crashingApp.start(consoleLogging: true);
            expect(true, false);
          } on ApplicationStartupException catch (e) {
            expect(e.toString(), contains("TestException: willOpen"));
          }

          crashingApp.configuration.options = {"crashIn": "dontCrash"};
          await crashingApp.start(consoleLogging: true);
          var response = await http.get("http://localhost:8081/t");
          expect(response.statusCode, 200);
          await crashingApp.stop();
        });

    test(
        "Application that fails to open because port is bound fails gracefully",
            () async {
          var server = await HttpServer.bind(InternetAddress.ANY_IP_V4, 8081);
          server.listen((req) {});

          var conflictingApp = new Application<TestSink>();
          conflictingApp.configuration.port = 8081;

          try {
            await conflictingApp.start(consoleLogging: true);
            expect(true, false);
          } on ApplicationStartupException catch (e) {
            expect(e.toString(), contains("Failed to create server socket"));
          }

          await server.close(force: true);
        });

    test("Isolate timeout kills application when first isolate fails", () async {
      var timeoutApp = new Application<TimeoutSink>()
        ..isolateStartupTimeout = new Duration(seconds: 4)
        ..configuration.options = {
          "timeout1" : 10
        };

      try {
        await timeoutApp.start(numberOfInstances: 2, consoleLogging: true);
        expect(true, false);
      } on TimeoutException catch (e) {
        expect(e.toString(), contains("Isolate (1) failed to launch"));
      }

      expect(timeoutApp.supervisors.length, 0);
      print("-- test completes");
    });

    test("Isolate timeout kills application when first isolate succeeds, but next fails", () async {
      var timeoutApp = new Application<TimeoutSink>()
        ..isolateStartupTimeout = new Duration(seconds: 4)
        ..configuration.options = {
          "timeout2" : 10
        };

      try {
        await timeoutApp.start(numberOfInstances: 2, consoleLogging: true);
        expect(true, false);
      } on TimeoutException catch (e) {
        expect(e.toString(), contains("Isolate (2) failed to launch"));
      }

      expect(timeoutApp.supervisors.length, 0);
      print("-- test completes");
    });
  });
}

class TimeoutSink extends RequestSink {
  Timer timer;

  TimeoutSink(ApplicationConfiguration config) : super(config);
  @override
  void setupRouter(Router router) {}

  @override
  Future willOpen() async {
    int timeoutLength = configuration.options["timeout${server.identifier}"];
    if (timeoutLength == null) {
      return;
    }

    var completer = new Completer();
    var elapsed = 0;
    timer = new Timer.periodic(new Duration(milliseconds: 500), (t) {
      elapsed += 500;
      print("waiting...");
      if (elapsed > timeoutLength * 1000) {
        completer.complete();
        t.cancel();
      }
    });
    await completer.future;
  }

  @override
  Future close() async {
    timer?.cancel();
    await super.close();
  }
}

class TestException implements Exception {
  final String message;
  TestException(this.message);

  @override
  String toString() {
    return "TestException: $message";
  }
}

class CrashSink extends RequestSink {
  CrashSink(ApplicationConfiguration opts) : super(opts) {
    if (opts.options["crashIn"] == "constructor") {
      throw new TestException("constructor");
    }
  }

  @override
  void setupRouter(Router router) {
    if (configuration.options["crashIn"] == "addRoutes") {
      throw new TestException("addRoutes");
    }
    router.route("/t").listen((req) async => new Response.ok("t_ok"));
  }

  @override
  Future willOpen() async {
    if (configuration.options["crashIn"] == "willOpen") {
      throw new TestException("willOpen");
    }
  }
}

class TestSink extends RequestSink {
  TestSink(ApplicationConfiguration opts) : super(opts);

  static Future initializeApplication(ApplicationConfiguration config) async {
    List<int> v = config.options["startup"] ?? [];
    v.add(1);
    config.options["startup"] = v;
  }

  @override
  void setupRouter(Router router) {
    router.route("/t").listen((req) async => new Response.ok("t_ok"));
    router.route("/r").listen((req) async => new Response.ok("r_ok"));
    router.route("startup").listen((r) async {
      var total = configuration.options["startup"].fold(0, (a, b) => a + b);
      return new Response.ok("$total");
    });
  }
}