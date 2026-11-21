class StreamInfo {
  final String fullRtmpUrl;
  final String baseUrl;
  final String streamKey;
  final String shareUrl;
  final String roomId;
  final String streamId;
  
  StreamInfo({
    required this.fullRtmpUrl,
    required this.baseUrl,
    required this.streamKey,
    required this.shareUrl,
    required this.roomId,
    this.streamId = '',
  });
  
  factory StreamInfo.fromMap(Map<String, dynamic> map) {
    return StreamInfo(
      fullRtmpUrl: map['fullRtmpUrl']?.toString() ?? '${map['baseUrl'] ?? ''}${map['streamKey'] ?? ''}',
      baseUrl: map['baseUrl'] ?? '',
      streamKey: map['streamKey'] ?? '',
      shareUrl: map['shareUrl'] ?? '',
      roomId: map['roomId']?.toString() ?? '',
      streamId: map['streamId']?.toString() ?? '',
    );
  }
}

