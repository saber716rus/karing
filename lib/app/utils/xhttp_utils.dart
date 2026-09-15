// ignore_for_file: constant_identifier_names, empty_catches

import 'dart:convert';

import 'package:karing/app/utils/convert_utils.dart';
import 'package:tuple/tuple.dart';
import 'package:yaml/yaml.dart';

/// XHTTP (also known as splithttp) transport support for karing.
///
/// XHTTP is a modern Xray-core transport protocol that uses HTTP/2 or HTTP/3
/// for proxying, replacing legacy WebSocket / HTTPUpgrade / gRPC transports.
/// Spec: https://xtls.github.io/en/config/transports/xhttp.html
///
/// This module is intentionally self-contained: it provides the Clash YAML
/// option classes, the sing-box option classes, the URL query-string parser,
/// and the converters between Clash ↔ sing-box ↔ V2Ray URL formats.
///
/// Public files (`clash_yaml.dart`, `singbox_json.dart`, `clash_to_singbox.dart`,
/// `v2ray_txt_utils.dart`) wire up their existing switch/case chains to call
/// into the helpers exposed here.

// ============================================================================
// V2Ray URL query parameters (subset of Xray-core `infra/conf/transport_method.go`)
// ============================================================================

/// V2Ray URL fragment for the xhttp "extra" parameter is a JSON blob.
/// Xray stores advanced options under `?extra=<base64-or-json>`.
class V2RayXHttpExtra {
  Map<String, dynamic> raw;

  V2RayXHttpExtra() : raw = {};

  static V2RayXHttpExtra? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final decoded = _maybeDecodeBase64(raw);
    try {
      final obj = jsonDecode(decoded) as Map<String, dynamic>;
      final x = V2RayXHttpExtra();
      x.raw = obj;
      return x;
    } catch (_) {
      return null;
    }
  }

  /// Returns the inner JSON map (already decoded), or null if absent.
  Map<String, dynamic>? toJsonObject() =>
      raw.isEmpty ? null : Map<String, dynamic>.from(raw);

  static String? _maybeDecodeBase64(String s) {
    // Heuristic: if it starts with `{` it's JSON; otherwise try base64.
    final trimmed = s.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return trimmed;
    // Standard + URL-safe base64 alphabet
    final re = RegExp(r'^[A-Za-z0-9_\-=+/]+$');
    if (!re.hasMatch(trimmed)) return trimmed;
    try {
      final norm = trimmed.replaceAll('-', '+').replaceAll('_', '/');
      final padded = norm.padRight((norm.length + 3) & ~3, '=');
      final bytes = base64.decode(padded);
      return utf8.decode(bytes);
    } catch (_) {
      return trimmed;
    }
  }
}

/// V2Ray URL `xmux` parameter is a JSON blob, e.g.
/// `xmux={"maxConcurrency":16}` or `xmux=eyJoS2VlcEFsaXZlUGVyaW9kIjozMH0`.
class V2RayXHttpXMux {
  int? maxConcurrency;
  int? maxConnections;
  int? cMaxReuseTimes;
  int? hMaxRequestTimes;
  int? hMaxReusableSecs;
  int? hKeepAlivePeriod;

  bool get isEmpty =>
      maxConcurrency == null &&
      maxConnections == null &&
      cMaxReuseTimes == null &&
      hMaxRequestTimes == null &&
      hMaxReusableSecs == null &&
      hKeepAlivePeriod == null;

