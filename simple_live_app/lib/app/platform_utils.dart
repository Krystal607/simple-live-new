import 'dart:io';

class PlatformUtils {
  PlatformUtils._();

  static bool get isMobileApp => Platform.isAndroid || Platform.isIOS;

  /// 多画面同屏现在是同一个页面内的多路播放，
  /// 不再依赖桌面端独立进程窗口，因此全平台可用。
  static bool get supportsInlineMultiRoom => true;
}
