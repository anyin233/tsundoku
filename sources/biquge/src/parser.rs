use crate::config;
use aidoku::{
	Chapter, HashMap, Manga, MangaPageResult, MangaStatus, Result, Viewer,
	alloc::{String, Vec, format, vec},
	error,
	imports::{
		html::{Document, Element, ElementList},
		net::Request,
	},
};

const MAX_TOC_PAGES: usize = 50;
const MAX_CHAPTER_SUBPAGES: usize = 25;

pub fn trim_cjk_space(s: &str) -> &str {
	s.trim_matches(|c: char| c.is_whitespace() || c == '\u{3000}' || c == '\u{00a0}')
}

pub fn unescape_entities(input: &str) -> String {
	if !input.contains('&') {
		return String::from(input);
	}
	let mut out = String::with_capacity(input.len());
	let mut rest = input;
	while let Some(amp) = rest.find('&') {
		out.push_str(&rest[..amp]);
		let after_amp = &rest[amp..];
		if let Some(semi) = after_amp[1..].find(';').filter(|&i| i <= 12) {
			let entity = &after_amp[1..1 + semi];
			if let Some(decoded) = decode_entity(entity) {
				out.push_str(&decoded);
				rest = &after_amp[2 + semi..];
				continue;
			}
		}
		out.push('&');
		rest = &after_amp[1..];
	}
	out.push_str(rest);
	out
}

fn decode_entity(entity: &str) -> Option<String> {
	match entity {
		"nbsp" | "ensp" => return Some(String::from(" ")),
		"emsp" => return Some(String::from("\u{3000}")),
		"amp" => return Some(String::from("&")),
		"lt" => return Some(String::from("<")),
		"gt" => return Some(String::from(">")),
		"quot" => return Some(String::from("\"")),
		"apos" => return Some(String::from("'")),
		_ => {}
	}
	if let Some(hex) = entity.strip_prefix("#x").or_else(|| entity.strip_prefix("#X")) {
		if let Ok(code) = u32::from_str_radix(hex, 16) {
			if let Some(ch) = char::from_u32(code) {
				return Some(String::from(ch));
			}
		}
	} else if let Some(dec) = entity.strip_prefix('#') {
		if let Ok(code) = dec.parse::<u32>() {
			if let Some(ch) = char::from_u32(code) {
				return Some(String::from(ch));
			}
		}
	}
	None
}

pub fn is_ad_or_nav_line(line: &str) -> bool {
	let lower = line.to_ascii_lowercase();
	let ad_markers = [
		"一秒记住",
		"天才一秒记住",
		"请记住本书首发域名",
		"手机用户请浏览",
		"本章未完",
		"请点击下一页",
		"点击下一页继续阅读",
		"投推荐票",
		"加入书签",
		"加入书架",
		"章节错误,点此举报",
		"章节错误，点此举报",
		"最新网址：",
		"最新网址:",
		"记住网址",
		"笔趣阁手机版",
		"无弹窗小说网",
		"最快更新",
		"请收藏本站",
	];
	for m in ad_markers {
		if lower.contains(m) {
			return true;
		}
	}
	let trimmed = trim_cjk_space(line);
	if trimmed.starts_with("第(") && trimmed.ends_with(")页") {
		return true;
	}
	if matches!(
		trimmed,
		"上一章"
			| "下一章"
			| "上一页"
			| "下一页"
			| "返回目录"
			| "目录"
			| "书签"
			| "投推荐票"
			| "飘天文学"
			| "返回书页"
			| "加入书签"
			| "推荐本书"
			| "收藏本书"
			| "我的书架"
			| "书籍介绍"
			| "章节目录"
	) {
		return true;
	}
	// Short bracketed domain promotions like "(笔趣阁 www.xbiquge.la)"
	if line.chars().count() <= 60
		&& (lower.contains(".com")
			|| lower.contains(".net")
			|| lower.contains(".cc")
			|| lower.contains(".la")
			|| lower.contains(".org")
			|| lower.contains(".tw")
			|| lower.contains(".xyz")
			|| lower.contains(".vip")
			|| lower.contains("www."))
		&& (line.contains("笔趣") || line.contains("小说") || line.contains("更新") || line.contains("网址") || line.contains("阅读"))
	{
		return true;
	}
	false
}

fn is_break_open_tag(name: &[u8]) -> bool {
	name.eq_ignore_ascii_case(b"br")
		|| name.eq_ignore_ascii_case(b"p")
		|| name.eq_ignore_ascii_case(b"div")
		|| name.eq_ignore_ascii_case(b"li")
		|| name.eq_ignore_ascii_case(b"h1")
		|| name.eq_ignore_ascii_case(b"h2")
		|| name.eq_ignore_ascii_case(b"h3")
		|| name.eq_ignore_ascii_case(b"h4")
		|| name.eq_ignore_ascii_case(b"h5")
		|| name.eq_ignore_ascii_case(b"h6")
		|| name.eq_ignore_ascii_case(b"blockquote")
		|| name.eq_ignore_ascii_case(b"tr")
}

