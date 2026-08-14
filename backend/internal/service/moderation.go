package service

import (
	"bytes"
	"context"
	"errors"
	"image"
	_ "image/jpeg" // decode format support for image.DecodeConfig below
	_ "image/png"
	"strings"
)

// ModerationCategory is one value from tekir's own fixed, bounded
// moderation vocabulary (issue #241's "settled architecture decision":
// "tekir owns the allow/reject policy" — a provider classifies content, but
// only ever against this application-owned set, never an open-ended vendor
// taxonomy). New categories are a product decision, not something an
// adapter can introduce on its own.
type ModerationCategory string

const (
	ModerationCategorySexual          ModerationCategory = "sexual"
	ModerationCategoryGraphicViolence ModerationCategory = "graphic_violence"
	ModerationCategoryHate            ModerationCategory = "hate"
	ModerationCategoryHarassment      ModerationCategory = "harassment"
	ModerationCategorySelfHarm        ModerationCategory = "self_harm"
	ModerationCategoryIllegalActivity ModerationCategory = "illegal_activity"
	ModerationCategoryAnimalCruelty   ModerationCategory = "animal_cruelty"
)

// moderationCategories is the closed set every adapter's structured-result
// parser validates against — an unrecognized category name in a provider's
// response is malformed output, not a new category (see
// CloudflareModerator's parser).
var moderationCategories = map[ModerationCategory]bool{
	ModerationCategorySexual:          true,
	ModerationCategoryGraphicViolence: true,
	ModerationCategoryHate:            true,
	ModerationCategoryHarassment:      true,
	ModerationCategorySelfHarm:        true,
	ModerationCategoryIllegalActivity: true,
	ModerationCategoryAnimalCruelty:   true,
}

// ModerationDecision is the application-owned contract every Moderator
// method normalizes its provider's raw output into (issue #241: "raw model
// prose is never a product contract"). Categories is informational/logging
// only — callers never surface it to a user (issue #241: "moderation
// categories ... are not user-visible").
type ModerationDecision struct {
	Allowed    bool
	Categories []ModerationCategory
}

// ErrContentRejected means a Moderator classified submitted content as
// falling under the application's reject policy. This is a stable,
// recoverable validation outcome (issue #241) — never a system failure —
// so it is always safe to map to a 4xx response the caller can act on
// (edit/replace/remove and retry), never retried automatically the way
// ErrModerationUnavailable is.
var ErrContentRejected = errors.New("content rejected by moderation")

// ErrModerationUnavailable means a Moderator could not produce a decision at
// all: a provider timeout, transport failure, or a structured result that
// failed strict parsing. Issue #241 requires all three to fail closed
// identically for the write in progress — nothing public is stored — and to
// surface as the same generic retryable answer any other backend dependency
// outage produces (docs/architecture/api.md), never a moderation-specific
// response shape that would hint at provider identity.
var ErrModerationUnavailable = errors.New("moderation unavailable")

// Moderator classifies user-submitted public content against tekir's
// application-owned policy before it is ever stored or published (issue
// #241). Implementations: FakeModerator (deterministic, local/test —
// MODERATION_PROVIDER=fake) and CloudflareModerator (production —
// MODERATION_PROVIDER=cloudflare). There is deliberately no runtime
// fallback from cloudflare to fake, mirroring every other provider pair in
// this package (ObjectStore, SmsSender, NotificationSender).
//
// Video is deliberately not a separate method: a video's contact sheet
// (issue #241's 3-frame, one-request design) is just another image by the
// time it reaches a Moderator — see mediaPipeline's video moderation call
// site in media.go.
type Moderator interface {
	// ModerateText classifies text (a cat name, an update/needs-help
	// comment). Callers skip this entirely for empty/whitespace-only
	// optional text (issue #241) — never call it with "".
	ModerateText(ctx context.Context, text string) (ModerationDecision, error)
	// ModerateImage classifies a fully processed, canonical image (or a
	// video's contact sheet) by its content type and bytes.
	ModerateImage(ctx context.Context, contentType string, data []byte) (ModerationDecision, error)
}

