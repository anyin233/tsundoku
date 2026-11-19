use crate::{config, parser, search};
use aidoku::{
	Chapter, Manga, Result,
	alloc::{String, Vec, format},
	error,
};
use core::cell::RefCell;

struct WasmState<T>(RefCell<T>);

// WASM linear memory in wazero is single-threaded per runtime instance.
unsafe impl<T> Sync for WasmState<T> {}

struct FallbackSession {
	preferred_sibling: Option<String>,
	cross_toc_cache: Vec<(String, String, Option<Vec<(String, String)>>)>,
}

impl FallbackSession {
	const fn new() -> Self {
		Self {
			preferred_sibling: None,
			cross_toc_cache: Vec::new(),
		}
	}
}

static SESSION: WasmState<FallbackSession> = WasmState(RefCell::new(FallbackSession::new()));

pub fn reset_session_cache() {
	let mut s = SESSION.0.borrow_mut();
	s.preferred_sibling = None;
	s.cross_toc_cache.clear();
}

const BQG5200_CLUSTER: &[&str] = &[
	"https://www.bqg6.xyz",
	"https://www.bqg9.xyz",
	"http://www.b5200.net",
	"http://www.biquge5200.cc",
];

const BIQUGE123_CLUSTER: &[&str] = &[
	"https://www.biquge123.uk",
	"https://www.biquge7.xyz",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChapterTarget {
	pub base: String,
	pub start_url: String,
	pub root_key: String,
	pub is_desktop_sibling: bool,
}

fn is_bqg5200_host(host_lower: &str) -> bool {
	host_lower == "bqg6.xyz"
		|| host_lower.ends_with(".bqg6.xyz")
		|| host_lower == "bqg9.xyz"
		|| host_lower.ends_with(".bqg9.xyz")
		|| host_lower.contains("bqg5.xyz")
		|| host_lower.contains("bqg7.xyz")
		|| host_lower.contains("bqg8.xyz")
		|| host_lower.contains("b5200.net")
		|| host_lower.contains("biquge5200.")
}

fn is_biquge123_host(host_lower: &str) -> bool {
	host_lower == "biquge123.uk"
		|| host_lower.ends_with(".biquge123.uk")
		|| host_lower == "biquge7.xyz"
		|| host_lower.ends_with(".biquge7.xyz")
}

fn same_cluster_desktop_siblings(primary_base: &str) -> &'static [&'static str] {
	let host_lower = config::url_host(primary_base)
		.unwrap_or("")
		.to_ascii_lowercase();
	if is_bqg5200_host(&host_lower) {
		BQG5200_CLUSTER
	} else if is_biquge123_host(&host_lower) {
		BIQUGE123_CLUSTER
	} else {
		&[]
	}
}

/// Extracts `(book_id, chapter_id)` from Biquge5200-style keys such as
/// `/129_129484/170227086.html` or `/129484/170227086.html`.
pub fn extract_bqg_wap_ids(rel_key: &str) -> Option<(String, String)> {
	let path = rel_key.split(['?', '#']).next().unwrap_or(rel_key).trim();
	let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
	if segs.len() != 2 {
		return None;
	}
	let book_part = segs[0];
	let book_id = match book_part.rsplit_once('_') {
		Some((_, id)) => id,
		None => book_part,
	};
	if book_id.is_empty() || !book_id.chars().all(|c| c.is_ascii_digit()) {
		return None;
	}
	let ch_file = segs[1];
	let ch_id = ch_file
		.strip_suffix(".html")
		.or_else(|| ch_file.strip_suffix(".htm"))?;
	if ch_id.is_empty() || !ch_id.chars().all(|c| c.is_ascii_digit()) {
		return None;
	}
	Some((String::from(book_id), String::from(ch_id)))
}

fn push_unique_target(targets: &mut Vec<ChapterTarget>, cand: ChapterTarget) {
	if cand.start_url.is_empty() {
		return;
	}
	if !targets.iter().any(|t| t.start_url == cand.start_url) {
		targets.push(cand);
	}
}

fn build_desktop_target(base: &str, rel_key: &str, is_desktop_sibling: bool) -> ChapterTarget {
	ChapterTarget {
		base: String::from(base),
		start_url: config::make_full_url(base, rel_key),
		root_key: String::from(rel_key),
		is_desktop_sibling,
	}
}

