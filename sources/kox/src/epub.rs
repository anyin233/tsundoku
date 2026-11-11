use aidoku::{
	Page, PageContent, Result,
	alloc::{String, Vec},
	error,
	serde::Deserialize,
};
use miniz_oxide::inflate::decompress_to_vec;

#[derive(Deserialize)]
struct DownUrlResp {
	#[serde(default)]
	url: String,
	#[serde(default)]
	msg: String,
}

pub fn parse_down_url(json_text: &str) -> Result<String> {
	let parsed: DownUrlResp =
		serde_json::from_str(json_text).map_err(|_| error!("下载链接响应解析失败"))?;
	if parsed.url.trim().is_empty() {
		if !parsed.msg.trim().is_empty() {
			return Err(error!("获取下载链接失败: {}", parsed.msg.trim()));
		}
		return Err(error!("获取下载链接失败（可能需要登录、手机验证或额度不足）"));
	}
	Ok(parsed.url)
}

#[derive(Debug, Clone)]
struct ZipEntryMeta {
	name: String,
	method: u16,
	comp_size: usize,
	uncomp_size: usize,
	local_header_offset: usize,
}

/// Minimal `no_std` ZIP Central Directory reader + Deflate extractor using `miniz_oxide`.
struct MiniZip<'a> {
	data: &'a [u8],
	entries: Vec<ZipEntryMeta>,
}

impl<'a> MiniZip<'a> {
	fn open(data: &'a [u8]) -> Option<Self> {
		if data.len() < 22 {
			return None;
		}
		// Locate End of Central Directory (EOCD) signature 0x06054b50 within last 65557 bytes
		let min_pos = data.len().saturating_sub(65557);
		let mut eocd_pos = None;
		let mut pos = data.len() - 22;
		loop {
			if read_u32_le(data, pos) == Some(0x0605_4b50) {
				eocd_pos = Some(pos);
				break;
			}
			if pos == min_pos {
				break;
			}
			pos -= 1;
		}
		let eocd = eocd_pos?;
		let total_entries = read_u16_le(data, eocd + 10)? as usize;
		let cd_size = read_u32_le(data, eocd + 12)? as usize;
		let cd_offset = read_u32_le(data, eocd + 16)? as usize;
		if cd_offset.checked_add(cd_size)? > data.len() {
			return None;
		}

		let mut entries = Vec::with_capacity(total_entries.min(4096));
		let mut cur = cd_offset;
		let cd_end = cd_offset + cd_size;
		while cur + 46 <= cd_end {
			if read_u32_le(data, cur) != Some(0x0201_4b50) {
				break;
			}
			let method = read_u16_le(data, cur + 10)?;
			let comp_size = read_u32_le(data, cur + 20)? as usize;
			let uncomp_size = read_u32_le(data, cur + 24)? as usize;
			let name_len = read_u16_le(data, cur + 28)? as usize;
			let extra_len = read_u16_le(data, cur + 30)? as usize;
			let comment_len = read_u16_le(data, cur + 32)? as usize;
			let local_header_offset = read_u32_le(data, cur + 42)? as usize;

			let name_start = cur + 46;
			let next = name_start.checked_add(name_len)?.checked_add(extra_len)?.checked_add(comment_len)?;
			if next > cd_end {
				break;
			}
			if let Ok(name_str) = core::str::from_utf8(&data[name_start..name_start + name_len]) {
				entries.push(ZipEntryMeta {
					name: String::from(name_str),
					method,
					comp_size,
					uncomp_size,
					local_header_offset,
				});
			}
			cur = next;
		}

		Some(Self { data, entries })
	}

	fn read_entry_bytes(&self, name: &str) -> Option<Vec<u8>> {
		let entry = self.entries.iter().find(|e| e.name == name)?;
		let lho = entry.local_header_offset;
		if lho + 30 > self.data.len() || read_u32_le(self.data, lho) != Some(0x0403_4b50) {
			return None;
		}
		let l_name_len = read_u16_le(self.data, lho + 26)? as usize;
		let l_extra_len = read_u16_le(self.data, lho + 28)? as usize;
		let data_start = lho.checked_add(30)?.checked_add(l_name_len)?.checked_add(l_extra_len)?;
		let data_end = data_start.checked_add(entry.comp_size)?;
		if data_end > self.data.len() {
			return None;
		}
		let slice = &self.data[data_start..data_end];
		match entry.method {
			0 => Some(slice.to_vec()),
			8 => {
				// Cap text inflation to 16MB for safety
				if entry.uncomp_size > (16 << 20) {
					return None;
				}
				decompress_to_vec(slice).ok()
			}
			_ => None,
		}
	}

