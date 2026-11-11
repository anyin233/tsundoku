#![no_std]

pub mod auth;
pub mod epub;

use aidoku::{
	BasicLoginHandler, ButtonSetting, Chapter, ContentRating, DeepLinkHandler, DeepLinkResult,
	DynamicListings, DynamicSettings, FilterValue, GroupSetting, Home, HomeComponent,
	HomeComponentValue, HomeLayout, ImageRequestProvider, Listing, ListingKind, ListingProvider,
	Manga, MangaPageResult, MangaStatus, NotificationHandler, Page, PageContext, Result, Setting,
	Source, TextSetting, Viewer,
	alloc::{String, Vec, format, vec},
	error,
	helpers::uri::encode_uri_component,
	imports::{
		defaults::{DefaultValue, defaults_get, defaults_set},
		net::Request,
		std::{parse_date, send_partial_result},
	},
	prelude::*,
	serde::Deserialize,
};

const SORT_VALUES: [&str; 7] = [
	"sortpoint",
	"score",
	"count_push",
	"count_rise",
	"random",
	"newadd",
	"lastupdate",
];

struct KoxSource;

#[derive(Deserialize)]
struct DataListResp {
	#[serde(default)]
	totalpage: i32,
	#[serde(default)]
	nowpage: i32,
	#[serde(default)]
	data: Vec<DataListEntry>,
}

#[derive(Deserialize)]
struct DataListEntry {
	#[serde(default)]
	status: String,
	#[serde(default)]
	lang: String,
	#[serde(default)]
	url_book: String,
	#[serde(default)]
	url_cover: String,
	#[serde(default)]
	newvol: String,
	#[serde(default)]
	name: String,
	#[serde(default)]
	author: String,
}

#[derive(Deserialize)]
struct DataBookResp {
	#[serde(default)]
	voldata: Vec<Vec<String>>,
}

#[derive(Deserialize)]
struct KoobSeriesListResp {
	#[serde(default)]
	totalpage: i32,
	#[serde(default)]
	nowpage: i32,
	#[serde(default)]
	data: Vec<KoobSeriesEntry>,
}

#[derive(Deserialize)]
struct KoobSeriesEntry {
	#[serde(default)]
	seq: i64,
	#[serde(default)]
	series: String,
	#[serde(default)]
	seriesid: String,
	#[serde(default)]
	count_vol: i32,
	#[serde(default)]
	cover_url: String,
	#[serde(default)]
	series_url: String,
}

#[derive(Deserialize)]
struct KoobVolListResp {
	#[serde(default)]
	data: Vec<KoobVolEntry>,
}

#[derive(Deserialize)]
struct KoobVolEntry {
	#[serde(default)]
	file_md5: String,
	#[serde(default)]
	vol_name: String,
	#[serde(default)]
	vol_author: String,
	#[serde(default)]
	vol_series: String,
	#[serde(default)]
	vol_snumber: String,
	#[serde(default)]
	vol_language: String,
	#[serde(default)]
	time_add: String,
	#[serde(default)]
	cover_url: String,
	#[serde(default)]
	file_url: String,
}

impl KoxSource {
	fn clean_html_text(raw: &str) -> String {
		let mut out = String::with_capacity(raw.len());
		let mut in_tag = false;
		for ch in raw.chars() {
			match ch {
				'<' => in_tag = true,
				'>' => in_tag = false,
				_ if !in_tag => out.push(ch),
				_ => {}
			}
		}
		out.replace("&nbsp;", " ")
			.replace("&amp;", "&")
			.replace("&lt;", "<")
			.replace("&gt;", ">")
			.replace("&quot;", "\"")
			.replace("&#39;", "'")
			.replace("&apos;", "'")
			.trim()
			.into()
	}

	fn extract_manga_key(url_or_key: &str) -> String {
		let s = url_or_key.trim();
		if let Some(rest) = s.split("/c/").nth(1) {
			let key = rest.split('.').next().unwrap_or(rest).trim_matches('/');
			if !key.is_empty() {
				return String::from(key);
			}
		}
		String::from(s.trim_end_matches(".htm").trim_matches('/'))
	}

	fn parse_status(status: &str) -> MangaStatus {
		if status.contains("完結") || status.contains("完结") {
			MangaStatus::Completed
		} else if status.contains("停更") || status.contains("休刊") {
			MangaStatus::Hiatus
		} else if status.contains("連載") || status.contains("连载") {
			MangaStatus::Ongoing
		} else {
			MangaStatus::Unknown
		}
	}

