package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"syscall"
	"time"
	"unsafe"

	"windows-reencode-utility/src/internal/config"
	"windows-reencode-utility/src/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/sys/windows"
)

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	kernel32                = windows.NewLazySystemDLL("kernel32.dll")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procGetConsoleWindow    = kernel32.NewProc("GetConsoleWindow")
	procMessageBoxW         = user32.NewProc("MessageBoxW")
)

const pipeName = `\\.\pipe\windows-reencode-utility`

type pipeMessage struct {
	Action string   `json:"action"`
	Paths  []string `json:"paths"`
}

func showHelp() {
	helpText := `
================================================================================
  Windows-ReEncodeUtility (Go + Bubble Tea TUI 版)
================================================================================

【概要】
  モダンな Bubble Tea TUI フレームワークを採用した高速・多機能な動画再エンコードツールです。
  4大モード（通常、プラットフォーム向け、中間ファイル作成、チャプター/字幕分割）を
  1画面完結のダッシュボードから直感的に操作できます。

【使用方法】
  ReEncodeUtility.exe [オプション] [動画ファイルまたはフォルダのパス...]

【オプション】
  -h, --help    この詳しいヘルプメッセージを表示して終了します。

【キー操作体系】
  Tab           左ペイン (キュー一覧) と 右ペイン (設定パネル) のフォーカス切替
  ↑ / ↓         項目移動 / 選択肢の切り替え
  Ctrl+↑ / ↓    キュー内動画の順序入替
  Del           選択した動画をキューから削除
  Space         エンコードの一時停止 / 再開
  Enter         エンコード開始 / ダイアログ決定 / 完了時終了
  Esc           ダイアログを閉じる / エンコード中断 / 終了
  Alt+D         詳細設定・リソース制御の展開 / 折りたたみ
  F1            ヘルプモーダルの表示
  F2            右クリックメニュー / SendTo 連携登録ダイアログ
  F3            インライン・ログコンソールの展開 / 折りたたみ
  F4            テンプレート読込ダイアログ
  F5            現在の設定をテンプレートとして保存

【4大エンコードモード】
  1. 通常モード (General): フルパラメータ（HWデコード/エンコード/品質/速度/音声等）直接設定
  2. プラットフォーム向け (Platform): Twitter, Discord, catbox 等の容量制限に合わせた自動逆算設定
  3. 中間ファイル作成 (Intermediate): ProRes 422 HQ / DNxHR / FFV1 高画質・ロスレス作成
  4. 分割モード (Split): チャプターや SRT 字幕に基づくセグメント個別切り出し＆エンコード

================================================================================
`
	fmt.Println(helpText)
}

func showErrorMessageBox(title, message string) {
	titlePtr, _ := syscall.UTF16PtrFromString(title)
	msgPtr, _ := syscall.UTF16PtrFromString(message)
	_, _, _ = procMessageBoxW.Call(0, uintptr(unsafe.Pointer(msgPtr)), uintptr(unsafe.Pointer(titlePtr)), 0x10) // MB_ICONERROR
}

func main() {
	// 1. Argument parsing
	args := os.Args[1:]
	var targetPaths []string

	for _, arg := range args {
		if arg == "-h" || arg == "--help" || arg == "/?" {
			showHelp()
			return
		}
		targetPaths = append(targetPaths, arg)
	}

	// 2. Multi-instance Named Pipe check (Specification 5.16)
	if trySendToExistingInstance(targetPaths) {
		// Successfully sent paths to existing IDLE instance; exit new process
		return
	}

	// 3. Load or generate configuration
	cfg, err := config.LoadConfig()
	if err != nil {
		showErrorMessageBox("起動エラー - Windows-ReEncodeUtility", fmt.Sprintf("設定ファイルまたは実行フォルダの初期化に失敗しました:\n%s\n\nアプリケーションを終了します。", err))
		fmt.Fprintf(os.Stderr, "エラー: %v\n", err)
		os.Exit(1)
	}

	// 4. Initialize Bubble Tea Program
	model := ui.NewMainModel(cfg, targetPaths)
	p := tea.NewProgram(
		model,
		tea.WithAltScreen(),
		tea.WithMouseCellMotion(),
	)

	// 5. Start background Named Pipe server
	go startNamedPipeServer(p)

	// 6. Run TUI
	if _, errRun := p.Run(); errRun != nil {
		fmt.Fprintf(os.Stderr, "TUI実行エラー: %v\n", errRun)
		os.Exit(1)
	}
}

func trySendToExistingInstance(paths []string) bool {
	if len(paths) == 0 {
		return false
	}

	conn, err := net.Dial("pipe", pipeName)
	if err != nil {
		return false
	}
	defer conn.Close()

	msg := pipeMessage{
		Action: "add_queue",
		Paths:  paths,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return false
	}

	_, err = conn.Write(append(data, '\n'))
	return err == nil
}

func startNamedPipeServer(p *tea.Program) {
	pipePath := `\\.\pipe\windows-reencode-utility`
	pathPtr, _ := syscall.UTF16PtrFromString(pipePath)

	for {
		handle, err := windows.CreateNamedPipe(
			pathPtr,
			windows.PIPE_ACCESS_DUPLEX,
			windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_WAIT,
			windows.PIPE_UNLIMITED_INSTANCES,
			4096,
			4096,
			0,
			nil,
		)
		if err != nil {
			time.Sleep(1 * time.Second)
			continue
		}

		err = windows.ConnectNamedPipe(handle, nil)
		if err == nil {
			go handlePipeClient(handle, p)
		} else {
			_ = windows.CloseHandle(handle)
		}
	}
}

func handlePipeClient(handle windows.Handle, p *tea.Program) {
	file := os.NewFile(uintptr(handle), "pipe")
	defer file.Close()

	scanner := bufio.NewScanner(file)
	if scanner.Scan() {
		line := scanner.Text()
		var msg pipeMessage
		if err := json.Unmarshal([]byte(line), &msg); err == nil && msg.Action == "add_queue" {
			p.Send(ui.NamedPipeAddMsg{Paths: msg.Paths})

			// Bring console window to foreground
			hwnd, _, _ := procGetConsoleWindow.Call()
			if hwnd != 0 {
				_, _, _ = procSetForegroundWindow.Call(hwnd)
			}
		}
	}
}
