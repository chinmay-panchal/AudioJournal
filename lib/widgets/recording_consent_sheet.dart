import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants.dart';

/// One-time consent sheet shown before the user's first recording.
/// Returns `true` when the user taps "I Understand — Continue".
class RecordingConsentSheet extends StatelessWidget {
  const RecordingConsentSheet({super.key});

  static const _primaryColor = Color(0xFFF97316);
  static const _textPrim = Color(0xFF111827);
  static const _textMut = Color(0xFF9CA3AF);
  static const _borderColor = Color(0xFFE5E7EB);

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.parse(kPrivacyPolicyUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Icon + headline row
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF818CF8), _primaryColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.mic, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'Before You Start Recording',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _textPrim,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Divider
          const Divider(color: _borderColor, height: 1),
          const SizedBox(height: 20),

          // Bullet points
          _BulletPoint(
            icon: Icons.fiber_manual_record_rounded,
            text:
                'This app records audio and continues recording in the background — even if you switch apps or lock your phone — until you tap Stop.',
          ),
          const SizedBox(height: 12),
          _BulletPoint(
            icon: Icons.notifications_active_outlined,
            text:
                "You'll see a persistent notification the entire time recording is active, so you always know it's running.",
          ),
          const SizedBox(height: 12),
          _BulletPoint(
            icon: Icons.cloud_outlined,
            text:
                'Your audio is processed by Google (Gemini AI) to generate transcripts and summaries, and stored securely using Amazon Web Services (AWS).',
          ),
          const SizedBox(height: 12),
          _BulletPoint(
            icon: Icons.email_outlined,
            text: 'Your email is used only to manage your account.',
          ),
          const SizedBox(height: 20),

          // Privacy Policy tappable link
          Center(
            child: GestureDetector(
              onTap: _openPrivacyPolicy,
              child: RichText(
                text: const TextSpan(
                  style: TextStyle(fontSize: 12, color: _textMut),
                  children: [
                    TextSpan(text: 'Read our '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: TextStyle(
                        color: _primaryColor,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: _primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // CTA button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline_rounded, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'I Understand — Continue',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletPoint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BulletPoint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: const Color(0xFFF97316)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
