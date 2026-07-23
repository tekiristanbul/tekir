package handler

import (
	"net/http"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type TraitsHandler struct {
	traits *service.TraitsService
}

func NewTraitsHandler(traits *service.TraitsService) *TraitsHandler {
	return &TraitsHandler{traits: traits}
}

// traitVocabResponse extends traitResponse with group metadata (issue #23)
// so a future grouped multi-select picker can render section headers
// without a second fetch. Backward compatible with the pre-#23 shape: key
// and label are unchanged, group_key/group_label are additive and null for
// an ungrouped trait.
type traitVocabResponse struct {
	Key        string  `json:"key"`
	Label      string  `json:"label"`
	GroupKey   *string `json:"group_key"`
	GroupLabel *string `json:"group_label"`
}

// List answers GET /v1/traits with the currently selectable trait
// vocabulary, so a future add/edit-cat flow can render a selector without
// hard-coding trait options client-side.
func (h *TraitsHandler) List(w http.ResponseWriter, r *http.Request) {
	traits, err := h.traits.ListActive(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	resp := make([]traitVocabResponse, 0, len(traits))
	for _, t := range traits {
		resp = append(resp, traitVocabResponse{
			Key:        t.Key,
			Label:      t.Label,
			GroupKey:   t.GroupKey,
			GroupLabel: t.GroupLabel,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}