	fn map_list_entry(item: DataListEntry) -> Option<Manga> {
		let key = Self::extract_manga_key(&item.url_book);
		if key.is_empty() {
			return None;
		}
		let title = Self::clean_html_text(&item.name);
		if title.is_empty() {
			return None;
		}
		let authors: Vec<String> = item
			.author
			.split(',')
			.map(str::trim)
			.filter(|s| !s.is_empty())
			.map(String::from)
			.collect();
		let mut tags = Vec::new();
		if !item.lang.trim().is_empty() {
			tags.push(String::from(item.lang.trim()));
		}
		if !item.newvol.trim().is_empty() {
			tags.push(String::from(item.newvol.trim()));
		}
		let base = auth::base_url();
		Some(Manga {
			key: key.clone(),
			title,
			cover: if item.url_cover.is_empty() {
				None
			} else {
				Some(item.url_cover)
			},
			authors: if authors.is_empty() {
				None
			} else {
				Some(authors)
			},
			tags: if tags.is_empty() { None } else { Some(tags) },
			url: Some(format!("{base}/c/{key}.htm")),
			status: Self::parse_status(&item.status),
			viewer: Viewer::RightToLeft,
			..Default::default()
		})
	}

	fn query_data_list(
		s_param: &str,
		status: &str,
		lang: &str,
		blen: &str,
		region: &str,
		order_by: &str,
		color: i32,
		hd: i32,
		page: i32,
	) -> Result<MangaPageResult> {
		let base = auth::base_url();
		let url = format!(
			"{base}/data_list.php?k=&s={}&end={}&lang={}&blen={}&regn={}&by={}&color={color}&hd={hd}&p={}",
			encode_uri_component(s_param),
			encode_uri_component(status),
			encode_uri_component(lang),
			encode_uri_component(blen),
			encode_uri_component(region),
			encode_uri_component(order_by),
			page.max(1),
		);
		let req = auth::apply_kox_headers(
			Request::get(&url)?,
			"/m/idx.php",
			Some("KJS/1.0.3 Brower(1) GET /m/idx.php"),
		);
		let resp: DataListResp = req.json_owned()?;
		let entries = resp
			.data
			.into_iter()
			.filter_map(Self::map_list_entry)
			.collect::<Vec<_>>();
		Ok(MangaPageResult {
			entries,
			has_next_page: resp.nowpage < resp.totalpage,
		})
	}

