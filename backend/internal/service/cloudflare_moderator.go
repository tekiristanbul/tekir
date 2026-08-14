package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

const (
	// cloudflareModerationDefaultTimeout bounds one outbound attempt to
	// Workers AI. Generous relative to s3DefaultTimeout: a vision model call
	// carries an image payload and can run measurably slower than a text
	// call, and issue #241 requires the composer to stay responsive around
	// this call rather than for the call itself to be fast.
	cloudflareModerationDefaultTimeout = 20 * time.Second
	// cloudflareModerationRetryDelay separates the single retry from the
	// failed attempt, mirroring s3RetryDelay.
	cloudflareModerationRetryDelay = 250 * time.Millisecond
	// cloudflareModerationMaxResponseBytes bounds how much of a Workers AI
	// response is ever read — a runaway or malicious response body can never
	// force an unbounded allocation.
	cloudflareModerationMaxResponseBytes = 1 << 20
	// cloudflareModerationAPIBase is Cloudflare's fixed Workers AI REST
	// endpoint base. Never itself configuration — only the account id, api
	// token, and model slugs are (issue #241: "model identifiers remain
	// configuration, not public api/domain concepts").
	cloudflareModerationAPIBase = "https://api.cloudflare.com/client/v4/accounts"
)

// CloudflareModerator is the production Moderator implementation (issue
// #241's settled architecture decision): it calls Cloudflare Workers AI's
// REST inference endpoint with the configured text/vision model slugs and
// this package's fixed moderationTextPrompt/moderationImagePrompt, then
// strictly parses the model's own reply as {"decision":...,"categories":
// [...]}. Malformed output, a timeout, or a transport failure all fail
// closed as ErrModerationUnavailable — never a silent allow, and never a
// fallback to FakeModerator (mirrors every other real/fake provider pair in
// this package: no runtime fallback, ever).
//
// The exact Workers AI request/response envelope for a given model slug is
// deployment configuration (MODERATION_TEXT_MODEL/MODERATION_VISION_MODEL),
// not something this adapter can fully pin down without a live account —
// issue #241 deliberately keeps a live-model call out of normal ci and
// startup, and instead requires a separate, manually-triggered smoke suite
// to verify the configured slugs, request schema, and structured-result
// parsing against the real api before a release ships this provider.
type CloudflareModerator struct {
	client      *http.Client
	logger      *slog.Logger
	accountID   string
	apiToken    string
	textModel   string
	visionModel string
	apiBase     string
	timeout     time.Duration
	retryDelay  time.Duration
}

// CloudflareModeratorOption configures optional CloudflareModerator behavior.
type CloudflareModeratorOption func(*CloudflareModerator)

// WithCloudflareModerationTimeout overrides the per-attempt request timeout.
func WithCloudflareModerationTimeout(d time.Duration) CloudflareModeratorOption {
	return func(m *CloudflareModerator) { m.timeout = d }
}

// WithCloudflareModerationRetryDelay overrides the delay before the single
// retry — tests set it to zero.
func WithCloudflareModerationRetryDelay(d time.Duration) CloudflareModeratorOption {
	return func(m *CloudflareModerator) { m.retryDelay = d }
}

// WithCloudflareModerationLogger overrides the logger — tests use it to
// assert redaction.
func WithCloudflareModerationLogger(l *slog.Logger) CloudflareModeratorOption {
	return func(m *CloudflareModerator) { m.logger = l }
}

// WithCloudflareModerationHTTPClient overrides the http client — tests
// point it at a local httptest server.
func WithCloudflareModerationHTTPClient(c *http.Client) CloudflareModeratorOption {
	return func(m *CloudflareModerator) { m.client = c }
}

// WithCloudflareModerationAPIBase overrides the Workers AI api base url —
// tests point it at a local httptest server instead of the real Cloudflare
// endpoint.
func WithCloudflareModerationAPIBase(base string) CloudflareModeratorOption {
	return func(m *CloudflareModerator) { m.apiBase = base }
}

// NewCloudflareModerator validates that every required setting is present —
// selecting cloudflare with an incomplete configuration must fail startup,
// not degrade at runtime (issue #241). Errors name the offending variable
// but never echo a configured secret value.
func NewCloudflareModerator(accountID, apiToken, textModel, visionModel string, opts ...CloudflareModeratorOption) (*CloudflareModerator, error) {
	var missing []string
	if accountID == "" {
		missing = append(missing, "CLOUDFLARE_ACCOUNT_ID")
	}
	if apiToken == "" {
		missing = append(missing, "CLOUDFLARE_API_TOKEN")
	}
	if textModel == "" {
		missing = append(missing, "MODERATION_TEXT_MODEL")
	}
	if visionModel == "" {
		missing = append(missing, "MODERATION_VISION_MODEL")
	}
	if len(missing) > 0 {
		return nil, errors.New("cloudflare moderator: missing required settings: " + strings.Join(missing, ", "))
	}

	m := &CloudflareModerator{
		client:      &http.Client{},
		logger:      slog.Default(),
		accountID:   accountID,
		apiToken:    apiToken,
		textModel:   textModel,
		visionModel: visionModel,
		apiBase:     cloudflareModerationAPIBase,
		timeout:     cloudflareModerationDefaultTimeout,
		retryDelay:  cloudflareModerationRetryDelay,
	}
	for _, opt := range opts {
		opt(m)
	}
	return m, nil
}