	fn read_entry_string(&self, name: &str) -> Option<String> {
		let bytes = self.read_entry_bytes(name)?;
		String::from_utf8(bytes).ok()
	}
}

fn read_u16_le(buf: &[u8], offset: usize) -> Option<u16> {
	let b = buf.get(offset..offset + 2)?;
	Some(u16::from_le_bytes([b[0], b[1]]))
}

fn read_u32_le(buf: &[u8], offset: usize) -> Option<u32> {
	let b = buf.get(offset..offset + 4)?;
	Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

/// Parses a Kmoe/Koobone EPUB archive in memory to extract the ordered list of image file paths
/// inside the EPUB ZIP archive (matching Kmoe's `vol.opf` spine + `html/page-*.html` -> `image/*`).
/// Returns `Vec<Page>` using `PageContent::Zip(epub_url, image_entry_path)` so Aidoku downloads
/// the EPUB archive once per chapter/volume and streams every page directly without extra quota cost.
pub fn extract_epub_pages(epub_bytes: &[u8], epub_url: &str) -> Result<Vec<Page>> {
	let archive =
		MiniZip::open(epub_bytes).ok_or_else(|| error!("无法打开 EPUB 压缩包（文件可能损坏或无权限）"))?;

	// 1. Locate OPF path via META-INF/container.xml (fallback to vol.opf)
	let opf_path = archive
		.read_entry_string("META-INF/container.xml")
		.and_then(|xml| extract_attr(&xml, "rootfile", "full-path"))
		.unwrap_or_else(|| String::from("vol.opf"));

	let opf_xml = archive
		.read_entry_string(&opf_path)
		.or_else(|| archive.read_entry_string("vol.opf"))
		.ok_or_else(|| error!("EPUB 缺少 OPF 元数据文件"))?;

	// 2. Parse manifest id -> (href, media-type)
	let manifest = parse_opf_manifest(&opf_xml, &opf_path);
	// 3. Parse spine itemref idrefs in reading order
	let spine_ids = parse_opf_spine(&opf_xml);

	let mut image_paths: Vec<String> = Vec::new();
	for idref in spine_ids {
		let Some((item_path, media_type)) = manifest
			.iter()
			.find(|(id, _, _)| id == &idref)
			.map(|(_, href, mt)| (href.clone(), mt.clone()))
		else {
			continue;
		};

		if media_type.starts_with("image/") || is_image_filename(&item_path) {
			if !is_trailing_credit_image(&item_path) {
				image_paths.push(item_path);
			}
			continue;
		}

		if let Some(html) = archive.read_entry_string(&item_path) {
			if let Some(img_rel) = extract_img_src(&html) {
				let resolved = resolve_rel_path(&item_path, &img_rel);
				if !is_trailing_credit_image(&resolved) {
					image_paths.push(resolved);
				}
			}
		}
	}

	// Fallback if OPF spine yielded nothing: collect image/* entries in sorted order
	if image_paths.is_empty() {
		let mut fallback: Vec<String> = archive
			.entries
			.iter()
			.filter(|e| !e.name.ends_with('/') && is_image_filename(&e.name) && !is_trailing_credit_image(&e.name))
			.map(|e| e.name.clone())
			.collect();
		fallback.sort();
		image_paths = fallback;
	}

	if image_paths.is_empty() {
		return Err(error!("EPUB 中未找到任何漫画图片页面"));
	}

	let pages = image_paths
		.into_iter()
		.map(|entry_path| Page {
			content: PageContent::Zip(String::from(epub_url), entry_path),
			..Default::default()
		})
		.collect();

	Ok(pages)
}

fn is_trailing_credit_image(path: &str) -> bool {
	path.ends_with("theendinfo.png")
}

fn is_image_filename(path: &str) -> bool {
	let lower = path.to_ascii_lowercase();
	lower.ends_with(".jpg")
		|| lower.ends_with(".jpeg")
		|| lower.ends_with(".png")
		|| lower.ends_with(".webp")
		|| lower.ends_with(".gif")
}

fn resolve_rel_path(base_file: &str, rel: &str) -> String {
	let rel = rel.trim();
	if let Some(stripped) = rel.strip_prefix('/') {
		return String::from(stripped);
	}
	let mut parts: Vec<&str> = match base_file.rfind('/') {
		Some(idx) => base_file[..idx].split('/').filter(|s| !s.is_empty()).collect(),
		None => Vec::new(),
	};
	for seg in rel.split('/') {
		match seg {
			"" | "." => {}
			".." => {
				parts.pop();
			}
			other => parts.push(other),
		}
	}
	parts.join("/")
}

fn extract_attr(xml: &str, tag_name: &str, attr_name: &str) -> Option<String> {
	let mut rest = xml;
	while let Some(pos) = rest.find('<') {
		rest = &rest[pos + 1..];
		let end = rest.find('>')?;
		let tag = &rest[..end];
		let trimmed = tag.trim_start();
		if trimmed.starts_with(tag_name)
			&& trimmed[tag_name.len()..]
				.chars()
				.next()
				.is_some_and(|c| c.is_whitespace() || c == '/')
		{
			if let Some(val) = get_xml_attr(trimmed, attr_name) {
				return Some(val);
			}
		}
		rest = &rest[end + 1..];
	}
	None
}

fn get_xml_attr(tag_body: &str, attr_name: &str) -> Option<String> {
	for quote in ['"', '\''] {
		let pat = aidoku::prelude::format!("{attr_name}={quote}");
		if let Some(idx) = tag_body.find(&pat) {
			let after = &tag_body[idx + pat.len()..];
			if let Some(end) = after.find(quote) {
				return Some(unescape_xml(&after[..end]));
			}
		}
	}
	None
}

fn unescape_xml(s: &str) -> String {
	s.replace("&amp;", "&")
		.replace("&lt;", "<")
		.replace("&gt;", ">")
		.replace("&quot;", "\"")
		.replace("&apos;", "'")
}

fn parse_opf_manifest(opf_xml: &str, opf_path: &str) -> Vec<(String, String, String)> {
	let mut items = Vec::new();
	let section = match (opf_xml.find("<manifest"), opf_xml.find("</manifest>")) {
		(Some(s), Some(e)) if e > s => &opf_xml[s..e],
		_ => opf_xml,
	};
	let mut rest = section;
	while let Some(pos) = rest.find("<item") {
		rest = &rest[pos + 5..];
		if !rest
			.chars()
			.next()
			.is_some_and(|c| c.is_whitespace())
		{
			continue;
		}
		let Some(end) = rest.find('>') else {
			break;
		};
		let tag = &rest[..end];
		if let (Some(id), Some(href)) = (get_xml_attr(tag, "id"), get_xml_attr(tag, "href")) {
			let mt = get_xml_attr(tag, "media-type").unwrap_or_default();
			let full_href = resolve_rel_path(opf_path, &href);
			items.push((id, full_href, mt));
		}
		rest = &rest[end + 1..];
	}
	items
}

fn parse_opf_spine(opf_xml: &str) -> Vec<String> {
	let mut ids = Vec::new();
	let section = match (opf_xml.find("<spine"), opf_xml.find("</spine>")) {
		(Some(s), Some(e)) if e > s => &opf_xml[s..e],
		_ => opf_xml,
	};
	let mut rest = section;
	while let Some(pos) = rest.find("<itemref") {
		rest = &rest[pos + 8..];
		let Some(end) = rest.find('>') else {
			break;
		};
		let tag = &rest[..end];
		if let Some(idref) = get_xml_attr(tag, "idref") {
			ids.push(idref);
		}
		rest = &rest[end + 1..];
	}
	ids
}

fn extract_img_src(html: &str) -> Option<String> {
	let mut rest = html;
	while let Some(pos) = rest.find("<img") {
		rest = &rest[pos + 4..];
		let end = rest.find('>')?;
		let tag = &rest[..end];
		if let Some(src) = get_xml_attr(tag, "src") {
			if !src.is_empty() {
				return Some(src);
			}
		}
		rest = &rest[end + 1..];
	}
	let mut rest2 = html;
	while let Some(pos) = rest2.find("<image") {
		rest2 = &rest2[pos + 6..];
		let end = rest2.find('>')?;
		let tag = &rest2[..end];
		if let Some(href) = get_xml_attr(tag, "xlink:href").or_else(|| get_xml_attr(tag, "href")) {
			if !href.is_empty() {
				return Some(href);
			}
		}
		rest2 = &rest2[end + 1..];
	}
	None
}