  static V2RayXHttpXMux? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final decoded = V2RayXHttpExtra._maybeDecodeBase64(raw);
    try {
      final obj = jsonDecode(decoded) as Map<String, dynamic>;
      final m = V2RayXHttpXMux();
      m.maxConcurrency = ConvertUtils.intParseDynamic(obj["maxConcurrency"]);
      m.maxConnections = ConvertUtils.intParseDynamic(obj["maxConnections"]);
      m.cMaxReuseTimes = ConvertUtils.intParseDynamic(obj["cMaxReuseTimes"]);
      m.hMaxRequestTimes = ConvertUtils.intParseDynamic(obj["hMaxRequestTimes"]);
      m.hMaxReusableSecs = ConvertUtils.intParseDynamic(obj["hMaxReusableSecs"]);
      m.hKeepAlivePeriod =
          ConvertUtils.intParseDynamic(obj["hKeepAlivePeriod"]);
      return m.isEmpty ? null : m;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (maxConcurrency != null) ret['max_concurrency'] = maxConcurrency;
    if (maxConnections != null) ret['max_connections'] = maxConnections;
    if (cMaxReuseTimes != null) ret['c_max_reuse_times'] = cMaxReuseTimes;
    if (hMaxRequestTimes != null) ret['h_max_request_times'] = hMaxRequestTimes;
    if (hMaxReusableSecs != null) ret['h_max_reusable_secs'] = hMaxReusableSecs;
    if (hKeepAlivePeriod != null) ret['h_keep_alive_period'] = hKeepAlivePeriod;
    return ret;
  }
}

/// Result of parsing `?type=xhttp&...` query parameters from a `vless://`,
/// `vmess://` or `trojan://` URL.
class V2RayXHttpUrlParams {
  String? path;
  String? host;
  String? mode; // "auto" | "packet-up" | "stream-up" | "stream-one"
  Map<String, String>? headers;
  V2RayXHttpXMux? xmux;
  V2RayXHttpExtra? extra;

  bool get isEmpty =>
      (path == null || path!.isEmpty) &&
      (host == null || host!.isEmpty) &&
      (mode == null || mode!.isEmpty) &&
      (headers == null || headers!.isEmpty) &&
      (xmux == null || xmux!.isEmpty) &&
      extra == null;

  /// Parse from a URL's query-parameter map. Accepts both modern
  /// Xray parameter names (`type=xhttp`, `path=`, `host=`, `mode=`,
  /// `extra=`, `xmux=`) and the legacy `splithttp` aliases.
  static V2RayXHttpUrlParams parse(Map<String, String> q) {
    final r = V2RayXHttpUrlParams();
    r.path = _stringOrNull(q["path"] ?? q["xhttpPath"]);
    r.host = _stringOrNull(q["host"] ?? q["xhttpHost"]);
    r.mode = _stringOrNull(q["mode"] ?? q["xhttpMode"]);
    r.extra = V2RayXHttpExtra.parse(q["extra"] ?? q["xhttpExtra"]);
    r.xmux = V2RayXHttpXMux.parse(q["xmux"] ?? q["xhttpXmux"]);
    // headers: Xray accepts `headers=Host=example.com;X-Header=value`
    final headersStr = _stringOrNull(q["headers"]);
    if (headersStr != null && headersStr.isNotEmpty) {
      r.headers = {};
      for (final pair in headersStr.split(RegExp(r'[;\n]'))) {
        final idx = pair.indexOf('=');
        if (idx <= 0) continue;
        final k = pair.substring(0, idx).trim();
        final v = pair.substring(idx + 1).trim();
        if (k.isNotEmpty) r.headers![k] = v;
      }
      if (r.headers!.isEmpty) r.headers = null;
    }
    // make sure path begins with "/"
    if (r.path != null && r.path!.isNotEmpty && !r.path!.startsWith('/')) {
      r.path = '/${r.path}';
    }
    return r;
  }

  static String? _stringOrNull(String? s) {
    if (s == null) return null;
    final v = s.trim();
    return v.isEmpty ? null : v;
  }
}

// ============================================================================
// Clash YAML option classes
// ============================================================================

/// Clash YAML `xhttp-opts.xmux` sub-options.
class ClashYamlXHttpOptionsXmux {
  int? max_concurrency;
  int? max_connections;
  int? c_max_reuse_times;
  int? h_max_request_times;
  int? h_max_reusable_secs;
  int? h_keep_alive_period;

