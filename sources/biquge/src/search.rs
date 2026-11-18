use crate::{config, parser};
use aidoku::{
	Manga, MangaPageResult, Result, Viewer,
	alloc::{String, Vec, format, vec},
	error,
	imports::{
		html::{Document, Element},
		net::{HttpMethod, Request, Response},
	},
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchEndpoint {
	pub method: String,
	pub action: String,
	pub query_param: String,
	pub charset: String,
	#[serde(default)]
	pub extra_params: Vec<(String, String)>,
}

pub fn percent_encode_bytes(bytes: &[u8]) -> String {
	const HEX: &[u8; 16] = b"0123456789ABCDEF";
	let mut out = String::with_capacity(bytes.len() * 3);
	for &b in bytes {
		if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
			out.push(b as char);
		} else if b == b' ' {
			out.push('+');
		} else {
			out.push('%');
			out.push(HEX[(b >> 4) as usize] as char);
			out.push(HEX[(b & 0x0F) as usize] as char);
		}
	}
	out
}

pub fn encode_query(query: &str, charset: &str) -> String {
	let lower = charset.to_ascii_lowercase();
	if lower == "gbk" || lower == "gb2312" || lower == "gb18030" {
		let (encoded, _, _) = encoding_rs::GBK.encode(query);
		percent_encode_bytes(&encoded)
	} else {
		percent_encode_bytes(query.as_bytes())
	}
}

pub fn build_form_body(ep: &SearchEndpoint, query: &str, page: i32) -> String {
	let mut parts: Vec<String> = Vec::new();
	parts.push(format!(
		"{}={}",
		encode_query(&ep.query_param, &ep.charset),
		encode_query(query, &ep.charset)
	));
	for (k, v) in &ep.extra_params {
		if k != &ep.query_param {
			parts.push(format!(
				"{}={}",
				encode_query(k, &ep.charset),
				encode_query(v, &ep.charset)
			));
		}
	}
	if page > 1 {
		parts.push(format!("page={page}"));
	}
	parts.join("&")
}

fn effective_charset(hint: &str) -> String {
	let configured = config::configured_charset();
	if configured != "auto" {
		return configured;
	}
	let h = hint.to_ascii_lowercase();
	if h.contains("gbk") || h.contains("gb2312") || h.contains("gb18030") {
		String::from("gbk")
	} else {
		String::from("utf-8")
	}
}

fn detect_doc_charset(doc: &Document) -> String {
	if let Some(m) = doc.select_first("meta[charset]") {
		if let Some(cs) = m.attr("charset") {
			let l = cs.to_ascii_lowercase();
			if l.contains("gb") {
				return String::from("gbk");
			}
		}
	}
	if let Some(m) = doc.select_first("meta[http-equiv]") {
		if let Some(content) = m.attr("content") {
			let l = content.to_ascii_lowercase();
			if l.contains("gbk") || l.contains("gb2312") || l.contains("gb18030") {
				return String::from("gbk");
			}
		}
	}
	String::from("utf-8")
}

