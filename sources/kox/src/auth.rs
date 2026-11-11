use aidoku::{
	Result,
	alloc::{String, Vec, format},
	error,
	imports::{
		defaults::{DefaultValue, defaults_get, defaults_set},
		net::{Request, Response},
	},
	serde::{Deserialize, Serialize},
};

pub const KOOBONE_URL: &str = "https://koobone.com";
const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

const LOGIN_USERNAME_KEY: &str = "login.username";
const LOGIN_PASSWORD_KEY: &str = "login.password";
const JUST_LOGGED_IN_KEY: &str = "auth.justLoggedIn";
const SESSION_COOKIE_KEY: &str = "auth.cookie";
const KOOB_UIN_KEY: &str = "koob.uin";
const KOOB_SKEY_KEY: &str = "koob.skey";
const KOOB_COOKIE_KEY: &str = "koob.cookie";
const USER_STATUS_JSON_KEY: &str = "auth.statusJson";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UserStatus {
	pub logged_in: bool,
	pub uin: String,
	pub nickname: String,
	pub email: String,
	pub level: i32,
	pub is_vip: bool,
	pub vip_expire: String,
	pub phone_verified: bool,
	pub quota_remaining_mb: f64,
	pub quota_free_total_mb: f64,
	pub quota_free_left_mb: f64,
	pub quota_vip_total_mb: f64,
	pub quota_vip_left_mb: f64,
	pub quota_extra_left_mb: f64,
	pub quota_today_used_mb: f64,
	pub quota_month_used_mb: f64,
	pub quota_reset_day: String,
	pub koobone_active: bool,
	pub koobone_vol_count: i64,
	pub koobone_quota_used_bytes: i64,
	pub koobone_quota_max_bytes: i64,
}

#[derive(Deserialize)]
struct LoginActResp {
	#[serde(default)]
	msgid: String,
}

#[derive(Deserialize)]
struct KoobLoginResp {
	#[serde(default)]
	uin: serde_json::Value,
	#[serde(default)]
	skey: Option<String>,
	#[serde(default)]
	msg: Option<String>,
}

#[derive(Deserialize)]
pub struct KoobUinfoResp {
	#[serde(default)]
	pub uin: i64,
	#[serde(default)]
	pub nick: String,
	#[serde(default)]
	pub uid: String,
	#[serde(default)]
	pub vip: i32,
	#[serde(default)]
	pub count_vol: i64,
	#[serde(default)]
	pub quota_used: i64,
	#[serde(default)]
	pub quota_max: i64,
}

pub fn base_url() -> String {
	let url = defaults_get::<String>("url")
		.filter(|s| !s.trim().is_empty())
		.unwrap_or_else(|| String::from("https://kzo.moe"));
	String::from(url.trim_end_matches('/'))
}

pub fn stored_cookie() -> Option<String> {
	defaults_get::<String>(SESSION_COOKIE_KEY).filter(|s| !s.trim().is_empty())
}

pub fn stored_credentials() -> Option<(String, String)> {
	let u = defaults_get::<String>(LOGIN_USERNAME_KEY).filter(|s| !s.trim().is_empty())?;
	let p = defaults_get::<String>(LOGIN_PASSWORD_KEY).filter(|s| !s.trim().is_empty())?;
	Some((u, p))
}

pub fn is_logged_in() -> bool {
	stored_cookie().is_some() || stored_credentials().is_some()
}

pub fn set_just_logged_in() {
	defaults_set(JUST_LOGGED_IN_KEY, DefaultValue::Bool(true));
}

pub fn clear_auth() {
	defaults_set(SESSION_COOKIE_KEY, DefaultValue::Null);
	defaults_set(KOOB_UIN_KEY, DefaultValue::Null);
	defaults_set(KOOB_SKEY_KEY, DefaultValue::Null);
	defaults_set(KOOB_COOKIE_KEY, DefaultValue::Null);
	defaults_set(USER_STATUS_JSON_KEY, DefaultValue::Null);
	defaults_set("status.account", DefaultValue::Null);
	defaults_set("status.level", DefaultValue::Null);
	defaults_set("status.quota_left", DefaultValue::Null);
	defaults_set("status.quota_used", DefaultValue::Null);
	defaults_set("status.koobone", DefaultValue::Null);
	defaults_set(JUST_LOGGED_IN_KEY, DefaultValue::Null);
}

