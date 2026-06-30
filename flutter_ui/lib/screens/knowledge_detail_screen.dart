import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

// ─── Shared data models ───────────────────────────────────────────────────────

class TipSection {
  final String header;
  final List<String> tips;
  const TipSection({required this.header, required this.tips});
}

class VideoItem {
  final String label;
  final String path;
  const VideoItem({required this.label, required this.path});
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class KnowledgeDetailScreen extends StatelessWidget {
  final String category;
  final String imagePath;
  final Color color;
  final List<String> tips;
  final List<TipSection> sections;
  final List<VideoItem> videos;

  const KnowledgeDetailScreen({
    super.key,
    required this.category,
    required this.imagePath,
    required this.color,
    this.tips = const [],
    this.sections = const [],
    this.videos = const [],
  });

  @override
  Widget build(BuildContext context) {
    final useSections = sections.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F3EC),
      body: CustomScrollView(
        slivers: [
          // ── Header ───────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            backgroundColor: color,
            iconTheme: const IconThemeData(color: Colors.white),
            flexibleSpace: FlexibleSpaceBar(
              centerTitle: true,
              title: Text(
                category,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [color.withValues(alpha: 0.85), color],
                      ),
                    ),
                  ),
                  Positioned(
                    right: -40, top: -40,
                    child: Container(
                      width: 180, height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  Positioned(
                    left: -25, bottom: -25,
                    child: Container(
                      width: 120, height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Center(
                      child: Image.asset(
                        imagePath,
                        height: 160,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.image_outlined,
                          size: 80,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Tips / Sections (first) ───────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: _SectionHeader(label: '重點須知', color: color),
            ),
          ),

          if (useSections)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) =>
                    _TipSectionWidget(section: sections[i], color: color),
                childCount: sections.length,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) =>
                    _TipRow(number: i + 1, text: tips[i], color: color),
                childCount: tips.length,
              ),
            ),

          // ── Videos (below tips) ───────────────────────────────────────────
          if (videos.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: _SectionHeader(label: '相關影片', color: color),
              ),
            ),
            SliverToBoxAdapter(
              child: _VideoList(videos: videos, color: color),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}

// ─── Section header bar ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionHeader({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4, height: 22,
          decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold, color: color,
          ),
        ),
      ],
    );
  }
}

// ─── Flat tip row ─────────────────────────────────────────────────────────────

