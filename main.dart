import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:watcher/watcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SayCheeseAgentApp());
}

class EjercicioResuelto {
  final String id;
  final String rutaImagen;
  final DateTime fecha;
  String? solucion;
  bool procesando;

  EjercicioResuelto({
    required this.id,
    required this.rutaImagen,
    required this.fecha,
    this.solucion,
    this.procesando = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'rutaImagen': rutaImagen,
        'fecha': fecha.toIso8601String(),
        'solucion': solucion,
        'procesando': procesando,
      };

  factory EjercicioResuelto.fromJson(Map<String, dynamic> json) =>
      EjercicioResuelto(
        id: json['id'],
        rutaImagen: json['rutaImagen'],
        fecha: DateTime.parse(json['fecha']),
        solucion: json['solucion'],
        procesando: json['procesando'] ?? false,
      );
}

class SayCheeseAgentApp extends StatelessWidget {
  const SayCheeseAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SayCheese Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurpleAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _pestanaActual = 0;
  bool _agenteActivo = false;
  StreamSubscription<WatchEvent>? _watcherSub;
  final List<EjercicioResuelto> _historial = [];

  final String _rutaCarpeta = '/storage/emulated/0/Pictures/SayCheese';
  
  String _apiKey = const String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  @override
  void initState() {
    super.initState();
    _cargarDatosLocales();
    _iniciarAgente();
  }

  Future<void> _cargarDatosLocales() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString('gemini_api_key');
    if (savedKey != null && savedKey.isNotEmpty) {
      setState(() => _apiKey = savedKey);
    }

    final historialJson = prefs.getStringList('historial_ejercicios') ?? [];
    setState(() {
      _historial.clear();
      _historial.addAll(
        historialJson.map((e) => EjercicioResuelto.fromJson(jsonDecode(e))),
      );
    });
  }