pub fn handle_login_notification() {
	let just_in = defaults_get::<bool>(JUST_LOGGED_IN_KEY).unwrap_or(false);
	let has_user = defaults_get::<String>(LOGIN_USERNAME_KEY)
		.is_some_and(|u| !u.trim().is_empty());
	if just_in && has_user {
		defaults_set(JUST_LOGGED_IN_KEY, DefaultValue::Null);
	} else if !has_user {
		clear_auth();
	}
}

pub fn cached_status() -> Option<UserStatus> {
	let raw = defaults_get::<String>(USER_STATUS_JSON_KEY)?;
	serde_json::from_str::<UserStatus>(&raw).ok()
}

pub fn save_cached_status(st: &UserStatus) {
	if let Ok(raw) = serde_json::to_string(st) {
		defaults_set(USER_STATUS_JSON_KEY, DefaultValue::String(raw));
	}
}

pub fn apply_kox_headers(mut req: Request, referer_path: &str, api_header: Option<&str>) -> Request {
	let base = base_url();
	req.set_header("User-Agent", USER_AGENT);
	req.set_header("Referer", &format!("{base}{referer_path}"));
	if let Some(h) = api_header {
		req.set_header("X-KAPI-FROM", h);
		req.set_header("X-KM-FROM", "KMOE/3.0.0(WEB) GET /");
	}
	if let Some(cookie) = stored_cookie() {
		req.set_header("Cookie", &cookie);
	}
	req
}

fn merge_set_cookie_header(existing: Option<&str>, set_cookie_raw: Option<String>) -> Option<String> {
	let mut pairs: Vec<(String, String)> = Vec::new();
	if let Some(ex) = existing {
		for part in ex.split(';') {
			if let Some((k, v)) = part.trim().split_once('=') {
				let k = k.trim();
				let v = v.trim();
				if !k.is_empty() && !v.is_empty() && v != "deleted" {
					pairs.push((String::from(k), String::from(v)));
				}
			}
		}
	}
	if let Some(raw) = set_cookie_raw {
		// Go flattenHeader joins multiple Set-Cookie headers with ", ".
		// Split carefully: cookie attributes like `Expires=Wed, 11 Nov 2026 ...` contain `, ` followed by digits,
		// whereas a new cookie starts with `<NAME>=<VALUE>` before `;`.
		for chunk in split_set_cookie_headers(&raw) {
			let first = chunk.split(';').next().unwrap_or("").trim();
			if let Some((k, v)) = first.split_once('=') {
				let k = k.trim();
				let v = v.trim();
				if k.is_empty() {
					continue;
				}
				pairs.retain(|(ek, _)| ek != k);
				if !v.is_empty() && v != "deleted" {
					pairs.push((String::from(k), String::from(v)));
				}
			}
		}
	}
	if pairs.is_empty() {
		None
	} else {
		let joined = pairs
			.into_iter()
			.map(|(k, v)| format!("{k}={v}"))
			.collect::<Vec<_>>()
			.join("; ");
		Some(joined)
	}
}

fn split_set_cookie_headers(raw: &str) -> Vec<&str> {
	let bytes = raw.as_bytes();
	let mut out = Vec::new();
	let mut start = 0usize;
	let mut i = 0usize;
	while i + 1 < bytes.len() {
		if bytes[i] == b',' && bytes[i + 1] == b' ' {
			// Check if what follows `, ` looks like `CookieName=` before the next `;` or `,`
			let rest = &raw[i + 2..];
			let next_semi = rest.find(';').unwrap_or(rest.len());
			let token = &rest[..next_semi];
			if let Some((name, _)) = token.split_once('=') {
				let name = name.trim();
				if !name.is_empty()
					&& name
						.chars()
						.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
				{
					out.push(raw[start..i].trim());
					start = i + 2;
					i += 2;
					continue;
				}
			}
		}
		i += 1;
	}
	if start <= raw.len() {
		let tail = raw[start..].trim();
		if !tail.is_empty() {
			out.push(tail);
		}
	}
	out
}

fn capture_response_cookies(resp: &Response, key: &str) {
	let cur = defaults_get::<String>(key);
	let sc = resp
		.get_header("Set-Cookie")
		.or_else(|| resp.get_header("set-cookie"));
	if let Some(merged) = merge_set_cookie_header(cur.as_deref(), sc) {
		defaults_set(key, DefaultValue::String(merged));
	}
}

