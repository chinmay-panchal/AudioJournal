import 'package:flutter/material.dart';
import 'screens/main_screen.dart';
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
            brightness: Brightness.light,
            primaryColor: const Color(0xFFF97316),
            scaffoldBackgroundColor: Colors.white,
            fontFamily: 'Inter',
          ),
          // Check if session is initialized and authenticated
          home: authService.initialized
              ? (authService.isAuthenticated ? const MainScreen() : const LoginScreen())
              : const Scaffold(
                  backgroundColor: Colors.white,
                  body: Center(
                    child: CircularProgressIndicator(color: Color(0xFFF97316)),
                  ),
                ),
        );
      },
    );
  }
}
