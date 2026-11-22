import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';

/// 多画面布局。
///
/// 与 Pure Live 的多画面一致：
/// - 1×1 / 1×2 / 2×2 是等分网格；
/// - 1+3 由「左侧大画面 + 右侧可滚动小画面列」组成，见 MultiRoomPage。
enum MultiviewLayout {
  /// 1×1，单画面。
  single,

  /// 1×2，左右两格。
  dual,

  /// 2×2，四格等分。
  quad,

  /// 1+3，一大三小。
  focus,
}

extension MultiviewLayoutInfo on MultiviewLayout {
  /// 该布局能容纳的画面数量。
  int get capacity {
    switch (this) {
      case MultiviewLayout.single:
        return 1;
      case MultiviewLayout.dual:
        return 2;
      case MultiviewLayout.quad:
      case MultiviewLayout.focus:
        return 4;
    }
  }

  /// 等分网格的列数；1+3 不使用该值（由页面单独排布）。
  int get columns {
    switch (this) {
      case MultiviewLayout.single:
        return 1;
      case MultiviewLayout.dual:
        return 2;
      case MultiviewLayout.quad:
      case MultiviewLayout.focus:
        return 2;
    }
  }

  /// 等分网格的行数。
  int get rows {
    switch (this) {
      case MultiviewLayout.single:
      case MultiviewLayout.dual:
        return 1;
      case MultiviewLayout.quad:
      case MultiviewLayout.focus:
        return 2;
    }
  }

  /// 布局选择器上的文字。
  String get label {
    switch (this) {
      case MultiviewLayout.single:
        return "1×1";
      case MultiviewLayout.dual:
        return "1×2";
      case MultiviewLayout.quad:
        return "2×2";
      case MultiviewLayout.focus:
        return "1+3";
    }
  }
}

/// 打开多画面时按房间数量挑一个初始布局。
MultiviewLayout multiviewLayoutForCount(int count) {
  if (count <= 1) {
    return MultiviewLayout.single;
  }
  if (count == 2) {
    return MultiviewLayout.dual;
  }
  return MultiviewLayout.quad;
}

/// 多画面里的一个直播间。
class MultiRoomItem {
  final Site site;
  final String roomId;
  final String userName;
  final String face;

  const MultiRoomItem({
    required this.site,
    required this.roomId,
    required this.userName,
    required this.face,
  });

  factory MultiRoomItem.fromFollow(FollowUser item) {
    return MultiRoomItem(
      site: Sites.allSites[item.siteId]!,
      roomId: item.roomId,
      userName: item.userName,
      face: item.face,
    );
  }

  /// 从观看记录构造；平台已下线时返回 null。
  static MultiRoomItem? fromHistory(History item) {
    final site = Sites.allSites[item.siteId];
    if (site == null) {
      return null;
    }
    return MultiRoomItem(
      site: site,
      roomId: item.roomId,
      userName: item.userName,
      face: item.face,
    );
  }

  String get key => "${site.id}_$roomId";
}
