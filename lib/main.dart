import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/sprite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialisiere die Kameras
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(MainApp(camera: firstCamera));
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  final CameraDescription camera;

  const MainApp({super.key, required this.camera});

  @override
  State<MainApp> createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  CameraController? _controller;
  Image? _image;
  String? _tempImagePath;

  // Letzter Frame-Zeitstempel zur Begrenzung der Bildrate
  DateTime _lastFrameTime = DateTime.now();

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    // Initialisiere die Kamera
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.low,
      imageFormatGroup: ImageFormatGroup.yuv420,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();

      // Starte den Kamerastream
      await _controller!.startImageStream(_processCameraImage);

      // Initialisiere die UI
      setState(() {
        _image = null; // Anfangs kein Bild anzeigen
      });
    } catch (e) {
      _log.severe('Kamera-Initialisierungsfehler: $e');
      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    }
  }

  Future<void> _processCameraImage(CameraImage cameraImage) async {
    // Begrenze die Bildrate auf 1 Bild alle 2 Sekunden
    final now = DateTime.now();
    if (now.difference(_lastFrameTime).inMilliseconds < 4000) {
      return; // Frame überspringen
    }
    _lastFrameTime = now;

    try {
      // Konvertiere YUV420 zu RGB
      img.Image imgLib = _convertYUV420toImage(cameraImage);

      // Bild um -90 Grad drehen, um es korrekt auszurichten
      imgLib = img.copyRotate(imgLib, angle: -270);
      _log.info('Bild um -270 Grad gedreht.');

      // Konvertiere das Bild in Graustufen
      img.Image grayscaleImage = img.grayscale(imgLib);
      _log.info('Bild in Graustufen konvertiert.');

      // Passe die Bildgröße an
      img.Image resizedImage = img.copyResize(grayscaleImage, width: 280, height: 280);
      _log.info('Bildgröße nach Resize: ${resizedImage.width}x${resizedImage.height}');

      // Binäre Quantisierung (Schwarz/Weiß)
      img.Image binaryImage = _binarizeImage(resizedImage);
      _log.info('Bild in Schwarz-Weiß umgewandelt.');

      // Verwenden der Frame-Standardpalette
      List<int> framePalette = [
        // RGB-Werte der Frame-Standardpalette
        0x00, 0x00, 0x00, // Farbe 0: Schwarz
        0xFF, 0xFF, 0xFF, // Farbe 1: Weiß
        // Weitere Farben hinzufügen, falls erforderlich
      ];

      // Indizes für Schwarz und Weiß in der Palette
      int blackIndex = 0;
      int whiteIndex = 1;

      img.PaletteUint8 palette = img.PaletteUint8(framePalette.length ~/ 3, 3);
      for (int i = 0; i < framePalette.length; i += 3) {
        int index = i ~/ 3;
        palette.setRgb(index, framePalette[i], framePalette[i + 1], framePalette[i + 2]);
      }

      // Erstellen eines neuen Bildes mit dieser Palette
      img.Image palettedImage = img.Image(
        width: binaryImage.width,
        height: binaryImage.height,
        numChannels: 1,
        palette: palette,
      );

      // Setzen der Pixelwerte basierend auf dem binärisierten Bild
      for (int y = 0; y < binaryImage.height; y++) {
        for (int x = 0; x < binaryImage.width; x++) {
          img.Pixel pixel = binaryImage.getPixel(x, y);
          int grayValue = pixel.r.toInt();

          // Zuordnung des Farbindizes
          int colorIndex = grayValue == 0 ? blackIndex : whiteIndex;
          palettedImage.setPixelIndex(x, y, colorIndex);
        }
      }

      // Kodieren des palettierten Bildes als PNG
      Uint8List pngBytes = Uint8List.fromList(img.encodePng(palettedImage));
      _log.info('PNG-Kodierung abgeschlossen. Größe: ${pngBytes.length} Bytes');

      // Speichern des Bildes zur Überprüfung
      await _savePng(pngBytes, 'test_image');
      _log.info('PNG gespeichert unter: test_image.png');

      // Überprüfe die unkomprimierte Größe
      int bpp = 1; // 1 Bit pro Pixel für Schwarz-Weiß-Bild
      int uncompressedSize = palettedImage.width * palettedImage.height * bpp ~/ 8;
      _log.info('Unkomprimierte Größe: $uncompressedSize Bytes');
      if (uncompressedSize > 25000) {
        _log.warning('Bildgröße überschreitet 25kB: $uncompressedSize Bytes');
        return;
      }

      // Aktualisiere die UI mit dem quantisierten Bild
      setState(() {
        _image = Image.memory(pngBytes);
      });

      // Sende das Bild an das Frame-Display
      await frame?.sendMessage(TxSprite.fromPngBytes(msgCode: 0x20, pngBytes: pngBytes));
      _log.info('Bild erfolgreich an das Frame-Display gesendet.');
    } catch (e, stackTrace) {
      _log.severe('Fehler bei der Bildverarbeitung: $e', e, stackTrace);
    }
  }

  img.Image _convertYUV420toImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final img.Image imgLib = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      final int yOffset = y * yRowStride;
      final int uvRowOffset = (y ~/ 2) * uvRowStride;

      for (int x = 0; x < width; x++) {
        final int uvOffset = uvRowOffset + (x ~/ 2) * uvPixelStride;

        final int Y = yPlane.bytes[yOffset + x];
        final int U = uPlane.bytes[uvOffset];
        final int V = vPlane.bytes[uvOffset];

        final int R = (Y + (1.370705 * (V - 128))).clamp(0, 255).toInt();
        final int G =
            (Y - (0.698001 * (V - 128)) - (0.337633 * (U - 128)))
                .clamp(0, 255)
                .toInt();
        final int B = (Y + (1.732446 * (U - 128))).clamp(0, 255).toInt();

        imgLib.setPixelRgb(x, y, R, G, B);
      }
    }

    return imgLib;
  }

  img.Image _binarizeImage(img.Image grayscaleImage) {
    // Binäre Schwelle
    const threshold = 128;

    // Bild auf Schwarz-Weiß reduzieren
    for (int y = 0; y < grayscaleImage.height; y++) {
      for (int x = 0; x < grayscaleImage.width; x++) {
        img.Pixel pixel = grayscaleImage.getPixel(x, y);
        int grayValue = pixel.r.toInt();
        int color = grayValue > threshold ? 255 : 0;
        grayscaleImage.setPixelRgb(x, y, color, color, color);
      }
    }
    return grayscaleImage;
  }

  Future<void> _savePng(Uint8List pngBytes, String fileName) async {
    try {
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/$fileName.png';
      final file = File(path);
      await file.writeAsBytes(pngBytes);
      _log.info('PNG gespeichert unter: $path');
    } catch (e) {
      _log.severe('Fehler beim Speichern des PNGs: $e');
    }
  }

  @override
  Future<void> cancel() async {
    await _controller?.stopImageStream();
    await _controller?.dispose();
    _controller = null;
    await frame?.sendMessage(TxCode(msgCode: 0x10, value: 1));
    setState(() {
      _image = null;
    });
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Spycam',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Spycam'),
          actions: [getBatteryWidget()],
        ),
        body: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              if (_image != null) _image!,
              const Spacer(),
            ],
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(
            const Icon(Icons.camera), const Icon(Icons.close)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