  void fromYaml(YamlMap? map) {
    if (map == null) return;
    max_concurrency = ConvertUtils.intParseDynamic(map["max-concurrency"]);
    max_connections = ConvertUtils.intParseDynamic(map["max-connections"]);
    c_max_reuse_times = ConvertUtils.intParseDynamic(map["c-max-reuse-times"]);
    h_max_request_times =
        ConvertUtils.intParseDynamic(map["h-max-request-times"]);
    h_max_reusable_secs =
        ConvertUtils.intParseDynamic(map["h-max-reusable-secs"]);
    h_keep_alive_period =
        ConvertUtils.intParseDynamic(map["h-keep-alive-period"]);
  }

  static ClashYamlXHttpOptionsXmux? fromYamlStatic(YamlMap? map) {
    if (map == null) return null;
    final o = ClashYamlXHttpOptionsXmux();
    o.fromYaml(map);
    return o;
  }

  bool get isEmpty =>
      max_concurrency == null &&
      max_connections == null &&
      c_max_reuse_times == null &&
      h_max_request_times == null &&
      h_max_reusable_secs == null &&
      h_keep_alive_period == null;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (max_concurrency != null) ret['max_concurrency'] = max_concurrency;
    if (max_connections != null) ret['max_connections'] = max_connections;
    if (c_max_reuse_times != null) ret['c_max_reuse_times'] = c_max_reuse_times;
    if (h_max_request_times != null) {
      ret['h_max_request_times'] = h_max_request_times;
    }
    if (h_max_reusable_secs != null) {
      ret['h_max_reusable_secs'] = h_max_reusable_secs;
    }
    if (h_keep_alive_period != null) {
      ret['h_keep_alive_period'] = h_keep_alive_period;
    }
    return ret;
  }
}

/// Clash YAML `xhttp-opts.download-settings` sub-options.
class ClashYamlXHttpDownloadOptions {
  String? mode;
  String? path;
  String? host;
  Map<String, String>? headers;
  String? extra;

  void fromYaml(YamlMap? map) {
    if (map == null) return;
    mode = map["mode"]?.toString();
    path = map["path"]?.toString();
    host = map["host"]?.toString();
    final h = map["headers"];
    if (h is YamlMap) {
      headers = {};
      h.forEach((k, v) {
        if (k != null && v != null) {
          headers![k.toString()] = v.toString();
        }
      });
      if (headers!.isEmpty) headers = null;
    }
    extra = map["extra"]?.toString();
  }

  static ClashYamlXHttpDownloadOptions? fromYamlStatic(YamlMap? map) {
    if (map == null) return null;
    final o = ClashYamlXHttpDownloadOptions();
    o.fromYaml(map);
    return o;
  }

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (mode != null && mode!.isNotEmpty) ret['mode'] = mode;
    if (path != null && path!.isNotEmpty) ret['path'] = path;
    if (host != null && host!.isNotEmpty) ret['host'] = host;
    if (headers != null && headers!.isNotEmpty) ret['headers'] = headers;
    if (extra != null && extra!.isNotEmpty) ret['extra'] = extra;
    return ret;
  }
}

/// Clash YAML `xhttp-opts` block (full).
class ClashYamlXHttpOptions {
  String? path;
  String? host;
  String? mode;
  Map<String, String>? headers;
  ClashYamlXHttpOptionsXmux? xmux;
  ClashYamlXHttpDownloadOptions? download;

  void fromYaml(YamlMap? map) {
    if (map == null) return;
    path = map["path"]?.toString();
    host = map["host"]?.toString();
    mode = map["mode"]?.toString();
    final h = map["headers"];
    if (h is YamlMap) {
      headers = {};
      h.forEach((k, v) {
        if (k != null && v != null) {
          headers![k.toString()] = v.toString();
        }
      });
      if (headers!.isEmpty) headers = null;
    }
    final x = map["xmux"];
    if (x is YamlMap) {
      xmux = ClashYamlXHttpOptionsXmux.fromYamlStatic(x);
    }
    final d = map["download-settings"] ?? map["download"];
    if (d is YamlMap) {
      download = ClashYamlXHttpDownloadOptions.fromYamlStatic(d);
    }
  }

