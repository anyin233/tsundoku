package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/ohaiibuzzle/aidokurunner-go/kox"
	"github.com/ohaiibuzzle/aidokurunner-go/settingsstore"
)

type kooboneDownloadPayload struct {
	Volume       kox.KooboneVolume `json:"volume"`
	SourcePath   string            `json:"sourcePath"`
	OutputPath   string            `json:"outputPath"`
	DownloadsDir string            `json:"downloadsDir"`
	MangaDirName string            `json:"mangaDirName"`
	Redownload   bool              `json:"redownload"`
}

func handleKox(ctx context.Context, settings *settingsstore.Store, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: kox <login|logout|status|push-koobone> [args...]")
	}
	client := kox.NewClient(settings)

	switch args[0] {
	case "login":
		if len(args) < 3 {
			return fmt.Errorf("usage: kox login <email> <password>")
		}
		st, err := client.Login(ctx, args[1], args[2])
		if err != nil {
			return err
		}
		return printJSON(st)

	case "logout":
		if err := client.Logout(); err != nil {
			return err
		}
		return printJSON(map[string]any{"ok": true, "logged_in": false})

	case "status":
		if len(args) > 1 && args[1] == "cached" {
			if st := client.CachedStatus(); st != nil {
				return printJSON(st)
			}
			return printJSON(&kox.UserStatus{LoggedIn: client.IsLoggedIn()})
		}
		st, err := client.FetchStatus(ctx)
		if err != nil {
			return err
		}
		return printJSON(st)

	case "push-koobone":
		if len(args) < 3 {
			return fmt.Errorf("usage: kox push-koobone <bookid> <volid1[,volid2...]>")
		}
		volIDs := strings.Split(args[2], ",")
		var cleaned []string
		for _, v := range volIDs {
			if v = strings.TrimSpace(v); v != "" {
				cleaned = append(cleaned, v)
			}
		}
		msg, err := client.PushToKoobone(ctx, args[1], cleaned)
		if err != nil {
			return err
		}
		return printJSON(map[string]any{"ok": true, "message": msg})

	default:
		return fmt.Errorf("unknown kox subcommand %q (want login|logout|status|push-koobone)", args[0])
	}
}

func handleKoobone(ctx context.Context, settings *settingsstore.Store, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: koobone <uinfo|series|vols|all-vols|download-payload> [args...]")
	}
	client := kox.NewClient(settings)

	switch args[0] {
	case "uinfo":
		info, err := client.FetchKooboneUserInfo(ctx)
		if err != nil {
			return err
		}
		return printJSON(info)

	case "series":
		page := 1
		if len(args) > 1 && args[1] != "" {
			if p, err := strconv.Atoi(args[1]); err == nil && p > 0 {
				page = p
			}
		}
		res, err := client.ListKooboneSeries(ctx, page, 49)
		if err != nil {
			return err
		}
		return printJSON(res)

	case "vols":
		page := 1
		if len(args) > 1 && args[1] != "" {
			if p, err := strconv.Atoi(args[1]); err == nil && p > 0 {
				page = p
			}
		}
		seriesID := ""
		if len(args) > 2 {
			seriesID = args[2]
		}
		seriesName := ""
		if len(args) > 3 {
			seriesName = args[3]
		}
		search := ""
		if len(args) > 4 {
			search = args[4]
		}
		liked := len(args) > 5 && (args[5] == "1" || args[5] == "true")
		res, err := client.ListKooboneVolumes(ctx, page, 100, seriesID, seriesName, search, liked)
		if err != nil {
			return err
		}
		return printJSON(res)

	case "all-vols":
		seriesID := ""
		if len(args) > 1 {
			seriesID = args[1]
		}
		seriesName := ""
		if len(args) > 2 {
			seriesName = args[2]
		}
		liked := len(args) > 3 && (args[3] == "1" || args[3] == "true")
		vols, err := client.ListAllKooboneVolumes(ctx, seriesID, seriesName, liked)
		if err != nil {
			return err
		}
		return printJSON(map[string]any{
			"total": len(vols),
			"data":  vols,
		})

	case "download-payload":
		if len(args) < 2 {
			return fmt.Errorf("usage: koobone download-payload <payload.json>")
		}
		data, err := os.ReadFile(args[1])
		if err != nil {
			return fmt.Errorf("reading koobone download payload: %w", err)
		}
		var p kooboneDownloadPayload
		if err := json.Unmarshal(data, &p); err != nil {
			return fmt.Errorf("parsing koobone download payload: %w", err)
		}
		if p.Volume.FileMD5 == "" {
			return fmt.Errorf("koobone download payload requires volume.file_md5")
		}
		outPath, err := client.DownloadKooboneVolumeCBZ(
			ctx,
			p.Volume,
			p.SourcePath,
			p.OutputPath,
			p.DownloadsDir,
			p.MangaDirName,
			p.Redownload,
			printDownloadProgress,
		)
		if err != nil {
			return err
		}
		fmt.Println(outPath)
		return nil

	default:
		return fmt.Errorf("unknown koobone subcommand %q (want uinfo|series|vols|all-vols|download-payload)", args[0])
	}
}
