import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../constants.dart';

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  static const String _keyAccessToken = 'access_token';
  static const String _keyRefreshToken = 'refresh_token';
  static const String _keyUserEmail = 'user_email';

  String? _accessToken;
  String? _refreshToken;
  String? _userEmail;
  bool _initialized = false;

  bool get initialized => _initialized;
  bool get isAuthenticated => _accessToken != null;
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  String? get userEmail => _userEmail;

  final _dio = Dio(
    BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_keyAccessToken);
    _refreshToken = prefs.getString(_keyRefreshToken);
    _userEmail = prefs.getString(_keyUserEmail);
    _initialized = true;
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    try {
      debugPrint('[AuthService] Initiating login for: $email');
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/login');
      final response = await _dio.post(
        '/auth/login',
        data: {'email': email, 'password': password},
      );

      debugPrint('[AuthService] Login response status: ${response.statusCode}');
      debugPrint('[AuthService] Login response data: ${response.data}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = response.data;
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        _userEmail = email;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyAccessToken, _accessToken!);
        await prefs.setString(_keyRefreshToken, _refreshToken!);
        await prefs.setString(_keyUserEmail, _userEmail!);

        debugPrint('[AuthService] Login succeeded. Stored tokens locally.');
        notifyListeners();
      } else {
        debugPrint(
          '[AuthService] Login response check failed with body: ${response.data}',
        );
        throw Exception(response.data?['detail'] ?? 'Login failed');
      }
    } on DioException catch (e) {
      debugPrint('[AuthService] Login failed with DioException:');
      debugPrint('  - Message: ${e.message}');
      debugPrint('  - Error: ${e.error}');
      debugPrint('  - Type: ${e.type}');
      debugPrint('  - Response Status Code: ${e.response?.statusCode}');
      debugPrint('  - Response Data: ${e.response?.data}');
      debugPrint(
        '  - Request Info: ${e.requestOptions.path} with data ${e.requestOptions.data}',
      );

      final detail = e.response?.data?['detail'];
      if (detail != null) {
        if (detail is String) {
          throw Exception(detail);
        } else if (detail is List && detail.isNotEmpty) {
          final errors = detail.map((e) {
            if (e is Map && e['msg'] != null) {
              String msg = e['msg'].toString();
              if (msg.startsWith('Value error, ')) {
                msg = msg.substring(13);
              }
              return msg;
            }
            return e.toString();
          }).join('\n');
          throw Exception(errors);
        } else {
          throw Exception(detail.toString());
        }
      }
      throw Exception(e.message ?? 'Network error during login');
    } catch (e, stacktrace) {
      debugPrint('[AuthService] Login failed with generic error: $e');
      debugPrint('Stacktrace: $stacktrace');
      rethrow;
    }
  }

  Future<void> register(String email, String password) async {
    try {
      debugPrint('[AuthService] Initiating registration for: $email');
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/register');
      final response = await _dio.post(
        '/auth/register',
        data: {'email': email, 'password': password},
      );

      debugPrint(
        '[AuthService] Register response status: ${response.statusCode}',
      );
      debugPrint('[AuthService] Register response data: ${response.data}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = response.data;
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        _userEmail = email;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyAccessToken, _accessToken!);
        await prefs.setString(_keyRefreshToken, _refreshToken!);
        await prefs.setString(_keyUserEmail, _userEmail!);

        debugPrint(
          '[AuthService] Registration succeeded. Stored tokens locally.',
        );
        notifyListeners();
      } else {
        debugPrint(
          '[AuthService] Register response check failed with body: ${response.data}',
        );
        throw Exception(response.data?['detail'] ?? 'Registration failed');
      }
    } on DioException catch (e) {
      debugPrint('[AuthService] Registration failed with DioException:');
      debugPrint('  - Message: ${e.message}');
      debugPrint('  - Error: ${e.error}');
      debugPrint('  - Type: ${e.type}');
      debugPrint('  - Response Status Code: ${e.response?.statusCode}');
      debugPrint('  - Response Data: ${e.response?.data}');
      debugPrint(
        '  - Request Info: ${e.requestOptions.path} with data ${e.requestOptions.data}',
      );

      final detail = e.response?.data?['detail'];
      if (detail != null) {
        if (detail is String) {
          throw Exception(detail);
        } else if (detail is List && detail.isNotEmpty) {
          final errors = detail.map((e) {
            if (e is Map && e['msg'] != null) {
              String msg = e['msg'].toString();
              if (msg.startsWith('Value error, ')) {
                msg = msg.substring(13);
              }
              return msg;
            }
            return e.toString();
          }).join('\n');
          throw Exception(errors);
        } else {
          throw Exception(detail.toString());
        }
      }
      throw Exception(e.message ?? 'Network error during registration');
    } catch (e, stacktrace) {
      debugPrint('[AuthService] Registration failed with generic error: $e');
      debugPrint('Stacktrace: $stacktrace');
      rethrow;
    }
  }

  Future<void> requestPasswordReset(String email) async {
    try {
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/forgot-password');
      final response = await _dio.post(
        '/auth/forgot-password',
        data: {'email': email},
      );

      debugPrint('[AuthService] Forgot password response status: ${response.statusCode}');
      if (response.statusCode != 200) {
        throw Exception(response.data?['detail'] ?? 'Failed to send OTP');
      }
    } on DioException catch (e) {
      final detail = e.response?.data?['detail'];
      if (detail != null) throw Exception(detail.toString());
      throw Exception(e.message ?? 'Network error');
    }
  }

  /// Verifies the OTP sent to [email] and returns a reset_session_token.
  Future<String> verifyOtp(String email, String otp) async {
    try {
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/verify-otp');
      final response = await _dio.post(
        '/auth/verify-otp',
        data: {'email': email, 'otp': otp},
      );

      debugPrint('[AuthService] Verify OTP response status: ${response.statusCode}');
      final resetToken = response.data?['reset_session_token'];
      if (resetToken == null) throw Exception('No session token returned');
      return resetToken as String;
    } on DioException catch (e) {
      final detail = e.response?.data?['detail'];
      if (detail != null) throw Exception(detail.toString());
      throw Exception(e.message ?? 'Network error');
    }
  }

  Future<void> resetPassword(String resetSessionToken, String newPassword) async {
    try {
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/reset-password');
      final response = await _dio.post(
        '/auth/reset-password',
        data: {'reset_session_token': resetSessionToken, 'new_password': newPassword},
      );

      debugPrint('[AuthService] Reset password response status: ${response.statusCode}');
      if (response.statusCode != 200) {
        throw Exception(response.data?['detail'] ?? 'Failed to reset password');
      }
    } on DioException catch (e) {
      final detail = e.response?.data?['detail'];
      if (detail != null) {
        if (detail is List && detail.isNotEmpty) {
          final errors = detail.map((e) => e['msg'] ?? e.toString()).join('\n');
          throw Exception(errors);
        }
        throw Exception(detail.toString());
      }
      throw Exception(e.message ?? 'Network error');
    }
  }

  Future<void> logout() async {
    final token = _refreshToken;

    // Clear credentials locally first so UI updates immediately
    _accessToken = null;
    _refreshToken = null;
    _userEmail = null;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyUserEmail);

    if (token != null) {
      try {
        debugPrint('[AuthService] Revoking refresh token on server...');
        await _dio.post('/auth/logout', data: {'refresh_token': token});
        debugPrint('[AuthService] Server logout request completed.');
      } catch (e) {
        debugPrint(
          '[AuthService] Logout API request error (already revoked/invalid): $e',
        );
      }
    }
  }

  Future<bool> refreshSession() async {
    if (_refreshToken == null) {
      debugPrint(
        '[AuthService] Cannot refresh session - refresh token is null',
      );
      return false;
    }
    try {
      debugPrint('[AuthService] Initiating token refresh');
      debugPrint('[AuthService] Request URL: $kApiBaseUrl/auth/refresh');
      final response = await _dio.post(
        '/auth/refresh',
        data: {'refresh_token': _refreshToken},
      );

      debugPrint(
        '[AuthService] Refresh response status: ${response.statusCode}',
      );
      debugPrint('[AuthService] Refresh response data: ${response.data}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = response.data;
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyAccessToken, _accessToken!);
        await prefs.setString(_keyRefreshToken, _refreshToken!);
        debugPrint('[AuthService] Session successfully refreshed.');
        return true;
      }
    } on DioException catch (e) {
      debugPrint('[AuthService] Refresh session failed with DioException:');
      debugPrint('  - Message: ${e.message}');
      debugPrint('  - Response Status Code: ${e.response?.statusCode}');
      debugPrint('  - Response Data: ${e.response?.data}');
    } catch (e) {
      debugPrint('[AuthService] Session refresh failed with generic error: $e');
    }

    // If refresh fails, log out the user
    debugPrint('[AuthService] Refresh failed - logging out user');
    await logout();
    return false;
  }
}
