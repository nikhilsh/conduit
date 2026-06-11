package push

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// unifiedPushSender delivers push notifications for the "unifiedpush"
// platform. For UnifiedPush the device registers its distributor endpoint
// URL as the token; we POST directly to it — no vendor hop.
//
// Wire format (UnifiedPush spec: ≤4 KB arbitrary JSON body):
//
//	POST <distributorURL>
//	{"title":"…","body":"…","session_id":"…"}
//
// Permanent 4xx (404 / 410) → ErrTokenGone (the distributor is gone or
// the registration was revoked). Transient errors are retried once.
type unifiedPushSender struct {
	httpClient *http.Client
}

// unifiedPushPayload is the small body posted to the distributor.
type unifiedPushPayload struct {
	Title     string `json:"title"`
	Body      string `json:"body"`
	SessionID string `json:"session_id,omitempty"`
}

// NewUnifiedPushSender constructs an unifiedPushSender. No configuration
// needed: the distributor URL is carried in each DeviceToken.Token.
func NewUnifiedPushSender() Sender {
	return &unifiedPushSender{
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

func (s *unifiedPushSender) Send(ctx context.Context, token DeviceToken, payload Payload) error {
	endpoint := strings.TrimSpace(token.Token)
	if !isHTTPURL(endpoint) {
		// Caller registered a non-URL token for unifiedpush — reject it
		// as permanently invalid so the registry prunes it.
		log.Printf("push unifiedpush: token is not a valid http(s) URL (pruning): %q", endpoint)
		return ErrTokenGone
	}

	body := unifiedPushPayload{Title: payload.Title, Body: payload.Body, SessionID: payload.SessionID}

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		lastErr = s.doSend(ctx, endpoint, body)
		if lastErr == nil {
			return nil
		}
		if errors.Is(lastErr, ErrTokenGone) {
			return ErrTokenGone
		}
		// Only retry on network / 5xx errors.
		var httpErr *upHTTPError
		if errors.As(lastErr, &httpErr) && httpErr.statusCode < 500 {
			return lastErr
		}
	}
	log.Printf("push unifiedpush: send failed after retry: %v", lastErr)
	return lastErr
}

func (s *unifiedPushSender) doSend(ctx context.Context, endpoint string, body unifiedPushPayload) error {
	b, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("push unifiedpush: marshal: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(b))
	if err != nil {
		return fmt.Errorf("push unifiedpush: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("push unifiedpush: http: %w", err)
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		// The distributor endpoint is permanently gone.
		return ErrTokenGone
	default:
		return &upHTTPError{statusCode: resp.StatusCode}
	}
}

// isHTTPURL reports whether s is a valid http or https URL.
func isHTTPURL(s string) bool {
	u, err := url.Parse(s)
	if err != nil {
		return false
	}
	return u.Scheme == "http" || u.Scheme == "https"
}

type upHTTPError struct{ statusCode int }

func (e *upHTTPError) Error() string {
	return fmt.Sprintf("push unifiedpush: HTTP %d", e.statusCode)
}
