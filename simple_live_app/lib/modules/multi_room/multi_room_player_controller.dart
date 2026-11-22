import 'dart:async';

import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/multi_room/multi_room_models.dart';
import 'package:simple_live_app/services/mpv_options_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 多画面里的一路播放器。
///
/// 每个画面都有独立的 [Player] / [VideoController]（独立解码 + 独立纹理），
/// 音频不再由本类自己决定：出声与否由 [MultiRoomController] 按「音频焦点」
/// 统一仲裁，本类只负责把音量真正下发到 media_kit。
class MultiRoomPlayerController extends GetxController {
  final MultiRoomItem item;

  MultiRoomPlayerController(this.item);

  late final Player player = Player(
    configuration: PlayerConfiguration(
      title: item.userName,
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.error,
    ),
  );
  late final VideoController videoController = VideoController(
    player,
    configuration: MpvOptionsService.videoControllerConfiguration(),
  );

  final detail = Rx<LiveRoomDetail?>(null);
  final loading = true.obs;
  final liveStatus = false.obs;
  final errorText = "".obs;
  final qualityInfo = "".obs;
  final lineInfo = "".obs;

  /// 是否为当前出声的画面，由多画面控制器统一仲裁。
  final audible = false.obs;

  /// 本画面相对 App 音量的增益（0-1）。
  final volume = 1.0.obs;

  List<LivePlayQuality> _qualities = const [];
  List<String> _playUrls = const [];
  Map<String, String>? _playHeaders;
  int _qualityIndex = -1;
  int _lineIndex = 0;
  bool _disposed = false;
  int _loadGeneration = 0;
  Future<void>? _opening;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<bool>? _completedSubscription;

  bool _isLoadCurrent(int generation) {
    return !_disposed && generation == _loadGeneration;
  }

  String get title {
    final roomTitle = detail.value?.title.trim();
    if (roomTitle != null && roomTitle.isNotEmpty) {
      return roomTitle;
    }
    return item.userName;
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(_bootstrap());
  }

  /// mpv 参数必须在 `open()` 之前生效（`volume-max`、断流重连参数），
  /// 否则第一路会带着默认参数起播。
  Future<void> _bootstrap() async {
    // 新建的播放器默认满音量；先按「未获得音频焦点」压到 0，
    // 避免格子刚起播就抢声音。
    unawaited(_applyVolume());
    _errorSubscription = player.stream.error.listen((error) {
      if (_disposed) {
        return;
      }
      if (errorText.value.isEmpty) {
        errorText.value = error;
      }
    });
    _completedSubscription = player.stream.completed.listen((completed) {
      if (_disposed || !completed) {
        return;
      }
      if (errorText.value.isEmpty) {
        errorText.value = "播放已结束，可点刷新重试";
      }
    });
    await MpvOptionsService.applyToPlayer(player, audioExclusive: false);
    if (_disposed) {
      return;
    }
    await load();
  }

  Future<void> load() async {
    if (_disposed) {
      return;
    }
    final generation = ++_loadGeneration;
    loading.value = true;
    errorText.value = "";
    liveStatus.value = false;
    try {
      await player.stop();
      if (!_isLoadCurrent(generation)) {
        return;
      }
      final roomDetail =
          await item.site.liveSite.getRoomDetail(roomId: item.roomId);
      if (!_isLoadCurrent(generation)) {
        return;
      }
      detail.value = roomDetail;
      liveStatus.value = roomDetail.status || roomDetail.isRecord;
      if (!liveStatus.value) {
        return;
      }
      await _loadQualities(roomDetail, generation);
      if (!_isLoadCurrent(generation)) {
        return;
      }
      await _loadPlayUrls(roomDetail, generation);
      if (!_isLoadCurrent(generation)) {
        return;
      }
      await _openCurrentUrl(generation);
      if (!_isLoadCurrent(generation)) {
        return;
      }
    } catch (e) {
      if (!_isLoadCurrent(generation)) {
        return;
      }
      Log.e(
        "多画面直播间加载失败：${item.site.id}/${item.roomId} $e",
        StackTrace.current,
      );
      errorText.value = e.toString();
    } finally {
      if (_isLoadCurrent(generation)) {
        loading.value = false;
      }
    }
  }

