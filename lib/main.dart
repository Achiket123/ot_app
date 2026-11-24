import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:web_socket_client/web_socket_client.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  StringBuffer buffer = StringBuffer();
  List<Operation> ops = [];
  int maxBufferLength = 4;
  Timer? _flushTimer;
  StreamSubscription<DocChange>? _changeSubscription;
  // Batching should be hybrid
  // After a certain period of time like 0.25 s -> sends the data
  // and after certain amount is written in the buffer 32 bytes -> sends the data
  // OR between them
  int? documentId;
  Document doc = Document();
  late QuillController _controller;
  late WebSocket socket;
  void _openConnection(int id) {
    socket = WebSocket(
      Uri.parse("ws://localhost:8080/join-doc/$id?user_id=1"),
      headers: {"Content-Type": "Application/json", "user_id": 1},
    );
    socket.messages.listen(_handleIncomingInformation);
  }

  void _operationHandlers() {
    _flushTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (buffer.length > 0) {
        // send buffer to server
        print("TIM:${buffer.toString()}");
        final data = ops.map((e) {
          final t = e.toJson();
          t["timestamp"] = DateTime.now().toUtc().toIso8601String();
          return t;
        }).toList();
        print(data);
        socket.send(jsonEncode({"data": data}));
        // clear the buffer
        buffer.clear();
        ops.clear();
      }
    });

    // _controller.onSelectionChanged = (selection) {
    //   // send the selection to server
    // };
    // _controller.onReplaceText = (a, v, obj) {
    //   print("REP: a: $a v: $v obj:$obj");
    //   return true;
    // };
    // _controller.onDelete = (a, v) {
    //   print("DEL: a: $a v: $v ");
    //   return;
    // };

    _changeSubscription = _controller.changes.listen((d) {
      ops.add(d.change.last);
      print("LAST: ${d.before}");
      // Take change last data and append to buffer
      // what buffer?? string may be
      if (ops.length > maxBufferLength) {
        // send buffer to server

        // clear the buffer
        final data = ops.map((e) {
          final t = e.toJson();
          t["timestamp"] = DateTime.now().toUtc().toIso8601String();
          return t;
        }).toList();
        socket.send(jsonEncode({"data": data}));
        ops.clear();
      }
    });
  }

  void _handleIncomingInformation(message) {
    print(message);
  }

  Future<int> createNewDoc() async {
    final response = await http.post(
      Uri.parse("http://localhost:8080/new-doc"),
      body: jsonEncode({"user_id": 1}),
      headers: {"Content-Type": "Application/json"},
    );

    final body = jsonDecode(response.body);
    if (body["Error"] != null) {
      print(body);
      return 0;
    }

    setState(() {});
    return body["id"] as int;
  }

  @override
  void initState() {
    super.initState();
    _controller = QuillController(
      document: doc,
      selection: TextSelection.collapsed(offset: 0),
    );
    // _openConnection();
    // _operationHandlers();
  }

  @override
  void dispose() {
    // TODO: implement dispose
    _flushTimer?.cancel();
    _changeSubscription?.cancel();
    _controller.dispose();
    socket.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: .center,
          children: [
            QuillSimpleToolbar(
              controller: _controller,
              config: const QuillSimpleToolbarConfig(),
            ),
            Expanded(
              child: QuillEditor.basic(
                controller: _controller,
                config: const QuillEditorConfig(),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () async {
          final controller = TextEditingController();
          final id = await showDialog(
            context: context,
            builder: (context) {
              return Dialog(
                child: Container(
                  child: Column(
                    children: [
                      TextField(controller: controller),
                      TextButton.icon(
                        label: Text("Join Room"),
                        onPressed: () {
                          final id = int.parse(controller.text.trim());
                          Navigator.of(context).pop(id);
                        },
                      ),
                      TextButton.icon(
                        label: Text("Create Room"),
                        onPressed: () {
                          final id = createNewDoc();
                          Navigator.of(context).pop(id);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
          _openConnection(id);
          _operationHandlers();
        },
      ),
    );
  }
}