	fn extract_between<'a>(haystack: &'a str, prefix: &str, suffix: &str) -> Option<&'a str> {
		let start = haystack.find(prefix)? + prefix.len();
		let rest = &haystack[start..];
		let end = rest.find(suffix)?;
		Some(&rest[..end])
	}

	fn parse_js_var(html: &str, var_name: &str) -> Option<String> {
		let pat1 = format!("var {var_name}");
		let idx = html.find(&pat1)?;
		let rest = &html[idx + pat1.len()..];
		let eq = rest.find('=')?;
		let after_eq = &rest[eq + 1..];
		let semi = after_eq.find(';')?;
		let expr = after_eq[..semi].trim();
		if let Some(q1) = expr.find('"') {
			let inner = &expr[q1 + 1..];
			if let Some(q2) = inner.find('"') {
				return Some(String::from(&inner[..q2]));
			}
		}
		None
	}

	fn fetch_manga_html(key: &str) -> Result<String> {
		let base = auth::base_url();
		let url = format!("{base}/c/{key}.htm");
		let req = auth::apply_kox_headers(Request::get(&url)?, "/", None);
		req.string()
	}

	fn update_kox_manga(mut manga: Manga, needs_details: bool, needs_chapters: bool) -> Result<Manga> {
		let base = auth::base_url();
		let key = Self::extract_manga_key(&manga.key);
		manga.key = key.clone();

		if needs_chapters && !auth::is_logged_in() {
			return Err(error!("Kox.moe 查看章节与下载需先在源设置中登录账号"));
		}

		let mut html = Self::fetch_manga_html(&key)?;
		let mut uin = Self::parse_js_var(&html, "uin").unwrap_or_default();
		if (uin.is_empty() || uin == "0") && auth::try_relogin() {
			html = Self::fetch_manga_html(&key)?;
			uin = Self::parse_js_var(&html, "uin").unwrap_or_default();
		}

		let bookid = Self::parse_js_var(&html, "bookid").unwrap_or_else(|| key.clone());
		let is_vip = Self::parse_js_var(&html, "is_vip")
			.and_then(|s| s.parse::<i32>().ok())
			.unwrap_or(0)
			>= 1;

		if needs_details {
			manga.url = Some(format!("{base}/c/{key}.htm"));
			if let Some(title_raw) =
				Self::extract_between(&html, "<font class=\"text_bglight_big\">", "</font>")
			{
				let t = Self::clean_html_text(title_raw);
				if !t.is_empty() {
					manga.title = t;
				}
			}
			if let Some(cover) =
				Self::extract_between(&html, "<meta name=\"og:image\" content=\"", "\"")
			{
				if !cover.is_empty() {
					manga.cover = Some(String::from(cover));
				}
			}
			if let Some(kw) =
				Self::extract_between(&html, "<meta name=\"keywords\" content=\"", "\"")
			{
				let parts: Vec<&str> = kw.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
				if parts.len() > 1 {
					manga.authors = Some(parts[1..].iter().map(|s| String::from(*s)).collect());
				}
			}
			// Parse visible author links if present
			let mut authors = Vec::new();
			let mut search_rest = html.as_str();
			while let Some(pos) = search_rest.find("<font style=\"display:\"><a href=\"") {
				search_rest = &search_rest[pos..];
				if let Some(end_font) = search_rest.find("</font>") {
					let snippet = &search_rest[..end_font];
					if snippet.contains("list.php?s=") {
						let name = Self::clean_html_text(snippet);
						if !name.is_empty() && !authors.contains(&name) {
							authors.push(name);
						}
					}
					search_rest = &search_rest[end_font + 7..];
				} else {
					break;
				}
			}
			if !authors.is_empty() {
				manga.authors = Some(authors);
			}

			if let Some(desc_raw) = Self::extract_between(
				&html,
				"document.getElementById(\"div_desc_content\").innerHTML = \"",
				"\";",
			) {
				let unescaped = desc_raw
					.replace("\\\"", "\"")
					.replace("<br />", "\n")
					.replace("<br/>", "\n")
					.replace("<br>", "\n");
				let desc = Self::clean_html_text(&unescaped);
				if !desc.is_empty() {
					manga.description = Some(desc);
				}
			}

			let mut tags = Vec::new();
			if let Some(cat_block) = Self::extract_between(&html, "<!-- VOTE -->", "<div class=\"hr_10\">") {
				let mut cr = cat_block;
				while let Some(p) = cr.find("style=\"display:\">") {
					cr = &cr[p + 17..];
					if let Some(end) = cr.find("<font") {
						let tag = Self::clean_html_text(&cr[..end]);
						if !tag.is_empty() {
							tags.push(tag);
						}
					}
				}
			}
			if !tags.is_empty() {
				manga.tags = Some(tags);
			}

			if let Some(st_var) = Self::parse_js_var(&html, "bookstatus") {
				manga.status = Self::parse_status(&st_var);
			}
			let r18 = Self::parse_js_var(&html, "is_r18")
				.and_then(|s| s.parse::<i32>().ok())
				.unwrap_or(0);
			manga.content_rating = match r18 {
				2.. => ContentRating::NSFW,
				1 => ContentRating::Suggestive,
				_ => ContentRating::Safe,
			};
			manga.viewer = Viewer::RightToLeft;

			if needs_chapters {
				send_partial_result(&manga);
			}
		}

		if needs_chapters {
			if uin.is_empty() || uin == "0" {
				return Err(error!("登录状态已失效，请在源设置中重新登录 Kox.moe"));
			}
			let hash = Self::extract_between(&html, "Kmoe.book( \"", "\" )")
				.or_else(|| Self::extract_between(&html, "Kmoe.book(\"", "\")"))
				.ok_or_else(|| error!("未能提取章节数据签名 (Kmoe.book hash)"))?;

			let data_url = format!("{base}/data_book.php?h={hash}");
			let req = auth::apply_kox_headers(
				Request::get(&data_url)?,
				&format!("/c/{key}.htm"),
				Some(&format!("KJS/1.0.3 Brower(1) GET /c/{key}.htm")),
			);
			let book_resp: DataBookResp = req.json_owned()?;
			manga.chapters = Some(Self::parse_chapters(
				&bookid,
				&key,
				is_vip,
				book_resp.voldata,
			));
		}

		Ok(manga)
	}

	fn parse_chapters(
		bookid: &str,
		manga_key: &str,
		is_vip: bool,
		voldata: Vec<Vec<String>>,
	) -> Vec<Chapter> {
		let base = auth::base_url();
		let filter_mode = defaults_get::<String>("chapter_filter").unwrap_or_else(|| String::from("all"));

		let mut vols = Vec::new();
		let mut chs = Vec::new();
		let mut extras = Vec::new();

		for row in voldata {
			if row.len() < 12 {
				continue;
			}
			let vol_id = row[0].trim();
			let vol_type = row[3].trim();
			let seq_num = row[4].trim().parse::<f32>().ok();
			let vol_title = row[5].trim();
			let page_count = row[7].trim();
			let size_mb = row[11].trim();
			let pub_date = row.get(13).map(|s| s.trim()).unwrap_or("");
			let epub_build = row.get(15).map(|s| s.trim()).unwrap_or("");

			let date_str = if !pub_date.is_empty() {
				Some(pub_date)
			} else {
				epub_build.split_whitespace().next()
			};
			let date_uploaded = date_str.and_then(|d| parse_date(d, "yyyy-MM-dd"));

			let is_building = size_mb.parse::<f32>().unwrap_or(0.0) <= 0.0
				&& page_count.parse::<i32>().unwrap_or(0) <= 0;

			let display_title = if is_building {
				format!("{vol_title} [制作中]")
			} else if !size_mb.is_empty() && !page_count.is_empty() {
				format!("{vol_title} ({size_mb}M · {page_count}页)")
			} else {
				String::from(vol_title)
			};

			let is_tankobon = vol_type == "單行本" || vol_type == "单行本";
			let is_serial = vol_type == "話" || vol_type == "话";

			// Chapter number vs Volume number for canonical reading order
			let (volume_number, chapter_number) = if is_tankobon {
				(seq_num, seq_num)
			} else if is_serial {
				(None, seq_num.map(|n| 10000.0 + n))
			} else {
				(None, seq_num.map(|n| 20000.0 + n))
			};

			let vip_flag = if is_vip { "1" } else { "0" };
			let ch = Chapter {
				key: format!("{bookid}:{vol_id}:{vip_flag}"),
				title: Some(display_title),
				chapter_number,
				volume_number,
				date_uploaded,
				scanlators: Some(vec![String::from(vol_type)]),
				url: Some(format!("{base}/c/{manga_key}.htm")),
				language: Some(String::from("zh")),
				locked: is_building,
				..Default::default()
			};

			if is_tankobon {
				vols.push(ch);
			} else if is_serial {
				chs.push(ch);
			} else {
				extras.push(ch);
			}
		}

		let mut combined = match filter_mode.as_str() {
			"vol" if !vols.is_empty() => vols,
			"ch" if !chs.is_empty() => chs,
			_ => {
				let mut all = Vec::with_capacity(vols.len() + chs.len() + extras.len());
				all.extend(vols);
				all.extend(chs);
				all.extend(extras);
				all
			}
		};

		// Aidoku standard convention: newest chapter first in returned slice
		combined.reverse();
		combined
	}

	// ===== Koobone Listing & Series Integration inside Aidoku =====

	fn get_koobone_series_listing(page: i32) -> Result<MangaPageResult> {
		let resp: KoobSeriesListResp =
			auth::koobone_get_json(&format!("/v1/serieslist?p={}&limit=49", page.max(1)))?;
		let mut entries = Vec::new();
		for item in resp.data {
			let key = if !item.seriesid.is_empty() {
				format!("koob:sid:{}:{}", item.seriesid, item.series)
			} else {
				format!("koob:seq:{}:{}", item.seq, item.series)
			};
			entries.push(Manga {
				key,
				title: item.series,
				cover: if item.cover_url.is_empty() {
					None
				} else {
					Some(item.cover_url)
				},
				tags: Some(vec![format!("Koobone 书架 · 共 {} 本", item.count_vol)]),
				url: if item.series_url.is_empty() {
					Some(String::from(auth::KOOBONE_URL))
				} else {
					Some(item.series_url)
				},
				viewer: Viewer::RightToLeft,
				..Default::default()
			});
		}
		Ok(MangaPageResult {
			entries,
			has_next_page: resp.nowpage < resp.totalpage,
		})
	}

	fn update_koobone_manga(mut manga: Manga) -> Result<Manga> {
		// key format: koob:sid:<seriesid>:<series_name> or koob:seq:<seq>:<series_name>
		let rest = manga.key.strip_prefix("koob:").unwrap_or(&manga.key);
		let (kind, after_kind) = rest.split_once(':').unwrap_or(("sid", rest));
		let (id_part, series_name) = after_kind.split_once(':').unwrap_or((after_kind, ""));

		let query = if kind == "sid" && !id_part.is_empty() {
			format!(
				"/v1/vollist?sid={}&sna={}&p=1&limit=200",
				encode_uri_component(id_part),
				encode_uri_component(series_name)
			)
		} else {
			format!(
				"/v1/vollist?sna={}&p=1&limit=200",
				encode_uri_component(series_name)
			)
		};

		let resp: KoobVolListResp = auth::koobone_get_json(&query)?;
		let mut chapters = Vec::new();
		for (idx, v) in resp.data.into_iter().enumerate() {
			if !v.vol_series.is_empty() && manga.title.is_empty() {
				manga.title = v.vol_series.clone();
			}
			if manga.cover.is_none() && !v.cover_url.is_empty() {
				manga.cover = Some(v.cover_url.clone());
			}
			if manga.authors.is_none() && !v.vol_author.is_empty() {
				manga.authors = Some(
					v.vol_author
						.split(',')
						.map(str::trim)
						.filter(|s| !s.is_empty())
						.map(String::from)
						.collect(),
				);
			}
			let ch_title = if !v.vol_snumber.is_empty() {
				v.vol_snumber
			} else {
				v.vol_name
			};
			let date_uploaded = v
				.time_add
				.split_whitespace()
				.next()
				.and_then(|d| parse_date(d, "yyyy-MM-dd"));
			chapters.push(Chapter {
				key: format!("koobvol:{}:{}", v.file_md5, idx + 1),
				title: Some(ch_title),
				chapter_number: Some((idx + 1) as f32),
				date_uploaded,
				language: Some(if v.vol_language.is_empty() {
					String::from("zh")
				} else {
					v.vol_language
				}),
				..Default::default()
			});
		}
		manga.viewer = Viewer::RightToLeft;
		manga.chapters = Some(chapters);
		Ok(manga)
	}

	fn fetch_koobone_vol_pages(manga: &Manga, chapter_key: &str) -> Result<Vec<Page>> {
		let fmd = chapter_key
			.strip_prefix("koobvol:")
			.and_then(|r| r.split(':').next())
			.unwrap_or(chapter_key);

		// Query fresh signed file_url from Koobone vollist
		let rest = manga.key.strip_prefix("koob:").unwrap_or("");
		let (kind, after_kind) = rest.split_once(':').unwrap_or(("", ""));
		let (id_part, series_name) = after_kind.split_once(':').unwrap_or((after_kind, ""));

		let query = if kind == "sid" && !id_part.is_empty() {
			format!(
				"/v1/vollist?sid={}&sna={}&p=1&limit=200",
				encode_uri_component(id_part),
				encode_uri_component(series_name)
			)
		} else {
			String::from("/v1/vollist?p=1&limit=200")
		};
		let resp: KoobVolListResp = auth::koobone_get_json(&query)?;
		let vol = resp
			.data
			.into_iter()
			.find(|v| v.file_md5 == fmd)
			.ok_or_else(|| error!("Koobone 书架中未找到该卷 (md5={fmd})"))?;

		if vol.file_url.is_empty() {
			return Err(error!("Koobone 返回了空的 EPUB 下载地址"));
		}

		let mut req = Request::get(&vol.file_url)?;
		req.set_header(
			"X-KAPI-FROM",
			"KOOBONE(Html)/6.2.0 Web(8) FETCH /web.htm",
		);
		let epub_bytes = req
			.data()
			.map_err(|_| error!("下载 Koobone EPUB 文档失败"))?;
		epub::extract_epub_pages(&epub_bytes, &vol.file_url)
	}

	fn fetch_kox_chapter_pages(chapter_key: &str) -> Result<Vec<Page>> {
		auth::ensure_logged_in()?;
		let mut parts = chapter_key.split(':');
		let bookid = parts
			.next()
			.filter(|s| !s.is_empty())
			.ok_or_else(|| error!("无效的章节标识: {chapter_key}"))?;
		let volid = parts
			.next()
			.filter(|s| !s.is_empty())
			.ok_or_else(|| error!("无效的卷标识: {chapter_key}"))?;
		let is_vip = parts.next().unwrap_or("0") == "1";

		let pref_line = defaults_get::<String>("download_line").unwrap_or_else(|| String::from("0"));
		let line = if is_vip && pref_line == "1" { "1" } else { "0" };

		let base = auth::base_url();
		let api_url = format!("{base}/getdownurl.php?b={bookid}&v={volid}&mobi=2&vip={line}&json=1");

		let mut json_text = auth::apply_kox_headers(
			Request::get(&api_url)?,
			&format!("/c/{bookid}.htm"),
			Some(&format!("KJS/1.0.3 Brower(1) GET /c/{bookid}.htm")),
		)
		.string()?;

		if (json_text.contains("e401") || json_text.trim().is_empty()) && auth::try_relogin() {
			json_text = auth::apply_kox_headers(
				Request::get(&api_url)?,
				&format!("/c/{bookid}.htm"),
				Some(&format!("KJS/1.0.3 Brower(1) GET /c/{bookid}.htm")),
			)
			.string()?;
		}

		let down_url = epub::parse_down_url(&json_text)?;
		let mut dl_req = Request::get(&down_url)?;
		dl_req.set_header("Referer", &format!("{base}/"));
		dl_req.set_header("X-KAPI-FROM", "KJS/1.0.3 Brower(1) FETCH /");
		let epub_bytes = dl_req
			.data()
			.map_err(|_| error!("下载 Kox EPUB 文档失败（请检查网络或剩余配额）"))?;

		epub::extract_epub_pages(&epub_bytes, &down_url)
	}
}

