import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_player_controller.dart';

/// 多画面同看控制器。
///
/// 负责三件事：
/// 1. 画面槽位：每格是一个独立的 [MultiRoomPlayerController]（独立解码/纹理）；
/// 2. 布局：1×1 / 1×2 / 2×2 等分网格，1+3 一大三小；
/// 3. 声音：同一时刻只有「音频焦点」那一格出声，其余格静音；支持全部静音。
///
/// 生命周期：本控制器由 `kMultiRoom` 路由的 binding 创建，
/// 子播放器注册在 GetX 容器里（tag = `siteId_roomId`），必须由本类的
/// [onClose] 统一回收；不要在路由之外直接 `Get.put(MultiRoomController(...))`。
class MultiRoomController extends GetxController {
  MultiRoomController(this.initialRooms);

  /// 同屏最多 4 路：每路都是独立解码 + 独立纹理，负载线性叠加。
  static const int maxCells = 4;

  final List<MultiRoomItem> initialRooms;

  /// 当前布局，默认 2×2。
  final Rx<MultiviewLayout> layout = MultiviewLayout.quad.obs;

  /// 画面槽位；null 表示空位（点击后选台）。
  final RxList<MultiRoomItem?> cells = <MultiRoomItem?>[].obs;

  /// 出声画面下标：只有它有声，其余静音。
  final RxInt audioFocusIndex = 0.obs;

  /// 1+3 布局中的大画面下标。
  final RxInt focusedCellIndex = 0.obs;

  /// 选台面板当前要填充的槽位。
  final RxInt targetCell = 0.obs;

  /// 是否全部静音。
  final RxBool allMuted = false.obs;

  /// 每个直播间记忆的音量增益（0-1），换台/换布局后重新载入仍保留。
  final Map<String, double> _volumes = <String, double>{};

  /// 缩容时被收起的画面：切回大布局会按顺序回填，而不是永久丢失。
  final List<MultiRoomItem> _stashed = <MultiRoomItem>[];

  final List<Worker> _workers = <Worker>[];