fn discover_search_endpoint(base: &str) -> Option<SearchEndpoint> {
	let home_url = format!("{base}/");
	let req = config::apply_headers(Request::get(&home_url).ok()?, &home_url);
	let resp = req.send().ok()?;
	let final_url = resp.get_url().unwrap_or_else(|| home_url.clone());
	let doc = resp.get_html().ok()?;
	let page_charset = detect_doc_charset(&doc);

	let forms = doc.select("form")?;
	let mut best: Option<(i32, SearchEndpoint)> = None;

	for form in forms {
		let action_raw = form.attr("abs:action")
			.filter(|s| !s.trim().is_empty())
			.or_else(|| form.attr("action"))
			.unwrap_or_default();
		let action = if action_raw.trim().is_empty() {
			final_url.clone()
		} else {
			config::resolve_href(base, &final_url, &action_raw)
		};
		if action.is_empty() {
			continue;
		}
		let method = form
			.attr("method")
			.map(|m| m.trim().to_ascii_uppercase())
			.filter(|m| m == "POST" || m == "GET")
			.unwrap_or_else(|| String::from("GET"));
		let form_charset = form
			.attr("accept-charset")
			.unwrap_or_else(|| page_charset.clone());

		let mut query_param = String::new();
		let mut extra_params: Vec<(String, String)> = Vec::new();
		if let Some(inputs) = form.select("input") {
			for inp in inputs {
				let name = inp.attr("name").unwrap_or_default();
				let name = name.trim();
				if name.is_empty() {
					continue;
				}
				let itype = inp
					.attr("type")
					.map(|t| t.trim().to_ascii_lowercase())
					.unwrap_or_else(|| String::from("text"));
				if itype == "hidden" {
					let val = inp.attr("value").unwrap_or_default();
					extra_params.push((String::from(name), val));
				} else if itype == "text" || itype == "search" {
					if query_param.is_empty() {
						query_param = String::from(name);
					}
				}
			}
		}
		if let Some(selects) = form.select("select") {
			for sel in selects {
				let name = sel.attr("name").unwrap_or_default();
				let name = name.trim();
				if name.is_empty() {
					continue;
				}
				let opt = sel
					.select_first("option[selected]")
					.or_else(|| sel.select_first("option"));
				if let Some(opt_el) = opt {
					let val = opt_el
						.attr("value")
						.or_else(|| opt_el.text())
						.unwrap_or_default();
					extra_params.push((String::from(name), val));
				}
			}
		}
		if query_param.is_empty() {
			continue;
		}

		let mut score = 1;
		let act_lower = action.to_ascii_lowercase();
		let qp_lower = query_param.to_ascii_lowercase();
		if act_lower.contains("search") || act_lower.contains("/s.php") {
			score += 10;
		}
		if matches!(
			qp_lower.as_str(),
			"searchkey" | "keyword" | "key" | "kw" | "wd" | "q" | "search"
		) {
			score += 5;
		}
		let ep = SearchEndpoint {
			method,
			action,
			query_param,
			charset: effective_charset(&form_charset),
			extra_params,
		};
		if best.as_ref().is_none_or(|(s, _)| score > *s) {
			best = Some((score, ep));
		}
	}

	best.map(|(_, ep)| ep)
}

fn send_search_endpoint(base: &str, ep: &SearchEndpoint, query: &str, page: i32) -> Result<Response> {
	let body_qs = build_form_body(ep, query, page);
	let referer = format!("{base}/");
	if ep.method.eq_ignore_ascii_case("POST") {
		let mut req = config::apply_headers(Request::post(&ep.action)?, &referer);
		req.set_header("Content-Type", "application/x-www-form-urlencoded");
		req.set_body(body_qs.into_bytes());
		Ok(req.send()?)
	} else {
		let sep = if ep.action.contains('?') { "&" } else { "?" };
		let url = format!("{}{}{}", ep.action, sep, body_qs);
		let req = config::apply_headers(Request::get(&url)?, &referer);
		Ok(req.send()?)
	}
}

fn parse_custom_rule(base: &str, rule: &str, query: &str, page: i32) -> (HttpMethod, String, Option<String>) {
	let page_str = format!("{page}");
	let cs = effective_charset("");
	let encoded_q = encode_query(query, &cs);

	if let Some(rest) = rule.strip_prefix("POST|").or_else(|| rule.strip_prefix("post|")) {
		let (path_tpl, body_tpl) = rest.split_once('|').unwrap_or((rest, ""));
		let url = config::make_full_url(base, &path_tpl.replace("{query}", &encoded_q).replace("{page}", &page_str));
		let body = body_tpl.replace("{query}", &encoded_q).replace("{page}", &page_str);
		return (HttpMethod::Post, url, Some(body));
	}
	let path_tpl = rule.strip_prefix("GET|").or_else(|| rule.strip_prefix("get|")).unwrap_or(rule);
	let mut url = config::make_full_url(base, &path_tpl.replace("{query}", &encoded_q).replace("{page}", &page_str));
	if page > 1 && !path_tpl.contains("{page}") {
		let sep = if url.contains('?') { "&" } else { "?" };
		url = format!("{url}{sep}page={page}");
	}
	(HttpMethod::Get, url, None)
}

