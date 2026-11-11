// Package kox implements Tsundoku's first-class native integration for
// Kox.moe (kzo.moe / kxx.moe / kzz.moe / koz.moe) and its companion online
// reader Koobone (koobone.com):
//   - Account authentication & session management (sharing state seamlessly
//     with the bundled Aidoku `kox` source under `kox.*` settings keys)
//   - Rich user status parsing (ID, nickname, email, Lv level, VIP status &
//     expiry, phone verification, remaining/monthly/daily/VIP/free quotas,
//     and Koobone storage & book counts)
//   - Koobone bookshelf browsing (series list, volume list, liked list)
//   - Streaming EPUB -> uncompressed CBZ conversion with ComicInfo.xml and
//     downloads index registration, enabling zero-extra-Kox-quota offline
//     push from kox.moe -> Koobone -> KOReader.
package kox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ohaiibuzzle/aidokurunner-go/runtime/host"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
)

const (
	SourceKey      = "kox"
	DefaultBaseURL = "https://kzo.moe"
	KooboneBaseURL = "https://koobone.com"
	userAgent      = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
)

const (
	keyBaseURL        = "kox.url"
	keyLoginUsername  = "kox.login.username"
	keyLoginPassword  = "kox.login.password"
	keySessionCookie  = "kox.auth.cookie"
	keyStatusJSON     = "kox.auth.statusJson"
	keyJustLoggedIn   = "kox.auth.justLoggedIn"
	keyKoobUin        = "kox.koob.uin"
	keyKoobSkey       = "kox.koob.skey"
	keyKoobCookie     = "kox.koob.cookie"
	keyStatusAccount  = "kox.status.account"
	keyStatusLevel    = "kox.status.level"
	keyStatusQuotaLft = "kox.status.quota_left"
	keyStatusQuotaUsd = "kox.status.quota_used"
	keyStatusKoobone  = "kox.status.koobone"
)

// UserStatus represents the authenticated user's profile, level, and quota
// across both Kox.moe and Koobone.
type UserStatus struct {
	LoggedIn              bool    `json:"logged_in"`
	Uin                   string  `json:"uin"`
	Nickname              string  `json:"nickname"`
	Email                 string  `json:"email"`
	Level                 int     `json:"level"`
	IsVIP                 bool    `json:"is_vip"`
	VIPExpire             string  `json:"vip_expire"`
	PhoneVerified         bool    `json:"phone_verified"`
	QuotaRemainingMB      float64 `json:"quota_remaining_mb"`
	QuotaFreeTotalMB      float64 `json:"quota_free_total_mb"`
	QuotaFreeLeftMB       float64 `json:"quota_free_left_mb"`
	QuotaVIPTotalMB       float64 `json:"quota_vip_total_mb"`
	QuotaVIPLeftMB        float64 `json:"quota_vip_left_mb"`
	QuotaExtraLeftMB      float64 `json:"quota_extra_left_mb"`
	QuotaTodayUsedMB      float64 `json:"quota_today_used_mb"`
	QuotaMonthUsedMB      float64 `json:"quota_month_used_mb"`
	QuotaResetDay         string  `json:"quota_reset_day"`
	KooboneActive         bool    `json:"koobone_active"`
	KooboneVolCount       int64   `json:"koobone_vol_count"`
	KooboneQuotaUsedBytes int64   `json:"koobone_quota_used_bytes"`
	KooboneQuotaMaxBytes  int64   `json:"koobone_quota_max_bytes"`
}

// Client talks to Kox.moe and Koobone using the shared settings store.
type Client struct {
	Settings   *settingsstore.Store
	HTTPClient *http.Client
	BaseURL    string
	KooboneURL string
}

// NewClient constructs a Client backed by settings.
func NewClient(settings *settingsstore.Store) *Client {
	base := DefaultBaseURL
	if settings != nil {
		if u, ok := settings.Object(keyBaseURL).(string); ok && strings.TrimSpace(u) != "" {
			base = strings.TrimRight(strings.TrimSpace(u), "/")
		}
	}
	return &Client{
		Settings:   settings,
		HTTPClient: &http.Client{Timeout: 90 * time.Second},
		BaseURL:    base,
		KooboneURL: KooboneBaseURL,
	}
}