fn is_break_close_tag(name: &[u8]) -> bool {
	!name.eq_ignore_ascii_case(b"br") && is_break_open_tag(name)
}

/// Converts raw inner HTML from a Biquge chapter content container into
/// newline-separated clean paragraphs, stripping inline `<script>`/`<style>`
/// blocks, ad lines, and duplicate leading chapter headings.
pub fn clean_chapter_html(inner_html: &str, chapter_title: &str) -> String {
	let mut buf = String::with_capacity(inner_html.len());
	let bytes = inner_html.as_bytes();
	let mut i = 0usize;
	while i < bytes.len() {
		if bytes[i] == b'<' {
			if let Some(rel_end) = bytes[i..].iter().position(|&b| b == b'>') {
				let te = i + rel_end;
				let mut ts = i + 1;
				while ts < te && bytes[ts].is_ascii_whitespace() {
					ts += 1;
				}
				let is_closing = ts < te && bytes[ts] == b'/';
				let mut ns = if is_closing { ts + 1 } else { ts };
				if is_closing {
					while ns < te && bytes[ns].is_ascii_whitespace() {
						ns += 1;
					}
				}
				let mut ne = ns;
				while ne < te && !bytes[ne].is_ascii_whitespace() && bytes[ne] != b'/' {
					ne += 1;
				}
				let tag_name = &bytes[ns..ne];

				if !is_closing && (tag_name.eq_ignore_ascii_case(b"script") || tag_name.eq_ignore_ascii_case(b"style")) {
					let needle = if tag_name.eq_ignore_ascii_case(b"script") { "</script>" } else { "</style>" };
					let after_open = &inner_html[te + 1..];
					if let Some(close_pos) = find_ascii_ci(after_open, needle) {
						i = te + 1 + close_pos + needle.len();
						continue;
					}
				}

				let should_break = if is_closing {
					is_break_close_tag(tag_name)
				} else {
					is_break_open_tag(tag_name)
				};
				if should_break {
					buf.push('\n');
				}
				i = te + 1;
				continue;
			}
			buf.push('<');
			i += 1;
			continue;
		}
		let next_lt = bytes[i..].iter().position(|&b| b == b'<').map_or(bytes.len(), |off| i + off);
		buf.push_str(&inner_html[i..next_lt]);
		i = next_lt;
	}

	let decoded = unescape_entities(&buf);
	let clean_title = trim_cjk_space(chapter_title);
	let mut paragraphs: Vec<String> = Vec::new();
	let mut first = true;
	for raw_line in decoded.split('\n') {
		let line = trim_cjk_space(raw_line.trim_end_matches('\r'));
		if line.is_empty() || is_ad_or_nav_line(line) {
			continue;
		}
		if first {
			first = false;
			if !clean_title.is_empty() && line == clean_title {
				continue;
			}
		}
		paragraphs.push(String::from(line));
	}
	paragraphs.join("\n\n")
}

fn find_ascii_ci(haystack: &str, needle: &str) -> Option<usize> {
	let hb = haystack.as_bytes();
	let nb = needle.as_bytes();
	if nb.is_empty() || hb.len() < nb.len() {
		return None;
	}
	for i in 0..=hb.len() - nb.len() {
		if hb[i..i + nb.len()].eq_ignore_ascii_case(nb) {
			return Some(i);
		}
	}
	None
}

/// Deduplicates `(chapter_key, title)` entries while keeping ONLY each key's
/// **last** appearance, so top "最新章节" preview blocks never strand latest
/// chapters before Chapter 1.
pub fn dedup_toc_keep_last(items: Vec<(String, String)>) -> Vec<(String, String)> {
	let mut last_idx: HashMap<String, usize> = HashMap::with_capacity(items.len());
	for (i, (key, _)) in items.iter().enumerate() {
		if !key.is_empty() {
			last_idx.insert(key.clone(), i);
		}
	}
	let mut out = Vec::with_capacity(last_idx.len());
	for (i, item) in items.into_iter().enumerate() {
		if !item.0.is_empty() && last_idx.get(&item.0).copied() == Some(i) {
			out.push(item);
		}
	}
	out
}

pub fn is_toc_preview_dt(text: &str) -> bool {
	let t = trim_cjk_space(text);
	t.contains("最新") || t.contains("最近") || t.contains("更新")
}