pub fn parse_search_results(doc: &Document, base: &str, final_url: &str) -> MangaPageResult {
	// Handle 302 direct redirect to book detail page (very common in Jieqi CMS exact hits)
	if parser::is_book_detail_doc(doc) {
		let manga = parser::parse_manga_details_from_doc(doc, base, final_url, "");
		if !manga.key.is_empty() && !manga.title.is_empty() {
			return MangaPageResult {
				entries: vec![manga],
				has_next_page: false,
			};
		}
	}

	let mut entries: Vec<Manga> = Vec::new();
	let mut seen: Vec<String> = Vec::new();

	// 1. Standard Jieqi table.grid rows
	if let Some(rows) = doc.select("table.grid tr") {
		for row in rows {
			if row.select_first("th").is_some() {
				continue;
			}
			if let Some(m) = parse_grid_row(&row, base, final_url) {
				if !seen.iter().any(|k| k == &m.key) {
					seen.push(m.key.clone());
					entries.push(m);
				}
			}
		}
	}

	// 2. Common div/list search card templates (ShipSay, mobile Biquge, modern templates)
	if entries.is_empty() {
		let card_selectors = [
			".result-item",
			"li.hot_4_item",
			".hot_4_item",
			"div.col-md-6:has(dl)",
			".novelslist2 li",
			".novelslistss li",
			".bookbox",
			".sone",
			".search-list li",
			"#search-main li",
			".list-group-item",
			"dl:has(dt a)",
			"#nr",
		];
		for sel in card_selectors {
			if let Some(cards) = doc.select(sel) {
				for card in cards {
					if let Some(m) = parser::extract_card_manga(&card, base, final_url) {
						if !seen.iter().any(|k| k == &m.key) {
							seen.push(m.key.clone());
							entries.push(m);
						}
					}
				}
				if !entries.is_empty() {
					break;
				}
			}
		}
	}

	// 3. Broad fallback: extract candidate book links from main content container
	if entries.is_empty() {
		if let Some(links) = doc.select("#main a[href], .main a[href], #content a[href], #centerm a[href]") {
			for a in links {
				let abs = parser::element_href(&a, base, final_url);
				if abs.is_empty() || !parser::looks_like_book_href(&abs) {
					continue;
				}
				let title = a.text().unwrap_or_default();
				let title = parser::trim_cjk_space(&title);
				if title.is_empty() || title.contains("下一页") || title.contains("首页") {
					continue;
				}
				let key = config::normalize_key(&abs, base);
				if !key.is_empty() && !seen.iter().any(|k| k == &key) {
					seen.push(key.clone());
					entries.push(Manga {
						key,
						title: String::from(title),
						url: Some(abs),
						viewer: Viewer::LeftToRight,
						..Default::default()
					});
					if entries.len() >= 30 {
						break;
					}
				}
			}
		}
	}

	let has_next_page = !entries.is_empty() && parser::find_next_page_url(doc, base, final_url).is_some();
	MangaPageResult {
		entries,
		has_next_page,
	}
}

fn parse_grid_row(row: &Element, base: &str, page_url: &str) -> Option<Manga> {
	let tds = row.select("td")?;
	let first_td = tds.get(0)?;
	let link = first_td.select_first("a[href]")?;
	let abs = parser::element_href(&link, base, page_url);
	if abs.is_empty() {
		return None;
	}
	let key = config::normalize_key(&abs, base);
	let title = String::from(parser::trim_cjk_space(&link.text().unwrap_or_default()));
	if key.is_empty() || title.is_empty() {
		return None;
	}
	let author = tds
		.get(2)
		.and_then(|td| td.text())
		.map(|s| parser::clean_author(&s))
		.filter(|s| !s.is_empty());

	Some(Manga {
		key,
		title,
		authors: author.map(|a| vec![a]),
		url: Some(abs),
		viewer: Viewer::LeftToRight,
		..Default::default()
	})
}

