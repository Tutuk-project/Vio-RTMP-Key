import 'dart:convert';
import 'package:http/http.dart' as http;
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
      final webcastSdkVersion = version.replaceAll('.', '').replaceAll('0', '');
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
      final createResponse = await http.post(
        uri,
        headers: headers,
        body: data,
      );
      
      final createResponseBody = createResponse.body;
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room http_status=${createResponse.statusCode}');
      
      if (createResponse.statusCode != 200) {
        addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room failed http_status=${createResponse.statusCode}');
        throw Exception('Gagal membuat room: HTTP ${createResponse.statusCode}');
      }
      
      final createData = jsonDecode(createResponseBody);
      final errorData = createData['data'] ?? {};
      final apiStatusCode = createData['status_code'];
      final apiStatusMessage = createData['status_msg'];
      final responseData = createData is Map ? createData['data'] : null;

      String diagnosticValueType(dynamic value) {
        if (value == null) return 'null';
        if (value is String) return 'string';
        if (value is bool) return 'bool';
        if (value is int || value is num) return 'int';
        if (value is Map) return 'object';
        if (value is List) return 'array';
        return value.runtimeType.toString();
      }

      void collectDiagnosticPaths(dynamic value, String path, int depth, List<String> output) {
        if (depth >= 3) return;
        if (value is Map) {
          for (final entry in value.entries) {
            final key = entry.key.toString();
            final childPath = path.isEmpty ? key : '$path.$key';
            output.add('$childPath:${diagnosticValueType(entry.value)}');
            collectDiagnosticPaths(entry.value, childPath, depth + 1, output);
          }
        } else if (value is List) {
          for (var i = 0; i < value.length; i++) {
            final childPath = '$path[$i]';
            output.add('$childPath:${diagnosticValueType(value[i])}');
            collectDiagnosticPaths(value[i], childPath, depth + 1, output);
          }
        }
      }

      bool diagnosticFieldExists(dynamic value, String field) {
        if (value is Map) {
          if (value.containsKey(field)) return true;
          for (final child in value.values) {
            if (diagnosticFieldExists(child, field)) return true;
          }
        } else if (value is List) {
          for (final child in value) {
            if (diagnosticFieldExists(child, field)) return true;
          }
        }
        return false;
      }

      dynamic findDiagnosticField(dynamic value, String field) {
        if (value is Map) {
          if (value.containsKey(field)) return value[field];
          for (final child in value.values) {
            final found = findDiagnosticField(child, field);
            if (found != null) return found;
          }
        } else if (value is List) {
          for (final child in value) {
            final found = findDiagnosticField(child, field);
            if (found != null) return found;
          }
        }
        return null;
      }

      final diagnosticPaths = <String>[];
      collectDiagnosticPaths(responseData, 'data', 0, diagnosticPaths);
      const diagnosticFields = [
        'room_id',
        'room_id_str',
        'stream_id',
        'stream_id_str',
        'living_room_attrs',
        'rtmp_push_url',
        'share_url',
      ];
      final diagnosticPresence = diagnosticFields
          .map((field) => '$field=${diagnosticFieldExists(responseData, field)}')
          .join(' ');
      final diagnosticPrompts = findDiagnosticField(responseData, 'prompts');
      final diagnosticPromptsText = diagnosticPrompts == null
          ? 'missing'
          : diagnosticPrompts.toString().replaceAll('\n', ' ').substring(
              0,
              diagnosticPrompts.toString().replaceAll('\n', ' ').length > 200
                  ? 200
                  : diagnosticPrompts.toString().replaceAll('\n', ' ').length,
            );
      final diagnosticStatusMessage = apiStatusMessage == null
          ? 'missing'
          : apiStatusMessage.toString().replaceAll('\n', ' ').substring(
              0,
              apiStatusMessage.toString().replaceAll('\n', ' ').length > 200
                  ? 200
                  : apiStatusMessage.toString().replaceAll('\n', ' ').length,
            );
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] create_room response_keys '
          'paths=[${diagnosticPaths.join(', ')}] field_presence=[$diagnosticPresence] '
          'prompts=$diagnosticPromptsText status_msg=$diagnosticStatusMessage');
      final hasPrompts = diagnosticPrompts != null;
      
      // Check for error in response
      if (createData['data'] != null && createData['data']['prompts'] != null) {
        final prompts = createData['data']['prompts'];
        if (prompts.toString().toLowerCase().contains('login') || 
            prompts.toString().toLowerCase().contains('please login')) {
          throw Exception('Please login first. Cookies mungkin tidak valid atau expired. Coba login ulang atau import cookies dari file.');
        }
        throw Exception('TikTok mengembalikan prompts saat membuat room.');
      }
      
      if (createData['status_code'] != null && createData['status_code'] != 0) {
        final errorMsg = createData['status_msg'] ?? 'Unknown error';
        
        // Check jika error terkait login
        if (errorMsg.toLowerCase().contains('login') || 
            errorMsg.toString().toLowerCase().contains('please login') ||
            errorData.toString().toLowerCase().contains('login')) {
          throw Exception('Please login first. Cookies mungkin tidak valid atau expired. Coba login ulang atau import cookies dari file.');
        }
        
        throw Exception('Error create room: $errorMsg');
      }
      
      // Extract stream info dari response
      // Response sudah memberikan full RTMP URL lengkap di rtmp_push_url
      final fullRtmpUrl = createData['data']['stream_url']['rtmp_push_url'];
      final shareUrl = createData['data']['share_url'];
      
      // Extract base URL dan stream key untuk backward compatibility
      // Base URL adalah bagian sebelum stream key (termasuk trailing slash)
      // Stream key adalah bagian setelah slash terakhir
      final splitIndex = fullRtmpUrl.lastIndexOf('/');
      final baseStreamUrl = fullRtmpUrl.substring(0, splitIndex + 1);
      final streamKey = fullRtmpUrl.substring(splitIndex + 1);
      
      return {
        'success': true,
        'fullRtmpUrl': fullRtmpUrl, // Full RTMP URL lengkap (gabungan base + stream key)
        'baseUrl': baseStreamUrl,
        'streamKey': streamKey,
        'shareUrl': shareUrl,
        'roomId': createData['data']['room_id'] ?? '',
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
  
  // End stream
  static Future<bool> endStream(String roomId, {String? diagnosticId}) async {
    try {
      final cookies = await getCookies();
      if (cookies == null || cookies.isEmpty) {
        addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream cookie_missing=true');
        return false;
      }
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream room_id=$roomId cookie_health ${_cookieHealth(cookies)}');
      final baseUrl = await getServerUrl();
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream server_url=$baseUrl source=${_lastServerSource ?? 'unknown'}');
      final version = await getLiveStudioVersion();
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream live_studio_version=$version source=${_lastVersionSource ?? 'unknown'}');
      
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) TikTokLIVEStudio/$version Chrome/108.0.5359.215 Electron/22.3.18-tt.8.release.main.44 TTElectron/22.3.18-tt.8.release.main.44 Safari/537.36',
        'Cookie': cookies,
      };
      
      final params = <String, String>{
        'aid': '8311',
        'app_name': 'tiktok_live_studio',
        'channel': 'studio',
        'device_platform': 'windows',
        'live_mode': '6',
      };
      
      final uri = Uri.parse('${baseUrl}webcast/room/finish_abnormal/').replace(queryParameters: params);
      final response = await http.post(uri, headers: headers);
      
      final Map<String, dynamic> data = response.statusCode == 200
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};
      final apiStatusCode = data['status_code'];
      final apiStatusMessage = data['status_msg'];
      final hasPrompts = data['data'] != null && data['data']['prompts'] != null;
      final success = response.statusCode == 200 && apiStatusCode == 0 && !hasPrompts;
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream http_status=${response.statusCode} '
          'api_status_code=${apiStatusCode ?? 'missing'} status_msg=${apiStatusMessage ?? 'missing'} '
          'prompts_present=$hasPrompts result=$success');
      return success;
    } catch (e) {
      addDiagnosticLog('[${diagnosticId ?? 'untracked'}] end_stream exception_type=${e.runtimeType}');
      return false;
    }
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