pub fn looks_like_book_href(href: &str) -> bool {
	let lower = href.trim().to_ascii_lowercase();
	if lower.is_empty()
		|| lower == "/"
		|| lower.starts_with('#')
		|| lower.starts_with("javascript:")
		|| lower.starts_with("mailto:")
	{
		return false;
	}
	let path = lower.split(['?', '#']).next().unwrap_or(&lower);
	let excluded_prefixes = [
		"/search", "/s.php", "/login", "/register", "/logout", "/user", "/modules/article/search",
		"/modules/article/toplist", "/rank", "/top", "/sort", "/fenlei", "/wanben", "/full",
		"/over", "/history", "/bookcase", "/shujia", "/wap", "/help", "/about",
	];
	for ex in excluded_prefixes {
		if path == ex || path.starts_with(&format!("{ex}/")) || path.starts_with(&format!("{ex}.")) {
			return false;
		}
	}
	if path.ends_with(".css")
		|| path.ends_with(".js")
		|| path.ends_with(".png")
		|| path.ends_with(".jpg")
		|| path.ends_with(".jpeg")
		|| path.ends_with(".gif")
		|| path.ends_with(".ico")
	{
		return false;
	}
	// Strip scheme+host if present to inspect path segments
	let rel = if let Some(origin) = config::url_origin(path) {
		&path[origin.len()..]
	} else {
		path
	};
	let segs: Vec<&str> = rel.split('/').filter(|s| !s.is_empty()).collect();
	if segs.is_empty() {
		return false;
	}
	if segs[0].starts_with("list")
		|| segs[0].starts_with("booksort")
		|| segs[0].starts_with("class")
		|| segs[0].starts_with("sort")
		|| matches!(segs[0], "author" | "category" | "tag" | "top" | "full" | "rank")
	{
		return false;
	}
	// Reject deep chapter-looking links like /12_12345/67890.html when harvesting book links
	if segs.len() >= 2
		&& segs.last().is_some_and(|s| s.ends_with(".html") || s.ends_with(".htm"))
		&& segs[0].chars().any(|c| c.is_ascii_digit())
		&& !matches!(
			segs[0],
			"book" | "bookinfo" | "html" | "xiaoshuo" | "xs" | "shu" | "info" | "read" | "biquge"
		)
	{
		return false;
	}
	true
}

pub fn extract_subpage_stem(key: &str) -> Option<String> {
	let path = key.split(['?', '#']).next().unwrap_or(key).trim_end_matches('/');
	let stem = path
		.strip_suffix(".html")
		.or_else(|| path.strip_suffix(".htm"))
		.unwrap_or(path);
	// Strip existing `_2` or `/2` subpage suffix if present
	if let Some(pos) = stem.rfind('_') {
		let suffix = &stem[pos + 1..];
		if !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit()) {
			return Some(String::from(&stem[..pos]));
		}
	}
	Some(String::from(stem))
}

pub fn is_subpage_key(root_stem: &str, candidate_key: &str) -> bool {
	let path = candidate_key.split(['?', '#']).next().unwrap_or(candidate_key);
	let cand_stem = path
		.strip_suffix(".html")
		.or_else(|| path.strip_suffix(".htm"))
		.unwrap_or(path);
	if let Some(rest) = cand_stem.strip_prefix(root_stem) {
		if let Some(num) = rest.strip_prefix('_').or_else(|| rest.strip_prefix('/')) {
			return !num.is_empty() && num.chars().all(|c| c.is_ascii_digit());
		}
	}
	false
}

pub fn parse_status_text(s: &str) -> MangaStatus {
	if s.contains("完本") || s.contains("完结") || s.contains("已完成") || s.contains("已完结") {
		MangaStatus::Completed
	} else if s.contains("连载") || s.contains("更新") {
		MangaStatus::Ongoing
	} else if s.contains("暂停") || s.contains("断更") {
		MangaStatus::Hiatus
	} else {
		MangaStatus::Unknown
	}
}

pub fn clean_author(raw: &str) -> String {
	let t = trim_cjk_space(raw);
	let stripped = t
		.strip_prefix("作者：")
		.or_else(|| t.strip_prefix("作者:"))
		.or_else(|| t.strip_prefix("作　　者："))
		.or_else(|| t.strip_prefix("作　者："))
		.or_else(|| t.strip_prefix("Author:"))
		.unwrap_or(t);
	String::from(trim_cjk_space(stripped))
}

pub fn clean_desc(raw: &str) -> String {
	let t = trim_cjk_space(raw);
	let stripped = t
		.strip_prefix("简介：")
		.or_else(|| t.strip_prefix("简介:"))
		.or_else(|| t.strip_prefix("内容简介："))
		.unwrap_or(t);
	String::from(trim_cjk_space(stripped))
}

