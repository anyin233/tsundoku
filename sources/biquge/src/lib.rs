#![cfg_attr(not(test), no_std)]

pub mod config;
pub mod parser;
pub mod search;

use aidoku::{
	Chapter, FilterValue, Listing, ListingProvider, Manga, MangaPageResult, NotificationHandler,
	Page, PageContent, Result, Source,
	alloc::{String, Vec, vec},
};
#[cfg(not(test))]
use aidoku::prelude::*;

struct BiqugeSource;

impl Source for BiqugeSource {
	fn new() -> Self {
		Self
	}

	fn get_search_manga_list(
		&self,
		query: Option<String>,
		page: i32,
		filters: Vec<FilterValue>,
	) -> Result<MangaPageResult> {
		let mut q = query.unwrap_or_default();
		if q.trim().is_empty() {
			for f in filters {
				if let FilterValue::Text { value, .. } = f {
					if !value.trim().is_empty() {
						q = value;
						break;
					}
				}
			}
		}
		search::search_manga(&q, page.max(1))
	}

	fn get_manga_update(
		&self,
		manga: Manga,
		needs_details: bool,
		needs_chapters: bool,
	) -> Result<Manga> {
		parser::fetch_manga_update(manga, needs_details, needs_chapters)
	}

	fn get_page_list(&self, _manga: Manga, chapter: Chapter) -> Result<Vec<Page>> {
		let text = parser::fetch_chapter_text(&chapter)?;
		Ok(vec![Page {
			content: PageContent::text(text),
			..Default::default()
		}])
	}
}

impl ListingProvider for BiqugeSource {
	fn get_manga_list(&self, listing: Listing, _page: i32) -> Result<MangaPageResult> {
		parser::fetch_listing(&listing.id)
	}
}

impl NotificationHandler for BiqugeSource {
	fn handle_notification(&self, notification: String) {
		match notification.as_str() {
			"reset_probe" | "mirror_url" | "charset" => config::clear_probe_cache(),
			_ => {}
		}
	}
}

#[cfg(not(test))]
register_source!(BiqugeSource, ListingProvider, NotificationHandler);

#[cfg(test)]
mod tests {
	use super::{config, parser, search};

	#[test]
	fn test_normalize_base_and_keys() {
		assert_eq!(
			config::normalize_base_url("www.xbiquge.tw/ "),
			Some("https://www.xbiquge.tw".into())
		);
		assert_eq!(config::normalize_base_url("   "), None);
		assert_eq!(
			config::normalize_key("https://www.xbiquge.tw/12_12345/67890.html", "https://www.xbiquge.tw"),
			"/12_12345/67890.html"
		);
		assert_eq!(
			config::resolve_href("https://m.bg.cc", "https://m.bg.cc/book/99/101.html", "101_2.html"),
			"https://m.bg.cc/book/99/101_2.html"
		);
	}

	#[test]
	fn test_clean_chapter_html_and_ads() {
		let html = r#"
			<div class="ads">一秒记住【笔趣阁 www.xbiquge.la】，精彩小说无弹窗免费阅读！</div>
			&nbsp;&nbsp;&nbsp;&nbsp;第一章 初入仙途<br /><br />
			&emsp;韩立推开木门，望着远山。<script>bad();</script><br>
			　　远处炊烟袅袅。<p>（本章未完，请点击下一页继续阅读）</p>
		"#;
		let cleaned = parser::clean_chapter_html(html, "第一章 初入仙途");
		assert_eq!(cleaned, "韩立推开木门，望着远山。\n\n远处炊烟袅袅。");

		let mixed_html = "<P>第一段\r\n</P><SCRIPT>skip()</SCRIPT><BR/>第二段\r\n";
		assert_eq!(parser::clean_chapter_html(mixed_html, ""), "第一段\n\n第二段");
	}

	#[test]
	fn test_dedup_toc_keep_last() {
		let input = vec![
			("/b/1/99.html".into(), "第99章".into()),
			("/b/1/100.html".into(), "第100章".into()),
			("/b/1/1.html".into(), "第1章".into()),
			("/b/1/99.html".into(), "第99章".into()),
			("/b/1/100.html".into(), "第100章".into()),
		];
		let out = parser::dedup_toc_keep_last(input);
		let keys: Vec<&str> = out.iter().map(|(k, _)| k.as_str()).collect();
		assert_eq!(keys, vec!["/b/1/1.html", "/b/1/99.html", "/b/1/100.html"]);
	}

	#[test]
	fn test_gbk_and_utf8_query_encoding() {
		assert_eq!(search::encode_query("斗破", "gbk"), "%B6%B7%C6%C6");
		assert_eq!(search::encode_query("斗破", "utf-8"), "%E6%96%97%E7%A0%B4");
	}

	#[test]
	fn test_subpage_detection() {
		let stem = parser::extract_subpage_stem("/book/1/101.html").unwrap();
		assert!(parser::is_subpage_key(&stem, "/book/1/101_2.html"));
		assert!(parser::is_subpage_key(&stem, "/book/1/101/2.html"));
		assert!(!parser::is_subpage_key(&stem, "/book/1/102.html"));
	}

	#[test]
	fn test_resolve_base_url_and_book_links() {
		assert_eq!(
			config::resolve_base_url("", None).unwrap(),
			config::DEFAULT_PRESET_MIRROR
		);
		assert_eq!(
			config::resolve_base_url("", Some("https://www.piaotia.com/")).unwrap(),
			"https://www.piaotia.com"
		);
		assert_eq!(
			config::resolve_base_url("custom.example.com/", Some("https://www.piaotia.com")).unwrap(),
			"https://custom.example.com"
		);
		assert!(config::resolve_base_url("   ", Some("custom")).is_err());

		assert!(parser::looks_like_book_href("https://www.piaotia.com/bookinfo/0/706.html"));
		assert!(parser::looks_like_book_href("/33/33999/"));
		assert!(!parser::looks_like_book_href("https://www.biqiuge8.net/list1/"));
		assert!(!parser::looks_like_book_href("/booksort1/0/1.html"));
	}
}
