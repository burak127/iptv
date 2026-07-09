import 'package:flutter/material.dart';

/// Self-rolled shimmer (no extra dependency) for loading placeholders.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height, this.borderRadius = 10});
  final double? width;
  final double? height;
  final double borderRadius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1 - 2 * t, 0),
              end: Alignment(1 - 2 * t, 0),
              colors: const [
                Color(0xFF171C26),
                Color(0xFF262D3B),
                Color(0xFF171C26),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A grid of skeleton cards matching the content grid layout.
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.aspectRatio = 0.82, this.tileWidth = 170});
  final double aspectRatio;
  final double tileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cross = (constraints.maxWidth / tileWidth).floor().clamp(2, 8);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: aspectRatio,
          ),
          itemCount: cross * 3,
          itemBuilder: (_, __) => const Skeleton(borderRadius: 14),
        );
      },
    );
  }
}
