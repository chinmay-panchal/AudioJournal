import 'package:flutter/material.dart';
import 'screens/recorder_screen.dart';
import 'services/recorder_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize recording/background service
  final recorderService = RecorderService();
  await recorderService.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Voice Recorder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFF111827),
        fontFamily: 'Inter',
      ),
      home: const RecorderScreen(),
    );
  }
}
