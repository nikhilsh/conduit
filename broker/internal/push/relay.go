package push

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// relaySender delivers push notifications via the conduit vendor relay
// (CONDUIT_PUSH_RELAY_URL). The relay holds the APNs .p8 / FCM service-
// account key so the broker binary never embeds them. Used for both
// PlatformAPNs (iOS) and PlatformFCM (Android fallback).
//
// Wire format:
//
//	POST <relay>/v1/send
//	{
//	  "install_id":     "<32-hex>",
//	  "install_secret": "<48-hex>",
//	  "platform":       "apns"|"fcm",
//	  "token":          "<device-token>",
//	  "env":            "production",
//	  "payload": {
//	    "title":      "...",
//	    "body":       "...",
//	    "session_id": "...",
//	    "category":   ""
//	  }
//	}
type relaySender struct {
	relayURL   string
	installID  string
	installSec string
	httpClient *http.Client
}

// relaySendBody is the JSON body posted to <relay>/v1/send.
type relaySendBody struct {
	InstallID     string     `json:"install_id"`
	InstallSecret string     `json:"install_secret"`
	Platform      string     `json:"platform"`
	Token         string     `json:"token"`
	Env           string     `json:"env"`
	Payload       relayInner `json:"payload"`
}

type relayInner struct {
	Title     string `json:"title"`
	Body      string `json:"body"`
	SessionID string `json:"session_id"`
	Category  string `json:"category"`
}

// NewRelaySender builds a relaySender. relayURL is the base URL of the
// vendor relay (e.g. "https://push.conduit.nikhil.sh"). installCredFile
// is the path to ~/.conduit/push-install.json where the per-install
// id+secret is persisted; it is created on first use.
//
// Returns nil (no sender, no error) when relayURL is empty so callers
// can skip construction when the relay is not configured.
func NewRelaySender(relayURL, installCredFile string) (Sender, error) {
	if relayURL == "" {
		return nil, nil
	}
	cred, err := loadOrMintInstallCred(installCredFile)
	if err != nil {
		return nil, fmt.Errorf("push relay: install cred: %w", err)
	}
	return &relaySender{
		relayURL:   relayURL,
		installID:  cred.InstallID,
		installSec: cred.InstallSecret,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}, nil
}

func (s *relaySender) Send(ctx context.Context, token DeviceToken, payload Payload) error {
	body := relaySendBody{
		InstallID:     s.installID,
		InstallSecret: s.installSec,
		Platform:      string(token.Platform),
		Token:         token.Token,
		Env:           "production",
		Payload: relayInner{
			Title:     payload.Title,
			Body:      payload.Body,
			SessionID: payload.SessionID,
			Category:  "",
		},
	}

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		lastErr = s.doSend(ctx, body)
		if lastErr == nil {
			return nil
		}
		if errors.Is(lastErr, ErrTokenGone) {
			return ErrTokenGone
		}
		// 429: rate-limited — log and return (don't retry).
		var rateLimitErr *relayRateLimitError
		if errors.As(lastErr, &rateLimitErr) {
			log.Printf("push relay: rate limited (429) platform=%s", token.Platform)
			return lastErr
		}
		// 4xx client error: don't retry.
		var httpErr *relayHTTPError
		if errors.As(lastErr, &httpErr) && httpErr.statusCode < 500 {
			return lastErr
		}
		// Network / 5xx: fall through to retry (first iteration only).
	}
	log.Printf("push relay: send failed after retry platform=%s: %v", token.Platform, lastErr)
	return lastErr
}

func (s *relaySender) doSend(ctx context.Context, body relaySendBody) error {
	b, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("push relay: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.relayURL+"/v1/send", bytes.NewReader(b))
	if err != nil {
		return fmt.Errorf("push relay: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("push relay: http: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusOK:
		return nil
	case resp.StatusCode == http.StatusGone:
		// Relay echoes APNs/FCM "device token no longer valid".
		return ErrTokenGone
	case resp.StatusCode == http.StatusTooManyRequests:
		return &relayRateLimitError{statusCode: resp.StatusCode}
	default:
		return &relayHTTPError{statusCode: resp.StatusCode}
	}
}

type relayHTTPError struct{ statusCode int }

func (e *relayHTTPError) Error() string {
	return fmt.Sprintf("push relay: HTTP %d", e.statusCode)
}

type relayRateLimitError struct{ statusCode int }

func (e *relayRateLimitError) Error() string {
	return fmt.Sprintf("push relay: rate limited (HTTP %d)", e.statusCode)
}

// installCred is the per-installation identity persisted under
// ~/.conduit/push-install.json. Minted once on first use; reused across
// restarts. The relay uses (install_id, install_secret) for per-install
// rate limiting and authorization.
//
// install_id:     32 hex chars (16 random bytes).
// install_secret: 48 hex chars (24 random bytes).
type installCred struct {
	InstallID     string `json:"install_id"`
	InstallSecret string `json:"install_secret"`
}

// loadOrMintInstallCred reads the persisted install credential from path,
// or mints a fresh one and writes it at mode 0600.
func loadOrMintInstallCred(path string) (*installCred, error) {
	if path == "" {
		return nil, errors.New("push relay: empty install cred path")
	}
	if data, err := os.ReadFile(path); err == nil {
		var c installCred
		if err2 := json.Unmarshal(data, &c); err2 == nil && c.InstallID != "" && c.InstallSecret != "" {
			return &c, nil
		}
	}
	// Mint fresh.
	idBytes := make([]byte, 16)
	secBytes := make([]byte, 24)
	if _, err := rand.Read(idBytes); err != nil {
		return nil, fmt.Errorf("push relay: rand id: %w", err)
	}
	if _, err := rand.Read(secBytes); err != nil {
		return nil, fmt.Errorf("push relay: rand secret: %w", err)
	}
	cred := &installCred{
		InstallID:     hex.EncodeToString(idBytes),
		InstallSecret: hex.EncodeToString(secBytes),
	}
	data, err := json.Marshal(cred)
	if err != nil {
		return nil, err
	}
	if err := writeFile600(path, data); err != nil {
		return nil, fmt.Errorf("push relay: persist install cred: %w", err)
	}
	return cred, nil
}

// writeFile600 writes data to path with mode 0600. Not atomic: the
// install cred is written once on first use and never overwritten.
func writeFile600(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr != nil {
		return werr
	}
	return cerr
}
