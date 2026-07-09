import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/http_client.dart';
import '../../services/tv_mode.dart';
import '../../theme.dart';
import 'focusable_card.dart';

const Map<String, String> kImageHeaders = {'User-Agent': kDefaultUserAgent};

/// Cached, downscaled network image (logo/poster) with the VLC UA + placeholder.
class NetworkImageBox extends StatelessWidget {
  const NetworkImageBox({
    super.key,
    required this.url,
    required this.placeholderIcon,
    this.fit = BoxFit.cover,
    this.borderRadius = 8,
  });

  final String? url;
  final IconData placeholderIcon;
  final BoxFit fit;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Container(
          color: Colors.white.withValues(alpha: 0.05),
          child: Center(
            child: Icon(placeholderIcon, size: 34, color: Colors.white38),
          ),
        );

    final child = (url == null || url!.isEmpty)
        ? placeholder()
        : CachedNetworkImage(
            imageUrl: url!,
            fit: fit,
            httpHeaders: kImageHeaders,
            // Weak TV SoCs (Chromecast) choke on decoding big logos/posters while
            // scrolling a grid — decode smaller there. And skip the per-image
            // opacity fade on TV: animating dozens of newly-visible images during
            // a scroll is a real jank source (the tablet handles both fine).
            memCacheWidth: isTvMode ? 200 : 360,
            fadeInDuration:
                isTvMode ? Duration.zero : const Duration(milliseconds: 180),
            filterQuality: FilterQuality.low,
            placeholder: (_, __) => placeholder(),
            errorWidget: (_, __, ___) => placeholder(),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.expand(child: child),
    );
  }
}

/// A focusable content tile (channel logo / movie poster / series cover).
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.title,
    required this.onTap,
    this.imageUrl,
    this.subtitle,
    this.autofocus = false,
    this.aspectRatio = 1.0,
    this.imageFit = BoxFit.contain,
    this.placeholderIcon = Icons.live_tv,
    this.progress,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.badgeNumber,
    this.focusNode,
    this.onFocusChange,
  });

  final String title;
  final VoidCallback onTap;
  final String? imageUrl;
  final String? subtitle;
  final bool autofocus;
  final double aspectRatio;
  final BoxFit imageFit;
  final IconData placeholderIcon;
  final double? progress;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final int? badgeNumber;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap,
      // Hold OK on a remote (or long-press on touch) toggles favorite.
      onLongPress: onToggleFavorite,
      focusNode: focusNode,
      onFocusChange: onFocusChange,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetworkImageBox(
                  url: imageUrl,
                  placeholderIcon: placeholderIcon,
                  fit: imageFit,
                ),
                if (badgeNumber != null)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: _pill('$badgeNumber'),
                  ),
                if (onToggleFavorite != null)
                  Positioned(
                    right: 0,
                    top: 0,
                    // ExcludeFocus: the star must NOT be a second D-pad stop —
                    // an invisible focus target that swallows every other key
                    // press. Touch users tap it; remotes hold OK instead.
                    child: ExcludeFocus(
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        onPressed: onToggleFavorite,
                        icon: Icon(
                          isFavorite ? Icons.star : Icons.star_border,
                          color: isFavorite ? Colors.amber : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (progress != null && progress! > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: progress!.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.black45,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: AppTheme.tvFont(13, 16), fontWeight: FontWeight.w500),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.tvFont(11, 13.5), color: Colors.white54),
            ),
        ],
      ),
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
      );
}