  static ClashYamlXHttpOptions? fromYamlStatic(YamlMap? map) {
    if (map == null) return null;
    final o = ClashYamlXHttpOptions();
    o.fromYaml(map);
    return o;
  }

  bool get isEmpty =>
      (path == null || path!.isEmpty) &&
      (host == null || host!.isEmpty) &&
      (mode == null || mode!.isEmpty) &&
      (headers == null || headers!.isEmpty) &&
      (xmux == null || xmux!.isEmpty) &&
      download == null;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (path != null && path!.isNotEmpty) ret['path'] = path;
    if (host != null && host!.isNotEmpty) ret['host'] = host;
    if (mode != null && mode!.isNotEmpty) ret['mode'] = mode;
    if (headers != null && headers!.isNotEmpty) ret['headers'] = headers;
    if (xmux != null && !xmux!.isEmpty) ret['xmux'] = xmux!.toJson();
    if (download != null) ret['download'] = download!.toJson();
    return ret;
  }

  /// Build from a parsed V2Ray URL parameter set.
  static ClashYamlXHttpOptions fromUrlParams(V2RayXHttpUrlParams p) {
    final o = ClashYamlXHttpOptions();
    o.path = p.path;
    o.host = p.host;
    o.mode = p.mode;
    o.headers = p.headers;
    if (p.xmux != null) {
      o.xmux = ClashYamlXHttpOptionsXmux()
        ..max_concurrency = p.xmux!.maxConcurrency
        ..max_connections = p.xmux!.maxConnections
        ..c_max_reuse_times = p.xmux!.cMaxReuseTimes
        ..h_max_request_times = p.xmux!.hMaxRequestTimes
        ..h_max_reusable_secs = p.xmux!.hMaxReusableSecs
        ..h_keep_alive_period = p.xmux!.hKeepAlivePeriod;
    }
    if (p.extra != null) {
      // store the raw JSON map as a string in the `extra` field via a sub-dict
      o.download = ClashYamlXHttpDownloadOptions();
      // encode extra into download.extra for round-tripping
      try {
        o.download!.extra = jsonEncode(p.extra!.toJsonObject());
      } catch (_) {
        o.download!.extra = null;
      }
    }
    return o;
  }
}

// ============================================================================
// sing-box option classes
// ============================================================================

class SingboxJsonTransportXHttpBaseOptions {
  String? path;
  String? host;
  String? mode;
  Map<String, String>? headers;
  String? extra;
  // Padding / streaming options (all optional in the sing-box schema)
  // We include the most commonly-used subset; full schema has 30+ fields.
  String? x_padding_key;
  String? x_padding_header;
  String? x_padding_method;
  String? x_padding_placement;
  bool? x_padding_obfs_mode;
  // uplink
  String? uplink_http_method;
  String? uplink_data_placement;
  String? uplink_data_key;
  int? uplink_chunk_size;
  // session
  String? session_placement;
  String? session_key;
  // seq
  String? seq_placement;
  String? seq_key;
  // sc (stream control)
  int? sc_max_each_post_bytes;
  int? sc_min_posts_interval_ms;
  int? sc_max_buffered_posts;
  int? sc_stream_up_server_secs;
  // server
  int? server_max_header_bytes;
  // flags
  bool? no_grpc_header;
  bool? no_sse_header;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    void set(String k, dynamic v) {
      if (v != null) ret[k] = v;
    }

