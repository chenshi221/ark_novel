import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

/// 朗读时通知栏 / 锁屏上的播放卡片。背后是安卓的前台服务，熄屏久了也不会被系统杀掉；
/// 按钮（含耳机线控）转给阅读页的回调，朗读本身还是阅读页里的 flutter_tts。
class TtsNotice extends BaseAudioHandler {
  TtsNotice._();

  static Future<TtsNotice?>? _init;

  /// 第一次朗读时才启动服务；启动失败（不支持的平台）返回 null，朗读照常只是没有通知。
  static Future<TtsNotice?> get() => _init ??= AudioService.init(
    builder: TtsNotice._,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'ark.tts',
      androidNotificationChannelName: '朗读',
      androidNotificationIcon: 'mipmap/launcher_icon',
    ),
  ).then<TtsNotice?>((h) => h, onError: (_) => null);

  void Function()? onPlay, onPause, onStop, onNext, onPrev;
  int _gen = 0;

  void clearCallbacks() => onPlay = onPause = onStop = onNext = onPrev = null;

  @override
  Future<void> play() async => onPlay?.call();
  @override
  Future<void> pause() async => onPause?.call();
  @override
  Future<void> stop() async => onStop?.call();
  @override
  Future<void> skipToNext() async => onNext?.call();
  @override
  Future<void> skipToPrevious() async => onPrev?.call();

  void show({required String book, required String chapter, String? cover /* 本地文件路径 */, required bool playing}) {
    _gen++;
    mediaItem.add(MediaItem(id: '$book/$chapter', title: chapter, album: book, artist: book, artUri: cover == null ? null : Uri.file(cover)));
    playbackState.add(
      PlaybackState(
        controls: [MediaControl.skipToPrevious, playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext, MediaControl.stop],
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
      ),
    );
  }

  /// 收起通知、停掉前台服务。服务一直被 App 绑着，audio_service 的 stop 删不掉通知：
  /// 先发一次暂停让它退出前台，再自己把通知删掉。
  Future<void> hide() async {
    final g = ++_gen;
    playbackState.add(playbackState.value.copyWith(playing: false));
    playbackState.add(PlaybackState(processingState: AudioProcessingState.idle, playing: false));
    await Future<void>.delayed(const Duration(milliseconds: 300)); // 等上面两次状态发到原生那边
    if (g != _gen) return;
    await const MethodChannel('ark/tts').invokeMethod('cancelNotice').catchError((_) {});
  }
}