  @override
  void onInit() {
    super.onInit();
    _seed(initialRooms);
    // 设置页改了全局音量后，已开着的画面跟着变。
    _workers.add(
      ever(
        AppSettingsController.instance.playerVolume,
        (_) => _reapplyVolumes(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 槽位与布局
  // ---------------------------------------------------------------------------

  MultiRoomItem? itemAt(int index) {
    if (index < 0 || index >= cells.length) {
      return null;
    }
    return cells[index];
  }

  MultiRoomPlayerController? playerAt(int index) {
    final item = itemAt(index);
    if (item == null) {
      return null;
    }
    return _findPlayer(item);
  }

  MultiRoomPlayerController? playerOf(MultiRoomItem item) => _findPlayer(item);

  /// 是否还有空位；没有空位时选台等于替换当前目标画面。
  bool get hasEmptyCell => cells.any((item) => item == null);

  /// 已经在画面里的直播间，选台时置灰。
  Set<String> get assignedKeys {
    final keys = <String>{};
    for (final item in cells) {
      if (item != null) {
        keys.add(item.key);
      }
    }
    return keys;
  }

  void setLayout(MultiviewLayout next) {
    if (next == layout.value) {
      return;
    }
    final capacity = next.capacity;
    final previousLength = cells.length;
    // 缩容：被裁掉的画面先收起来（回收播放器），扩容时按顺序回填。
    for (var i = capacity; i < cells.length; i++) {
      final item = cells[i];
      if (item != null && !_stashed.any((room) => room.key == item.key)) {
        if (_stashed.length >= maxCells) {
          _stashed.removeAt(0);
        }
        _stashed.add(item);
      }
      _disposeCellPlayer(i);
    }
    final resized = <MultiRoomItem?>[
      for (var i = 0; i < capacity; i++)
        i < cells.length ? cells[i] : null,
    ];
    // 只有扩容才回填，缩容时不把「原来就在里面的空位」补上。
    if (capacity > previousLength) {
      for (var i = 0; i < resized.length && _stashed.isNotEmpty; i++) {
        if (resized[i] != null) {
          continue;
        }
        final item = _stashed.removeAt(0);
        resized[i] = item;
        _ensurePlayer(item);
      }
    }
    cells.assignAll(resized);
    layout.value = next;

    if (audioFocusIndex.value >= capacity) {
      audioFocusIndex.value = _firstAssignedIndex();
    }
    if (focusedCellIndex.value >= capacity) {
      focusedCellIndex.value = _firstAssignedIndex();
    }
    targetCell.value = _nextEmptyCell();
    _applyAudio();
  }

  /// 把 [item] 放到 [index] 号画面。
  void assignRoom(int index, MultiRoomItem item) {
    if (index < 0 || index >= cells.length) {
      return;
    }
    final existing = cells.indexWhere((room) => room?.key == item.key);
    if (existing == index) {
      return;
    }
    if (existing >= 0 && existing != index) {
      SmartDialog.showToast("该直播间已在画面 ${existing + 1} 中");
      return;
    }

    _stashed.removeWhere((room) => room.key == item.key);
    _disposeCellPlayer(index);
    cells[index] = item;
    _ensurePlayer(item);

    // 网格布局里新加的画面直接拿走声音；1+3 只有落在当前大画面上才改声音。
    if (layout.value != MultiviewLayout.focus ||
        index == focusedCellIndex.value) {
      audioFocusIndex.value = index;
    }
    targetCell.value = _nextEmptyCell(preferred: index);
    _applyAudio();
  }

  void removeCell(int index) {
    if (index < 0 || index >= cells.length) {
      return;
    }
    _disposeCellPlayer(index);
    cells[index] = null;
    if (audioFocusIndex.value == index) {
      audioFocusIndex.value = _firstAssignedIndex();
    }
    if (focusedCellIndex.value == index) {
      focusedCellIndex.value = _firstAssignedIndex();
    }
    targetCell.value = index;
    _applyAudio();
  }

  void refreshAll() {
    var count = 0;
    for (var i = 0; i < cells.length; i++) {
      final player = playerAt(i);
      if (player == null) {
        continue;
      }
      count += 1;
      unawaited(player.refreshRoom());
    }
    if (count > 0) {
      SmartDialog.showToast("已刷新 $count 个画面");
    }
  }

  // ---------------------------------------------------------------------------
  // 声音
  // ---------------------------------------------------------------------------

  /// 指定画面出声（点击画面时调用）。
  void setAudioFocus(int index) {
    if (index < 0 || index >= cells.length || cells[index] == null) {
      return;
    }
    audioFocusIndex.value = index;
    _applyAudio();
  }

  /// 1+3 布局里把小画面升级成大画面，同时把声音交给它。
  void promoteCell(int index) {
    if (index < 0 || index >= cells.length || cells[index] == null) {
      return;
    }
    focusedCellIndex.value = index;
    audioFocusIndex.value = index;
    _applyAudio();
  }

  /// 全部静音 / 恢复声音。
  ///
  /// 静音期间音频焦点仍然可以切换（画面、音量、角标都跟着走），只是不出声；
  /// 恢复声音时继续用当前焦点格，不会变成所有画面一起响。
  void toggleMuteAll() {
    allMuted.value = !allMuted.value;
    _applyAudio();
  }

  double cellVolume(int index) {
    final item = itemAt(index);
    if (item == null) {
      return 1;
    }
    return _volumes[item.key] ?? 1.0;
  }

  void setCellVolume(int index, double value) {
    final item = itemAt(index);
    if (item == null) {
      return;
    }
    final gain = value.clamp(0.0, 1.0).toDouble();
    _volumes[item.key] = gain;
    _findPlayer(item)?.setGain(gain);
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  void _seed(List<MultiRoomItem> rooms) {
    final unique = <MultiRoomItem>[];
    final keys = <String>{};
    for (final item in rooms) {
      if (keys.add(item.key)) {
        unique.add(item);
      }
    }
    var items = unique;
    if (items.length > maxCells) {
      items = items.take(maxCells).toList();
      _toastLater(
        AppSettingsController.instance.powerSaveMode.value
            ? "省电模式下最多同时多开 $maxCells 个直播间"
            : "多画面最多同时显示 $maxCells 个直播间",
      );
    }
    final initial = items.isEmpty
        ? MultiviewLayout.quad
        : multiviewLayoutForCount(items.length);
    layout.value = initial;
    cells.assignAll(<MultiRoomItem?>[
      for (var i = 0; i < initial.capacity; i++)
        i < items.length ? items[i] : null,
    ]);
    for (final item in items) {
      _ensurePlayer(item);
    }
    audioFocusIndex.value = _firstAssignedIndex();
    focusedCellIndex.value = audioFocusIndex.value;
    targetCell.value = _nextEmptyCell();
    _applyAudio();
  }

  /// 控制器在路由 binding 里同步初始化，此时还在 build 阶段，
  /// 直接弹 toast 会触发 markNeedsBuild，推迟到帧末。
  void _toastLater(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SmartDialog.showToast(message);
    });
  }

  MultiRoomPlayerController _ensurePlayer(MultiRoomItem item) {
    final tag = item.key;
    if (Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
      final existing = Get.find<MultiRoomPlayerController>(tag: tag);
      existing.setGain(_volumes[tag] ?? 1.0);
      return existing;
    }
    final player = Get.put<MultiRoomPlayerController>(
      MultiRoomPlayerController(item),
      tag: tag,
    );
    player.setGain(_volumes[tag] ?? 1.0);
    return player;
  }

  MultiRoomPlayerController? _findPlayer(MultiRoomItem item) {
    final tag = item.key;
    if (!Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
      return null;
    }
    return Get.find<MultiRoomPlayerController>(tag: tag);
  }

  /// 先让界面把这一格的 `Video` 卸掉，下一帧再释放播放器，
  /// 避免「播放器已 dispose、视频纹理还挂在树上」的一帧。
  void _disposeCellPlayer(int index) {
    final item = itemAt(index);
    if (item == null) {
      return;
    }
    cells[index] = null;
    _releasePlayerLater(item);
  }

  void _releasePlayerLater(MultiRoomItem item) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 同一帧里又被放回画面（换格/切布局回填）就不回收。
      if (cells.any((room) => room?.key == item.key)) {
        return;
      }
      _deletePlayer(item);
    });
  }