pub fn element_href(el: &Element, base: &str, page_url: &str) -> String {
	if let Some(raw) = el.attr("href") {
		let resolved = config::resolve_href(base, page_url, &raw);
		if !resolved.is_empty() {
			return resolved;
		}
	}
	if let Some(abs) = el.attr("abs:href").filter(|s| !s.trim().is_empty()) {
		return abs;
	}
	String::new()
}

pub fn element_src(el: &Element, base: &str, page_url: &str) -> Option<String> {
	let raw = el
		.attr("data-original")
		.filter(|s| !s.trim().is_empty())
		.or_else(|| el.attr("data-src").filter(|s| !s.trim().is_empty()))
		.or_else(|| el.attr("abs:src").filter(|s| !s.trim().is_empty()))
		.or_else(|| el.attr("src").filter(|s| !s.trim().is_empty()))?;
	let resolved = config::resolve_href(base, page_url, &raw);
	if resolved.is_empty() { None } else { Some(resolved) }
}

fn meta_content(doc: &Document, prop: &str) -> Option<String> {
	let sel = format!("meta[property='{prop}'], meta[name='{prop}']");
	doc.select_first(&sel)
		.and_then(|el| el.attr("content"))
		.map(|s| String::from(trim_cjk_space(&s)))
		.filter(|s| !s.is_empty())
}

pub fn is_book_detail_doc(doc: &Document) -> bool {
	if meta_content(doc, "og:novel:book_name").is_some() {
		return true;
	}
	if doc
		.select_first("h1.info_title, .book_list, #list-chapterAll, a[title*=点击阅读], a:contains(点击阅读)")
		.is_some()
	{
		return true;
	}
	let has_info = doc.select_first("#info h1, .book-info h1").is_some();
	let has_list = doc
		.select_first("#list dl, .listmain dl, #chapterlist, #ul_all_chapters, ul.chapter, div.list li")
		.is_some();
	has_info && has_list
}

pub fn parse_manga_details_from_doc(doc: &Document, base: &str, page_url: &str, key_hint: &str) -> Manga {
	let title = meta_content(doc, "og:novel:book_name")
		.or_else(|| meta_content(doc, "og:title"))
		.or_else(|| {
			doc.select_first("#info h1, h1.info_title, .book-info h1, .info h1, h1")
				.and_then(|el| el.text())
				.map(|s| String::from(trim_cjk_space(&s)))
				.filter(|s| !s.is_empty())
		})
		.unwrap_or_else(|| String::from(key_hint));

	let author = meta_content(doc, "og:novel:author")
		.or_else(|| {
			doc.select_first("#info p:contains(作者), div.info_ct div:contains(作者), .book-info :contains(作者), dd.book_other:contains(作者), .author, #info span:contains(作者), td:contains(作)")
				.and_then(|el| el.text())
				.map(|s| clean_author(&s))
				.filter(|s| !s.is_empty())
		})
		.unwrap_or_default();

	let cover = meta_content(doc, "og:image")
		.map(|u| config::resolve_href(base, page_url, &u))
		.filter(|s| !s.is_empty())
		.or_else(|| {
			doc.select_first("#fmimg img, div.info_lt img, .book-img img, .book_info img, .cover img, .imgbox img")
				.and_then(|el| element_src(&el, base, page_url))
		});

	let description = meta_content(doc, "og:description")
		.or_else(|| {
			doc.select_first("#intro, div.des, #intro_pc, .intro, .book-intro, #info .intro")
				.and_then(|el| el.text())
		})
		.map(|s| clean_desc(&s))
		.filter(|s| !s.is_empty());

	let status = meta_content(doc, "og:novel:status")
		.or_else(|| {
			doc.select_first("#info p:contains(状态), .book-info :contains(状态)")
				.and_then(|el| el.text())
		})
		.map(|s| parse_status_text(&s))
		.unwrap_or(MangaStatus::Unknown);

	let mut tags = Vec::new();
	if let Some(cat) = meta_content(doc, "og:novel:category") {
		if !cat.is_empty() {
			tags.push(cat);
		}
	}

	let canonical_url = meta_content(doc, "og:novel:read_url")
		.or_else(|| meta_content(doc, "og:url"))
		.map(|u| config::resolve_href(base, page_url, &u))
		.filter(|s| !s.is_empty())
		.unwrap_or_else(|| String::from(page_url));

	let key = if !key_hint.is_empty() {
		config::normalize_key(key_hint, base)
	} else {
		config::normalize_key(&canonical_url, base)
	};

	Manga {
		key,
		title,
		cover,
		authors: if author.is_empty() { None } else { Some(vec![author]) },
		description,
		url: Some(canonical_url),
		tags: if tags.is_empty() { None } else { Some(tags) },
		status,
		viewer: Viewer::LeftToRight,
		..Default::default()
	}
}