// cloudflareChatRequest is the Workers AI request body for a text-generation
// model (issue #241's MODERATION_TEXT_MODEL, e.g. an instruct-tuned llm):
// one fixed user message combining moderationTextPrompt and the text being
// classified.
type cloudflareChatRequest struct {
	Messages []cloudflareChatMessage `json:"messages"`
}

type cloudflareChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// cloudflareVisionRequest is the Workers AI request body for a vision model
// (issue #241's MODERATION_VISION_MODEL): the image as a byte array plus the
// fixed moderationImagePrompt.
type cloudflareVisionRequest struct {
	Image  []int  `json:"image"`
	Prompt string `json:"prompt"`
}

// cloudflareRunResponse is Workers AI's fixed response envelope, common to
// every model class. result is decoded separately per call (chat vs vision
// models put the model's own text reply under a different field name), so
// it stays raw json here.
type cloudflareRunResponse struct {
	Success bool              `json:"success"`
	Errors  []cloudflareError `json:"errors"`
	Result  json.RawMessage   `json:"result"`
}

type cloudflareError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// cloudflareRunResult covers the field names Workers AI models are known to
// put a generated text reply under, across model classes — this adapter
// tries them in order and uses the first non-empty match. The model's own
// reply is expected to be, verbatim, the strict single-line json this
// package's fixed prompts require (see parseModerationResult).
type cloudflareRunResult struct {
	Response    string `json:"response"`
	Description string `json:"description"`
	Text        string `json:"text"`
}

func (r cloudflareRunResult) text() string {
	switch {
	case r.Response != "":
		return r.Response
	case r.Description != "":
		return r.Description
	default:
		return r.Text
	}
}

// ModerateText implements Moderator.
func (m *CloudflareModerator) ModerateText(ctx context.Context, text string) (ModerationDecision, error) {
	body, err := json.Marshal(cloudflareChatRequest{
		Messages: []cloudflareChatMessage{
			{Role: "user", Content: moderationTextPrompt + text},
		},
	})
	if err != nil {
		return ModerationDecision{}, fmt.Errorf("%w: encode text request: %v", ErrModerationUnavailable, err)
	}
	return m.run(ctx, m.textModel, body)
}

// ModerateImage implements Moderator.
func (m *CloudflareModerator) ModerateImage(ctx context.Context, contentType string, data []byte) (ModerationDecision, error) {
	pixels := make([]int, len(data))
	for i, b := range data {
		pixels[i] = int(b)
	}
	body, err := json.Marshal(cloudflareVisionRequest{Image: pixels, Prompt: moderationImagePrompt})
	if err != nil {
		return ModerationDecision{}, fmt.Errorf("%w: encode image request: %v", ErrModerationUnavailable, err)
	}
	return m.run(ctx, m.visionModel, body)
}

// run executes one Workers AI inference call against model with at most one
// retry (mirrors S3ObjectStore.do: a moderation call is a read-only
// classification with no side effect, so retrying a timeout is safe, unlike
// TwilioVerifier's never-retry-a-timeout rule for an sms send), then strictly
// parses the model's own text reply as this package's fixed
// {"decision":...,"categories":[...]} contract. Any failure at any stage —
// transport, non-2xx, malformed envelope, or malformed model reply — fails
// closed as ErrModerationUnavailable; provider identity, model slugs, and
// raw model output are never included in the returned error or logged
// verbatim (issue #241: "raw ai output ... [is] not user-visible", and this
// package's convention of never leaking vendor detail into an error a caller
// could propagate).
func (m *CloudflareModerator) run(ctx context.Context, model string, body []byte) (ModerationDecision, error) {
	respBody, err := m.do(ctx, model, body)
	if err != nil {
		return ModerationDecision{}, err
	}

	var envelope cloudflareRunResponse
	if err := json.Unmarshal(respBody, &envelope); err != nil {
		m.logger.Warn("cloudflare moderation: malformed response envelope", "model", model)
		return ModerationDecision{}, ErrModerationUnavailable
	}
	if !envelope.Success {
		m.logger.Warn("cloudflare moderation: request unsuccessful", "model", model, "error_count", len(envelope.Errors))
		return ModerationDecision{}, ErrModerationUnavailable
	}

	var result cloudflareRunResult
	if err := json.Unmarshal(envelope.Result, &result); err != nil {
		m.logger.Warn("cloudflare moderation: malformed result field", "model", model)
		return ModerationDecision{}, ErrModerationUnavailable
	}

	decision, err := parseModerationResult(result.text())
	if err != nil {
		m.logger.Warn("cloudflare moderation: malformed structured result", "model", model)
		return ModerationDecision{}, ErrModerationUnavailable
	}
	return decision, nil
}