// moderationTextPrompt is the fixed, application-owned instruction sent to
// the configured text model (issue #241: "a fixed moderation prompt"). It is
// never exposed to a user or client — see Moderator's doc comment — and
// intentionally encodes tekir's own category vocabulary rather than
// deferring to whatever taxonomy the model would otherwise apply on its own.
const moderationTextPrompt = `You are a content-safety classifier for a public street-cat welfare app written in Turkish. Classify the user-submitted text below (a cat's name, or a short free-text note about a cat) against exactly this category list:
- sexual: sexual or explicit nudity content
- graphic_violence: graphic violence or gore
- hate: hate speech or extremist content
- harassment: harassment or credible threats against a person
- self_harm: self-harm content
- illegal_activity: illegal or clearly dangerous activity
- animal_cruelty: content that encourages, glorifies, or depicts gratuitous animal cruelty or abuse

Ordinary descriptions of a street cat's condition, injuries, needs, or location are always allowed, including when they mention an injury or illness in a factual, welfare-reporting way (e.g. "arka ayağı yaralı", "kulağı kesik") — this is the app's core purpose and must never be flagged as animal_cruelty.

Respond with only a single-line, strictly valid JSON object and nothing else, in exactly this shape:
{"decision":"allow"|"reject","categories":["category_a","category_b"]}
"decision" is "reject" if and only if at least one category from the list above genuinely applies; "categories" lists every category that applies (empty array when allowed). Never include any category not in the list above. Never include explanation, markdown, or any text outside this single JSON object.

Text to classify:
`

// moderationImagePrompt is the fixed, application-owned instruction sent to
// the configured vision model for a photo or a video's contact sheet (issue
// #241). The welfare-documentation exception is the one domain rule this
// issue calls out explicitly: "ordinary street-cat welfare documentation,
// including non-gratuitous visible injuries used to communicate that a cat
// needs help, is legitimate product content and must not be rejected merely
// because an animal is injured."
const moderationImagePrompt = `You are a content-safety classifier for a public street-cat welfare app. Classify the attached image against exactly this category list:
- sexual: sexual or explicit nudity content
- graphic_violence: graphic violence or gore
- hate: hate speech or extremist symbols/content
- harassment: harassment or credible threats against a person
- self_harm: self-harm content
- illegal_activity: illegal or clearly dangerous activity depicted
- animal_cruelty: gratuitous animal cruelty or abuse — deliberate harm being inflicted, or content that glorifies cruelty

A photo of a street cat that is injured, sick, thin, or in visibly poor condition is core, legitimate product content documenting that the cat needs help — this alone is never animal_cruelty and must never be rejected for showing a non-gratuitous visible injury. Only flag animal_cruelty for content depicting cruelty being inflicted or glorified, not for showing its aftermath in a documentary, welfare-reporting way. If the image is a contact sheet composed of multiple video frames, classify the combined sheet as a whole.

Respond with only a single-line, strictly valid JSON object and nothing else, in exactly this shape:
{"decision":"allow"|"reject","categories":["category_a","category_b"]}
"decision" is "reject" if and only if at least one category from the list above genuinely applies; "categories" lists every category that applies (empty array when allowed). Never include any category not in the list above. Never include explanation, markdown, or any text outside this single JSON object.`

// FakeModerator is the deterministic, no-network moderation provider used by
// local development and every automated test (MODERATION_PROVIDER=fake),
// mirroring FakeObjectStore/the fake OTP provider's role: no real model call
// is ever made. It does not attempt real-world content judgment — it decodes
// an explicit, deterministic trigger embedded in the input so tests can
// construct exact allow/reject/unavailable fixtures without a network
// dependency. Real policy enforcement lives in CloudflareModerator's fixed
// prompts, not here.
type FakeModerator struct{}

// FakeModerationRejectMarker returns the bracketed token that makes
// FakeModerator.ModerateText reject text containing it, classified under
// category. Exported so other packages' tests (handler, cmd) can build a
// "this text/comment must be rejected" fixture without duplicating the
// token table here.
func FakeModerationRejectMarker(category ModerationCategory) string {
	for token, c := range fakeModerationTextTriggers {
		if c == category {
			return token
		}
	}
	return ""
}

