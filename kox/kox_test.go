package kox

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"

	"github.com/ohaiibuzzle/aidokurunner-go/models"
)

func TestDecodeCFEmail(t *testing.T) {
	got := DecodeCFEmail("017269687b746a7471737173717341666c60686d2f626e6c")
	if got != "shizukuprprpr@gmail.com" {
		t.Fatalf("DecodeCFEmail = %q, want %q", got, "shizukuprprpr@gmail.com")
	}
}

func TestParseMyPHPVIP(t *testing.T) {
	sample := `
	<a href="/u/11232315/">https://kxx.moe/u/11232315/</a>
	<a href="/cdn-cgi/l/email-protection" data-cfemail="017269687b746a7471737173717341666c60686d2f626e6c"></a>
	<input type="text" name="nickname" value="shizukuprprpr">
	<span class='color_gree'>已驗證</span>
	<div id="div_user_vip" style="display:none">
		你是本站 Lv3 用戶，且是本站 VIP ，VIP開通日期 2025-12-13，VIP期限至 <b>2026-12-12</b>。<br />
		VIP 額度 : <font>每月 <u><font color="red">&nbsp;13&nbsp;</font></u> 日<u> 0 </u>時更新</font><br />
		今日已用 : 0.0 M , 本月已用免費額度 : 740.9 M , 本月已經用VIP額度 : 0.0 M<br />
		Lv3 每月額度 : &nbsp; 3072.0 M , 剩餘 : &nbsp; 2331.1 M ,<br />
		VIP 每月額度 : 40960.0 M , 剩餘 : 40960.0 M ,
		額外額度剩餘 : &nbsp;0.0 M <br />
	</div>
	<script>
	var user_level = "3";
	var is_vip     = "1";
	</script>`

	st := ParseMyPHP(sample)
	if !st.LoggedIn || st.Uin != "11232315" || st.Nickname != "shizukuprprpr" || st.Email != "shizukuprprpr@gmail.com" {
		t.Fatalf("unexpected identity: %+v", st)
	}
	if st.Level != 3 || !st.IsVIP || st.VIPExpire != "2026-12-12" || !st.PhoneVerified {
		t.Fatalf("unexpected level/vip: %+v", st)
	}
	if st.QuotaFreeTotalMB != 3072.0 || st.QuotaFreeLeftMB != 2331.1 || st.QuotaVIPTotalMB != 40960.0 || st.QuotaRemainingMB != 43291.1 {
		t.Fatalf("unexpected quota: %+v", st)
	}
	if st.QuotaResetDay != "每月 13 日" {
		t.Fatalf("QuotaResetDay = %q, want %q", st.QuotaResetDay, "每月 13 日")
	}
}

func TestParseMyPHPNormal(t *testing.T) {
	sample := `
	<a href="/u/998877/">home</a>
	<input type="text" name="nickname" value="reader">
	<div id="div_user_nor" style="display:none">
		你是本站 Lv2 用戶。每月 <font color="red">15</font> 日 0 時更新額度<br />
		今日已用 : 12.5 M , 本月已用額度 : 500.0 M<br />
		每月免費額度 : &nbsp;2048.0 M , 剩餘 : 1548.0 M ,
		額外額度剩餘 : &nbsp;100.0 M <br />
	</div>
	<script>
	var user_level = "2";
	var is_vip     = "0";
	</script>`

	st := ParseMyPHP(sample)
	if st.Level != 2 || st.IsVIP {
		t.Fatalf("unexpected level/vip: %+v", st)
	}
	if st.QuotaRemainingMB != 1648.0 || st.QuotaMonthUsedMB != 500.0 || st.QuotaTodayUsedMB != 12.5 {
		t.Fatalf("unexpected quota: %+v", st)
	}
	if st.QuotaResetDay != "每月 15 日" {
		t.Fatalf("QuotaResetDay = %q, want %q", st.QuotaResetDay, "每月 15 日")
	}
}

func TestConvertEPUBFileToCBZ(t *testing.T) {
	tmpDir := t.TempDir()
	epubPath := filepath.Join(tmpDir, "sample.epub")

	f, err := os.Create(epubPath)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	writeEntry := func(name, content string) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	writeBytes := func(name string, b []byte) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(b); err != nil {
			t.Fatal(err)
		}
	}

	// Minimal 1x1 PNG
	png1x1 := []byte{
		0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
		0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
		0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
		0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
		0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
	}

	writeEntry("META-INF/container.xml", `<?xml version="1.0"?><container><rootfiles><rootfile full-path="vol.opf"/></rootfiles></container>`)
	writeEntry("vol.opf", `<?xml version="1.0"?><package><manifest>
		<item id="p2" href="html/p2.html" media-type="application/xhtml+xml"/>
		<item id="p1" href="html/p1.html" media-type="application/xhtml+xml"/>
		<item id="end" href="image/theendinfo.png" media-type="image/png"/>
	</manifest><spine>
		<itemref idref="p1"/>
		<itemref idref="p2"/>
		<itemref idref="end"/>
	</spine></package>`)
	writeEntry("html/p1.html", `<html><body><img src="../image/moe-999.png"/></body></html>`)
	writeEntry("html/p2.html", `<html><body><img src="../image/moe-001.png"/></body></html>`)
	writeBytes("image/moe-999.png", png1x1)
	writeBytes("image/moe-001.png", png1x1)
	writeBytes("image/theendinfo.png", png1x1)

	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	chTitle := "卷01"
	outCBZ := filepath.Join(tmpDir, "out.cbz")
	gotPath, err := ConvertEPUBFileToCBZ(
		epubPath,
		models.Manga{Key: "15816", Title: "Test Manga"},
		models.Chapter{Key: "koobvol:abc", Title: &chTitle},
		outCBZ,
		"",
		nil,
	)
	if err != nil {
		t.Fatalf("ConvertEPUBFileToCBZ: %v", err)
	}

	zr, err := zip.OpenReader(gotPath)
	if err != nil {
		t.Fatalf("opening output cbz: %v", err)
	}
	defer zr.Close()

	// Expect ComicInfo.xml + 2 pages (excluding trailing theendinfo.png)
	if len(zr.File) != 3 {
		t.Fatalf("cbz entry count = %d, want 3", len(zr.File))
	}
}
