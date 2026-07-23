// Package handler holds thin HTTP handlers that delegate to services.
package handler

import (
	"encoding/json"
	"net/http"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type HealthHandler struct {
	health *service.HealthService
}

func NewHealthHandler(health *service.HealthService) *HealthHandler {
	return &HealthHandler{health: health}
}

// Live answers liveness: the process is up and serving requests.
func (h *HealthHandler) Live(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Ready answers readiness: dependencies (currently: the database) are reachable.
func (h *HealthHandler) Ready(w http.ResponseWriter, r *http.Request) {
	if err := h.health.Ready(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
