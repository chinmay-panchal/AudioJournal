import 'package:flutter/material.dart';
import 'screens/recorder_screen.dart';
import 'screens/login_screen.dart';
import 'services/recorder_service.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize recording/background service
  final recorderService = RecorderService();
  await recorderService.init();

  // Initialize authentication state
  final authService = AuthService();
  await authService.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();

    return AnimatedBuilder(
      animation: authService,
      builder: (context, _) {
        return MaterialApp(
          title: 'Voice Recorder',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.indigo,
            scaffoldBackgroundColor: const Color(0xFF111827),
            fontFamily: 'Inter',
          ),
          // Check if session is initialized and authenticated
          home: authService.initialized
              ? (authService.isAuthenticated ? const RecorderScreen() : const LoginScreen())
              : const Scaffold(
                  backgroundColor: Color(0xFF0A0E1A),
                  body: Center(
                    child: CircularProgressIndicator(color: Colors.indigo),
                  ),
                ),
        );
      },
    );
  }
}