    set('path', path);
    set('host', host);
    set('mode', mode);
    if (headers != null && headers!.isNotEmpty) ret['headers'] = headers;
    set('extra', extra);
    set('x_padding_key', x_padding_key);
    set('x_padding_header', x_padding_header);
    set('x_padding_method', x_padding_method);
    set('x_padding_placement', x_padding_placement);
    set('x_padding_obfs_mode', x_padding_obfs_mode);
    set('uplink_http_method', uplink_http_method);
    set('uplink_data_placement', uplink_data_placement);
    set('uplink_data_key', uplink_data_key);
    set('uplink_chunk_size', uplink_chunk_size);
    set('session_placement', session_placement);
    set('session_key', session_key);
    set('seq_placement', seq_placement);
    set('seq_key', seq_key);
    set('sc_max_each_post_bytes', sc_max_each_post_bytes);
    set('sc_min_posts_interval_ms', sc_min_posts_interval_ms);
    set('sc_max_buffered_posts', sc_max_buffered_posts);
    set('sc_stream_up_server_secs', sc_stream_up_server_secs);
    set('server_max_header_bytes', server_max_header_bytes);
    set('no_grpc_header', no_grpc_header);
    set('no_sse_header', no_sse_header);
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    path = map["path"];
    host = map["host"];
    mode = map["mode"];
    final h = map["headers"];
    if (h is Map) {
      headers = {};
      h.forEach((k, v) {
        if (k != null && v != null) headers![k.toString()] = v.toString();
      });
      if (headers!.isEmpty) headers = null;
    }
    extra = map["extra"]?.toString();
    x_padding_key = map["x_padding_key"]?.toString();
    x_padding_header = map["x_padding_header"]?.toString();
    x_padding_method = map["x_padding_method"]?.toString();
    x_padding_placement = map["x_padding_placement"]?.toString();
    x_padding_obfs_mode = map["x_padding_obfs_mode"] as bool?;
    uplink_http_method = map["uplink_http_method"]?.toString();
    uplink_data_placement = map["uplink_data_placement"]?.toString();
    uplink_data_key = map["uplink_data_key"]?.toString();
    uplink_chunk_size = ConvertUtils.intParseDynamic(map["uplink_chunk_size"]);
    session_placement = map["session_placement"]?.toString();
    session_key = map["session_key"]?.toString();
    seq_placement = map["seq_placement"]?.toString();
    seq_key = map["seq_key"]?.toString();
    sc_max_each_post_bytes =
        ConvertUtils.intParseDynamic(map["sc_max_each_post_bytes"]);
    sc_min_posts_interval_ms =
        ConvertUtils.intParseDynamic(map["sc_min_posts_interval_ms"]);
    sc_max_buffered_posts =
        ConvertUtils.intParseDynamic(map["sc_max_buffered_posts"]);
    sc_stream_up_server_secs =
        ConvertUtils.intParseDynamic(map["sc_stream_up_server_secs"]);
    server_max_header_bytes =
        ConvertUtils.intParseDynamic(map["server_max_header_bytes"]);
    no_grpc_header = map["no_grpc_header"] as bool?;
    no_sse_header = map["no_sse_header"] as bool?;
  }

  static SingboxJsonTransportXHttpBaseOptions? fromJsonStatic(
      Map<String, dynamic>? map) {
    if (map == null) return null;
    final o = SingboxJsonTransportXHttpBaseOptions();
    o.fromJson(map);
    return o;
  }
}

