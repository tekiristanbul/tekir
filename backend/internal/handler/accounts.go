package handler

import (
	"context"
	"net/http"
)

// AccountDeleter is satisfied by service.AccountsService; kept as an
// interface so the handler is testable without a real database.
type AccountDeleter interface {
	Delete(ctx context.Context, userID string) error
}

// AccountsHandler exposes in-app account deletion (issue #242, apple
// guideline 5.1.1(v)). RequireBearer only: an account can delete itself and
// nothing else — there is no account id anywhere in the request, so there
// is no shape in which one account could ask to delete another.
type AccountsHandler struct {
	accounts AccountDeleter
}

func NewAccountsHandler(accounts AccountDeleter) *AccountsHandler {
	return &AccountsHandler{accounts: accounts}
}

// Delete answers DELETE /v1/me: terminal deletion of the calling account
// and its data. Answers 204 on success and on an account that is already
// gone — deletion is idempotent, so a retry after a dropped response is
// safe, which is what lets the client clear its local session only once the
// server has confirmed. Any failure answers 500 and the client keeps its
// session: reporting success before the server confirms would leave the
// user signed out of an account that still exists.
func (h *AccountsHandler) Delete(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if err := h.accounts.Delete(r.Context(), user.UserID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
