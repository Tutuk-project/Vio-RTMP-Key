import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TikTokService {
  static String? _baseUrl;
  static const String liveStudioUrl = 'https://studio.tiktok.com';
  static const int _maxDiagnosticEntries = 200;
  static final List<String> _diagnosticEntries = [];
  static final Map<String, DateTime> _diagnosticStarts = {};
  static String? _lastServerSource;
  static String? _lastVersionSource;
  static bool? _lastLoginCheckResult;

  static String startDiagnosticOperation(String operation) {
    final now = DateTime.now();
    final id = '${now.microsecondsSinceEpoch}';
    _diagnosticStarts[id] = now;
    addDiagnosticLog('[$id] START operation=$operation timestamp=${now.toIso8601String()}');
    return id;
  }

  static void finishDiagnosticOperation(String id, String outcome) {
    final started = _diagnosticStarts.remove(id);
    final durationMs = started == null ? -1 : DateTime.now().difference(started).inMilliseconds;
    addDiagnosticLog('[$id] END outcome=$outcome duration_ms=$durationMs timestamp=${DateTime.now().toIso8601String()}');
  }

  static void addDiagnosticLog(String message) {
    _diagnosticEntries.add('${DateTime.now().toIso8601String()} $message');
    if (_diagnosticEntries.length > _maxDiagnosticEntries) {
      _diagnosticEntries.removeRange(0, _diagnosticEntries.length - _maxDiagnosticEntries);
    }
  }

  static String getDiagnosticLogText() => _diagnosticEntries.join('\n');

  static String _cookieHealth(String cookies) {
    final names = <String>[];
    for (final part in cookies.split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) names.add(part.substring(0, separator).trim());
    }
    final nameSet = names.toSet();
    return 'cookie_count=${names.length} cookie_names=${names.join(',')} '
        'sessionid=${nameSet.contains('sessionid')} sid_tt=${nameSet.contains('sid_tt')} '
        'sid_guard=${nameSet.contains('sid_guard')} checkLoginStatus=${_lastLoginCheckResult?.toString() ?? 'not_checked'}';
  }
  
  // Get server URL dynamically
  static Future<String> getServerUrl() async {
    if (_baseUrl != null) {
      _lastServerSource = 'cache';
      return _baseUrl!;
    }
    
    try {
      final url = 'https://tnc16-platform-useast1a.tiktokv.com/get_domains/v4/?aid=8311&ttwebview_version=1130022001&device_platform=win';
      final response = await http.get(Uri.parse(url));
      final data = jsonDecode(response.body);
      
      for (var action in data['data']['ttnet_dispatch_actions']) {
        if (action['param'] != null && 
            action['param']['strategy_info'] != null &&
            action['param']['strategy_info'].toString().contains('webcast-normal.tiktokv.com')) {
          var serverUrl = action['param']['strategy_info']['webcast-normal.tiktokv.com'];
          
          for (var action2 in data['data']['ttnet_dispatch_actions']) {
            if (action2['param'] != null && 
                action2['param']['strategy_info'] != null &&
                action2['param']['strategy_info'][serverUrl] != null) {
              serverUrl = action2['param']['strategy_info'][serverUrl];
              _baseUrl = 'https://$serverUrl/';
              _lastServerSource = 'lookup';
              return _baseUrl!;
            }
          }
          _baseUrl = 'https://$serverUrl/';
          _lastServerSource = 'lookup';
          return _baseUrl!;
        }
      }
    } catch (_) {
      addDiagnosticLog('server_lookup=error');
    }
    _baseUrl = 'https://webcast16-normal-c-useast2a.tiktokv.com/';
    _lastServerSource = 'fallback';
    return _baseUrl!;
  }
  
  // Simpan cookies
  static Future<void> saveCookies(String cookies) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tiktok_cookies', cookies);
  }
  
  // Ambil cookies
  static Future<String?> getCookies() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('tiktok_cookies');
  }
  
  // Parse cookies dari string
  static Map<String, String> parseCookies(String cookieString) {
    final Map<String, String> cookies = {};
    final List<String> cookieList = cookieString.split(';');
    
    for (String cookie in cookieList) {
      final parts = cookie.trim().split('=');
      if (parts.length == 2) {
        cookies[parts[0].trim()] = parts[1].trim();
      }
    }
    
    return cookies;
  }
  
  
  // Get Live Studio version
  static Future<String> getLiveStudioVersion() async {
    try {
      final url = 'https://tron-sg.bytelemon.com/api/sdk/check_update';
      final params = {
        'pid': '7393277106664249610',
        'uid': '7464643088460875280',
        'branch': 'studio/release/stable',
        'buildId': '0',
      };
      final response = await http.get(Uri.parse(url).replace(queryParameters: params));
      final data = jsonDecode(response.body);
      final resolvedVersion = data['data']['manifest']['win32']['version'];
      _lastVersionSource = resolvedVersion == null ? 'fallback' : 'network';
      return resolvedVersion ?? '0.99.0';
    } catch (_) {
      _lastVersionSource = 'fallback';
      return '0.99.0';
    }
  }

  // Upload thumbnail (sama seperti source code Python)
  static Future<String?> uploadThumbnail(String filePath, String baseUrl, Map<String, String> params) async {
    try {
      final cookies = await getCookies();
      if (cookies == null || cookies.isEmpty) {
        return null;
      }
      
      final version = await getLiveStudioVersion();
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TikTokLIVEStudio/$version Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36',
        'Cookie': cookies,
      };
      
      final file = await http.MultipartFile.fromPath(
        'file',
        filePath,
        filename: 'crop_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${baseUrl}webcast/room/upload/image/').replace(queryParameters: params),
      );
      
      request.headers.addAll(headers);
      request.files.add(file);
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['data']?['uri']?.toString();
      }
      
      return null;
    } catch (e) {
      print('Error uploading thumbnail: $e');
      return null;
    }
  }
  
  // Generate stream key
  static Future<Map<String, dynamic>> generateStreamKey({
    required String title,
    String? hashtagId,
    String? gameTagId,
    bool enableReplay = false,
    bool closeRoomWhenStreamEnds = false,
    String regionPriority = '',
    bool isMatureContent = false,
    String? thumbnailPath,
    String? diagnosticId,
  }) async {
    try {
      final cookies = await getCookies();
      
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] generate_start cookies_loaded=${cookies != null && cookies.isNotEmpty}');
      
      if (cookies == null || cookies.isEmpty) {
        throw Exception('Silakan login terlebih dahulu');
      }
      
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] cookie_health ${_cookieHealth(cookies)}');
      
      // Get server URL
      final baseUrl = await getServerUrl();
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] server_url=$baseUrl source=${_lastServerSource ?? 'unknown'}');
      final version = await getLiveStudioVersion();
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] live_studio_version=$version source=${_lastVersionSource ?? 'unknown'}');
      
      // Build headers sesuai source code Python
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TikTokLIVEStudio/$version Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36',
        'Cookie': cookies,
      };
      
      // Build query params sesuai source code Python
      final webcastSdkVersion = version.replaceAll('.', '');
      final params = <String, String>{
        'aid': '8311',
        'app_name': 'tiktok_live_studio',
        'channel': 'studio',
        'device_platform': 'windows',
        'priority_region': regionPriority,
        'live_mode': '6',
        'version_code': version,
        'webcast_sdk_version': webcastSdkVersion,
        'webcast_language': 'en',
        'app_language': 'en',
        'language': 'en',
        'browser_version': '5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TikTokLIVEStudio/0.69.2 Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36',
        'browser_name': 'Mozilla',
        'browser_platform': 'Win32',
        'browser_language': 'en-US',
        'screen_height': '1080',
        'screen_width': '1920',
        'timezone_name': 'Asia/Jakarta',
        'device_id': '7378193331631310352',
        'install_id': '7378196538524927745',
      };
      
      // Upload thumbnail jika ada
      String? coverUri = '';
      if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
        coverUri = await uploadThumbnail(thumbnailPath, baseUrl, params);
      }
      
      // Build form data sesuai source code Python
      final data = <String, String>{
        'title': title,
        'live_studio': '1',
        'gen_replay': enableReplay.toString().toLowerCase(),
        'chat_auth': '1',
        'cover_uri': coverUri ?? '',
        'close_room_when_close_stream': closeRoomWhenStreamEnds.toString().toLowerCase(),
        'hashtag_id': hashtagId ?? '',
        'game_tag_id': gameTagId ?? '0',
        'screenshot_cover_status': '1',
        'live_sub_only': '0',
        'chat_sub_only_auth': '2',
        'multi_stream_scene': '0',
        'gift_auth': '1',
        'chat_l2': '1',
        'star_comment_switch': 'true',
        'multi_stream_source': '1',
      };
      
      if (isMatureContent) {
        data['age_restricted'] = '4';
      }
      
      // Request untuk create room - menggunakan form data, bukan JSON
      final createRoomUrl = '${baseUrl}webcast/room/create/';
      
      final uri = Uri.parse(createRoomUrl).replace(queryParameters: params);
      final encodedCreateBody = Uri(queryParameters: data).query;
      final createHeaders = <String, String>{
        ...headers,
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'sdk_aid': '8311',
        'x-ss-stub': md5.convert(utf8.encode(encodedCreateBody)).toString(),
      };
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room request_parameters '
          'webcast_sdk_version=$webcastSdkVersion x_ss_stub=true sdk_aid=true '
          'signature_headers_present=false');
      final createResponse = await http.post(
        uri,
        headers: createHeaders,
        body: encodedCreateBody,
      );
      
      final createResponseBody = createResponse.body;
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room http_status=${createResponse.statusCode}');
      
      if (createResponse.statusCode != 200) {
        addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room failed http_status=${createResponse.statusCode}');
        throw Exception('Gagal membuat room: HTTP ${createResponse.statusCode}');
      }
      
      final createData = jsonDecode(createResponseBody);
      final errorData = createData is Map ? (createData['data'] ?? {}) : {};
      final apiStatusCode = createData is Map ? createData['status_code'] : null;
      final parsedApiStatusCode = int.tryParse(apiStatusCode?.toString() ?? '');
      final apiStatusMessage = createData is Map ? createData['status_msg'] : null;
      final responseRoomData = createData is Map ? createData['data'] : null;
      final responseAttrs = responseRoomData is Map
          ? (responseRoomData['living_room_attrs'] is Map
              ? responseRoomData['living_room_attrs'] as Map
              : <dynamic, dynamic>{})
          : <dynamic, dynamic>{};
      final diagnosticRoomId = responseAttrs['room_id_str'] ??
          responseAttrs['room_id'] ??
          (responseRoomData is Map ? responseRoomData['room_id_str'] ?? responseRoomData['room_id'] : null);
      final diagnosticStreamId = responseRoomData is Map
          ? responseRoomData['stream_id_str'] ?? responseRoomData['stream_id']
          : null;
      final hasPrompts = responseRoomData is Map && responseRoomData['prompts'] != null;
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room api_status_code=${apiStatusCode ?? 'missing'} '
          'status_msg=${apiStatusMessage ?? 'missing'} prompts_present=$hasPrompts '
          'room_id_present=${diagnosticRoomId != null && diagnosticRoomId.toString().isNotEmpty} '
          'stream_id_present=${diagnosticStreamId != null && diagnosticStreamId.toString().isNotEmpty} '
          'room_id=${diagnosticRoomId ?? 'missing'} stream_id=${diagnosticStreamId ?? 'missing'}');
      
      // Check for error in response
      if (createData['data'] != null && createData['data']['prompts'] != null) {
        final prompts = createData['data']['prompts'];
        if (prompts.toString().toLowerCase().contains('login') || 
            prompts.toString().toLowerCase().contains('please login')) {
          throw Exception('Please login first. Cookies mungkin tidak valid atau expired. Coba login ulang atau import cookies dari file.');
        }
        throw Exception('TikTok mengembalikan prompts saat membuat room.');
      }
      
      if (parsedApiStatusCode != 0) {
        final errorMsg = (apiStatusMessage ?? 'Unknown or missing API status').toString();

        if (errorMsg.toLowerCase().contains('login') ||
            errorData.toString().toLowerCase().contains('login')) {
          throw Exception('Please login first. Cookies mungkin tidak valid atau expired. Coba login ulang atau import cookies dari file.');
        }

        throw Exception('Error create room: $errorMsg (status_code=${apiStatusCode ?? 'missing'})');
      }

      if (responseRoomData is! Map) {
        throw Exception('TikTok mengembalikan status_code=0 tetapi struktur data room tidak tersedia.');
      }

      final roomData = Map<String, dynamic>.from(responseRoomData);
      final livingRoomAttrs = roomData['living_room_attrs'] is Map
          ? Map<String, dynamic>.from(roomData['living_room_attrs'] as Map)
          : <String, dynamic>{};

      String firstNonEmpty(List<dynamic> values) {
        for (final candidate in values) {
          if (candidate == null) continue;
          final value = candidate.toString().trim();
          if (value.isNotEmpty && value != '0') return value;
        }
        return '';
      }

      final roomId = firstNonEmpty([
        livingRoomAttrs['room_id_str'],
        livingRoomAttrs['room_id'],
        roomData['room_id_str'],
        roomData['room_id'],
        roomData['id_str'],
        roomData['id'],
      ]);
      final streamId = firstNonEmpty([
        roomData['stream_id_str'],
        roomData['stream_id'],
      ]);
      final streamUrlData = roomData['stream_url'];
      final fullRtmpUrl = streamUrlData is Map
          ? (streamUrlData['rtmp_push_url']?.toString() ?? '')
          : '';
      final shareUrl = roomData['share_url']?.toString() ?? '';

      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room parsed '
          'room_id_present=${roomId.isNotEmpty} stream_id_present=${streamId.isNotEmpty} '
          'rtmp_url_present=${fullRtmpUrl.isNotEmpty} share_url_present=${shareUrl.isNotEmpty}');

      if (roomId.isEmpty) {
        throw Exception('TikTok memberi RTMP response tetapi room_id tidak ditemukan (living_room_attrs.room_id_str / room_id). Room tidak dianggap berhasil dibuat.');
      }
      if (streamId.isEmpty) {
        throw Exception('TikTok memberi room_id tetapi stream_id tidak ditemukan. Stream tidak dapat mempertahankan status LIVE.');
      }
      if (fullRtmpUrl.isEmpty) {
        throw Exception('TikTok tidak mengembalikan stream_url.rtmp_push_url.');
      }

      // Extract base URL dan stream key untuk backward compatibility.
      final splitIndex = fullRtmpUrl.lastIndexOf('/');
      if (splitIndex < 0 || splitIndex == fullRtmpUrl.length - 1) {
        throw Exception('Format RTMP URL dari TikTok tidak valid.');
      }
      final baseStreamUrl = fullRtmpUrl.substring(0, splitIndex + 1);
      final streamKey = fullRtmpUrl.substring(splitIndex + 1);

      return {
        'success': true,
        'fullRtmpUrl': fullRtmpUrl,
        'baseUrl': baseStreamUrl,
        'streamKey': streamKey,
        'shareUrl': shareUrl,
        'roomId': roomId,
        'streamId': streamId,
      };
    } catch (e) {
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] generate_exception type=${e.runtimeType}');
      final errorMessage = e is Exception
          ? e.toString().replaceAll('Exception: ', '')
          : 'Terjadi kesalahan saat membuat room.';
      return {
        'success': false,
        'error': errorMessage,
        'fullError': errorMessage,
      };
    }
  }
  
  // Keep the TikTok anchor room alive and explicitly update its state.
  // status: 1 = preparing, 2 = live, 3 = paused, 4 = finished.
  static Future<bool> pingAnchor({
    required String roomId,
    required String streamId,
    required int status,
    String? diagnosticId,
  }) async {
    final prefix = '[${diagnosticId ?? 'untracked'}] anchor_ping';
    if (roomId.trim().isEmpty || streamId.trim().isEmpty) {
      addDiagnosticLog('$prefix skipped missing_room_or_stream_id=true');
      return false;
    }

    try {
      final cookies = await getCookies();
      if (cookies == null || cookies.isEmpty) {
        addDiagnosticLog('$prefix cookie_missing=true');
        return false;
      }

      final baseUrl = await getServerUrl();
      final version = await getLiveStudioVersion();
      final webcastSdkVersion = version.replaceAll('.', '');
      final params = <String, String>{
        'aid': '8311',
        'app_name': 'tiktok_live_studio',
        'channel': 'studio',
        'device_platform': 'windows',
        'live_mode': '6',
        'version_code': version,
        'webcast_sdk_version': webcastSdkVersion,
        'webcast_language': 'en',
        'app_language': 'en',
        'language': 'en',
      };
      final body = <String, String>{
        'status': status.toString(),
        'room_id': roomId,
        'stream_id': streamId,
      };
      final encodedBody = Uri(queryParameters: body).query;
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TikTokLIVEStudio/$version Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36',
        'Cookie': cookies,
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'sdk_aid': '8311',
        'x-ss-stub': md5.convert(utf8.encode(encodedBody)).toString(),
      };
      final uri = Uri.parse('${baseUrl}webcast/room/ping/anchor/').replace(queryParameters: params);
      final response = await http.post(uri, headers: headers, body: encodedBody);
      final responseData = response.statusCode == 200 ? jsonDecode(response.body) : null;
      final apiStatusCode = responseData is Map
          ? int.tryParse(responseData['status_code']?.toString() ?? '')
          : null;
      final statusMessage = responseData is Map ? responseData['status_msg'] : null;
      final accepted = response.statusCode == 200 &&
          (apiStatusCode == 0 ||
              (status != 4 && apiStatusCode == 4003150) ||
              (status == 4 && (apiStatusCode == 30003 || apiStatusCode == 30003001)));
      addDiagnosticLog('$prefix status=$status http_status=${response.statusCode} '
          'api_status_code=${apiStatusCode ?? 'missing'} '
          'status_msg=${statusMessage ?? 'missing'} result=$accepted '
          'signature_headers_present=false');
      return accepted;
    } catch (e) {
      addDiagnosticLog('$prefix status=$status exception_type=${e.runtimeType}');
      return false;
    }
  }

  // End LIVE by sending the final anchor ping (status=4).
  static Future<bool> endStream(
    String roomId, {
    required String streamId,
    String? diagnosticId,
  }) {
    return pingAnchor(
      roomId: roomId,
      streamId: streamId,
      status: 4,
      diagnosticId: diagnosticId,
    );
  }

  // Check login status
  static Future<bool> checkLoginStatus() async {
    try {
      final cookies = await getCookies();
      if (cookies == null || cookies.isEmpty) {
        return false;
      }
      
      final headers = <String, String>{
        'Cookie': cookies,
      };
      
      final response = await http.get(
        Uri.parse('$liveStudioUrl/api/live/studio/check_login/'),
        headers: headers,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _lastLoginCheckResult = data['status_code'] == 0;
        return _lastLoginCheckResult!;
      }
      _lastLoginCheckResult = false;
      
      return false;
    } catch (e) {
      _lastLoginCheckResult = false;
      return false;
    }
  }

  // Import cookies dari file JSON
  static Future<Map<String, dynamic>> importCookiesFromJson(String jsonString) async {
    try {
      final jsonData = jsonDecode(jsonString);
      final List<String> cookiePairs = [];
      
      // Handle format array of cookie objects
      if (jsonData is List) {
        for (var cookie in jsonData) {
          if (cookie is Map) {
            final name = cookie['name']?.toString() ?? '';
            final value = cookie['value']?.toString() ?? '';
            if (name.isNotEmpty && value.isNotEmpty) {
              cookiePairs.add('$name=$value');
            }
          }
        }
      } 
      // Handle format object dengan cookies
      else if (jsonData is Map) {
        // Format 1: { "cookies": [...] }
        if (jsonData.containsKey('cookies') && jsonData['cookies'] is List) {
          for (var cookie in jsonData['cookies']) {
            if (cookie is Map) {
              final name = cookie['name']?.toString() ?? '';
              final value = cookie['value']?.toString() ?? '';
              if (name.isNotEmpty && value.isNotEmpty) {
                cookiePairs.add('$name=$value');
              }
            }
          }
        }
        // Format 2: { "sessionid": "...", "sid_tt": "..." }
        else {
          jsonData.forEach((key, value) {
            if (value is String && value.isNotEmpty) {
              cookiePairs.add('$key=$value');
            }
          });
        }
      }
      
      if (cookiePairs.isEmpty) {
        return {
          'success': false,
          'error': 'Format cookies tidak valid atau kosong',
        };
      }
      
      final cookieString = cookiePairs.join('; ');
      await saveCookies(cookieString);
      
      // Verify cookies dengan check login
      final isLoggedIn = await checkLoginStatus();
      
      return {
        'success': true,
        'message': 'Cookies berhasil diimport',
        'isLoggedIn': isLoggedIn,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error parsing JSON: $e',
      };
    }
  }
  
  // Fetch game tags dari API (sama seperti source code Python)
  static Future<Map<String, String>> fetchGameTags() async {
    try {
      // Gunakan base URL yang sama dengan source code Python
      final url = 'https://webcast16-normal-c-useast2a.tiktokv.com/webcast/room/hashtag/list/';
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final gameTagList = data['data']['game_tag_list'] as List;
        
        // Convert ke Map: id -> show_name
        final Map<String, String> games = {};
        for (var game in gameTagList) {
          final id = game['id']?.toString() ?? '';
          final name = game['show_name']?.toString() ?? '';
          if (id.isNotEmpty && name.isNotEmpty) {
            games[id] = name;
          }
        }
        
        return games;
      }
      
      return {};
    } catch (e) {
      print('Error fetching game tags: $e');
      return {};
    }
  }
  
  // Import cookies dari Netscape format (opsional)
  static Future<Map<String, dynamic>> importCookiesFromNetscape(String netscapeString) async {
    try {
      final List<String> cookiePairs = [];
      final lines = netscapeString.split('\n');
      
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#') || line.startsWith('HttpOnly')) {
          continue;
        }
        
        // Format Netscape: domain, flag, path, secure, expiration, name, value
        final parts = line.split('\t');
        if (parts.length >= 7) {
          final name = parts[5].trim();
          final value = parts[6].trim();
          if (name.isNotEmpty && value.isNotEmpty) {
            cookiePairs.add('$name=$value');
          }
        }
      }
      
      if (cookiePairs.isEmpty) {
        return {
          'success': false,
          'error': 'Format Netscape cookies tidak valid',
        };
      }
      
      final cookieString = cookiePairs.join('; ');
      await saveCookies(cookieString);
      
      final isLoggedIn = await checkLoginStatus();
      
      return {
        'success': true,
        'message': 'Cookies berhasil diimport',
        'isLoggedIn': isLoggedIn,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Error parsing Netscape format: $e',
      };
    }
  }
}