class SingboxJsonTransportXHttpOptionsXmux {
  int? max_concurrency;
  int? max_connections;
  int? c_max_reuse_times;
  int? h_max_request_times;
  int? h_max_reusable_secs;
  int? h_keep_alive_period;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (max_concurrency != null) ret['max_concurrency'] = max_concurrency;
    if (max_connections != null) ret['max_connections'] = max_connections;
    if (c_max_reuse_times != null) ret['c_max_reuse_times'] = c_max_reuse_times;
    if (h_max_request_times != null) {
      ret['h_max_request_times'] = h_max_request_times;
    }
    if (h_max_reusable_secs != null) {
      ret['h_max_reusable_secs'] = h_max_reusable_secs;
    }
    if (h_keep_alive_period != null) {
      ret['h_keep_alive_period'] = h_keep_alive_period;
    }
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    max_concurrency = ConvertUtils.intParseDynamic(map["max_concurrency"]);
    max_connections = ConvertUtils.intParseDynamic(map["max_connections"]);
    c_max_reuse_times = ConvertUtils.intParseDynamic(map["c_max_reuse_times"]);
    h_max_request_times =
        ConvertUtils.intParseDynamic(map["h_max_request_times"]);
    h_max_reusable_secs =
        ConvertUtils.intParseDynamic(map["h_max_reusable_secs"]);
    h_keep_alive_period =
        ConvertUtils.intParseDynamic(map["h_keep_alive_period"]);
  }

  static SingboxJsonTransportXHttpOptionsXmux? fromJsonStatic(
      Map<String, dynamic>? map) {
    if (map == null) return null;
    final o = SingboxJsonTransportXHttpOptionsXmux();
    o.fromJson(map);
    return o;
  }

  bool get isEmpty =>
      max_concurrency == null &&
      max_connections == null &&
      c_max_reuse_times == null &&
      h_max_request_times == null &&
      h_max_reusable_secs == null &&
      h_keep_alive_period == null;
}

class SingboxJsonTransportXHttpDownloadOptions {
  String? download_url;
  String? download_detour;
  // The full download sub-config is itself a StreamConfig in Xray; we expose
  // the most useful subset for karing's UI.
  Map<String, dynamic>? raw;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    if (download_url != null && download_url!.isNotEmpty) {
      ret['download_url'] = download_url;
    }
    if (download_detour != null && download_detour!.isNotEmpty) {
      ret['download_detour'] = download_detour;
    }
    if (raw != null && raw!.isNotEmpty) {
      ret.addAll(raw!);
    }
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    download_url = map["download_url"]?.toString();
    download_detour = map["download_detour"]?.toString();
    // store the entire blob so we can roundtrip fields we don't model
    final copy = Map<String, dynamic>.from(map);
    copy.remove('download_url');
    copy.remove('download_detour');
    raw = copy.isEmpty ? null : copy;
  }

  static SingboxJsonTransportXHttpDownloadOptions? fromJsonStatic(
      Map<String, dynamic>? map) {
    if (map == null) return null;
    final o = SingboxJsonTransportXHttpDownloadOptions();
    o.fromJson(map);
    return o;
  }
}

/// Top-level xhttp transport options for sing-box.
class SingboxJsonTransportXHttpOptions {
  SingboxJsonTransportXHttpBaseOptions base =
      SingboxJsonTransportXHttpBaseOptions();
  SingboxJsonTransportXHttpOptionsXmux? xmux;
  SingboxJsonTransportXHttpDownloadOptions? download;

  Map<String, dynamic> toJson() {
    final ret = <String, dynamic>{};
    ret['type'] = 'xhttp';
    ret.addAll(base.toJson());
    if (xmux != null && !xmux!.isEmpty) ret['xmux'] = xmux!.toJson();
    if (download != null) ret['download'] = download!.toJson();
    return ret;
  }

  void fromJson(Map<String, dynamic>? map) {
    if (map == null) return;
    base.fromJson(map);
    xmux = SingboxJsonTransportXHttpOptionsXmux.fromJsonStatic(map["xmux"]);
    download = SingboxJsonTransportXHttpDownloadOptions.fromJsonStatic(
        map["download"]);
  }

  static SingboxJsonTransportXHttpOptions? fromJsonStatic(
      Map<String, dynamic>? map) {
    if (map == null) return null;
    final o = SingboxJsonTransportXHttpOptions();
    o.fromJson(map);
    return o;
  }
}

// ============================================================================
// Converters
// ============================================================================