fn build_multipart_body(fields: &[(&str, &str)], boundary: &str) -> Vec<u8> {
	let mut buf = String::new();
	for (k, v) in fields {
		buf.push_str("--");
		buf.push_str(boundary);
		buf.push_str("\r\nContent-Disposition: form-data; name=\"");
		buf.push_str(k);
		buf.push_str("\"\r\n\r\n");
		buf.push_str(v);
		buf.push_str("\r\n");
	}
	buf.push_str("--");
	buf.push_str(boundary);
	buf.push_str("--\r\n");
	buf.into_bytes()
}

pub fn login_kox(username: &str, password: &str) -> Result<bool> {
	let base = base_url();
	// 1. Warm session cookie (VLIBSID) if needed
	if let Ok(init_req) = Request::get(format!("{base}/login.php")) {
		if let Ok(init_resp) = apply_kox_headers(init_req, "/", None).send() {
			capture_response_cookies(&init_resp, SESSION_COOKIE_KEY);
		}
	}

	// 2. POST /login_act.php
	let boundary = "----AidokuKoxFormBoundary7MA4YWxkTrZu0gW";
	let body = build_multipart_body(&[("email", username), ("passwd", password)], boundary);
	let mut req = Request::post(format!("{base}/login_act.php"))?;
	req = apply_kox_headers(req, "/login.php", None);
	req.set_header(
		"Content-Type",
		&format!("multipart/form-data; boundary={boundary}"),
	);
	req.set_header("X-KM-FROM", "KMOE/3.0.0 POST /login.php");
	req.set_body(body);

	let resp = req.send()?;
	capture_response_cookies(&resp, SESSION_COOKIE_KEY);
	let text = resp.get_string()?;
	let parsed: LoginActResp =
		serde_json::from_str(&text).map_err(|_| error!("登录响应解析失败"))?;
	if parsed.msgid != "m100" {
		return Ok(false);
	}

	// Persist credentials so session expiry can transparently re-authenticate
	defaults_set(
		LOGIN_USERNAME_KEY,
		DefaultValue::String(String::from(username)),
	);
	defaults_set(
		LOGIN_PASSWORD_KEY,
		DefaultValue::String(String::from(password)),
	);

	// 3. Also authenticate Koobone seamlessly with the same Kmoe account
	let _ = login_koobone(username, password);

	// 4. Refresh and cache user status immediately
	if let Ok(st) = fetch_user_status() {
		save_cached_status(&st);
	}

	Ok(true)
}

pub fn ensure_logged_in() -> Result<()> {
	if stored_cookie().is_some() {
		return Ok(());
	}
	if let Some((u, p)) = stored_credentials() {
		if login_kox(&u, &p).unwrap_or(false) {
			return Ok(());
		}
	}
	Err(error!("请先在 Kox 源设置中登录账号"))
}

pub fn try_relogin() -> bool {
	if let Some((u, p)) = stored_credentials() {
		login_kox(&u, &p).unwrap_or(false)
	} else {
		false
	}
}