fn fallback_endpoints(base: &str, cs_pref: &str) -> Vec<SearchEndpoint> {
	let cs = if cs_pref == "auto" { "utf-8" } else { cs_pref };
	let mut eps = vec![
		SearchEndpoint {
			method: String::from("POST"),
			action: format!("{base}/modules/article/search.php"),
			query_param: String::from("searchkey"),
			charset: String::from(cs),
			extra_params: vec![(String::from("searchtype"), String::from("articlename"))],
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/modules/article/search.php"),
			query_param: String::from("searchkey"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/search.php"),
			query_param: String::from("searchkey"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/search.php"),
			query_param: String::from("q"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/search"),
			query_param: String::from("keyword"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/s.php"),
			query_param: String::from("q"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/search/"),
			query_param: String::from("searchkey"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
		SearchEndpoint {
			method: String::from("GET"),
			action: format!("{base}/user/search.html"),
			query_param: String::from("q"),
			charset: String::from(cs),
			extra_params: Vec::new(),
		},
	];
	if cs_pref == "auto" {
		eps.push(SearchEndpoint {
			method: String::from("POST"),
			action: format!("{base}/modules/article/search.php"),
			query_param: String::from("searchkey"),
			charset: String::from("gbk"),
			extra_params: vec![(String::from("searchtype"), String::from("articlename"))],
		});
	}
	eps
}

pub fn search_manga(query: &str, page: i32) -> Result<MangaPageResult> {
	let base = config::base_url()?;
	let q = query.trim();
	if q.is_empty() {
		return parser::fetch_listing("hot");
	}

	if let Some(rule) = config::custom_search_rule() {
		let (method, url, body) = parse_custom_rule(&base, &rule, q, page);
		let mut req = config::apply_headers(Request::new(&url, method)?, &format!("{base}/"));
		if let Some(b) = body {
			req.set_header("Content-Type", "application/x-www-form-urlencoded");
			req.set_body(b.into_bytes());
		}
		let resp = req.send()?;
		let final_url = resp.get_url().unwrap_or(url);
		let doc = resp.get_html()?;
		return Ok(parse_search_results(&doc, &base, &final_url));
	}

	// 1. Try cached discovered endpoint
	if let Some(cached_json) = config::load_probe_cache(&base) {
		if let Ok(mut ep) = serde_json::from_str::<SearchEndpoint>(&cached_json) {
			let pref = config::configured_charset();
			if pref != "auto" {
				ep.charset = pref;
			}
			if let Ok(resp) = send_search_endpoint(&base, &ep, q, page) {
				if (200..400).contains(&resp.status_code()) {
					let final_url = resp.get_url().unwrap_or_else(|| ep.action.clone());
					if let Ok(doc) = resp.get_html() {
						let res = parse_search_results(&doc, &base, &final_url);
						if !res.entries.is_empty() {
							return Ok(res);
						}
					}
				}
			}
		}
	}

	// 2. Discover homepage <form>
	if let Some(ep) = discover_search_endpoint(&base) {
		if let Ok(resp) = send_search_endpoint(&base, &ep, q, page) {
			if (200..400).contains(&resp.status_code()) {
				let final_url = resp.get_url().unwrap_or_else(|| ep.action.clone());
				if let Ok(doc) = resp.get_html() {
					let res = parse_search_results(&doc, &base, &final_url);
					if let Ok(json) = serde_json::to_string(&ep) {
						config::save_probe_cache(&base, &json);
					}
					if !res.entries.is_empty() {
						return Ok(res);
					}
				}
			}
		}
	}

	// 3. Probe standard Jieqi / ShipSay endpoints
	let cs_pref = config::configured_charset();
	let mut first_ok: Option<MangaPageResult> = None;
	for ep in fallback_endpoints(&base, &cs_pref) {
		let Ok(resp) = send_search_endpoint(&base, &ep, q, page) else { continue };
		if !(200..400).contains(&resp.status_code()) {
			continue;
		}
		let final_url = resp.get_url().unwrap_or_else(|| ep.action.clone());
		let Ok(doc) = resp.get_html() else { continue };
		let res = parse_search_results(&doc, &base, &final_url);
		if !res.entries.is_empty() {
			if let Ok(json) = serde_json::to_string(&ep) {
				config::save_probe_cache(&base, &json);
			}
			return Ok(res);
		}
		if first_ok.is_none() {
			first_ok = Some(res);
		}
	}

	first_ok.ok_or_else(|| error!("搜索失败：未能探测到可用的搜索接口，请在设置中配置「自定义搜索规则」"))
}