impl Source for KoxSource {
	fn new() -> Self {
		Self
	}

	fn get_search_manga_list(
		&self,
		query: Option<String>,
		page: i32,
		filters: Vec<FilterValue>,
	) -> Result<MangaPageResult> {
		let mut s_param = query.unwrap_or_default();
		let mut order_by = "sortpoint";
		let mut status = String::new();
		let mut lang = String::new();
		let mut blen = String::new();
		let mut region = String::new();
		let mut color = 0;
		let mut hd = 0;

		for f in filters {
			match f {
				FilterValue::Sort { index, .. } => {
					if let Some(code) = SORT_VALUES.get(index as usize) {
						order_by = code;
					}
				}
				FilterValue::Text { id, value } => {
					if (id == "author" || id == "artist") && !value.trim().is_empty() {
						s_param = value;
					}
				}
				FilterValue::Select { id, value } => match id.as_str() {
					"genre" if s_param.trim().is_empty() && !value.is_empty() => {
						if value.starts_with("CAT*") {
							s_param = value;
						} else {
							s_param = format!("CAT*{value}");
						}
					}
					"lang" => lang = value,
					"region" => region = value,
					"blen" => blen = value,
					"status" => status = value,
					_ => {}
				},
				FilterValue::Check { id, value } => match id.as_str() {
					"color" if value > 0 => color = 1,
					"hd" if value > 0 => hd = 1,
					_ => {}
				},
				_ => {}
			}
		}

		Self::query_data_list(
			s_param.trim(),
			&status,
			&lang,
			&blen,
			&region,
			order_by,
			color,
			hd,
			page,
		)
	}