pub fn extract_toc_from_doc(doc: &Document, base: &str, page_url: &str) -> Vec<(String, String)> {
	// Prefer <dl> containers that often contain <dt>最新章节</dt> + <dt>正文</dt>
	let dl_selectors = ["#list dl", ".listmain dl", "#chapterlist dl", ".section-box dl", ".box_con #list dl"];
	for sel in dl_selectors {
		if let Some(dl) = doc.select_first(sel) {
			let extracted = extract_chapters_from_dl(&dl, base, page_url);
			if !extracted.is_empty() {
				return extracted;
			}
		}
	}

	// Sites like biqiuge8 render a "最新12章节" preview .book_list followed by
	// the main chapter .book_list; prefer the last container when multiple exist.
	if let Some(lists) = doc.select(".book_list") {
		let mut blocks: Vec<Element> = lists.collect();
		if blocks.len() >= 2 {
			if let Some(last_block) = blocks.pop() {
				if let Some(links) = last_block.select("a[href]") {
					let items = collect_toc_links(links, base, page_url);
					if !items.is_empty() {
						return dedup_toc_keep_last(items);
					}
				}
			}
		}
	}

	let list_selectors = [
		"#list a[href]",
		".listmain a[href]",
		"#chapterlist a[href]",
		"#list-chapterAll a[href]",
		"div.list li a[href]",
		".centent ul li a[href]",
		".book_list a[href]",
		".chapter-list a[href]",
		"#ul_all_chapters a[href]",
		"ul.chapter a[href]",
		".zjlist a[href]",
		".mulu a[href]",
		"#chapters-list a[href]",
	];
	for sel in list_selectors {
		if let Some(links) = doc.select(sel) {
			let items = collect_toc_links(links, base, page_url);
			if !items.is_empty() {
				return dedup_toc_keep_last(items);
			}
		}
	}
	Vec::new()
}

fn collect_toc_links<I: IntoIterator<Item = Element>>(links: I, base: &str, page_url: &str) -> Vec<(String, String)> {
	let mut items = Vec::new();
	for a in links {
		let title = a.text().unwrap_or_default();
		let title = trim_cjk_space(&title);
		let abs = element_href(&a, base, page_url);
		let key = config::normalize_key(&abs, base);
		if !title.is_empty() && !key.is_empty() && !title.contains("全部章节") && !title.contains("下一页") {
			items.push((key, String::from(title)));
		}
	}
	items
}

fn extract_chapters_from_dl(dl: &Element, base: &str, page_url: &str) -> Vec<(String, String)> {
	struct Section {
		dt_text: String,
		chapters: Vec<(String, String)>,
	}
	let mut sections: Vec<Section> = Vec::new();
	let mut cur = Section {
		dt_text: String::new(),
		chapters: Vec::new(),
	};

	// Query dt + dd links in one pass to avoid thousands of WASM-to-Go host calls on 2,000+ chapter TOCs.
	if let Some(nodes) = dl.select("dt, dd a[href]") {
		for node in nodes {
			let tag = node.tag_name().unwrap_or_default();
			if tag.eq_ignore_ascii_case("dt") {
				if !cur.chapters.is_empty() || !cur.dt_text.is_empty() {
					sections.push(cur);
				}
				cur = Section {
					dt_text: node.text().unwrap_or_default(),
					chapters: Vec::new(),
				};
			} else {
				let title = node.text().unwrap_or_default();
				let title = trim_cjk_space(&title);
				let abs = element_href(&node, base, page_url);
				let key = config::normalize_key(&abs, base);
				if !title.is_empty() && !key.is_empty() {
					cur.chapters.push((key, String::from(title)));
				}
			}
		}
	}
	if !cur.chapters.is_empty() || !cur.dt_text.is_empty() {
		sections.push(cur);
	}

	let non_empty: Vec<Section> = sections
		.into_iter()
		.filter(|s| !s.chapters.is_empty())
		.collect();
	if non_empty.is_empty() {
		// Fallback for <dl> lists that place <a> directly under <dl> without <dd>.
		if let Some(links) = dl.select("a[href]") {
			let mut items = Vec::new();
			for a in links {
				let title = a.text().unwrap_or_default();
				let title = trim_cjk_space(&title);
				let abs = element_href(&a, base, page_url);
				let key = config::normalize_key(&abs, base);
				if !title.is_empty() && !key.is_empty() {
					items.push((key, String::from(title)));
				}
			}
			return dedup_toc_keep_last(items);
		}
		return Vec::new();
	}

	let mut combined = Vec::new();
	let total_sections = non_empty.len();
	for (idx, sec) in non_empty.into_iter().enumerate() {
		let is_last = idx + 1 == total_sections;
		if total_sections >= 2 && !is_last && is_toc_preview_dt(&sec.dt_text) {
			continue;
		}
		combined.extend(sec.chapters);
	}
	dedup_toc_keep_last(combined)
}