  Future<void> _loadQualities(
    LiveRoomDetail roomDetail,
    int generation,
  ) async {
    final qualities =
        await item.site.liveSite.getPlayQualites(detail: roomDetail);
    if (!_isLoadCurrent(generation)) {
      return;
    }
    if (qualities.isEmpty) {
      throw Exception("无法读取播放清晰度");
    }
    _qualities = qualities;
    if (AppSettingsController.instance.powerSaveMode.value) {
      // 省电模式：多开每路都是全量解码渲染，统一压到最低清晰度档
      _qualityIndex = _qualities.length - 1;
    } else {
      final qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        _qualityIndex = 0;
      } else if (qualityLevel == 0) {
        _qualityIndex = _qualities.length - 1;
      } else {
        _qualityIndex = (_qualities.length / 2).floor();
      }
    }
    qualityInfo.value = _qualities[_qualityIndex].quality;
  }

  Future<void> _loadPlayUrls(
    LiveRoomDetail roomDetail,
    int generation,
  ) async {
    final quality = _qualities[_qualityIndex];
    final playUrl = await item.site.liveSite.getPlayUrls(
      detail: roomDetail,
      quality: quality,
    );
    if (!_isLoadCurrent(generation)) {
      return;
    }
    if (playUrl.urls.isEmpty) {
      throw Exception("无法读取播放地址");
    }
    _playUrls = playUrl.urls;
    _playHeaders = playUrl.headers;
    _lineIndex = 0;
    lineInfo.value = "线路${_lineIndex + 1}";
  }

  Future<void> _openCurrentUrl(int generation) async {
    if (!_isLoadCurrent(generation)) {
      return;
    }
    var url = _playUrls[_lineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      url = url.replaceAll("http://", "https://");
    }
    final opening = player.open(Media(url, httpHeaders: _playHeaders));
    _opening = opening;
    try {
      await opening;
    } finally {
      if (identical(_opening, opening)) {
        _opening = null;
      }
    }
    if (!_isLoadCurrent(generation)) {
      return;
    }
    await _applyVolume();
    if (!_isLoadCurrent(generation)) {
      return;
    }
  }

  Future<void> refreshRoom() async {
    await load();
  }

  /// 由多画面控制器调用：本画面是否出声。
  void setAudible(bool value) {
    if (audible.value == value) {
      return;
    }
    audible.value = value;
    unawaited(_applyVolume());
  }

  /// 本画面的音量增益（0-1）。
  void setGain(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if (volume.value == next) {
      return;
    }
    volume.value = next;
    unawaited(_applyVolume());
  }

  /// 全局音量变化后重新下发一次（焦点没变也会被调用）。
  void reapplyVolume() {
    unawaited(_applyVolume());
  }

  /// 把「App 音量 × 本画面增益」换算成 media_kit 需要的内部音量。
  ///
  /// 静音（未获得音频焦点、全部静音、增益为 0）一律下发 0，
  /// 避免任何一路在后台偷偷出声。
  ///
  /// 这里不套用主播放器的「移动端基础段交给系统音量」策略：多画面同一时刻
  /// 只有一格出声，用户拖的那一格滑杆必须真的变小，否则滑杆在手机上形同虚设。
  Future<void> _applyVolume() async {
    if (_disposed) {
      return;
    }
    final gain = volume.value.clamp(0.0, 1.0);
    final base = AppSettingsController.instance.playerVolume.value;
    final resolved = (!audible.value || gain <= 0)
        ? 0.0
        : (base * gain).clamp(0.0, PlayerVolumePolicy.maxVolume).toDouble();
    try {
      await player.setVolume(resolved);
    } catch (e) {
      Log.d("多画面音量设置失败：${item.key} $e", false);
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _loadGeneration += 1;
    unawaited(_errorSubscription?.cancel());
    _errorSubscription = null;
    unawaited(_completedSubscription?.cancel());
    _completedSubscription = null;
    unawaited(_release());
    super.onClose();
  }

  /// 先等可能在飞的 `open()` 结束，再串行 stop → dispose。
  /// 直接并发调用会踩到「dispose 时 open 还在跑」的原生崩溃/黑块。
  ///
  /// `stop()` 之后留一小段时间再 `dispose()`：画面被移除/页面正在退场时，
  /// `Video` 组件要到下一帧甚至转场结束才卸载，先让视频纹理安静下来。
  Future<void> _release() async {
    try {
      final opening = _opening;
      if (opening != null) {
        await opening.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
      }
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await player.dispose();
    } catch (e, stackTrace) {
      Log.e("多画面播放器释放失败：${item.key} $e", stackTrace);
    }
  }
}
