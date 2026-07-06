import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../constants.dart';
import 'auth_service.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: kApiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(
          minutes: 10,
        ), // large file imports can take several minutes
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final authService = AuthService();
          final token = authService.accessToken;

          debugPrint(
            '[ApiService] Request: ${options.method} ${options.baseUrl}${options.path}',
          );
          debugPrint('  - Query Parameters: ${options.queryParameters}');
          debugPrint('  - Headers: ${options.headers}');
          if (options.data != null) {
            if (options.data is FormData) {
              final formData = options.data as FormData;
              final fields = formData.fields
                  .map((f) => '${f.key}: ${f.value}')
                  .toList();
              final files = formData.files
                  .map((f) => '${f.key}: [File: ${f.value.filename}]')
                  .toList();
              debugPrint('  - FormData fields: $fields');
              debugPrint('  - FormData files: $files');
            } else {
              debugPrint('  - Body: ${options.data}');
            }
          }

          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
            debugPrint(
              '  - Attached Access Token: ${token.substring(0, (token.length > 10 ? 10 : token.length))}...',
            );
          } else {
            debugPrint('  - No access token found in AuthService.');
          }
          return handler.next(options);
        },
        onError: (DioException error, handler) async {
          debugPrint('[ApiService] Error encountered:');
          debugPrint(
            '  - Request: ${error.requestOptions.method} ${error.requestOptions.baseUrl}${error.requestOptions.path}',
          );
          debugPrint('  - Status Code: ${error.response?.statusCode}');
          debugPrint('  - Error Message: ${error.message}');
          debugPrint('  - Response Data: ${error.response?.data}');

          // Only attempt refresh on 401 Unauthorized errors
          if (error.response?.statusCode == 401) {
            final authService = AuthService();

            // If the request itself was the login, register, or refresh endpoint, do not attempt to refresh
            final path = error.requestOptions.path;
            if (path.contains('/auth/login') ||
                path.contains('/auth/refresh') ||
                path.contains('/auth/register')) {
              debugPrint(
                '  - 401 occurred on auth endpoint. Forwarding error directly.',
              );
              return handler.next(error);
            }

            if (authService.refreshToken != null) {
              debugPrint(
                '  - 401 Unauthorized detected. Attempting automatic token refresh...',
              );
              // Attempt to refresh the session
              final success = await authService.refreshSession();
              if (success) {
                // Retrieve new access token and retry original request
                final newAccessToken = authService.accessToken;
                if (newAccessToken != null) {
                  final options = error.requestOptions;
                  options.headers['Authorization'] = 'Bearer $newAccessToken';

                  debugPrint(
                    '  - Token refresh successful. Retrying original request with new token: ${newAccessToken.substring(0, (newAccessToken.length > 10 ? 10 : newAccessToken.length))}...',
                  );
                  // Retry request with new options
                  // try {
                  //   final response = await _dio.fetch(options);
                  //   debugPrint('  - Retried request succeeded with status: ${response.statusCode}');
                  //   return handler.resolve(response);
                  // } on DioException catch (retryError) {
                  //   debugPrint('  - Retried request failed: ${retryError.message}');
                  //   return handler.next(retryError);
                  // }
                  try {
                    // Clone FormData — original is finalized after first send
                    if (options.data is FormData) {
                      final original = options.data as FormData;
                      options.data = FormData.fromMap({
                        for (final f in original.fields) f.key: f.value,
                      });
                    }
                    final response = await _dio.fetch(options);
                    debugPrint(
                      '  - Retried request succeeded with status: ${response.statusCode}',
                    );
                    return handler.resolve(response);
                  } on DioException catch (retryError) {
                    debugPrint(
                      '  - Retried request failed: ${retryError.message}',
                    );
                    return handler.next(retryError);
                  }
                }
              } else {
                debugPrint(
                  '  - Automatic token refresh failed. User logged out.',
                );
              }
            } else {
              debugPrint(
                '  - 401 Unauthorized but no refresh token is stored. User logged out.',
              );
              await authService.logout();
            }
          }
          return handler.next(error);
        },
      ),
    );
  }

  late final Dio _dio;

  Dio get dio => _dio;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.get<T>(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.post<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.delete<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }
}