// moderationResultJSON is the strict shape this package's fixed prompts
// require a model to reply with — see moderationTextPrompt/
// moderationImagePrompt. Anything that doesn't parse into exactly this
// shape, with every category from the reject list drawn from
// moderationCategories, is malformed output (issue #241: "parse the
// configured structured result strictly; malformed/unparseable output fails
// closed").
type moderationResultJSON struct {
	Decision   string   `json:"decision"`
	Categories []string `json:"categories"`
}

// parseModerationResult strictly parses a model's raw text reply into
// ModerationDecision. raw is trimmed of surrounding whitespace/code-fence
// noise a model might still add despite the prompt's instruction not to —
// tolerated only at the edges, never inside the json itself.
func parseModerationResult(raw string) (ModerationDecision, error) {
	trimmed := strings.TrimSpace(raw)
	trimmed = strings.TrimPrefix(trimmed, "```json")
	trimmed = strings.TrimPrefix(trimmed, "```")
	trimmed = strings.TrimSuffix(trimmed, "```")
	trimmed = strings.TrimSpace(trimmed)

	var parsed moderationResultJSON
	dec := json.NewDecoder(strings.NewReader(trimmed))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&parsed); err != nil {
		return ModerationDecision{}, fmt.Errorf("malformed moderation result: %w", err)
	}

	var categories []ModerationCategory
	for _, c := range parsed.Categories {
		category := ModerationCategory(c)
		if !moderationCategories[category] {
			return ModerationDecision{}, fmt.Errorf("malformed moderation result: unrecognized category %q", c)
		}
		categories = append(categories, category)
	}

	switch parsed.Decision {
	case "allow":
		return ModerationDecision{Allowed: true, Categories: categories}, nil
	case "reject":
		if len(categories) == 0 {
			return ModerationDecision{}, errors.New("malformed moderation result: reject with no categories")
		}
		return ModerationDecision{Allowed: false, Categories: categories}, nil
	default:
		return ModerationDecision{}, fmt.Errorf("malformed moderation result: unrecognized decision %q", parsed.Decision)
	}
}

// do runs one Workers AI http call with at most one retry, exactly mirroring
// S3ObjectStore.do's retry/timeout/cancellation semantics.
func (m *CloudflareModerator) do(ctx context.Context, model string, body []byte) ([]byte, error) {
	const maxAttempts = 2
	for attempt := 1; ; attempt++ {
		respBody, status, err := m.doOnce(ctx, model, body)
		retryable := (err == nil && (status >= 500 || status == http.StatusTooManyRequests)) || (err != nil && ctx.Err() == nil)
		if !retryable {
			if err != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				m.logger.Warn("cloudflare moderation request failed", "model", model, "attempt", attempt, "error_kind", errorKind(err))
				return nil, ErrModerationUnavailable
			}
			if status/100 != 2 {
				m.logger.Warn("cloudflare moderation request failed", "model", model, "http_status", status)
				return nil, ErrModerationUnavailable
			}
			return respBody, nil
		}
		if attempt >= maxAttempts {
			if err != nil {
				m.logger.Warn("cloudflare moderation unavailable after retry", "model", model, "error_kind", errorKind(err))
				return nil, ErrModerationUnavailable
			}
			m.logger.Warn("cloudflare moderation unavailable after retry", "model", model, "http_status", status)
			return nil, ErrModerationUnavailable
		}
		if m.retryDelay > 0 {
			timer := time.NewTimer(m.retryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			case <-timer.C:
			}
		}
	}
}

func (m *CloudflareModerator) doOnce(ctx context.Context, model string, body []byte) ([]byte, int, error) {
	reqCtx, cancel := context.WithTimeout(ctx, m.timeout)
	defer cancel()

	url := m.apiBase + "/" + m.accountID + "/ai/run/" + model
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+m.apiToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := m.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, cloudflareModerationMaxResponseBytes))
	if err != nil {
		return nil, 0, err
	}
	return respBody, resp.StatusCode, nil
}
