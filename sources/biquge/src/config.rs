use aidoku::{
	Result,
	alloc::{String, Vec, format},
	error,
	imports::{
		defaults::{DefaultValue, defaults_get, defaults_set},
		net::Request,
	},
};

pub const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

const MIRROR_URL_KEY: &str = "mirror_url";
pub const PRESET_MIRROR_KEY: &str = "preset_mirror";
pub const DEFAULT_PRESET_MIRROR: &str = "https://www.bqg9.xyz";
const MIRROR_FALLBACK_KEY: &str = "mirror_fallback";
const FALLBACK_MIRRORS_KEY: &str = "fallback_mirrors";
const CHARSET_KEY: &str = "charset";
const SEARCH_RULE_KEY: &str = "search_rule";
const PROBE_PREFIX: &str = "probe.v1.";

pub const BUILTIN_MIRRORS: &[&str] = &[
	"https://www.bqg6.xyz",
	"https://www.bqg9.xyz",
	"https://www.myxyjs.com",
	"https://www.biquge123.uk",
	"https://www.piaotia.com",
	"https://www.biqiuge8.net",
];

pub fn resolve_base_url(custom_raw: &str, preset_raw: Option<&str>) -> Result<String> {
	if let Some(u) = normalize_base_url(custom_raw) {
		return Ok(u);
	}
	let preset = preset_raw
		.map(str::trim)
		.filter(|s| !s.is_empty())
		.unwrap_or(DEFAULT_PRESET_MIRROR);
	if preset == "custom" {
		return Err(error!("请先在「书源设置」中填写自定义镜像站网址，或切换为内置书源"));
	}
	normalize_base_url(preset).ok_or_else(|| error!("无效的书源网址配置"))
}

pub fn base_url() -> Result<String> {
	let custom = defaults_get::<String>(MIRROR_URL_KEY)
		.filter(|s| !s.trim().is_empty())
		.or_else(|| defaults_get::<String>("baseURL"))
		.unwrap_or_default();
	let preset = defaults_get::<String>(PRESET_MIRROR_KEY);
	resolve_base_url(&custom, preset.as_deref())
}

pub fn normalize_base_url(raw: &str) -> Option<String> {
	let trimmed = raw.trim().trim_end_matches('/');
	if trimmed.is_empty() {
		return None;
	}
	let with_scheme = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
		String::from(trimmed)
	} else {
		format!("https://{trimmed}")
	};
	Some(String::from(with_scheme.trim_end_matches('/')))
}

pub fn configured_charset() -> String {
	defaults_get::<String>(CHARSET_KEY)
		.map(|s| String::from(s.trim()))
		.filter(|s| !s.is_empty())
		.unwrap_or_else(|| String::from("auto"))
}

pub fn custom_search_rule() -> Option<String> {
	defaults_get::<String>(SEARCH_RULE_KEY)
		.map(|s| String::from(s.trim()))
		.filter(|s| !s.is_empty())
}

pub fn mirror_fallback_enabled() -> bool {
	defaults_get::<bool>(MIRROR_FALLBACK_KEY).unwrap_or(true)
}

pub fn parse_fallback_mirrors(raw: &str) -> Vec<String> {
	let mut out = Vec::new();
	for part in raw.split([',', ';', ' ', '\t', '\n', '\r']) {
		if let Some(norm) = normalize_base_url(part) {
			if !out.iter().any(|u: &String| u.eq_ignore_ascii_case(&norm)) {
				out.push(norm);
			}
		}
	}
	out
}

pub fn configured_fallback_mirrors() -> Vec<String> {
	defaults_get::<String>(FALLBACK_MIRRORS_KEY)
		.map(|s| parse_fallback_mirrors(&s))
		.unwrap_or_default()
}

pub fn probe_cache_key(base: &str) -> String {
	format!("{PROBE_PREFIX}{base}")
}

pub fn load_probe_cache(base: &str) -> Option<String> {
	defaults_get::<String>(&probe_cache_key(base)).filter(|s| !s.trim().is_empty())
}

pub fn save_probe_cache(base: &str, json: &str) {
	defaults_set(&probe_cache_key(base), DefaultValue::String(String::from(json)));
}

pub fn clear_probe_cache() {
	if let Ok(base) = base_url() {
		defaults_set(&probe_cache_key(&base), DefaultValue::Null);
	}
}

