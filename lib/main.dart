import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      title: 'OT Docs',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const HomePage(),
    );
  }
}

// ---------------- Home page (Google Docs style start page) ----------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _idController = TextEditingController();
  final int userId = Random(
    DateTime.now().microsecondsSinceEpoch,
  ).nextInt(6007);
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    print("app started");
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  void _openEditor(int id) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditorPage(documentId: id, userId: userId),
      ),
    );
  }

  void _joinDocument() {
    final id = int.tryParse(_idController.text.trim());
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter a valid document ID")),
      );
      return;
    }
    _openEditor(id);
  }

  Future<void> _createDocument() async {
    setState(() => _creating = true);
    final id = await createNewDoc();
    if (!mounted) return;
    setState(() => _creating = false);
    if (id == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Could not create document. Is the server running?"),
        ),
      );
      return;
    }
    _openEditor(id);
  }

  Future<int> createNewDoc() async {
    final response = await http.post(
      Uri.parse("http://localhost:8080/new-doc"),
      body: jsonEncode({"user_id": userId}),
      headers: {"Content-Type": "Application/json"},
    );

    final body = jsonDecode(response.body);
    if (body["Error"] != null) {
      print(body);
      return 0;
    }
    return body["id"] as int;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text("OT Docs"),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Start a new document",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                InkWell(
                  onTap: _creating ? null : _createDocument,
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 120,
                        height: 160,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _creating
                            ? const Center(child: CircularProgressIndicator())
                            : const Icon(
                                Icons.add,
                                size: 48,
                                color: Colors.deepPurple,
                              ),
                      ),
                      const SizedBox(height: 8),
                      const Text("Blank document"),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                const Text(
                  "Join a document",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _idController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Document ID",
                          hintText: "e.g. 5287050",
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _joinDocument(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _joinDocument,
                      child: const Text("Join"),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Editor page ----------------

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.documentId, required this.userId});

  final int documentId;
  final int userId;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  int maxBufferLength = 4;
  Timer? _flushTimer;
  StreamSubscription<DocChange>? _changeSubscription;
  Document doc = Document();
  QuillController? _controller;
  WebSocket? socket;
  int baseVersion = 0;
  Delta _buffer = Delta();
  bool _awaitingAck = false;

  void _openConnection(int id) {
    print("connecting to doc $id");
    socket = WebSocket(
      Uri.parse("ws://localhost:8080/join-doc/$id?user_id=${widget.userId}"),
      headers: {"Content-Type": "Application/json", "user_id": widget.userId},
    );
    socket?.messages.listen(
      _handleIncomingInformation,
      onDone: () {
        print("DONE");
      },
      onError: (d) {
        print("ERROR: $d");
      },
    );
  }

  void _operationHandlers() {
    _flushTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (_buffer.toJson().isNotEmpty && !_awaitingAck) {
        sendRemote(_buffer);
        _buffer = Delta();
      }
    });

    _changeSubscription = _controller?.changes.listen((d) {
      print(d.change.toJson());
      if (d.source != ChangeSource.local)
        return; // don't re-send remote changes

      _buffer = _buffer.compose(d.change);
      if (_buffer.toJson().length > maxBufferLength && !_awaitingAck) {
        sendRemote(_buffer);
        _buffer = Delta();
      }
    });
  }

  void _loadDocument(String content) {
    final controller = _controller;
    if (controller == null) return;
    final delta = Delta();
    final len = controller.document.length; // includes the final newline
    if (len > 1) delta.delete(len - 1); // clear everything but the newline
    if (content.isNotEmpty) delta.insert(content);
    if (delta.toJson().isNotEmpty) {
      controller.document.compose(delta, ChangeSource.remote);
    }
  }

  void sendRemote(Delta delta) {
    print("sending");
    _awaitingAck = true;
    socket?.send(
      jsonEncode({
        "type": "op",
        "baseVersion": baseVersion,
        "data": delta.toJson(),
      }),
    );
  }

  void _handleIncomingInformation(message) {
    print(message);
    final body = jsonDecode(message);
    switch (body["type"]) {
      case "error":
        print("server error: ${body["error"]}");
        _awaitingAck = false;
        if (body["error"] == "document not found") {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Document not found. Check the ID.")),
          );
          Navigator.of(context).pop();
          return;
        }
        _resync(); // local and server docs have diverged — reload (below)
        return;
      case "init":
        baseVersion = body["version"];
        _loadDocument(body["content"] as String? ?? "");
        break;
      case "ack":
        baseVersion = body["version"];
        _awaitingAck = false;
        if (_buffer.toJson().isNotEmpty) {
          sendRemote(_buffer);
          _buffer = Delta();
        }
        break;
      case "op":
        baseVersion = body["version"];
        final ops = (body["data"] as List).map((e) {
          final map = Map<String, dynamic>.from(e as Map);
          map.removeWhere((key, value) => value == null);
          return map;
        }).toList();
        _controller?.document.compose(Delta.fromJson(ops), ChangeSource.remote);
        break;
    }
  }

  void _resync() {
    _buffer = Delta();
    socket?.close();
    _openConnection(
      widget.documentId,
    ); // reconnect -> fresh init -> doc reloads
  }

  void _copyDocumentId() {
    Clipboard.setData(ClipboardData(text: "${widget.documentId}"));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Document ID ${widget.documentId} copied")),
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = QuillController(
      document: doc,
      selection: TextSelection.collapsed(offset: 0),
    );
    _openConnection(widget.documentId);
    _operationHandlers();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _changeSubscription?.cancel();
    _controller?.dispose();
    socket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          children: [
            const Icon(Icons.description_outlined),
            const SizedBox(width: 8),
            Text("Document ${widget.documentId}"),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: "Copy document ID",
              onPressed: _copyDocumentId,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          QuillSimpleToolbar(
            controller: _controller!,
            config: const QuillSimpleToolbarConfig(),
          ),
          Expanded(
            child: QuillEditor.basic(
              controller: _controller!,
              config: const QuillEditorConfig(),
            ),
          ),
        ],
      ),
    );
  }
}
