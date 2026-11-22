import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_controller.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_player_controller.dart';
import 'package:simple_live_app/modules/multi_room/widgets/multi_room_picker.dart';

/// 多画面同看。
///
/// 一个页面内同时播放多路直播（每路独立解码 + 独立纹理），
/// 点击画面把声音切给它；支持 1×1 / 1×2 / 2×2 等分网格与 1+3 布局，
/// 宽屏右侧是 320px 选台面板，窄屏用底部弹窗选台。
class MultiRoomPage extends GetView<MultiRoomController> {
  const MultiRoomPage({super.key});

  /// 宽到能并排放 320px 选台面板的阈值。
  static const double _wideBreakpoint = 820;

  /// 选台面板宽度。
  static const double _panelWidth = 320;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        return Scaffold(
          appBar: AppBar(
            title: const Text("多画面"),
            actions: [
              IconButton(
                tooltip: "全部刷新",
                onPressed: controller.refreshAll,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildToolbar(
                context,
                compact: constraints.maxWidth < 640,
              ),
              const Divider(height: 1),
              Expanded(
                child: isWide
                    ? Row(
                        children: [
                          Expanded(child: _buildGrid(context)),
                          const VerticalDivider(width: 1),
                          SizedBox(
                            width: _panelWidth,
                            child: _buildPanel(),
                          ),
                        ],
                      )
                    : _buildGrid(context),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 工具栏
  // ---------------------------------------------------------------------------

  Widget _buildToolbar(BuildContext context, {required bool compact}) {
    final selector = Obx(
      () => SegmentedButton<MultiviewLayout>(
        showSelectedIcon: false,
        segments: [
          for (final layout in MultiviewLayout.values)
            ButtonSegment<MultiviewLayout>(
              value: layout,
              label: Text(layout.label),
            ),
        ],
        selected: {controller.layout.value},
        onSelectionChanged: (selection) =>
            controller.setLayout(selection.first),
      ),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Obx(() {
          final muted = controller.allMuted.value;
          return IconButton(
            tooltip: muted ? "恢复声音" : "全部静音",
            onPressed: controller.toggleMuteAll,
            icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
          );
        }),
        Obx(() {
          final index = controller.audioFocusIndex.value;
          final player = controller.playerAt(index);
          return IconButton(
            tooltip: "当前画面音量",
            onPressed: player == null
                ? null
                : () => _showVolumeSheet(context, index),
            icon: const Icon(Icons.volume_down),
          );
        }),
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Column(
          children: [
            FittedBox(fit: BoxFit.scaleDown, child: selector),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: selector),
          ),
          actions,
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 画面
  // ---------------------------------------------------------------------------

  double get _gap =>
      AppSettingsController.instance.effectiveMultiRoomGap.toDouble();

  Widget _buildGrid(BuildContext context) {
    return Obx(() {
      final layout = controller.layout.value;
      final cells = controller.cells;
      if (layout == MultiviewLayout.focus) {
        return _buildFocusLayout(context, cells);
      }
      final gap = _gap;
      return Padding(
        padding: EdgeInsets.all(gap / 2),
        child: Column(
          children: [
            for (var row = 0; row < layout.rows; row++)
              Expanded(
                child: Row(
                  children: [
                    for (var col = 0; col < layout.columns; col++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(gap / 2),
                          child: _buildCell(
                            context,
                            row * layout.columns + col,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildFocusLayout(
    BuildContext context,
    List<MultiRoomItem?> cells,
  ) {
    if (cells.isEmpty) {
      return const SizedBox.shrink();
    }
    final gap = _gap;
    final big = controller.focusedCellIndex.value.clamp(0, cells.length - 1);
    final others = <int>[
      for (var i = 0; i < cells.length; i++)
        if (i != big) i,
    ];
    return Padding(
      padding: EdgeInsets.all(gap / 2),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: EdgeInsets.all(gap / 2),
              child: _buildCell(context, big),
            ),
          ),
          Expanded(
            flex: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final extent = constraints.maxHeight / 3;
                return ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: others.length,
                  itemBuilder: (context, index) => SizedBox(
                    height: extent,
                    child: Padding(
                      padding: EdgeInsets.all(gap / 2),
                      child: _buildCell(context, others[index]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCell(BuildContext context, int index) {
    final item = controller.itemAt(index);
    final player = controller.playerAt(index);
    final isAudioFocus =
        item != null && controller.audioFocusIndex.value == index;
    return _MultiRoomCell(
      key: ValueKey<String>("multi_cell_${index}_${item?.key ?? 'empty'}"),
      item: item,
      player: player,
      isAudioFocus: isAudioFocus,
      allMuted: controller.allMuted.value,
      onTap: () => _handleCellTap(context, index),
      onLongPress:
          item == null ? null : () => _showCellActions(context, index),
      onPick: () => _pickFor(context, index),
      onRemove: () => controller.removeCell(index),
      onRefresh: player?.refreshRoom,
    );
  }

  void _handleCellTap(BuildContext context, int index) {
    final item = controller.itemAt(index);
    if (item == null) {
      _pickFor(context, index);
      return;
    }
    if (controller.layout.value == MultiviewLayout.focus &&
        controller.focusedCellIndex.value != index) {
      controller.promoteCell(index);
      return;
    }
    controller.setAudioFocus(index);
  }

  void _pickFor(BuildContext context, int index) {
    controller.targetCell.value = index;
    if (MediaQuery.sizeOf(context).width >= _wideBreakpoint) {
      // 宽屏面板一直可见，直接等用户在右侧选台。
      return;
    }
    unawaited(_openPickerSheet(context, index));
  }

  Future<void> _openPickerSheet(BuildContext context, int index) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: MultiRoomPicker(
              controller: controller,
              onPicked: (item) {
                controller.assignRoom(index, item);
                Navigator.of(sheetContext).pop();
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 选台面板
  // ---------------------------------------------------------------------------

  Widget _buildPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Obx(() {
            final target = controller.targetCell.value + 1;
            final replace = !controller.hasEmptyCell;
            return Text(
              replace ? "为画面 $target 选台（将替换该画面）" : "为画面 $target 选台",
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            );
          }),
        ),
        Expanded(
          child: MultiRoomPicker(
            controller: controller,
            onPicked: (item) =>
                controller.assignRoom(controller.targetCell.value, item),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 弹窗
  // ---------------------------------------------------------------------------

  void _showVolumeSheet(BuildContext context, int index) {
    var value = controller.cellVolume(index);
    final title = controller.itemAt(index)?.userName ?? "当前画面";
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text("${(value * 100).round()}%"),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.volume_mute, size: 20),
                    Expanded(
                      child: Slider(
                        value: value,
                        onChanged: (next) {
                          setSheetState(() => value = next);
                          controller.setCellVolume(index, next);
                        },
                      ),
                    ),
                    const Icon(Icons.volume_up, size: 20),
                  ],
                ),
                Text(
                  "只有带「声音」标记的画面会出声；全部静音优先",
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(sheetContext).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCellActions(BuildContext context, int index) {
    final item = controller.itemAt(index);
    if (item == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Image.asset(item.site.logo, width: 24, height: 24),
              title: Text(item.userName),
              subtitle: Text(item.site.name),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text("刷新画面"),
              onTap: () {
                Navigator.of(sheetContext).pop();
                controller.playerAt(index)?.refreshRoom();
              },
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text("更换直播间"),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openPickerSheet(context, index));
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text("关闭该画面"),
              onTap: () {
                Navigator.of(sheetContext).pop();
                controller.removeCell(index);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个画面。
class _MultiRoomCell extends StatelessWidget {
  const _MultiRoomCell({
    super.key,
    required this.item,
    required this.player,
    required this.isAudioFocus,
    required this.allMuted,
    required this.onTap,
    required this.onLongPress,
    required this.onPick,
    required this.onRemove,
    required this.onRefresh,
  });

  final MultiRoomItem? item;
  final MultiRoomPlayerController? player;
  final bool isAudioFocus;
  final bool allMuted;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = isAudioFocus
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    return ClipRRect(
      borderRadius: AppStyle.radius8,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: item == null ? theme.colorScheme.surface : Colors.black,
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: item == null ? onPick : onTap,
              onLongPress: onLongPress,
              onSecondaryTap: onLongPress,
              child: item == null ? _buildEmpty(theme) : _buildRoom(theme),
            ),
          ),
          // 边框画在画面之上：视频纹理会盖住 Container 的后景边框。
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: AppStyle.radius8,
                border: Border.all(
                  color: borderColor,
                  width: isAudioFocus ? 2 : 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_circle_outline,
              size: 30,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              "点击选台",
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoom(ThemeData theme) {
    final controller = player;
    if (controller == null) {
      return _buildEmpty(theme);
    }
    return _buildRoomContent(theme, controller);
  }

  Widget _buildRoomContent(
    ThemeData theme,
    MultiRoomPlayerController controller,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 1+3 的小格 / 竖屏手机 2×2 的格子很窄，只保留名字，角标和按钮收进长按菜单。
        final compact = constraints.maxWidth < 200;
        return Obx(() {
          final loading = controller.loading.value;
          final live = controller.liveStatus.value;
          final error = controller.errorText.value;
          final quality = controller.qualityInfo.value;
          final line = controller.lineInfo.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: controller.videoController,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
              if (loading)
                const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (error.isNotEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              else if (!live)
                const Center(
                  child: Text(
                    "未开播",
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              Positioned(
                left: 6,
                right: 6,
                top: 6,
                child: Row(
                  children: [
                    Flexible(child: _buildNameChip()),
                    if (isAudioFocus && !compact) ...[
                      const SizedBox(width: 6),
                      allMuted
                          ? _buildMutedBadge(theme)
                          : _buildAudioBadge(theme),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 6,
                right: 4,
                bottom: 4,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (quality.isNotEmpty) quality,
                          if (line.isNotEmpty) line,
                        ].join(" · "),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (!compact) ...[
                      _CellIconButton(
                        icon: Icons.refresh,
                        tooltip: "刷新",
                        onPressed: onRefresh,
                      ),
                      _CellIconButton(
                        icon: Icons.close,
                        tooltip: "关闭画面",
                        onPressed: onRemove,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        });
      },
    );
  }

  Widget _buildNameChip() {
    final room = item;
    if (room == null) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(room.site.logo, width: 13, height: 13),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              room.userName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_up, size: 12, color: Colors.white),
          SizedBox(width: 3),
          Text(
            "声音",
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMutedBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.volume_off, size: 12, color: Colors.white70),
          SizedBox(width: 3),
          Text(
            "静音",
            style: TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _CellIconButton extends StatelessWidget {
  const _CellIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withAlpha(140),
          foregroundColor: Colors.white,
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
      ),
    );
  }
}