// fakeModerationTextTriggers maps an exact bracketed token to the decision
// FakeModerator returns when that token appears anywhere in the submitted
// text — a fixture convention, not a substring content-policy (that
// distinction matters: issue #241 rules out substring matching as
// production *policy*, which this fake never claims to implement). A real
// user's cat name or comment cannot collide with these by accident.
var fakeModerationTextTriggers = map[string]ModerationCategory{
	"[[moderation-test:sexual]]":           ModerationCategorySexual,
	"[[moderation-test:graphic_violence]]": ModerationCategoryGraphicViolence,
	"[[moderation-test:hate]]":             ModerationCategoryHate,
	"[[moderation-test:harassment]]":       ModerationCategoryHarassment,
	"[[moderation-test:self_harm]]":        ModerationCategorySelfHarm,
	"[[moderation-test:illegal_activity]]": ModerationCategoryIllegalActivity,
	"[[moderation-test:animal_cruelty]]":   ModerationCategoryAnimalCruelty,
}

// fakeModerationUnavailableTextTrigger makes FakeModerator return
// ErrModerationUnavailable, simulating a provider timeout or a malformed
// result surfacing from the fake path — both fail closed identically from a
// caller's perspective (see ErrModerationUnavailable's doc comment).
const fakeModerationUnavailableTextTrigger = "[[moderation-test:unavailable]]"

// ModerateText implements Moderator.
func (FakeModerator) ModerateText(ctx context.Context, text string) (ModerationDecision, error) {
	if ctx.Err() != nil {
		return ModerationDecision{}, ctx.Err()
	}
	if strings.Contains(text, fakeModerationUnavailableTextTrigger) {
		return ModerationDecision{}, ErrModerationUnavailable
	}
	for token, category := range fakeModerationTextTriggers {
		if strings.Contains(text, token) {
			return ModerationDecision{Allowed: false, Categories: []ModerationCategory{category}}, nil
		}
	}
	return ModerationDecision{Allowed: true}, nil
}

// fakeModerationImageDimensionTriggers maps a fixed (width, height) pair —
// values no real uploaded photo or generated contact sheet would ever
// happen to have — to the decision FakeModerator returns for an image of
// exactly that size. Dimensions are the one property mediaPipeline.process's
// re-encode always preserves exactly regardless of jpeg/png, so a test
// fixture only needs to construct an image of the right size, not
// pixel-exact content that would survive lossy jpeg re-encoding.
type fakeImageDimensions struct{ width, height int }

var fakeModerationImageDimensionTriggers = map[fakeImageDimensions]ModerationDecision{
	{4001, 4001}: {Allowed: false, Categories: []ModerationCategory{ModerationCategorySexual}},
	{4002, 4002}: {Allowed: false, Categories: []ModerationCategory{ModerationCategoryGraphicViolence}},
	{4003, 4003}: {Allowed: false, Categories: []ModerationCategory{ModerationCategoryHate}},
	{4004, 4004}: {Allowed: false, Categories: []ModerationCategory{ModerationCategoryHarassment}},
	{4005, 4005}: {Allowed: false, Categories: []ModerationCategory{ModerationCategorySelfHarm}},
	{4006, 4006}: {Allowed: false, Categories: []ModerationCategory{ModerationCategoryIllegalActivity}},
	// A gratuitous animal-cruelty fixture: rejected.
	{4007, 4007}: {Allowed: false, Categories: []ModerationCategory{ModerationCategoryAnimalCruelty}},
	// The domain exception fixture (issue #241): a legitimate injured-cat
	// welfare photo is allowed despite depicting a visible injury.
	{4008, 4008}: {Allowed: true},
}

// fakeModerationUnavailableImageDimensions simulates a provider
// timeout/malformed-result failure for an image of exactly this size — the
// image-side equivalent of fakeModerationUnavailableTextTrigger.
var fakeModerationUnavailableImageDimensions = fakeImageDimensions{4009, 4009}

// ModerateImage implements Moderator.
func (FakeModerator) ModerateImage(ctx context.Context, contentType string, data []byte) (ModerationDecision, error) {
	if ctx.Err() != nil {
		return ModerationDecision{}, ctx.Err()
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		// Not this Moderator's job to validate image structure — mediaPipeline
		// already did that before calling in. An undecodable buffer here is a
		// wiring bug, not a user-facing outcome; fail closed rather than guess.
		return ModerationDecision{}, ErrModerationUnavailable
	}
	dims := fakeImageDimensions{cfg.Width, cfg.Height}
	if dims == fakeModerationUnavailableImageDimensions {
		return ModerationDecision{}, ErrModerationUnavailable
	}
	if decision, ok := fakeModerationImageDimensionTriggers[dims]; ok {
		return decision, nil
	}
	return ModerationDecision{Allowed: true}, nil
}