	fn get_manga_update(
		&self,
		manga: Manga,
		needs_details: bool,
		needs_chapters: bool,
	) -> Result<Manga> {
		if manga.key.starts_with("koob:") {
			return Self::update_koobone_manga(manga);
		}
		Self::update_kox_manga(manga, needs_details, needs_chapters)
	}

	fn get_page_list(&self, manga: Manga, chapter: Chapter) -> Result<Vec<Page>> {
		if chapter.key.starts_with("koobvol:") || manga.key.starts_with("koob:") {
			return Self::fetch_koobone_vol_pages(&manga, &chapter.key);
		}
		Self::fetch_kox_chapter_pages(&chapter.key)
	}
}

impl Home for KoxSource {
	fn get_home(&self) -> Result<HomeLayout> {
		let popular = Self::query_data_list("", "", "", "", "", "sortpoint", 0, 0, 1)?.entries;
		let updated = Self::query_data_list("", "", "", "", "", "lastupdate", 0, 0, 1)?.entries;
		let rising = Self::query_data_list("", "", "", "", "", "count_rise", 0, 0, 1)?.entries;

		let mut components = Vec::new();
		if !popular.is_empty() {
			components.push(HomeComponent {
				title: Some(String::from("综合推荐")),
				subtitle: None,
				value: HomeComponentValue::Scroller {
					entries: popular.into_iter().map(Into::into).collect(),
					listing: Some(Listing {
						id: String::from("sortpoint"),
						name: String::from("综合推荐"),
						kind: ListingKind::Default,
					}),
				},
			});
		}
		if !rising.is_empty() {
			components.push(HomeComponent {
				title: Some(String::from("最近热门")),
				subtitle: None,
				value: HomeComponentValue::Scroller {
					entries: rising.into_iter().map(Into::into).collect(),
					listing: Some(Listing {
						id: String::from("count_rise"),
						name: String::from("最近热门"),
						kind: ListingKind::Default,
					}),
				},
			});
		}
		if !updated.is_empty() {
			components.push(HomeComponent {
				title: Some(String::from("最近更新")),
				subtitle: None,
				value: HomeComponentValue::Scroller {
					entries: updated.into_iter().map(Into::into).collect(),
					listing: Some(Listing {
						id: String::from("lastupdate"),
						name: String::from("最近更新"),
						kind: ListingKind::Default,
					}),
				},
			});
		}

		Ok(HomeLayout { components })
	}
}