pub fn sibling_chapter_targets(
	primary_base: &str,
	chapter: &Chapter,
	preferred_sibling: Option<&str>,
	fallback_enabled: bool,
	extra_mirrors: &[String],
) -> Vec<ChapterTarget> {
	let rel_key = config::normalize_key(&chapter.key, primary_base);
	let primary_url = if rel_key.starts_with('/') {
		config::make_full_url(primary_base, &rel_key)
	} else {
		chapter
			.url
			.as_deref()
			.filter(|s| !s.is_empty())
			.map(|u| config::make_full_url(primary_base, u))
			.unwrap_or_else(|| config::make_full_url(primary_base, &chapter.key))
	};
	let primary_target = ChapterTarget {
		base: String::from(primary_base),
		start_url: primary_url,
		root_key: rel_key.clone(),
		is_desktop_sibling: false,
	};

	let mut targets = Vec::new();
	if fallback_enabled && rel_key.starts_with('/') {
		if let Some(pref) = preferred_sibling {
			if !pref.eq_ignore_ascii_case(primary_base) {
				push_unique_target(&mut targets, build_desktop_target(pref, &rel_key, true));
			}
		}
	}
	push_unique_target(&mut targets, primary_target);

	if !fallback_enabled || !rel_key.starts_with('/') {
		return targets;
	}

	let siblings = same_cluster_desktop_siblings(primary_base);
	for &sib in siblings {
		if !sib.eq_ignore_ascii_case(primary_base) {
			push_unique_target(&mut targets, build_desktop_target(sib, &rel_key, true));
		}
	}

	for alt in extra_mirrors {
		if !alt.eq_ignore_ascii_case(primary_base) {
			let is_sib = siblings.iter().any(|s| s.eq_ignore_ascii_case(alt));
			push_unique_target(&mut targets, build_desktop_target(alt, &rel_key, is_sib));
		}
	}

	let host_lower = config::url_host(primary_base)
		.unwrap_or("")
		.to_ascii_lowercase();
	if is_bqg5200_host(&host_lower) {
		if let Some((book_id, ch_id)) = extract_bqg_wap_ids(&rel_key) {
			for wap_base in ["https://m.bqg6.xyz", "https://m.bqg9.xyz"] {
				let wap_key = format!("/wapbook-{book_id}-{ch_id}");
				let wap_url = format!("{wap_base}{wap_key}/");
				push_unique_target(
					&mut targets,
					ChapterTarget {
						base: String::from(wap_base),
						start_url: wap_url,
						root_key: wap_key,
						is_desktop_sibling: false,
					},
				);
			}
		}
	}

	targets
}

pub fn fetch_manga_update_with_fallback(
	manga: Manga,
	needs_details: bool,
	needs_chapters: bool,
) -> Result<Manga> {
	let primary_base = config::base_url()?;
	let rel_key = config::normalize_key(&manga.key, &primary_base);
	let fallback_enabled = config::mirror_fallback_enabled();

	let mut bases: Vec<String> = Vec::new();
	if fallback_enabled {
		let pref = SESSION.0.borrow().preferred_sibling.clone();
		if let Some(p) = pref {
			if !p.eq_ignore_ascii_case(&primary_base) {
				bases.push(p);
			}
		}
	}
	bases.push(primary_base.clone());

	if fallback_enabled && rel_key.starts_with('/') {
		for &sib in same_cluster_desktop_siblings(&primary_base) {
			if !bases.iter().any(|b| b.eq_ignore_ascii_case(sib)) {
				bases.push(String::from(sib));
			}
		}
		for alt in config::configured_fallback_mirrors() {
			if !bases.iter().any(|b| b.eq_ignore_ascii_case(&alt)) {
				bases.push(alt);
			}
		}
	}

	let mut last_err = None;
	for base in bases {
		let req_manga = Manga {
			key: rel_key.clone(),
			..manga.clone()
		};
		match parser::fetch_manga_update_on_base(&base, req_manga, needs_details, needs_chapters) {
			Ok(updated) => {
				if needs_chapters && updated.chapters.as_ref().is_none_or(|c| c.is_empty()) {
					last_err = Some(error!("目录章节列表为空 ({base})"));
					continue;
				}
				if !base.eq_ignore_ascii_case(&primary_base)
					&& same_cluster_desktop_siblings(&primary_base)
						.iter()
						.any(|s| s.eq_ignore_ascii_case(&base))
				{
					SESSION.0.borrow_mut().preferred_sibling = Some(base);
				}
				return Ok(updated);
			}
			Err(e) => {
				last_err = Some(e);
			}
		}
	}

	Err(last_err.unwrap_or_else(|| error!("获取目录失败")))
}