  void _deletePlayer(MultiRoomItem item) {
    final tag = item.key;
    if (Get.isRegistered<MultiRoomPlayerController>(tag: tag)) {
      Get.delete<MultiRoomPlayerController>(tag: tag);
    }
  }

  void _applyAudio() {
    for (var i = 0; i < cells.length; i++) {
      final player = playerAt(i);
      if (player == null) {
        continue;
      }
      player.setAudible(!allMuted.value && i == audioFocusIndex.value);
    }
  }

  void _reapplyVolumes() {
    for (var i = 0; i < cells.length; i++) {
      playerAt(i)?.reapplyVolume();
    }
  }

  int _firstAssignedIndex() {
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] != null) {
        return i;
      }
    }
    return 0;
  }

  int _nextEmptyCell({int? preferred}) {
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == null) {
        return i;
      }
    }
    if (preferred != null && preferred >= 0 && preferred < cells.length) {
      return preferred;
    }
    return 0;
  }

  @override
  void onClose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    for (final item in List<MultiRoomItem?>.from(cells)) {
      if (item == null) {
        continue;
      }
      _deletePlayer(item);
    }
    for (final item in List<MultiRoomItem>.from(_stashed)) {
      _deletePlayer(item);
    }
    _stashed.clear();
    super.onClose();
  }
}