impl DynamicListings for KoxSource {
	fn get_dynamic_listings(&self) -> Result<Vec<Listing>> {
		let mut listings = vec![
			Listing {
				id: String::from("lastupdate"),
				name: String::from("最近更新"),
				kind: ListingKind::Default,
			},
			Listing {
				id: String::from("count_rise"),
				name: String::from("最近热门"),
				kind: ListingKind::Default,
			},
			Listing {
				id: String::from("newadd"),
				name: String::from("最近收录"),
				kind: ListingKind::Default,
			},
			Listing {
				id: String::from("score"),
				name: String::from("评价排名"),
				kind: ListingKind::Default,
			},
		];
		if auth::is_logged_in() {
			listings.insert(
				0,
				Listing {
					id: String::from("koobone_shelf"),
					name: String::from("Koobone 书架"),
					kind: ListingKind::Default,
				},
			);
		}
		Ok(listings)
	}
}

impl ListingProvider for KoxSource {
	fn get_manga_list(&self, listing: Listing, page: i32) -> Result<MangaPageResult> {
		match listing.id.as_str() {
			"koobone_shelf" => Self::get_koobone_series_listing(page),
			"sortpoint" | "score" | "count_push" | "count_rise" | "random" | "newadd"
			| "lastupdate" => Self::query_data_list("", "", "", "", "", &listing.id, 0, 0, page),
			_ => Self::query_data_list("", "", "", "", "", "sortpoint", 0, 0, page),
		}
	}
}