func (c *Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return host.SharedHTTPClient()
}

func (c *Client) getString(key string) string {
	if c.Settings == nil {
		return ""
	}
	s, _ := c.Settings.Object(key).(string)
	return strings.TrimSpace(s)
}

func (c *Client) setValue(key string, v any) error {
	if c.Settings == nil {
		return nil
	}
	return c.Settings.SetValue(key, v)
}

// StoredCredentials returns the saved username and password if present.
func (c *Client) StoredCredentials() (username, password string, ok bool) {
	u := c.getString(keyLoginUsername)
	p := c.getString(keyLoginPassword)
	if u != "" && p != "" {
		return u, p, true
	}
	return "", "", false
}

// IsLoggedIn reports whether Kox credentials or session cookies are stored.
func (c *Client) IsLoggedIn() bool {
	if c.getString(keySessionCookie) != "" {
		return true
	}
	_, _, ok := c.StoredCredentials()
	return ok
}

// Logout clears all stored Kox and Koobone credentials, cookies, and cached status.
func (c *Client) Logout() error {
	keys := []string{
		keyLoginUsername,
		keyLoginPassword,
		keySessionCookie,
		keyStatusJSON,
		keyJustLoggedIn,
		keyKoobUin,
		keyKoobSkey,
		keyKoobCookie,
		keyStatusAccount,
		keyStatusLevel,
		keyStatusQuotaLft,
		keyStatusQuotaUsd,
		keyStatusKoobone,
	}
	for _, k := range keys {
		if err := c.setValue(k, nil); err != nil {
			return err
		}
	}
	return nil
}

// Login authenticates against Kox.moe (/login_act.php) and Koobone (/login_do.php),
// persists session cookies and credentials into settings.json (shared with the
// WASM `kox` source), and returns the freshly fetched UserStatus.
func (c *Client) Login(ctx context.Context, email, password string) (*UserStatus, error) {
	email = strings.TrimSpace(email)
	if email == "" || password == "" {
		return nil, fmt.Errorf("kox: email and password are required")
	}

	// 1. Warm session cookie on Kox
	if warmReq, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/login.php", nil); err == nil {
		c.applyKoxHeaders(warmReq, "/")
		if warmResp, err := c.httpClient().Do(warmReq); err == nil {
			c.captureCookies(warmResp, keySessionCookie)
			warmResp.Body.Close()
		}
	}

	// 2. POST /login_act.php
	bodyBuf, contentType, err := buildMultipart(map[string]string{
		"email":  email,
		"passwd": password,
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/login_act.php", bodyBuf)
	if err != nil {
		return nil, err
	}
	c.applyKoxHeaders(req, "/login.php")
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("X-KM-FROM", "KMOE/3.0.0 POST /login.php")

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("kox: login request failed: %w", err)
	}
	defer resp.Body.Close()
	c.captureCookies(resp, keySessionCookie)

	raw, err := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
	if err != nil {
		return nil, err
	}
	var loginResp struct {
		MsgID string `json:"msgid"`
		Msg   string `json:"msg"`
	}
	if err := json.Unmarshal(raw, &loginResp); err != nil {
		return nil, fmt.Errorf("kox: invalid login response: %w", err)
	}
	if loginResp.MsgID != "m100" {
		msg := strings.TrimSpace(loginResp.Msg)
		if msg == "" {
			msg = loginResp.MsgID
		}
		return nil, fmt.Errorf("kox: login failed: %s", msg)
	}

	_ = c.setValue(keyLoginUsername, email)
	_ = c.setValue(keyLoginPassword, password)

	// 3. Also sign into Koobone with the same Kmoe account (best-effort: user might not have activated Koobone yet)
	_, _, _ = c.LoginKoobone(ctx, email, password)

	// 4. Fetch and persist full user status
	status, err := c.FetchStatus(ctx)
	if err != nil {
		return &UserStatus{LoggedIn: true, Email: email}, nil
	}
	return status, nil
}