pub fn login_koobone(username: &str, password: &str) -> Result<(String, String)> {
	if let Ok(init_req) = Request::get(format!("{KOOBONE_URL}/login.php?goto=web.htm")) {
		let mut r = init_req;
		r.set_header("User-Agent", USER_AGENT);
		if let Ok(resp) = r.send() {
			capture_response_cookies(&resp, KOOB_COOKIE_KEY);
		}
	}

	let boundary = "----AidokuKoobFormBoundary7MA4YWxkTrZu0gW";
	let body = build_multipart_body(
		&[("email", username), ("passwd", password), ("keepalive", "1")],
		boundary,
	);
	let mut req = Request::post(format!("{KOOBONE_URL}/login_do.php"))?;
	req.set_header("User-Agent", USER_AGENT);
	req.set_header("Referer", &format!("{KOOBONE_URL}/login.php?goto=web.htm"));
	req.set_header("X-KAPI-FROM", "KOOBONE(Html)/6.2.0 POST /login.php");
	req.set_header(
		"Content-Type",
		&format!("multipart/form-data; boundary={boundary}"),
	);
	if let Some(c) = defaults_get::<String>(KOOB_COOKIE_KEY).filter(|s| !s.is_empty()) {
		req.set_header("Cookie", &c);
	}
	req.set_body(body);

	let resp = req.send()?;
	capture_response_cookies(&resp, KOOB_COOKIE_KEY);
	let text = resp.get_string()?;
	let parsed: KoobLoginResp =
		serde_json::from_str(&text).map_err(|_| error!("Koobone 登录响应解析失败"))?;
	let uin_str = match &parsed.uin {
		serde_json::Value::Number(n) => format!("{n}"),
		serde_json::Value::String(s) => s.clone(),
		_ => String::new(),
	};
	let skey = parsed.skey.unwrap_or_default();
	if uin_str.is_empty() || uin_str == "0" {
		let msg = parsed.msg.unwrap_or_else(|| String::from("未知错误"));
		return Err(error!("Koobone 登录失败: {msg}"));
	}
	defaults_set(KOOB_UIN_KEY, DefaultValue::String(uin_str.clone()));
	defaults_set(KOOB_SKEY_KEY, DefaultValue::String(skey.clone()));
	Ok((uin_str, skey))
}

pub fn koobone_get_json<T: serde::de::DeserializeOwned>(path: &str) -> Result<T> {
	for attempt in 0..2 {
		let mut uin = defaults_get::<String>(KOOB_UIN_KEY).unwrap_or_default();
		let mut skey = defaults_get::<String>(KOOB_SKEY_KEY).unwrap_or_default();
		if (uin.is_empty() || skey.is_empty()) && attempt == 0 {
			if let Some((u, p)) = stored_credentials() {
				if let Ok((nu, ns)) = login_koobone(&u, &p) {
					uin = nu;
					skey = ns;
				}
			}
		}
		let url = if path.starts_with("http") {
			String::from(path)
		} else {
			let sep = if path.contains('?') { "&" } else { "?" };
			if path.contains("u=") || path.contains("uin=") || uin.is_empty() {
				format!("{KOOBONE_URL}{path}")
			} else {
				format!("{KOOBONE_URL}{path}{sep}u={uin}")
			}
		};
		let mut req = Request::get(&url)?;
		req.set_header("User-Agent", USER_AGENT);
		req.set_header("Referer", &format!("{KOOBONE_URL}/web.htm"));
		req.set_header("X-KAPI-FROM", "KOOBONE(Html)/6.2.0 Web(8) GET /web.htm");
		if !skey.is_empty() {
			req.set_header("X-KAPI-INFO", &skey);
		}
		if let Some(c) = defaults_get::<String>(KOOB_COOKIE_KEY).filter(|s| !s.is_empty()) {
			req.set_header("Cookie", &c);
		}
		let resp = req.send()?;
		capture_response_cookies(&resp, KOOB_COOKIE_KEY);
		let raw = resp.get_string()?;
		if let Ok(val) = serde_json::from_slice::<serde_json::Value>(raw.as_bytes()) {
			let resp_uin = val
				.get("uin")
				.and_then(|v| {
					v.as_i64()
						.or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
				})
				.unwrap_or(0);
			if resp_uin <= 0 && attempt == 0 {
				defaults_set(KOOB_UIN_KEY, DefaultValue::Null);
				defaults_set(KOOB_SKEY_KEY, DefaultValue::Null);
				if let Some((u, p)) = stored_credentials() {
					let _ = login_koobone(&u, &p);
					continue;
				}
			}
		}
		return serde_json::from_slice::<T>(raw.as_bytes())
			.map_err(|_| error!("Koobone 数据解析失败"));
	}
	Err(error!("Koobone 未登录或会话已过期"))
}

pub fn fetch_user_status() -> Result<UserStatus> {
	let base = base_url();
	let mut html = fetch_my_php(&base)?;
	if is_login_page(&html) && try_relogin() {
		html = fetch_my_php(&base)?;
	}
	if is_login_page(&html) {
		return Ok(UserStatus::default());
	}

	let mut st = parse_my_php(&html);

	// Enrich with Koobone uinfo if available
	if let Ok(kb) = koobone_get_json::<KoobUinfoResp>("/v1/uinfo?v=web&ver=8") {
		if kb.uin > 0 {
			st.koobone_active = true;
			st.koobone_vol_count = kb.count_vol;
			st.koobone_quota_used_bytes = kb.quota_used;
			st.koobone_quota_max_bytes = kb.quota_max;
			if st.email.is_empty() && !kb.uid.is_empty() {
				st.email = kb.uid;
			}
			if st.nickname.is_empty() && !kb.nick.is_empty() {
				st.nickname = kb.nick;
			}
		}
	}

	save_cached_status(&st);
	Ok(st)
}

