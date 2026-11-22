import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_controller.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';

enum _PickerSource {
  favorites,
  history,
}

/// 「关注 / 历史记录」二选一的直播候选，带上展示用的状态。
class _PickerEntry {
  const _PickerEntry({
    required this.item,
    required this.subtitle,
    required this.status,
  });

  final MultiRoomItem item;
  final String subtitle;

  /// 2=直播中 1=未开播 0=未知 -1=不展示（历史记录）
  final int status;
}

/// 多画面选台面板：搜索 + 关注/历史记录 + 点击填充指定画面。
class MultiRoomPicker extends StatefulWidget {
  const MultiRoomPicker({
    super.key,
    required this.controller,
    required this.onPicked,
  });

  final MultiRoomController controller;
  final ValueChanged<MultiRoomItem> onPicked;

  @override
  State<MultiRoomPicker> createState() => _MultiRoomPickerState();
}

class _MultiRoomPickerState extends State<MultiRoomPicker> {
  final TextEditingController _searchController = TextEditingController();
  _PickerSource _source = _PickerSource.favorites;
  String _query = "";
  List<_PickerEntry>? _historyEntries;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 观看记录来自 Hive 全量读取 + 排序，缓存一次，
  /// 避免搜索框每敲一个字就重排一遍。
  List<_PickerEntry> _loadHistory() {
    final cached = _historyEntries;
    if (cached != null) {
      return cached;
    }
    final entries = <_PickerEntry>[];
    for (final history in DBService.instance.getHistores()) {
      final item = MultiRoomItem.fromHistory(history);
      if (item == null) {
        continue;
      }
      entries.add(
        _PickerEntry(
          item: item,
          subtitle: item.site.name,
          status: -1,
        ),
      );
    }
    _historyEntries = entries;
    return entries;
  }

  List<_PickerEntry> _entries() {
    final entries = <_PickerEntry>[];
    if (_source == _PickerSource.favorites) {
      for (final follow in FollowService.instance.followList) {
        final site = Sites.allSites[follow.siteId];
        if (site == null) {
          continue;
        }
        entries.add(
          _PickerEntry(
            item: MultiRoomItem(
              site: site,
              roomId: follow.roomId,
              userName: follow.userName,
              face: follow.face,
            ),
            subtitle: follow.roomTitle.isNotEmpty
                ? follow.roomTitle
                : site.name,
            status: follow.liveStatus.value,
          ),
        );
      }
      // 直播中的排前面，其余保持原顺序。
      entries.sort((a, b) {
        final left = a.status == 2 ? 1 : 0;
        final right = b.status == 2 ? 1 : 0;
        return right.compareTo(left);
      });
    } else {
      entries.addAll(_loadHistory());
    }

    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return entries;
    }
    return entries
        .where(
          (entry) =>
              entry.item.userName.toLowerCase().contains(query) ||
              entry.subtitle.toLowerCase().contains(query) ||
              entry.item.site.name.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: "搜索主播或标题",
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SegmentedButton<_PickerSource>(
            showSelectedIcon: false,
            selected: {_source},
            onSelectionChanged: (selection) =>
                setState(() => _source = selection.first),
            segments: const [
              ButtonSegment(
                value: _PickerSource.favorites,
                label: Text("关注"),
              ),
              ButtonSegment(
                value: _PickerSource.history,
                label: Text("历史记录"),
              ),
            ],
          ),
        ),
        Expanded(
          child: Obx(() {
            // 依赖画面槽位：加入/移除画面后「已添加」状态立即刷新。
            final assigned = widget.controller.assignedKeys;
            final entries = _entries();
            if (entries.isEmpty) {
              return Center(
                child: Text(
                  _query.isEmpty ? "暂无可选直播间" : "没有匹配的直播间",
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final added = assigned.contains(entry.item.key);
                return _PickerTile(
                  entry: entry,
                  added: added,
                  onTap: added ? null : () => widget.onPicked(entry.item),
                );
              },
            );
          }),
        ),
      ],
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.entry,
    required this.added,
    required this.onTap,
  });

  final _PickerEntry entry;
  final bool added;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = entry.item;
    return ListTile(
      dense: true,
      enabled: !added,
      onTap: onTap,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          NetImage(
            item.face,
            width: 36,
            height: 36,
            borderRadius: 18,
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                shape: BoxShape.circle,
              ),
              child: Image.asset(item.site.logo, width: 14, height: 14),
            ),
          ),
        ],
      ),
      title: Text(
        item.userName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        entry.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
      ),
      trailing: added
          ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
          : _PickerStatusBadge(status: entry.status),
    );
  }
}

class _PickerStatusBadge extends StatelessWidget {
  const _PickerStatusBadge({required this.status});

  final int status;

  @override
  Widget build(BuildContext context) {
    if (status < 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final live = status == 2;
    final color = live
        ? const Color(0xFF31C24C)
        : theme.colorScheme.outline.withAlpha(status == 0 ? 110 : 180);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          live
              ? "正在直播"
              : status == 1
                  ? "未开播"
                  : "状态未知",
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