fn find_full_toc_url(doc: &Document, base: &str, page_url: &str) -> Option<String> {
	let selectors = [
		"a[title*=点击阅读]",
		"a:contains(点击阅读)",
		"a:has(img[alt*=点击阅读])",
		"a:contains(全部章节)",
		"a:contains(查看完整目录)",
		"a:contains(章节目录)",
		"a:contains(完整目录)",
		"a:contains(更多章节)",
	];
	for sel in selectors {
		if let Some(a) = doc.select_first(sel) {
			let href = element_href(&a, base, page_url);
			if !href.is_empty() && href != page_url {
				return Some(href);
			}
		}
	}
	None
}

pub fn find_next_page_url(doc: &Document, base: &str, page_url: &str) -> Option<String> {
	let selectors = [
		"a:contains(下一页)",
		"a.next",
		".index-container-btn a:contains(下)",
		"li.page-item.active + li.page-item a.page-link[href]",
		".pagination li.active + li a[href]",
	];
	for sel in selectors {
		if let Some(a) = doc.select_first(sel) {
			let text = a.text().unwrap_or_default();
			if text.contains("下一章") {
				continue;
			}
			let href = element_href(&a, base, page_url);
			if !href.is_empty() && href != page_url {
				return Some(href);
			}
		}
	}
	None
}

pub fn fetch_manga_update(manga: Manga, needs_details: bool, needs_chapters: bool) -> Result<Manga> {
	let base = config::base_url()?;
	let book_url = config::make_full_url(&base, &manga.key);
	let req = config::apply_headers(Request::get(&book_url)?, &format!("{base}/"));
	let resp = req.send()?;
	let final_url = resp.get_url().unwrap_or_else(|| book_url.clone());
	let doc = resp.get_html()?;

	let mut out = if needs_details {
		parse_manga_details_from_doc(&doc, &base, &final_url, &manga.key)
	} else {
		manga
	};

	if needs_chapters {
		let mut toc_items = extract_toc_from_doc(&doc, &base, &final_url);
		let mut toc_doc_next = find_next_page_url(&doc, &base, &final_url);

		if (toc_items.is_empty() || toc_items.len() <= 20)
			&& let Some(full_toc_url) = find_full_toc_url(&doc, &base, &final_url)
		{
			if let Ok(req2) = Request::get(&full_toc_url) {
				if let Ok(resp2) = config::apply_headers(req2, &final_url).send() {
					let f2 = resp2.get_url().unwrap_or_else(|| full_toc_url.clone());
					if let Ok(doc2) = resp2.get_html() {
						let items2 = extract_toc_from_doc(&doc2, &base, &f2);
						if items2.len() >= toc_items.len() {
							toc_items = items2;
							toc_doc_next = find_next_page_url(&doc2, &base, &f2);
						}
					}
				}
			}
		}

		// Follow TOC pagination when present (e.g. mobile/ShipSay paginated TOC)
		let mut visited: Vec<String> = vec![final_url.clone()];
		let mut next_opt = toc_doc_next;
		while let Some(next_url) = next_opt {
			if visited.len() >= MAX_TOC_PAGES || visited.iter().any(|v| v == &next_url) {
				break;
			}
			visited.push(next_url.clone());
			let Ok(nreq) = Request::get(&next_url) else { break };
			let Ok(nresp) = config::apply_headers(nreq, &final_url).send() else { break };
			let nf = nresp.get_url().unwrap_or_else(|| next_url.clone());
			let Ok(ndoc) = nresp.get_html() else { break };
			let page_items = extract_toc_from_doc(&ndoc, &base, &nf);
			if page_items.is_empty() {
				break;
			}
			toc_items.extend(page_items);
			next_opt = find_next_page_url(&ndoc, &base, &nf);
		}

		let deduped = dedup_toc_keep_last(toc_items);
		let mut chapters: Vec<Chapter> = deduped
			.into_iter()
			.enumerate()
			.map(|(i, (key, title))| {
				let ch_url = config::make_full_url(&base, &key);
				Chapter {
					key,
					title: Some(title),
					// Monotonic 1..N in ascending TOC order so chapterorder.lua never
					// collapses distinct chapters as duplicate scanlations.
					chapter_number: Some((i + 1) as f32),
					url: Some(ch_url),
					language: Some(String::from("zh")),
					..Default::default()
				}
			})
			.collect();
		// Aidoku convention: newest chapter first.
		chapters.reverse();
		out.chapters = Some(chapters);
	}

	Ok(out)
}