fn fetch_my_php(base: &str) -> Result<String> {
	let req = apply_kox_headers(Request::get(format!("{base}/my.php"))?, "/", None);
	let resp = req.send()?;
	capture_response_cookies(&resp, SESSION_COOKIE_KEY);
	resp.get_string()
}

fn is_login_page(html: &str) -> bool {
	html.contains("action=\"/login_do.php\"") || html.contains("ipt_passwd")
}

pub fn decode_cf_email(hex: &str) -> Option<String> {
	let bytes = hex.trim().as_bytes();
	if bytes.len() < 4 || bytes.len() % 2 != 0 {
		return None;
	}
	let parse_byte = |idx: usize| -> Option<u8> {
		let s = core::str::from_utf8(&bytes[idx..idx + 2]).ok()?;
		u8::from_str_radix(s, 16).ok()
	};
	let key = parse_byte(0)?;
	let mut out = Vec::with_capacity((bytes.len() - 2) / 2);
	let mut i = 2;
	while i < bytes.len() {
		out.push(parse_byte(i)? ^ key);
		i += 2;
	}
	String::from_utf8(out).ok()
}

fn extract_between<'a>(haystack: &'a str, prefix: &str, suffix: &str) -> Option<&'a str> {
	let start = haystack.find(prefix)? + prefix.len();
	let rest = &haystack[start..];
	let end = rest.find(suffix)?;
	Some(&rest[..end])
}

fn parse_first_f64_after(haystack: &str, marker: &str) -> Option<f64> {
	let idx = haystack.find(marker)? + marker.len();
	let rest = haystack[idx..].replace("&nbsp;", " ");
	for tok in rest.split(|c: char| !(c.is_ascii_digit() || c == '.')) {
		if !tok.is_empty() {
			if let Ok(v) = tok.parse::<f64>() {
				return Some(v);
			}
		}
	}
	None
}

fn strip_tags(s: &str) -> String {
	let mut out = String::with_capacity(s.len());
	let mut in_tag = false;
	for ch in s.chars() {
		match ch {
			'<' => in_tag = true,
			'>' => in_tag = false,
			_ if !in_tag => out.push(ch),
			_ => {}
		}
	}
	out.replace("&nbsp;", " ").trim().into()
}