impl DynamicSettings for KoxSource {
	fn get_dynamic_settings(&self) -> Result<Vec<Setting>> {
		if !auth::is_logged_in() {
			return Ok(Vec::new());
		}

		if let Ok(st) = auth::fetch_user_status() {
			auth::save_cached_status(&st);
		}
		let status = auth::cached_status().unwrap_or_default();

		if !status.logged_in {
			return Ok(Vec::new());
		}

		let level_text = if status.is_vip {
			if status.vip_expire.is_empty() {
				format!("Lv{} · VIP 会员", status.level)
			} else {
				format!("Lv{} · VIP (至 {})", status.level, status.vip_expire)
			}
		} else {
			format!("Lv{} 普通用户", status.level)
		};

		let account_text = if !status.nickname.is_empty() && !status.uin.is_empty() {
			format!("{} (ID: {})", status.nickname, status.uin)
		} else if !status.email.is_empty() {
			status.email.clone()
		} else {
			status.uin.clone()
		};

		let quota_summary = auth::format_mb(status.quota_remaining_mb);
		let used_summary = format!(
			"今日 {:.1}M / 本月 {:.1}M",
			status.quota_today_used_mb, status.quota_month_used_mb
		);

		defaults_set("status.account", DefaultValue::String(account_text.clone()));
		defaults_set("status.level", DefaultValue::String(level_text.clone()));
		defaults_set("status.quota_left", DefaultValue::String(quota_summary.clone()));
		defaults_set("status.quota_used", DefaultValue::String(used_summary.clone()));
		if status.koobone_active {
			let kb_text = format!(
				"{} 本书 · 空间 {} / {}",
				status.koobone_vol_count,
				auth::format_bytes(status.koobone_quota_used_bytes),
				auth::format_bytes(status.koobone_quota_max_bytes)
			);
			defaults_set("status.koobone", DefaultValue::String(kb_text));
		} else {
			defaults_set("status.koobone", DefaultValue::Null);
		}

		let mut items: Vec<Setting> = vec![
			TextSetting {
				key: "status.account".into(),
				title: "当前账号".into(),
				default: Some(account_text.into()),
				..Default::default()
			}
			.into(),
			TextSetting {
				key: "status.level".into(),
				title: "用户等级".into(),
				default: Some(level_text.into()),
				..Default::default()
			}
			.into(),
			TextSetting {
				key: "status.quota_left".into(),
				title: "剩余可用配额".into(),
				default: Some(quota_summary.into()),
				..Default::default()
			}
			.into(),
			TextSetting {
				key: "status.quota_used".into(),
				title: "已用配额".into(),
				default: Some(used_summary.into()),
				..Default::default()
			}
			.into(),
		];

		if status.koobone_active {
			let kb_text = format!(
				"{} 本书 · 空间 {} / {}",
				status.koobone_vol_count,
				auth::format_bytes(status.koobone_quota_used_bytes),
				auth::format_bytes(status.koobone_quota_max_bytes)
			);
			items.push(
				TextSetting {
					key: "status.koobone".into(),
					title: "Koobone 状态".into(),
					default: Some(kb_text.into()),
					..Default::default()
				}
				.into(),
			);
		}

		items.push(
			ButtonSetting {
				key: "status.refresh".into(),
				title: "刷新账号与配额状态".into(),
				notification: Some("refresh_status".into()),
				refreshes: Some(vec!["settings".into()]),
				..Default::default()
			}
			.into(),
		);

		let footer = if !status.quota_reset_day.is_empty() {
			Some(
				format!(
					"免费额度剩余 {:.1}M / {:.1}M{} · 额度重置：{}",
					status.quota_free_left_mb,
					status.quota_free_total_mb,
					if status.is_vip {
						format!(
							" · VIP 额度剩余 {:.1}M / {:.1}M",
							status.quota_vip_left_mb, status.quota_vip_total_mb
						)
					} else {
						String::new()
					},
					status.quota_reset_day
				)
				.into(),
			)
		} else {
			None
		};

		Ok(vec![
			GroupSetting {
				key: "status.group".into(),
				title: "Kox 账户状态".into(),
				footer,
				items,
				..Default::default()
			}
			.into(),
		])
	}
}