fn match_subpage_next_in_links(
	links: ElementList,
	base: &str,
	current_url: &str,
	root_stem: Option<&str>,
	visited: &[String],
) -> (Option<String>, bool) {
	let mut saw_any = false;
	for a in links {
		saw_any = true;
		let text = a.text().unwrap_or_default();
		let trim_t = trim_cjk_space(&text);
		if trim_t.contains("上一") {
			continue;
		}
		let href = element_href(&a, base, current_url);
		if href.is_empty() || href == current_url || visited.iter().any(|u| u == &href) {
			continue;
		}
		// Check `_2.html` sub-page pattern before skipping `"下一章"` because
		// some mirrors label split chapter continuations as `"下一章"`.
		if let Some(stem) = root_stem {
			let cand_key = config::normalize_key(&href, base);
			if is_subpage_key(stem, &cand_key) {
				return (Some(href), true);
			}
		}
		if trim_t.contains("下一章") {
			continue;
		}
		if trim_t.contains("下一页") || trim_t.contains("下一节") || trim_t == "下页" {
			return (Some(href), true);
		}
	}
	(None, saw_any)
}

fn find_subpage_next_url(
	doc: &Document,
	base: &str,
	current_url: &str,
	root_stem: Option<&str>,
	visited: &[String],
) -> Option<String> {
	if let Some(links) = doc.select(
		".bottem a[href], .bottem1 a[href], .bottem2 a[href], .read-page a[href], .chapter-nav a[href], .nav-bottom a[href], #next1, .page_chapter a[href], .prenext a[href], #pager a[href], a[href]:contains(下一页), a[href]:contains(下一节), a[href]:contains(下页)",
	) {
		let (found, saw_targeted) =
			match_subpage_next_in_links(links, base, current_url, root_stem, visited);
		if found.is_some() || saw_targeted {
			return found;
		}
	}
	if let Some(links) = doc.select("a[href]") {
		return match_subpage_next_in_links(links, base, current_url, root_stem, visited).0;
	}
	None
}

fn extract_chapter_inner_html(doc: &Document) -> Option<String> {
	let selectors = [
		"#content",
		"#chaptercontent",
		"#booktxt",
		"#nr1",
		"#TextContent",
		"article.article",
		"article.font_max",
		".readcotent",
		".read-content",
		".txtnav",
		"#BookText",
		".showtxt",
		".content",
		"article",
	];
	for sel in selectors {
		if let Some(el) = doc.select_first(sel) {
			if let Some(noise) = el.select("script, style, ins, iframe, .ads, .ad, .txtinfo, .bottem, .bottem1, .bottem2, .read-page, .chapter-nav") {
				noise.remove();
			}
			if let Some(html) = el.html() {
				if !trim_cjk_space(&html).is_empty() {
					return Some(html);
				}
			}
		}
	}
	// Classic table/body templates (e.g. piaotia.com) place chapter prose
	// directly inside <body> without a dedicated #content wrapper.
	if doc.select_first("#guild, .toplink").is_some() {
		if let Some(body) = doc.select_first("body") {
			if let Some(noise) = body.select("header, nav, footer, script, style, table, h1, #guild, #shop, .toplink, .bottomlink, #Commenddiv, .feit2") {
				noise.remove();
			}
			if let Some(html) = body.html() {
				if !trim_cjk_space(&html).is_empty() {
					return Some(html);
				}
			}
		}
	}
	None
}

