import 'dart:math' as math;
import 'package:flutter/material.dart';

class VoiceWaveformWidget extends StatefulWidget {
  final bool isRecording;

  const VoiceWaveformWidget({
    Key? key,
    required this.isRecording,
  }) : super(key: key);

  @override
  State<VoiceWaveformWidget> createState() => _VoiceWaveformWidgetState();
}

class _VoiceWaveformWidgetState extends State<VoiceWaveformWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    if (widget.isRecording) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant VoiceWaveformWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isRecording && _controller.isAnimating) {
      // Smoothly stop by letting it finish or fading
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: WaveformPainter(
            animationValue: _controller.value,
            isRecording: widget.isRecording,
          ),
          child: const SizedBox(
            width: double.infinity,
            height: 120,
          ),
        );
      },
    );
  }
}

class WaveformPainter extends CustomPainter {
  final double animationValue;
  final bool isRecording;

  WaveformPainter({
    required this.animationValue,
    required this.isRecording,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double midY = size.height / 2;
    final double width = size.width;

    // We draw 3 layers of waves with different properties
    final waves = [
      _WaveParams(
        amplitude: isRecording ? 30.0 : 1.5,
        frequency: 0.015,
        speed: 2.0,
        phase: 0.0,
        colors: [
          const Color(0xFF6366F1).withOpacity(0.4), // Indigo
          const Color(0xFFA855F7).withOpacity(0.4), // Purple
        ],
      ),
      _WaveParams(
        amplitude: isRecording ? 20.0 : 1.0,
        frequency: 0.025,
        speed: -3.0,
        phase: math.pi / 3,
        colors: [
          const Color(0xFFEC4899).withOpacity(0.5), // Pink
          const Color(0xFFF43F5E).withOpacity(0.5), // Rose
        ],
      ),
      _WaveParams(
        amplitude: isRecording ? 12.0 : 0.5,
        frequency: 0.035,
        speed: 1.5,
        phase: math.pi / 1.5,
        colors: [
          const Color(0xFF06B6D4).withOpacity(0.6), // Cyan
          const Color(0xFF3B82F6).withOpacity(0.6), // Blue
        ],
      ),
    ];

    for (final wave in waves) {
      final path = Path();
      path.moveTo(0, midY);

      for (double x = 0; x <= width; x += 2) {
        // Calculate sine wave equation
        final double phaseShift = wave.phase + (animationValue * 2 * math.pi * (wave.speed / 4));
        final double y = midY +
            math.sin(x * wave.frequency + phaseShift) *
                wave.amplitude *
                // Make the wave taper off at the ends (left and right edges)
                math.sin((x / width) * math.pi);
        path.lineTo(x, y);
      }

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = LinearGradient(
          colors: wave.colors,
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ).createShader(Rect.fromLTWH(0, 0, width, size.height));

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.isRecording != isRecording;
  }
}

class _WaveParams {
  final double amplitude;
  final double frequency;
  final double speed;
  final double phase;
  final List<Color> colors;

  _WaveParams({
    required this.amplitude,
    required this.frequency,
    required this.speed,
    required this.phase,
    required this.colors,
  });
}