impl BasicLoginHandler for KoxSource {
	fn handle_basic_login(&self, key: String, username: String, password: String) -> Result<bool> {
		if key != "login" && !key.is_empty() {
			return Ok(false);
		}
		let ok = auth::login_kox(username.trim(), &password)?;
		if ok {
			auth::set_just_logged_in();
		}
		Ok(ok)
	}
}

impl NotificationHandler for KoxSource {
	fn handle_notification(&self, notification: String) {
		match notification.as_str() {
			"login" => auth::handle_login_notification(),
			"refresh_status" => {
				if let Ok(st) = auth::fetch_user_status() {
					auth::save_cached_status(&st);
				}
			}
			_ => {}
		}
	}
}

impl ImageRequestProvider for KoxSource {
	fn get_image_request(&self, url: String, _context: Option<PageContext>) -> Result<Request> {
		let base = auth::base_url();
		let mut req = Request::get(&url)?;
		if url.contains("koobone.com") || url.contains("mixmoe.com") {
			req.set_header("Referer", &format!("{}/", auth::KOOBONE_URL));
		} else {
			req.set_header("Referer", &format!("{base}/"));
		}
		Ok(req)
	}
}

impl DeepLinkHandler for KoxSource {
	fn handle_deep_link(&self, url: String) -> Result<Option<DeepLinkResult>> {
		if url.contains("/c/") {
			let key = Self::extract_manga_key(&url);
			if !key.is_empty() {
				return Ok(Some(DeepLinkResult::Manga { key }));
			}
		}
		Ok(None)
	}
}

register_source!(
	KoxSource,
	Home,
	DynamicListings,
	ListingProvider,
	DynamicSettings,
	BasicLoginHandler,
	NotificationHandler,
	ImageRequestProvider,
	DeepLinkHandler
);