pub fn fetch_chapter_text(chapter: &Chapter) -> Result<String> {
	let base = config::base_url()?;
	let start_url = chapter
		.url
		.as_deref()
		.filter(|s| !s.is_empty())
		.map(|u| config::make_full_url(&base, u))
		.unwrap_or_else(|| config::make_full_url(&base, &chapter.key));
	let root_key = config::normalize_key(&chapter.key, &base);
	let root_stem = extract_subpage_stem(&root_key);
	let chapter_title = chapter.title.as_deref().unwrap_or("");

	let mut visited: Vec<String> = Vec::new();
	let mut parts: Vec<String> = Vec::new();
	let mut cur_url = start_url;
	let mut referer = format!("{base}/");

	for _ in 0..MAX_CHAPTER_SUBPAGES {
		if visited.iter().any(|u| u == &cur_url) {
			break;
		}
		visited.push(cur_url.clone());

		let req = config::apply_headers(Request::get(&cur_url)?, &referer);
		let resp = req.send()?;
		let final_url = resp.get_url().unwrap_or_else(|| cur_url.clone());
		if !visited.iter().any(|u| u == &final_url) {
			visited.push(final_url.clone());
		}
		let doc = resp.get_html()?;

		// Locate subpage pagination BEFORE extract_chapter_inner_html strips .bottem/.read-page/.chapter-nav nodes.
		let next_opt =
			find_subpage_next_url(&doc, &base, &final_url, root_stem.as_deref(), &visited);
		let inner_html = extract_chapter_inner_html(&doc)
			.ok_or_else(|| error!("未能在页面中定位到小说正文容器"))?;
		let cleaned = clean_chapter_html(&inner_html, chapter_title);
		if !cleaned.is_empty() {
			parts.push(cleaned);
		}

		match next_opt {
			Some(next) if !visited.iter().any(|u| u == &next) => {
				referer = final_url;
				cur_url = next;
			}
			_ => break,
		}
	}

	let full = parts.join("\n\n");
	if trim_cjk_space(&full).is_empty() {
		return Err(error!("章节正文为空"));
	}
	Ok(full)
}

pub fn fetch_listing(listing_id: &str) -> Result<MangaPageResult> {
	let base = config::base_url()?;
	let home_url = format!("{base}/");
	let req = config::apply_headers(Request::get(&home_url)?, &home_url);
	let resp = req.send()?;
	let final_url = resp.get_url().unwrap_or_else(|| home_url.clone());
	let doc = resp.get_html()?;

	let mut entries: Vec<Manga> = Vec::new();
	let mut seen: Vec<String> = Vec::new();

	let card_selectors: &[&str] = if listing_id == "recent" {
		&["#newscontent .l li", ".up li", "#newscontent li", ".novelslist .content li"]
	} else {
		&["#hotcontent .item", ".novelslist .top", ".hot .item", ".bookbox", ".item"]
	};

	for sel in card_selectors {
		if let Some(items) = doc.select(sel) {
			for item in items {
				if let Some(m) = extract_card_manga(&item, &base, &final_url) {
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

	if entries.is_empty() {
		if let Some(links) = doc.select("body a[href]") {
			for a in links {
				let abs = element_href(&a, &base, &final_url);
				let key = config::normalize_key(&abs, &base);
				let title = a.text().unwrap_or_default();
				let title = trim_cjk_space(&title);
				if !title.is_empty()
					&& !key.is_empty()
					&& looks_like_book_href(&abs)
					&& !seen.iter().any(|k| k == &key)
				{
					seen.push(key.clone());
					entries.push(Manga {
						key,
						title: String::from(title),
						url: Some(abs),
						viewer: Viewer::LeftToRight,
						..Default::default()
					});
					if entries.len() >= 40 {
						break;
					}
				}
			}
		}
	}

	Ok(MangaPageResult {
		entries,
		has_next_page: false,
	})
}

pub fn extract_card_manga(container: &Element, base: &str, page_url: &str) -> Option<Manga> {
	let link = container
		.select_first("h3 a[href], h4 a[href], .s2 a[href], .bookname a[href], dd a[href]:not(:has(img)), a[href][title], a[href]:not(:has(img))")
		.or_else(|| container.select_first("dt a[href], a[href]"))?;
	let abs = element_href(&link, base, page_url);
	if abs.is_empty() || !looks_like_book_href(&abs) {
		return None;
	}
	let key = config::normalize_key(&abs, base);
	if key.is_empty() {
		return None;
	}
	let title_raw = link
		.attr("title")
		.filter(|s| !trim_cjk_space(s).is_empty())
		.or_else(|| link.text().filter(|s| !trim_cjk_space(s).is_empty()))
		.or_else(|| {
			link.select_first("img[alt]")
				.and_then(|img| img.attr("alt"))
		})?;
	let title = String::from(trim_cjk_space(&title_raw));
	if title.is_empty() {
		return None;
	}

	let cover = container
		.select_first("img")
		.and_then(|img| element_src(&img, base, page_url));

	let author = container
		.select_first(".author, .s4, dt span, span.author, dd.book_other span, dd.book_other:contains(作者)")
		.and_then(|el| el.text())
		.map(|s| clean_author(&s))
		.filter(|s| !s.is_empty());

	let description = container
		.select_first(".hot_des, dd, .intro, .desc, p")
		.and_then(|el| el.text())
		.map(|s| clean_desc(&s))
		.filter(|s| !s.is_empty() && s != &title);

	Some(Manga {
		key,
		title,
		cover,
		authors: author.map(|a| vec![a]),
		description,
		url: Some(abs),
		viewer: Viewer::LeftToRight,
		..Default::default()
	})
}