pub fn parse_my_php(html: &str) -> UserStatus {
	let mut st = UserStatus {
		logged_in: true,
		..Default::default()
	};

	if let Some(uid) = extract_between(html, "href=\"/u/", "/\"") {
		if uid.chars().all(|c| c.is_ascii_digit()) {
			st.uin = String::from(uid);
		}
	}
	if let Some(nick) = extract_between(html, "name=\"nickname\"", ">") {
		if let Some(val) = extract_between(nick, "value=\"", "\"") {
			st.nickname = String::from(val.trim());
		}
	}
	if let Some(cf) = extract_between(html, "data-cfemail=\"", "\"") {
		if let Some(email) = decode_cf_email(cf) {
			st.email = email;
		}
	}

	if let Some(lv_str) = extract_between(html, "var user_level = \"", "\"") {
		st.level = lv_str.trim().parse::<i32>().unwrap_or(0);
	}
	if st.level == 0 {
		if let Some(lv_cell) = extract_between(html, "Lv 等級：", "</tr>") {
			let plain = strip_tags(lv_cell);
			if let Some(rest) = plain.strip_prefix("Lv") {
				st.level = rest
					.chars()
					.take_while(|c| c.is_ascii_digit())
					.collect::<String>()
					.parse::<i32>()
					.unwrap_or(0);
			}
		}
	}

	if let Some(vip_str) = extract_between(html, "var is_vip     = \"", "\"")
		.or_else(|| extract_between(html, "var is_vip = \"", "\""))
	{
		st.is_vip = vip_str.trim().parse::<i32>().unwrap_or(0) >= 1;
	}

	st.phone_verified = html.contains(">已驗證<");

	if st.is_vip {
		if let Some(div_vip) = extract_between(html, "id=\"div_user_vip\"", "</div>") {
			if let Some(exp) = extract_between(div_vip, "VIP期限至 <b>", "</b>") {
				st.vip_expire = String::from(exp.trim());
			}
			st.quota_today_used_mb = parse_first_f64_after(div_vip, "今日已用 :").unwrap_or(0.0);
			let free_used = parse_first_f64_after(div_vip, "本月已用免費額度 :").unwrap_or(0.0);
			let vip_used = parse_first_f64_after(div_vip, "本月已經用VIP額度 :").unwrap_or(0.0);
			st.quota_month_used_mb = free_used + vip_used;

			if let Some(lv_line_idx) = div_vip.find(" 每月額度 :") {
				let tail = &div_vip[lv_line_idx..];
				st.quota_free_total_mb = parse_first_f64_after(tail, "每月額度 :").unwrap_or(0.0);
				st.quota_free_left_mb = parse_first_f64_after(tail, "剩餘 :").unwrap_or(0.0);
			}
			if let Some(vip_line_idx) = div_vip.find("VIP 每月額度 :") {
				let tail = &div_vip[vip_line_idx..];
				st.quota_vip_total_mb =
					parse_first_f64_after(tail, "VIP 每月額度 :").unwrap_or(0.0);
				st.quota_vip_left_mb = parse_first_f64_after(tail, "剩餘 :").unwrap_or(0.0);
			}
			st.quota_extra_left_mb =
				parse_first_f64_after(div_vip, "額外額度剩餘 :").unwrap_or(0.0);
			st.quota_remaining_mb =
				st.quota_free_left_mb + st.quota_vip_left_mb + st.quota_extra_left_mb;
			if let Some(day_raw) = extract_between(div_vip, "VIP 額度 :", "日") {
				let day = strip_tags(day_raw)
					.chars()
					.filter(|c| c.is_ascii_digit())
					.collect::<String>();
				if !day.is_empty() {
					st.quota_reset_day = format!("每月 {day} 日");
				}
			}
		}
	} else if let Some(div_nor) = extract_between(html, "id=\"div_user_nor\"", "</div>") {
		st.quota_today_used_mb = parse_first_f64_after(div_nor, "今日已用 :").unwrap_or(0.0);
		st.quota_month_used_mb = parse_first_f64_after(div_nor, "本月已用額度 :").unwrap_or(0.0);
		st.quota_free_total_mb = parse_first_f64_after(div_nor, "每月免費額度 :").unwrap_or(0.0);
		st.quota_free_left_mb = parse_first_f64_after(div_nor, "剩餘 :").unwrap_or(0.0);
		st.quota_extra_left_mb = parse_first_f64_after(div_nor, "額外額度剩餘 :").unwrap_or(0.0);
		st.quota_remaining_mb = st.quota_free_left_mb + st.quota_extra_left_mb;
		if let Some(day_raw) = extract_between(div_nor, "每月", "日") {
			let day = strip_tags(day_raw)
				.chars()
				.filter(|c| c.is_ascii_digit())
				.collect::<String>();
			if !day.is_empty() {
				st.quota_reset_day = format!("每月 {day} 日");
			}
		}
	}

	st
}

pub fn format_mb(mb: f64) -> String {
	if mb >= 1024.0 {
		let gb = mb / 1024.0;
		let tenths = ((gb * 10.0) + 0.5) as i64;
		format!("{}.{} GB ({} MB)", tenths / 10, tenths % 10, mb as i64)
	} else {
		let tenths = ((mb * 10.0) + 0.5) as i64;
		format!("{}.{} MB", tenths / 10, tenths % 10)
	}
}

pub fn format_bytes(bytes: i64) -> String {
	if bytes <= 0 {
		return String::from("0 MB");
	}
	let mb = (bytes as f64) / 1_048_576.0;
	if mb >= 1024.0 {
		let gb = mb / 1024.0;
		let tenths = ((gb * 10.0) + 0.5) as i64;
		format!("{}.{} GB", tenths / 10, tenths % 10)
	} else {
		let tenths = ((mb * 10.0) + 0.5) as i64;
		format!("{}.{} MB", tenths / 10, tenths % 10)
	}
}