// LoginKoobone authenticates against koobone.com/login_do.php and persists uin + skey + cookies.
func (c *Client) LoginKoobone(ctx context.Context, email, password string) (uin, skey string, err error) {
	if warmReq, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, c.KooboneURL+"/login.php?goto=web.htm", nil); reqErr == nil {
		warmReq.Header.Set("User-Agent", userAgent)
		if warmResp, doErr := c.httpClient().Do(warmReq); doErr == nil {
			c.captureCookies(warmResp, keyKoobCookie)
			warmResp.Body.Close()
		}
	}

	bodyBuf, contentType, err := buildMultipart(map[string]string{
		"email":     email,
		"passwd":    password,
		"keepalive": "1",
	})
	if err != nil {
		return "", "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.KooboneURL+"/login_do.php", bodyBuf)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Referer", c.KooboneURL+"/login.php?goto=web.htm")
	req.Header.Set("X-KAPI-FROM", "KOOBONE(Html)/6.2.0 POST /login.php")
	req.Header.Set("Content-Type", contentType)
	if ck := c.getString(keyKoobCookie); ck != "" {
		req.Header.Set("Cookie", ck)
	}

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", "", fmt.Errorf("koobone: login request failed: %w", err)
	}
	defer resp.Body.Close()
	c.captureCookies(resp, keyKoobCookie)

	raw, err := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
	if err != nil {
		return "", "", err
	}
	var parsed struct {
		Uin  any    `json:"uin"`
		Skey string `json:"skey"`
		Msg  string `json:"msg"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return "", "", fmt.Errorf("koobone: invalid login response: %w", err)
	}
	uin = formatAnyID(parsed.Uin)
	skey = strings.TrimSpace(parsed.Skey)
	if uin == "" || uin == "0" {
		msg := strings.TrimSpace(parsed.Msg)
		if msg == "" {
			msg = "authentication failed"
		}
		return "", "", fmt.Errorf("koobone: %s", msg)
	}
	_ = c.setValue(keyKoobUin, uin)
	_ = c.setValue(keyKoobSkey, skey)
	return uin, skey, nil
}

// PushToKoobone pushes one or more Kox volume IDs of a book directly to the user's Koobone bookshelf
// via Kox's `/book_push.php` endpoint (`pushto=2`).
func (c *Client) PushToKoobone(ctx context.Context, bookID string, volIDs []string) (string, error) {
	if len(volIDs) == 0 || strings.TrimSpace(bookID) == "" {
		return "", fmt.Errorf("kox: bookID and volIDs are required")
	}
	if !c.IsLoggedIn() {
		return "", fmt.Errorf("kox: not logged in")
	}
	bodyBuf, contentType, err := buildMultipart(map[string]string{
		"push_bookid":   strings.TrimSpace(bookID),
		"push_vol_list": strings.Join(volIDs, ","),
		"pushto":        "2",
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/book_push.php", bodyBuf)
	if err != nil {
		return "", err
	}
	c.applyKoxHeaders(req, "/c/"+bookID+".htm")
	req.Header.Set("Content-Type", contentType)

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	c.captureCookies(resp, keySessionCookie)
	raw, err := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
	if err != nil {
		return "", err
	}
	html := string(raw)
	// Extract postMessage / display_codeinfo code if present
	if m := rePushMsgCode.FindStringSubmatch(html); len(m) > 1 {
		return translatePushCode(m[1]), nil
	}
	return "推送请求已提交", nil
}

var rePushMsgCode = regexp.MustCompile(`(?:msg3=|display_codeinfo\(\s*['"])([a-zA-Z0-9_]+)`)

func translatePushCode(code string) string {
	switch code {
	case "m100", "c100":
		return "推送登记成功，漫画已推送至 Koobone 书架"
	case "m101":
		return "部分推送登记失败（可能由于额度不足或文件超限）"
	case "m103":
		return "操作成功"
	case "m104":
		return "存在 15 分钟内的重复推送，未完全登记"
	case "e401":
		return "登录状态已失效，请重新登录"
	case "e403":
		return "Kox.moe 网站额度不足"
	case "e480":
		return "Koobone 账号未激活，请先登录 Koobone"
	case "e481":
		return "Koobone 存储空间不足"
	default:
		return "推送返回状态: " + code
	}
}

// FetchStatus queries Kox.moe `/my.php` and Koobone `/v1/uinfo` to return real-time
// user level, VIP expiry, and quota metrics, caching the result into settings.json.
func (c *Client) FetchStatus(ctx context.Context) (*UserStatus, error) {
	if !c.IsLoggedIn() {
		return &UserStatus{LoggedIn: false}, nil
	}

	html, err := c.fetchMyPHP(ctx)
	if err != nil {
		if cached := c.CachedStatus(); cached != nil {
			return cached, nil
		}
		return nil, err
	}
	if isLoginPage(html) {
		if u, p, ok := c.StoredCredentials(); ok {
			if _, relogErr := c.loginKoxOnly(ctx, u, p); relogErr == nil {
				html, err = c.fetchMyPHP(ctx)
				if err != nil {
					return nil, err
				}
			}
		}
	}
	if isLoginPage(html) {
		return &UserStatus{LoggedIn: false}, nil
	}

	st := ParseMyPHP(html)

	if uinfo, kbErr := c.FetchKooboneUserInfo(ctx); kbErr == nil && uinfo != nil && uinfo.Uin > 0 {
		st.KooboneActive = true
		st.KooboneVolCount = uinfo.CountVol
		st.KooboneQuotaUsedBytes = uinfo.QuotaUsed
		st.KooboneQuotaMaxBytes = uinfo.QuotaMax
		if st.Email == "" && uinfo.UID != "" {
			st.Email = uinfo.UID
		}
		if st.Nickname == "" && uinfo.Nick != "" {
			st.Nickname = uinfo.Nick
		}
	}

	c.persistStatusSummary(&st)
	return &st, nil
}

// CachedStatus reads the last cached UserStatus from settings.json without hitting the network.
func (c *Client) CachedStatus() *UserStatus {
	raw := c.getString(keyStatusJSON)
	if raw == "" {
		return nil
	}
	var st UserStatus
	if err := json.Unmarshal([]byte(raw), &st); err != nil {
		return nil
	}
	return &st
}

func (c *Client) persistStatusSummary(st *UserStatus) {
	if b, err := json.Marshal(st); err == nil {
		_ = c.setValue(keyStatusJSON, string(b))
	}
	if !st.LoggedIn {
		return
	}
	levelText := fmt.Sprintf("Lv%d 普通用户", st.Level)
	if st.IsVIP {
		if st.VIPExpire != "" {
			levelText = fmt.Sprintf("Lv%d · VIP (至 %s)", st.Level, st.VIPExpire)
		} else {
			levelText = fmt.Sprintf("Lv%d · VIP 会员", st.Level)
		}
	}
	accountText := st.Uin
	if st.Nickname != "" && st.Uin != "" {
		accountText = fmt.Sprintf("%s (ID: %s)", st.Nickname, st.Uin)
	} else if st.Email != "" {
		accountText = st.Email
	}
	_ = c.setValue(keyStatusAccount, accountText)
	_ = c.setValue(keyStatusLevel, levelText)
	_ = c.setValue(keyStatusQuotaLft, FormatMB(st.QuotaRemainingMB))
	_ = c.setValue(keyStatusQuotaUsd, fmt.Sprintf("今日 %.1fM / 本月 %.1fM", st.QuotaTodayUsedMB, st.QuotaMonthUsedMB))
	if st.KooboneActive {
		_ = c.setValue(keyStatusKoobone, fmt.Sprintf("%d 本书 · 空间 %s / %s",
			st.KooboneVolCount, FormatBytes(st.KooboneQuotaUsedBytes), FormatBytes(st.KooboneQuotaMaxBytes)))
	}
}

func (c *Client) loginKoxOnly(ctx context.Context, email, password string) (bool, error) {
	bodyBuf, contentType, err := buildMultipart(map[string]string{
		"email":  email,
		"passwd": password,
	})
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/login_act.php", bodyBuf)
	if err != nil {
		return false, err
	}
	c.applyKoxHeaders(req, "/login.php")
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("X-KM-FROM", "KMOE/3.0.0 POST /login.php")
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	c.captureCookies(resp, keySessionCookie)
	raw, err := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
	if err != nil {
		return false, err
	}
	var out struct {
		MsgID string `json:"msgid"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return false, err
	}
	return out.MsgID == "m100", nil
}

func (c *Client) fetchMyPHP(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/my.php", nil)
	if err != nil {
		return "", err
	}
	c.applyKoxHeaders(req, "/")
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	c.captureCookies(resp, keySessionCookie)
	raw, err := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func (c *Client) applyKoxHeaders(req *http.Request, refererPath string) {
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Referer", c.BaseURL+refererPath)
	if ck := c.getString(keySessionCookie); ck != "" {
		req.Header.Set("Cookie", ck)
	}
}

func (c *Client) captureCookies(resp *http.Response, settingKey string) {
	if resp == nil {
		return
	}
	incoming := resp.Cookies()
	if len(incoming) == 0 {
		return
	}
	merged := mergeCookiesHeader(c.getString(settingKey), incoming)
	if merged != "" {
		_ = c.setValue(settingKey, merged)
	}
}

func mergeCookiesHeader(existing string, incoming []*http.Cookie) string {
	type kv struct{ k, v string }
	var order []kv
	set := func(name, val string) {
		name = strings.TrimSpace(name)
		val = strings.TrimSpace(val)
		if name == "" {
			return
		}
		for i := range order {
			if order[i].k == name {
				if val == "" || val == "deleted" {
					order = append(order[:i], order[i+1:]...)
				} else {
					order[i].v = val
				}
				return
			}
		}
		if val != "" && val != "deleted" {
			order = append(order, kv{name, val})
		}
	}

	for _, part := range strings.Split(existing, ";") {
		if k, v, ok := strings.Cut(strings.TrimSpace(part), "="); ok {
			set(k, v)
		}
	}
	for _, ck := range incoming {
		if ck.MaxAge < 0 {
			set(ck.Name, "")
		} else {
			set(ck.Name, ck.Value)
		}
	}
	parts := make([]string, 0, len(order))
	for _, item := range order {
		parts = append(parts, item.k+"="+item.v)
	}
	return strings.Join(parts, "; ")
}

func buildMultipart(fields map[string]string) (*bytes.Buffer, string, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		if err := mw.WriteField(k, v); err != nil {
			return nil, "", err
		}
	}
	if err := mw.Close(); err != nil {
		return nil, "", err
	}
	return &buf, mw.FormDataContentType(), nil
}

func isLoginPage(html string) bool {
	return strings.Contains(html, `action="/login_do.php"`) || strings.Contains(html, `ipt_passwd`)
}

// DecodeCFEmail decodes Cloudflare's data-cfemail XOR hex obfuscation.
func DecodeCFEmail(hexStr string) string {
	hexStr = strings.TrimSpace(hexStr)
	if len(hexStr) < 4 || len(hexStr)%2 != 0 {
		return ""
	}
	key, err := strconv.ParseUint(hexStr[:2], 16, 8)
	if err != nil {
		return ""
	}
	out := make([]byte, 0, (len(hexStr)-2)/2)
	for i := 2; i < len(hexStr); i += 2 {
		b, err := strconv.ParseUint(hexStr[i:i+2], 16, 8)
		if err != nil {
			return ""
		}
		out = append(out, byte(b^key))
	}
	return string(out)
}

var (
	reUinLink   = regexp.MustCompile(`href="/u/(\d+)/"`)
	reNickname  = regexp.MustCompile(`name="nickname"[^>]*value="([^"]*)"`)
	reCFEmail   = regexp.MustCompile(`data-cfemail="([0-9a-fA-F]+)"`)
	reUserLevel = regexp.MustCompile(`var\s+user_level\s*=\s*"(\d+)"`)
	reIsVIP     = regexp.MustCompile(`var\s+is_vip\s*=\s*"(\d+)"`)
	reTags      = regexp.MustCompile(`<[^>]+>`)
)

// ParseMyPHP extracts UserStatus from Kox.moe's `/my.php` HTML.
func ParseMyPHP(html string) UserStatus {
	st := UserStatus{LoggedIn: true}

	if m := reUinLink.FindStringSubmatch(html); len(m) > 1 {
		st.Uin = m[1]
	}
	if m := reNickname.FindStringSubmatch(html); len(m) > 1 {
		st.Nickname = strings.TrimSpace(m[1])
	}
	if m := reCFEmail.FindStringSubmatch(html); len(m) > 1 {
		st.Email = DecodeCFEmail(m[1])
	}
	if m := reUserLevel.FindStringSubmatch(html); len(m) > 1 {
		st.Level, _ = strconv.Atoi(m[1])
	}
	if m := reIsVIP.FindStringSubmatch(html); len(m) > 1 {
		v, _ := strconv.Atoi(m[1])
		st.IsVIP = v >= 1
	}
	st.PhoneVerified = strings.Contains(html, ">已驗證<")

	if st.IsVIP {
		if block := extractBetween(html, `id="div_user_vip"`, `</div>`); block != "" {
			st.VIPExpire = strings.TrimSpace(extractBetween(block, `VIP期限至 <b>`, `</b>`))
			st.QuotaTodayUsedMB = firstFloatAfter(block, "今日已用 :")
			freeUsed := firstFloatAfter(block, "本月已用免費額度 :")
			vipUsed := firstFloatAfter(block, "本月已經用VIP額度 :")
			st.QuotaMonthUsedMB = freeUsed + vipUsed

			if idx := strings.Index(block, " 每月額度 :"); idx >= 0 {
				tail := block[idx:]
				st.QuotaFreeTotalMB = firstFloatAfter(tail, "每月額度 :")
				st.QuotaFreeLeftMB = firstFloatAfter(tail, "剩餘 :")
			}
			if idx := strings.Index(block, "VIP 每月額度 :"); idx >= 0 {
				tail := block[idx:]
				st.QuotaVIPTotalMB = firstFloatAfter(tail, "VIP 每月額度 :")
				st.QuotaVIPLeftMB = firstFloatAfter(tail, "剩餘 :")
			}
			st.QuotaExtraLeftMB = firstFloatAfter(block, "額外額度剩餘 :")
			st.QuotaRemainingMB = st.QuotaFreeLeftMB + st.QuotaVIPLeftMB + st.QuotaExtraLeftMB
			if dayRaw := extractBetween(block, "VIP 額度 :", "日"); dayRaw != "" {
				digits := onlyDigits(stripHTML(dayRaw))
				if digits != "" {
					st.QuotaResetDay = "每月 " + digits + " 日"
				}
			}
		}
	} else {
		if block := extractBetween(html, `id="div_user_nor"`, `</div>`); block != "" {
			st.QuotaTodayUsedMB = firstFloatAfter(block, "今日已用 :")
			st.QuotaMonthUsedMB = firstFloatAfter(block, "本月已用額度 :")
			st.QuotaFreeTotalMB = firstFloatAfter(block, "每月免費額度 :")
			st.QuotaFreeLeftMB = firstFloatAfter(block, "剩餘 :")
			st.QuotaExtraLeftMB = firstFloatAfter(block, "額外額度剩餘 :")
			st.QuotaRemainingMB = st.QuotaFreeLeftMB + st.QuotaExtraLeftMB
			if dayRaw := extractBetween(block, "每月", "日"); dayRaw != "" {
				digits := onlyDigits(stripHTML(dayRaw))
				if digits != "" {
					st.QuotaResetDay = "每月 " + digits + " 日"
				}
			}
		}
	}

	return st
}

func extractBetween(s, prefix, suffix string) string {
	i := strings.Index(s, prefix)
	if i < 0 {
		return ""
	}
	rest := s[i+len(prefix):]
	j := strings.Index(rest, suffix)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

func firstFloatAfter(s, marker string) float64 {
	i := strings.Index(s, marker)
	if i < 0 {
		return 0
	}
	rest := strings.ReplaceAll(s[i+len(marker):], "&nbsp;", " ")
	var numBuf strings.Builder
	started := false
	for _, r := range rest {
		if (r >= '0' && r <= '9') || r == '.' {
			numBuf.WriteRune(r)
			started = true
		} else if started {
			break
		}
	}
	v, _ := strconv.ParseFloat(numBuf.String(), 64)
	return v
}

func stripHTML(s string) string {
	return strings.TrimSpace(strings.ReplaceAll(reTags.ReplaceAllString(s, ""), "&nbsp;", " "))
}

func onlyDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func formatAnyID(v any) string {
	switch x := v.(type) {
	case string:
		return strings.TrimSpace(x)
	case float64:
		return strconv.FormatInt(int64(x), 10)
	case json.Number:
		return x.String()
	default:
		if v == nil {
			return ""
		}
		return fmt.Sprint(v)
	}
}

// FormatMB formats megabytes cleanly into MB or GB.
func FormatMB(mb float64) string {
	if mb >= 1024 {
		return fmt.Sprintf("%.1f GB (%.0f MB)", mb/1024.0, mb)
	}
	return fmt.Sprintf("%.1f MB", mb)
}

// FormatBytes formats bytes cleanly into MB or GB.
func FormatBytes(b int64) string {
	if b <= 0 {
		return "0 MB"
	}
	mb := float64(b) / (1024 * 1024)
	if mb >= 1024 {
		return fmt.Sprintf("%.1f GB", mb/1024.0)
	}
	return fmt.Sprintf("%.1f MB", mb)
}

func (c *Client) kooboneGetJSON(ctx context.Context, pathAndQuery string, dst any) error {
	for attempt := 0; attempt < 2; attempt++ {
		uin := c.getString(keyKoobUin)
		skey := c.getString(keyKoobSkey)
		if (uin == "" || skey == "") && attempt == 0 {
			if u, p, ok := c.StoredCredentials(); ok {
				if nu, ns, err := c.LoginKoobone(ctx, u, p); err == nil {
					uin, skey = nu, ns
				}
			}
		}

		fullURL := pathAndQuery
		if !strings.HasPrefix(pathAndQuery, "http") {
			u, err := url.Parse(c.KooboneURL + pathAndQuery)
			if err != nil {
				return err
			}
			q := u.Query()
			if q.Get("u") == "" && q.Get("uin") == "" && uin != "" {
				q.Set("u", uin)
			}
			u.RawQuery = q.Encode()
			fullURL = u.String()
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", userAgent)
		req.Header.Set("Referer", c.KooboneURL+"/web.htm")
		req.Header.Set("X-KAPI-FROM", "KOOBONE(Html)/6.2.0 Web(8) GET /web.htm")
		if skey != "" {
			req.Header.Set("X-KAPI-INFO", skey)
		}
		if ck := c.getString(keyKoobCookie); ck != "" {
			req.Header.Set("Cookie", ck)
		}

		resp, err := c.httpClient().Do(req)
		if err != nil {
			return err
		}
		c.captureCookies(resp, keyKoobCookie)
		raw, readErr := host.ReadAllLimited(resp.Body, host.MaxResponseBytes)
		resp.Body.Close()
		if readErr != nil {
			return readErr
		}

		var probe struct {
			Uin any `json:"uin"`
		}
		if json.Unmarshal(raw, &probe) == nil {
			idStr := formatAnyID(probe.Uin)
			if (idStr == "" || idStr == "0") && attempt == 0 {
				_ = c.setValue(keyKoobUin, nil)
				_ = c.setValue(keyKoobSkey, nil)
				if u, p, ok := c.StoredCredentials(); ok {
					_, _, _ = c.LoginKoobone(ctx, u, p)
					continue
				}
			}
		}
		if err := json.Unmarshal(raw, dst); err != nil {
			return fmt.Errorf("koobone: decoding response: %w", err)
		}
		return nil
	}
	return fmt.Errorf("koobone: unauthorized or session expired")
}

// DownloadStream opens a streaming HTTP GET for a Koobone EPUB URL.
func (c *Client) DownloadStream(ctx context.Context, fileURL string) (io.ReadCloser, int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fileURL, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Referer", c.KooboneURL+"/")
	req.Header.Set("X-KAPI-FROM", "KOOBONE(Html)/6.2.0 Web(8) FETCH /web.htm")
	if skey := c.getString(keyKoobSkey); skey != "" {
		req.Header.Set("X-KAPI-INFO", skey)
	}
	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, 0, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, 0, fmt.Errorf("koobone: unexpected HTTP %s downloading epub", resp.Status)
	}
	return resp.Body, resp.ContentLength, nil
}