pub fn apply_headers(mut req: Request, referer: &str) -> Request {
	req.set_header("User-Agent", USER_AGENT);
	req.set_header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
	req.set_header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
	if !referer.is_empty() {
		req.set_header("Referer", referer);
	}
	req
}

pub fn url_origin(url: &str) -> Option<&str> {
	let scheme_end = url.find("://")?;
	let rest = &url[scheme_end + 3..];
	match rest.find('/') {
		Some(idx) => Some(&url[..scheme_end + 3 + idx]),
		None => Some(url),
	}
}

pub fn url_host(url: &str) -> Option<&str> {
	let scheme_end = url.find("://")?;
	let rest = &url[scheme_end + 3..];
	let host_port = rest.split('/').next().unwrap_or(rest);
	Some(host_port)
}

/// Resolves `href` relative to `current_url` and `base`.
pub fn resolve_href(base: &str, current_url: &str, href: &str) -> String {
	let h = href.trim();
	if h.is_empty() || h.starts_with('#') || h.starts_with("javascript:") || h.starts_with("mailto:") {
		return String::new();
	}
	let h = h.split('#').next().unwrap_or(h).trim();
	if h.is_empty() {
		return String::new();
	}
	if h.starts_with("http://") || h.starts_with("https://") {
		return String::from(h);
	}
	let origin = url_origin(current_url).or_else(|| url_origin(base)).unwrap_or(base);
	if h.starts_with("//") {
		let scheme = if origin.starts_with("http://") { "http:" } else { "https:" };
		return format!("{scheme}{h}");
	}
	if h.starts_with('/') {
		return format!("{origin}{h}");
	}
	let cur_no_query = current_url.split(['?', '#']).next().unwrap_or(current_url);
	if h.starts_with('?') {
		return format!("{cur_no_query}{h}");
	}
	let base_dir = match cur_no_query.rfind('/') {
		Some(idx) if idx >= origin.len() => &cur_no_query[..=idx],
		_ => origin,
	};
	let joined = if base_dir.ends_with('/') {
		format!("{base_dir}{h}")
	} else {
		format!("{base_dir}/{h}")
	};
	normalize_dot_segments(&joined)
}

fn normalize_dot_segments(url: &str) -> String {
	let Some(origin) = url_origin(url) else {
		return String::from(url);
	};
	let rest = &url[origin.len()..];
	let (path, suffix) = match rest.find(['?', '#']) {
		Some(i) => (&rest[..i], &rest[i..]),
		None => (rest, ""),
	};
	let mut stack: Vec<&str> = Vec::new();
	let trailing_slash = path.ends_with('/');
	for seg in path.split('/') {
		match seg {
			"" | "." => {}
			".." => {
				stack.pop();
			}
			other => stack.push(other),
		}
	}
	let mut out = String::from(origin);
	out.push('/');
	out.push_str(&stack.join("/"));
	if trailing_slash && !stack.is_empty() {
		out.push('/');
	}
	out.push_str(suffix);
	out
}

/// Converts a URL or path on the configured mirror into a stable root-relative
/// key (`/12_12345/` or `/12_12345/67890.html`) so changing mirror domains
/// keeps bookmarks and downloaded EPUB chapter keys intact.
pub fn normalize_key(href_or_url: &str, base: &str) -> String {
	let trimmed = href_or_url.trim();
	if trimmed.is_empty() {
		return String::new();
	}
	let clean = trimmed.split('#').next().unwrap_or(trimmed).trim();
	if clean.starts_with("http://") || clean.starts_with("https://") {
		let target_host = url_host(clean).unwrap_or("");
		let base_host = url_host(base).unwrap_or("");
		if !target_host.is_empty() && (base_host.is_empty() || target_host.eq_ignore_ascii_case(base_host)) {
			if let Some(origin) = url_origin(clean) {
				let rel = &clean[origin.len()..];
				return if rel.is_empty() { String::from("/") } else { String::from(rel) };
			}
		}
		return String::from(clean);
	}
	if clean.starts_with('/') {
		String::from(clean)
	} else {
		format!("/{clean}")
	}
}

pub fn make_full_url(base: &str, key_or_url: &str) -> String {
	let s = key_or_url.trim();
	if s.starts_with("http://") || s.starts_with("https://") {
		return String::from(s);
	}
	let base = base.trim_end_matches('/');
	if s.starts_with('/') {
		format!("{base}{s}")
	} else {
		format!("{base}/{s}")
	}
}
