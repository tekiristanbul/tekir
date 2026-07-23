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

// List answers GET /v1/traits with the currently selectable trait
// vocabulary, so a future add/edit-cat flow can render a selector without
// hard-coding trait options client-side.
func (h *TraitsHandler) List(w http.ResponseWriter, r *http.Request) {
	traits, err := h.traits.ListActive(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	resp := make([]traitResponse, 0, len(traits))
	for _, t := range traits {
		resp = append(resp, traitResponse{Key: t.Key, Label: t.Label})
	}
	writeJSON(w, http.StatusOK, resp)
}
