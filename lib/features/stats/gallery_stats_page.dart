import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/app_stores.dart';
import '../../core/theme/app_theme.dart';
import '../gallery/gallery_state.dart';
import '../local_gallery/local_gallery_state.dart';
import 'key_ledger.dart';

class GalleryAnalytics {
  const GalleryAnalytics({
    required this.totalImages,
    required this.totalBytes,
    required this.withMetadata,
    required this.resolutions,
    required this.models,
    required this.samplers,
    required this.hours,
    required this.days,
    required this.anlas,
  });

  final int totalImages;
  final int totalBytes;
  final int withMetadata;
  final Map<String, int> resolutions;
  final Map<String, int> models;
  final Map<String, int> samplers;
  final Map<int, int> hours;
  final Map<String, int> days;
  final int anlas;
}

final galleryAnalyticsProvider = FutureProvider.autoDispose<GalleryAnalytics>((
  ref,
) async {
  final local = ref.watch(localGalleryProvider).items;
  final generated = ref.watch(galleryProvider).results;
  final store = ref.read(appStoresProvider).gallery;
  final resolutions = <String, int>{};
  final models = <String, int>{};
  final samplers = <String, int>{};
  final hours = <int, int>{};
  final days = <String, int>{};
  var totalImages = 0;
  var totalBytes = 0;
  var withMetadata = 0;

  void add({
    required int width,
    required int height,
    required int bytes,
    required int createdAt,
    String model = '',
    String sampler = '',
    bool metadata = false,
  }) {
    totalImages++;
    totalBytes += bytes;
    if (metadata) {
      withMetadata++;
    }
    final resolution = width > 0 && height > 0 ? '$width×$height' : '未知尺寸';
    resolutions[resolution] = (resolutions[resolution] ?? 0) + 1;
    if (model.trim().isNotEmpty) {
      models[model] = (models[model] ?? 0) + 1;
    }
    if (sampler.trim().isNotEmpty) {
      samplers[sampler] = (samplers[sampler] ?? 0) + 1;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(
      createdAt > 0 ? createdAt : DateTime.now().millisecondsSinceEpoch,
    );
    hours[at.hour] = (hours[at.hour] ?? 0) + 1;
    final day = KeyLedgerStore.dayKey(at);
    days[day] = (days[day] ?? 0) + 1;
  }

  for (final item in local) {
    // History entries are references to the generated gallery, not another
    // image. Count them in the generated pass below so statistics stay
    // one-row/one-file even though the local catalog exposes them too.
    if (item.isHistoryReference) continue;
    add(
      width: item.width,
      height: item.height,
      bytes: item.sizeBytes,
      createdAt: item.createdAt,
      model: item.model,
      sampler: item.sampler,
      metadata: item.hasMetadata,
    );
  }
  for (final result in generated) {
    final input =
        result.input ??
        (result.hasInput ? await store.readInput(result.id) : null);
    add(
      width: result.width,
      height: result.height,
      bytes: result.bytes?.length ?? await store.imageLength(result.id) ?? 0,
      createdAt: result.createdAt,
      model: input?.params.model ?? '',
      sampler: input?.params.sampler ?? '',
      metadata: input != null,
    );
  }

  return GalleryAnalytics(
    totalImages: totalImages,
    totalBytes: totalBytes,
    withMetadata: withMetadata,
    resolutions: _top(resolutions),
    models: _top(models),
    samplers: _top(samplers),
    hours: hours,
    days: _top(days),
    anlas: ref.read(appStoresProvider).ledger.totalPts,
  );
});

Map<K, int> _top<K>(Map<K, int> source, [int limit = 8]) {
  final entries = source.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return {for (final entry in entries.take(limit)) entry.key: entry.value};
}

/// Gallery statistics dashboard for the mobile app.
class GalleryStatsPage extends ConsumerWidget {
  const GalleryStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(galleryAnalyticsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('图库统计'),
        actions: [
          IconButton(
            tooltip: '刷新统计',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(galleryAnalyticsProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('统计加载失败：$error')),
        data: (data) => _Dashboard(data: data),
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.data});

  final GalleryAnalytics data;

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = (constraints.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Metric(
                  label: '作品总数',
                  value: '${data.totalImages}',
                  icon: Icons.photo_library_outlined,
                  width: width,
                ),
                _Metric(
                  label: '有元数据',
                  value: '${data.withMetadata}',
                  icon: Icons.description_outlined,
                  width: width,
                ),
                _Metric(
                  label: '图库占用',
                  value: _bytes(data.totalBytes),
                  icon: Icons.storage_outlined,
                  width: width,
                ),
                _Metric(
                  label: 'Anlas 消耗',
                  value: '${data.anlas}',
                  icon: Icons.toll_outlined,
                  width: width,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        _Section(
          title: '尺寸分布',
          icon: Icons.aspect_ratio,
          child: _Distribution(data.resolutions),
        ),
        const SizedBox(height: 14),
        _Section(
          title: '模型分布',
          icon: Icons.auto_awesome_outlined,
          child: _Distribution(data.models),
        ),
        const SizedBox(height: 14),
        _Section(
          title: '采样器分布',
          icon: Icons.tune,
          child: _Distribution(data.samplers),
        ),
        const SizedBox(height: 14),
        _Section(
          title: '按时间',
          icon: Icons.schedule_outlined,
          child: _TimeChart(hours: data.hours),
        ),
        const SizedBox(height: 14),
        _Section(
          title: '最近活动',
          icon: Icons.calendar_month_outlined,
          child: data.days.isEmpty
              ? Text(
                  '还没有可统计的活动',
                  style: context.texts.bodySmall!.copyWith(
                    color: scheme.outline,
                  ),
                )
              : _Distribution(data.days),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
    required this.width,
  });

  final String label;
  final String value;
  final IconData icon;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Material(
      color: context.scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
        child: Row(
          children: [
            Icon(icon, size: 21, color: context.scheme.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context.texts.labelSmall!.copyWith(
                      color: context.scheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(context, size: 17, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 18, color: context.scheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Text(
            title,
            style: context.texts.titleSmall!.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      child,
    ],
  );
}

class _Distribution extends StatelessWidget {
  const _Distribution(this.values);

  final Map<String, int> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return Text(
        '暂无数据',
        style: context.texts.bodySmall!.copyWith(color: context.scheme.outline),
      );
    }
    final max = values.values.fold<int>(
      0,
      (current, value) => value > current ? value : current,
    );
    return Column(
      children: [
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 105,
                  child: Text(
                    entry.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : entry.value / max,
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Text(
                    '${entry.value}',
                    textAlign: TextAlign.end,
                    style: mono(context, size: 11),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TimeChart extends StatelessWidget {
  const _TimeChart({required this.hours});

  final Map<int, int> hours;

  @override
  Widget build(BuildContext context) {
    final max = hours.values.fold<int>(
      0,
      (current, value) => value > current ? value : current,
    );
    return SizedBox(
      height: 100,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var hour = 0; hour < 24; hour++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: max == 0 ? 0 : (hours[hour] ?? 0) / max,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: context.scheme.primary,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hour % 4 == 0 ? '$hour' : '',
                      style: context.texts.labelSmall!.copyWith(
                        color: context.scheme.outline,
                        fontSize: 9,
                      ),
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

String _bytes(int value) {
  if (value >= 1 << 30) {
    return '${(value / (1 << 30)).toStringAsFixed(1)} GB';
  }
  if (value >= 1 << 20) {
    return '${(value / (1 << 20)).toStringAsFixed(1)} MB';
  }
  if (value >= 1 << 10) {
    return '${(value / (1 << 10)).toStringAsFixed(0)} KB';
  }
  return '$value B';
}