/// Convert a ClashYamlXHttpOptions into the sing-box transport dict
/// (already wrapped in `{"type":"xhttp", ...}`).
Map<String, dynamic> clashXHttpToSingbox(ClashYamlXHttpOptions clash) {
  final out = <String, dynamic>{'type': 'xhttp'};
  if (clash.path != null && clash.path!.isNotEmpty) out['path'] = clash.path;
  if (clash.host != null && clash.host!.isNotEmpty) out['host'] = clash.host;
  if (clash.mode != null && clash.mode!.isNotEmpty) out['mode'] = clash.mode;
  if (clash.headers != null && clash.headers!.isNotEmpty) {
    out['headers'] = clash.headers;
  }
  if (clash.xmux != null && !clash.xmux!.isEmpty) {
    out['xmux'] = clash.xmux!.toJson();
  }
  if (clash.download != null) {
    out['download'] = clash.download!.toJson();
  }
  return out;
}

/// Inverse: parse a sing-box transport dict into a ClashYamlXHttpOptions.
ClashYamlXHttpOptions singboxXHttpToClash(Map<String, dynamic> map) {
  final o = ClashYamlXHttpOptions();
  o.path = map["path"]?.toString();
  o.host = map["host"]?.toString();
  o.mode = map["mode"]?.toString();
  final h = map["headers"];
  if (h is Map) {
    o.headers = {};
    h.forEach((k, v) {
      if (k != null && v != null) o.headers![k.toString()] = v.toString();
    });
    if (o.headers!.isEmpty) o.headers = null;
  }
  final x = map["xmux"];
  if (x is Map) {
    final m = Map<String, dynamic>.from(x);
    o.xmux = SingboxJsonTransportXHttpOptionsXmux()
      ..max_concurrency = ConvertUtils.intParseDynamic(m["max_concurrency"])
      ..max_connections = ConvertUtils.intParseDynamic(m["max_connections"])
      ..c_max_reuse_times =
          ConvertUtils.intParseDynamic(m["c_max_reuse_times"])
      ..h_max_request_times =
          ConvertUtils.intParseDynamic(m["h_max_request_times"])
      ..h_max_reusable_secs =
          ConvertUtils.intParseDynamic(m["h_max_reusable_secs"])
      ..h_keep_alive_period =
          ConvertUtils.intParseDynamic(m["h_keep_alive_period"]);
  }
  final d = map["download"];
  if (d is Map) {
    final dm = Map<String, dynamic>.from(d);
    o.download = ClashYamlXHttpDownloadOptions()
      ..mode = dm["mode"]?.toString()
      ..path = dm["path"]?.toString()
      ..host = dm["host"]?.toString()
      ..extra = dm["extra"]?.toString();
  }
  return o;
}

/// Convenience: detect whether a `type=` URL parameter refers to xhttp.
bool isXHttpNetwork(String? network) {
  if (network == null) return false;
  final n = network.toLowerCase();
  return n == 'xhttp' || n == 'splithttp';
}

/// Convenience: validate an xhttp mode value (auto / packet-up / stream-up /
/// stream-one). Returns null if valid, an error message otherwise.
String? validateXHttpMode(String? mode) {
  if (mode == null || mode.isEmpty) return null;
  switch (mode) {
    case 'auto':
    case 'packet-up':
    case 'stream-up':
    case 'stream-one':
      return null;
    default:
      return 'unsupported xhttp mode: $mode (allowed: auto, packet-up, '
          'stream-up, stream-one)';
  }
}

/// Validate that a xmux config doesn't simultaneously set max_concurrency and
/// max_connections — sing-box rejects this with "max_connections cannot be
/// specified together with max_concurrency".
Tuple2<bool, String?> validateXHttpXmux(ClashYamlXHttpOptionsXmux? xmux) {
  if (xmux == null) return const Tuple2(true, null);
  if (xmux.max_concurrency != null &&
      xmux.max_concurrency! > 0 &&
      xmux.max_connections != null &&
      xmux.max_connections! > 0) {
    return Tuple2(
        false,
        'xhttp xmux: max_connections cannot be specified together with '
            'max_concurrency');
  }
  return const Tuple2(true, null);
}