fn to_halfwidth_char(c: char) -> char {
	match c {
		'\u{3000}' => ' ',
		'\u{FF01}'..='\u{FF5E}' => char::from_u32((c as u32) - 0xFEE0).unwrap_or(c),
		_ => c,
	}
}

fn is_title_punct_or_space(c: char) -> bool {
	c.is_whitespace()
		|| matches!(
			c,
			'《' | '》'
				| '「' | '」'
				| '『' | '』'
				| '【' | '】'
				| '（' | '）'
				| '(' | ')'
				| '[' | ']'
				| '{' | '}'
				| '·' | '•'
				| ':' | '：'
				| '-' | '—' | '–'
				| '_' | ',' | '，'
				| '.' | '。'
				| '!' | '！'
				| '?' | '？'
				| '、' | '/' | '\\'
				| '"' | '\'' | '“' | '”' | '‘' | '’'
		)
}

pub fn normalize_title_token(raw: &str) -> String {
	let mut out = String::with_capacity(raw.len());
	for ch in raw.chars() {
		let hw = to_halfwidth_char(ch);
		if is_title_punct_or_space(hw) {
			continue;
		}
		if hw.is_ascii() {
			out.push(hw.to_ascii_lowercase());
		} else {
			out.push(hw);
		}
	}
	out
}

fn is_cn_numeral_or_digit(c: char) -> bool {
	c.is_ascii_digit()
		|| matches!(
			c,
			'零' | '〇' | '一' | '二' | '两' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '十' | '百' | '千' | '万'
		)
}

fn strip_leading_di_prefix(s: &str) -> &str {
	let mut rest = s;
	for _ in 0..2 {
		let Some(after_di) = rest.strip_prefix('第') else {
			break;
		};
		let mut num_end = 0usize;
		for (idx, ch) in after_di.char_indices() {
			if is_cn_numeral_or_digit(ch) {
				num_end = idx + ch.len_utf8();
			} else {
				break;
			}
		}
		if num_end == 0 {
			break;
		}
		let after_num = &after_di[num_end..];
		let mut unit_matched = None;
		for unit in ['章', '节', '回', '话', '卷', '集'] {
			if let Some(rem) = after_num.strip_prefix(unit) {
				unit_matched = Some(rem);
				break;
			}
		}
		match unit_matched {
			Some(rem) if !rem.is_empty() => rest = rem,
			_ => break,
		}
	}
	rest
}

pub fn core_chapter_title(raw: &str) -> String {
	let norm = normalize_title_token(raw);
	let stripped = strip_leading_di_prefix(&norm);
	if stripped.is_empty() {
		norm
	} else {
		String::from(stripped)
	}
}

fn bare_chapter_title(core: &str) -> &str {
	let trimmed = core.trim_start_matches(|c: char| c.is_ascii_digit());
	if trimmed.is_empty() { core } else { trimmed }
}

fn chapter_distance_score(toc_idx_1_based: usize, chapter: &Chapter) -> usize {
	match chapter.chapter_number {
		Some(n) if n > 0.0 => {
			let target = (n + 0.5) as usize;
			toc_idx_1_based.abs_diff(target)
		}
		_ => toc_idx_1_based,
	}
}