class _TipRow extends StatelessWidget {
  final int number;
  final String text;
  final Color color;
  const _TipRow({required this.number, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3D2C1E).withValues(alpha: 0.05),
              blurRadius: 8, offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                '$number',
                style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 15, height: 1.5, color: Color(0xFF3D2C1E),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Grouped tip section ──────────────────────────────────────────────────────

class _TipSectionWidget extends StatelessWidget {
  final TipSection section;
  final Color color;
  const _TipSectionWidget({required this.section, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Text(
              section.header,
              style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: color,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF3D2C1E).withValues(alpha: 0.05),
                  blurRadius: 8, offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: section.tips.asMap().entries.map((e) {
                final isLast = e.key == section.tips.length - 1;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 24, height: 24,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${e.key + 1}',
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              e.value,
                              style: const TextStyle(
                                fontSize: 14, height: 1.5,
                                color: Color(0xFF3D2C1E),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!isLast)
                      Divider(
                        height: 1, indent: 48, endIndent: 14,
                        color: const Color(0xFF3D2C1E).withValues(alpha: 0.06),
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Video list ───────────────────────────────────────────────────────────────

class _VideoList extends StatelessWidget {
  final List<VideoItem> videos;
  final Color color;
  const _VideoList({required this.videos, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: videos.map((v) {
        final showLabel = v.label.isNotEmpty && videos.length > 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLabel)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(
                  v.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: 0.8),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: _VideoPlayer(videoPath: v.path, color: color),
            ),
          ],
        );
      }).toList(),
    );
  }
}

// ─── YouTube-style video player ───────────────────────────────────────────────

class _VideoPlayer extends StatefulWidget {
  final String videoPath;
  final Color color;
  const _VideoPlayer({required this.videoPath, required this.color});

  @override
  State<_VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<_VideoPlayer> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset(widget.videoPath)
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
    _controller.setLooping(false);
    _controller.addListener(_onVideoChanged);
  }

  void _onVideoChanged() {
    // When video finishes, show controls and don't auto-hide
    final v = _controller.value;
    if (v.duration > Duration.zero && v.position >= v.duration) {
      _hideTimer?.cancel();
      if (mounted) setState(() => _showControls = true);
    }
  }

  // Tap on video area → toggle controls visibility
  void _handleTap() {
    if (!_showControls) {
      setState(() => _showControls = true);
      if (_controller.value.isPlaying) _startHideTimer();
    } else {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
      _hideTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      _controller.play();
      _startHideTimer();
    }
  }

  Future<void> _seek(Duration offset) async {
    final pos = await _controller.position ?? Duration.zero;
    await _controller.seekTo(pos + offset);
    _startHideTimer();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.removeListener(_onVideoChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width - 40;

    if (!_initialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: width,
          height: width * 9 / 16,
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(
                color: widget.color, strokeWidth: 2.5),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: GestureDetector(
          onTap: _handleTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // ── Video ────────────────────────────────────────────────────
              VideoPlayer(_controller),

              // ── Overlay (only interactive when visible) ──────────────────
              IgnorePointer(
                ignoring: !_showControls,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Stack(
                    children: [
                      // Dark gradient overlay
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.25),
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.55),
                            ],
                            stops: const [0.0, 0.25, 0.6, 1.0],
                          ),
                        ),
                      ),

                      // Center controls: rewind / play-pause / forward
                      Center(
                        child: ValueListenableBuilder(
                          valueListenable: _controller,
                          builder: (_, value, __) => Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _ControlBtn(
                                icon: Icons.replay_10_rounded,
                                size: 32,
                                onTap: () =>
                                    _seek(const Duration(seconds: -10)),
                              ),
                              const SizedBox(width: 24),
                              _ControlBtn(
                                icon: value.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 52,
                                filled: true,
                                onTap: _togglePlayPause,
                              ),
                              const SizedBox(width: 24),
                              _ControlBtn(
                                icon: Icons.forward_10_rounded,
                                size: 32,
                                onTap: () =>
                                    _seek(const Duration(seconds: 10)),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Bottom: time + progress bar
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: ValueListenableBuilder(
                          valueListenable: _controller,
                          builder: (_, value, __) {
                            final total =
                                value.duration.inMilliseconds.toDouble();
                            final current =
                                value.position.inMilliseconds.toDouble();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2.5,
                                    thumbShape:
                                        const RoundSliderThumbShape(
                                            enabledThumbRadius: 6),
                                    overlayShape:
                                        const RoundSliderOverlayShape(
                                            overlayRadius: 12),
                                    activeTrackColor: widget.color,
                                    inactiveTrackColor:
                                        Colors.white.withValues(alpha: 0.35),
                                    thumbColor: widget.color,
                                    overlayColor:
                                        widget.color.withValues(alpha: 0.2),
                                  ),
                                  child: Slider(
                                    value: total > 0
                                        ? current.clamp(0, total)
                                        : 0,
                                    min: 0,
                                    max: total > 0 ? total : 1,
                                    onChanged: (v) {
                                      _controller.seekTo(Duration(
                                          milliseconds: v.toInt()));
                                      _startHideTimer();
                                    },
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 0, 16, 10),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        _fmt(value.position),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          shadows: [
                                            Shadow(
                                                blurRadius: 4,
                                                color: Colors.black)
                                          ],
                                        ),
                                      ),
                                      Text(
                                        _fmt(value.duration),
                                        style: TextStyle(
                                          color: Colors.white
                                              .withValues(alpha: 0.7),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Control button helper ────────────────────────────────────────────────────

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool filled;
  final VoidCallback onTap;

  const _ControlBtn({
    required this.icon,
    required this.size,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(filled ? 10 : 6),
        decoration: filled
            ? BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.45),
              )
            : null,
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}