  Future<void> _guardarHistorialLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final listaJson = _historial.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('historial_ejercicios', listaJson);
  }

  Future<void> _iniciarAgente() async {
    await [
      Permission.photos,
      Permission.storage,
      Permission.manageExternalStorage,
    ].request();

    final dir = Directory(_rutaCarpeta);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {}
    }

    final watcher = DirectoryWatcher(_rutaCarpeta);
    _watcherSub = watcher.events.listen((event) {
      final pathLower = event.path.toLowerCase();
      if (event.type == ChangeType.ADD &&
          (pathLower.endsWith('.jpg') ||
              pathLower.endsWith('.jpeg') ||
              pathLower.endsWith('.png'))) {
        _procesarNuevaFoto(File(event.path));
      }
    });

    setState(() => _agenteActivo = true);
  }

  Future<void> _procesarNuevaFoto(File archivoImagen) async {
    await Future.delayed(const Duration(seconds: 2));

    final nuevoItem = EjercicioResuelto(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      rutaImagen: archivoImagen.path,
      fecha: DateTime.now(),
    );

    setState(() {
      _historial.insert(0, nuevoItem);
    });

    try {
      final respuesta = await _llamarGeminiProMedio(archivoImagen);
      setState(() {
        nuevoItem.solucion = respuesta;
        nuevoItem.procesando = false;
      });
      await _guardarHistorialLocal();
    } catch (e) {
      setState(() {
        nuevoItem.solucion = 'Error al resolver la hoja: $e';
        nuevoItem.procesando = false;
      });
      await _guardarHistorialLocal();
    }
  }

  Future<String> _llamarGeminiProMedio(File imagen) async {
    if (_apiKey.isEmpty) {
      throw Exception('Configura tu Gemini API Key en el icono de llave superior.');
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=$_apiKey',
    );

    final bytes = await imagen.readAsBytes();
    final base64Image = base64Encode(bytes);

    final body = jsonEncode({
      "contents": [
        {
          "parts": [
            {
              "text":
                  "Resuelve todos los ejercicios de esta hoja paso a paso. Usa formato Markdown claro, enumera cada ejercicio y destaca el resultado final."
            },
            {
              "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64Image,
              }
            }
          ]
        }
      ],
      "generationConfig": {
        "thinkingConfig": {
          "thinkingBudget": 4096
        }
      }
    });

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final parts = data['candidates'][0]['content']['parts'] as List;
      final textPart = parts.lastWhere(
        (p) => p.containsKey('text') && p['thought'] != true,
        orElse: () => parts.last,
      );
      return textPart['text'];
    } else {
      throw Exception('Código ${response.statusCode}: ${response.body}');
    }
  }

  void _mostrarDialogoApiKey() {
    final controller = TextEditingController(text: _apiKey);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Configurar Gemini API Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'AIzaSy...',
            labelText: 'API Key',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('gemini_api_key', controller.text.trim());
              setState(() => _apiKey = controller.text.trim());
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _watcherSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resueltos = _historial.where((e) => !e.procesando).toList();
    final enCola = _historial.where((e) => e.procesando).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_pestanaActual == 0
            ? 'Agente SayCheese'
            : 'Apartado de Soluciones (${resueltos.length})'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key),
            tooltip: 'Configurar API Key',
            onPressed: _mostrarDialogoApiKey,
          ),
        ],
      ),
      body: _pestanaActual == 0
          ? _buildVistaAgente(enCola)
          : _buildVistaSoluciones(resueltos),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _pestanaActual,
        onDestinationSelected: (index) => setState(() => _pestanaActual = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.radar),
            label: 'Agente Activo',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: resueltos.isNotEmpty,
              label: Text('${resueltos.length}'),
              child: const Icon(Icons.menu_book_rounded),
            ),
            label: 'Solucionario',
          ),
        ],
      ),
    );
  }

  Widget _buildVistaAgente(List<EjercicioResuelto> enCola) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                _agenteActivo ? Icons.check_circle : Icons.error,
                color: _agenteActivo ? Colors.greenAccent : Colors.orange,
                size: 36,
              ),
              title: Text(_agenteActivo
                  ? 'Vigilando carpeta SayCheese'
                  : 'Iniciando agente...'),
              subtitle: Text(
                  'Modelo: Gemini 2.5 Pro (Rendimiento Medio)\nRuta: $_rutaCarpeta'),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Procesando en segundo plano (${enCola.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: enCola.isEmpty
                ? const Center(
                    child: Text(
                      'Sube o mueve una foto a la carpeta "SayCheese" y empezará a resolverse sola aquí.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: enCola.length,
                    itemBuilder: (context, index) {
                      final item = enCola[index];
                      return Card(
                        child: ListTile(
                          leading: Image.file(
                            File(item.rutaImagen),
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.image),
                          ),
                          title: const Text('Analizando hoja de ejercicios...'),
                          subtitle: const LinearProgressIndicator(),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildVistaSoluciones(List<EjercicioResuelto> resueltos) {
    if (resueltos.isEmpty) {
      return const Center(
        child: Text('Aún no hay hojas resueltas en este apartado.'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: resueltos.length,
      itemBuilder: (context, index) {
        final item = resueltos[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(item.rutaImagen),
                width: 60,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.image, size: 40),
              ),
            ),
            title: Text('Hoja resuelta #${resueltos.length - index}'),
            subtitle: Text(
              item.solucion ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DetalleSolucionScreen(ejercicio: item),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class DetalleSolucionScreen extends StatelessWidget {
  final EjercicioResuelto ejercicio;

  const DetalleSolucionScreen({super.key, required this.ejercicio});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Resolución Paso a Paso')),
      body: Column(
        children: [
          SizedBox(
            height: 200,
            width: double.infinity,
            child: InteractiveViewer(
              child: Image.file(
                File(ejercicio.rutaImagen),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Center(child: Icon(Icons.broken_image, size: 48)),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Markdown(
              data: ejercicio.solucion ?? 'Sin respuesta.',
              selectable: true,
            ),
          ),
        ],
      ),
    );
  }
}