pub fn match_chapter_in_toc<'a>(
	toc: &'a [(String, String)],
	chapter: &Chapter,
) -> Option<&'a (String, String)> {
	let target_raw = chapter.title.as_deref().unwrap_or("");
	let target_norm = normalize_title_token(target_raw);
	let target_core = core_chapter_title(target_raw);
	if target_norm.is_empty() {
		return None;
	}

	let mut best_exact: Option<(usize, &'a (String, String))> = None;
	let mut best_core: Option<(usize, &'a (String, String))> = None;
	let mut bare_matches: Vec<(usize, &'a (String, String))> = Vec::new();
	let target_bare = bare_chapter_title(&target_core);
	let allow_bare = target_bare.chars().count() >= 4;

	for (i, item) in toc.iter().enumerate() {
		let dist = chapter_distance_score(i + 1, chapter);
		let cand_norm = normalize_title_token(&item.1);
		if cand_norm == target_norm {
			if best_exact.as_ref().is_none_or(|(bd, _)| dist < *bd) {
				best_exact = Some((dist, item));
			}
			continue;
		}
		let cand_core = core_chapter_title(&item.1);
		if target_core.chars().count() >= 2 && cand_core == target_core {
			if best_core.as_ref().is_none_or(|(bd, _)| dist < *bd) {
				best_core = Some((dist, item));
			}
			continue;
		}
		if allow_bare && bare_chapter_title(&cand_core) == target_bare {
			bare_matches.push((dist, item));
		}
	}

	if let Some((_, item)) = best_exact {
		return Some(item);
	}
	if let Some((_, item)) = best_core {
		return Some(item);
	}
	if bare_matches.len() == 1 {
		return Some(bare_matches[0].1);
	}
	if !bare_matches.is_empty() && chapter.chapter_number.is_some() {
		bare_matches.sort_by_key(|(dist, _)| *dist);
		return Some(bare_matches[0].1);
	}
	None
}

fn author_matches(expected: &[String], cand_authors: Option<&Vec<String>>) -> bool {
	let Some(cand_list) = cand_authors else {
		return false;
	};
	for exp in expected {
		let ne = normalize_title_token(exp);
		if ne.is_empty() {
			continue;
		}
		for ca in cand_list {
			let nc = normalize_title_token(ca);
			if !nc.is_empty() && (nc == ne || nc.contains(&ne) || ne.contains(&nc)) {
				return true;
			}
		}
	}
	false
}

fn pick_matching_book(entries: &[Manga], title: &str, authors: Option<&[String]>) -> Option<Manga> {
	let target_norm = normalize_title_token(title);
	if target_norm.is_empty() {
		return None;
	}
	let exp_authors = authors.unwrap_or(&[]);

	let mut first_exact: Option<&Manga> = None;
	for m in entries {
		if normalize_title_token(&m.title) == target_norm {
			if !exp_authors.is_empty() && author_matches(exp_authors, m.authors.as_ref()) {
				return Some(m.clone());
			}
			if first_exact.is_none() {
				first_exact = Some(m);
			}
		}
	}
	if let Some(m) = first_exact {
		return Some(m.clone());
	}

	let mut first_fuzzy: Option<&Manga> = None;
	for m in entries {
		let cand_norm = normalize_title_token(&m.title);
		let min_len = cand_norm.chars().count().min(target_norm.chars().count());
		if min_len >= 4 && (cand_norm.contains(&target_norm) || target_norm.contains(&cand_norm)) {
			if !exp_authors.is_empty() && author_matches(exp_authors, m.authors.as_ref()) {
				return Some(m.clone());
			}
			if first_fuzzy.is_none() {
				first_fuzzy = Some(m);
			}
		}
	}
	first_fuzzy.cloned()
}

fn get_cached_cross_toc(alt_base: &str, norm_book_title: &str) -> Option<Option<Vec<(String, String)>>> {
	let s = SESSION.0.borrow();
	for (b, t, toc_opt) in &s.cross_toc_cache {
		if b.eq_ignore_ascii_case(alt_base) && t == norm_book_title {
			return Some(toc_opt.clone());
		}
	}
	None
}

fn set_cached_cross_toc(alt_base: &str, norm_book_title: String, toc_opt: Option<Vec<(String, String)>>) {
	let mut s = SESSION.0.borrow_mut();
	for (b, t, slot) in &mut s.cross_toc_cache {
		if b.eq_ignore_ascii_case(alt_base) && *t == norm_book_title {
			*slot = toc_opt;
			return;
		}
	}
	s.cross_toc_cache.push((String::from(alt_base), norm_book_title, toc_opt));
}

fn load_cross_mirror_toc(alt_base: &str, manga: &Manga) -> Option<Vec<(String, String)>> {
	let book_title = manga.title.trim();
	let norm_book = normalize_title_token(book_title);
	if norm_book.is_empty() {
		return None;
	}
	if let Some(cached) = get_cached_cross_toc(alt_base, &norm_book) {
		return cached;
	}

	let Ok(sres) = search::search_manga_on_base(alt_base, book_title, 1) else {
		set_cached_cross_toc(alt_base, norm_book, None);
		return None;
	};
	let Some(matched_book) = pick_matching_book(&sres.entries, book_title, manga.authors.as_deref()) else {
		set_cached_cross_toc(alt_base, norm_book, None);
		return None;
	};
	let Ok(updated) = parser::fetch_manga_update_on_base(alt_base, matched_book, false, true) else {
		set_cached_cross_toc(alt_base, norm_book, None);
		return None;
	};
	let Some(mut chs) = updated.chapters else {
		set_cached_cross_toc(alt_base, norm_book, None);
		return None;
	};
	// fetch_manga_update_on_base returns newest-first; reverse to 1..N reading order.
	chs.reverse();
	let pairs: Vec<(String, String)> = chs
		.into_iter()
		.filter(|c| !c.key.is_empty())
		.map(|c| {
			let t = c.title.unwrap_or_default();
			(c.key, t)
		})
		.collect();
	let result = if pairs.is_empty() { None } else { Some(pairs) };
	set_cached_cross_toc(alt_base, norm_book, result.clone());
	result
}

fn cross_mirror_chapter_fallback(
	primary_base: &str,
	manga: &Manga,
	chapter: &Chapter,
) -> Option<String> {
	if manga.title.trim().is_empty() {
		return None;
	}
	let siblings = same_cluster_desktop_siblings(primary_base);
	let mut candidates: Vec<String> = Vec::new();
	for alt in config::configured_fallback_mirrors() {
		if !alt.eq_ignore_ascii_case(primary_base)
			&& !siblings.iter().any(|s| s.eq_ignore_ascii_case(&alt))
			&& !candidates.iter().any(|c| c.eq_ignore_ascii_case(&alt))
		{
			candidates.push(alt);
		}
	}
	for &builtin in config::BUILTIN_MIRRORS {
		if !builtin.eq_ignore_ascii_case(primary_base)
			&& !siblings.iter().any(|s| s.eq_ignore_ascii_case(builtin))
			&& !candidates.iter().any(|c| c.eq_ignore_ascii_case(builtin))
		{
			candidates.push(String::from(builtin));
		}
	}

	let ch_title = chapter.title.as_deref().unwrap_or("");
	for alt_base in candidates {
		let Some(toc) = load_cross_mirror_toc(&alt_base, manga) else {
			continue;
		};
		let Some((matched_key, matched_title)) = match_chapter_in_toc(&toc, chapter) else {
			continue;
		};
		let alt_url = config::make_full_url(&alt_base, matched_key);
		let root_key = config::normalize_key(matched_key, &alt_base);
		let effective_title = if ch_title.is_empty() { matched_title.as_str() } else { ch_title };
		if let Ok(text) = parser::fetch_chapter_text_from_url(&alt_base, &alt_url, &root_key, effective_title) {
			return Some(text);
		}
	}
	None
}

pub fn fetch_chapter_text_with_fallback(manga: &Manga, chapter: &Chapter) -> Result<String> {
	let primary_base = config::base_url()?;
	let fallback_enabled = config::mirror_fallback_enabled();
	let extra_mirrors = if fallback_enabled {
		config::configured_fallback_mirrors()
	} else {
		Vec::new()
	};
	let preferred_sibling = if fallback_enabled {
		SESSION.0.borrow().preferred_sibling.clone()
	} else {
		None
	};

	let targets = sibling_chapter_targets(
		&primary_base,
		chapter,
		preferred_sibling.as_deref(),
		fallback_enabled,
		&extra_mirrors,
	);
	let chapter_title = chapter.title.as_deref().unwrap_or("");
	let mut last_err = None;

	for target in &targets {
		match parser::fetch_chapter_text_from_url(
			&target.base,
			&target.start_url,
			&target.root_key,
			chapter_title,
		) {
			Ok(text) => {
				if target.is_desktop_sibling && !target.base.eq_ignore_ascii_case(&primary_base) {
					SESSION.0.borrow_mut().preferred_sibling = Some(target.base.clone());
				}
				return Ok(text);
			}
			Err(e) => {
				last_err = Some(e);
			}
		}
	}

	if fallback_enabled {
		if let Some(text) = cross_mirror_chapter_fallback(&primary_base, manga, chapter) {
			return Ok(text);
		}
	}

	Err(last_err.unwrap_or_else(|| error!("获取章节正文失败")))
}
