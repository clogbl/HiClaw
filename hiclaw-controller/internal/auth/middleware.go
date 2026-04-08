package auth

import (
	"context"
	"net/http"
	"strings"

	"github.com/hiclaw/hiclaw-controller/internal/httputil"
)

// Role constants.
const (
	RoleAdmin      = "admin"
	RoleManager    = "manager"
	RoleTeamLeader = "team-leader"
	RoleWorker     = "worker"
)

type contextKey string

const callerKey contextKey = "caller"

// CallerFromContext extracts the CallerIdentity from the request context.
func CallerFromContext(ctx context.Context) *CallerIdentity {
	if v := ctx.Value(callerKey); v != nil {
		return v.(*CallerIdentity)
	}
	return nil
}

// CallerKeyForTest returns the context key for injecting CallerIdentity in tests.
func CallerKeyForTest() contextKey {
	return callerKey
}

// IdentityEnricher resolves additional identity fields (role, team) from
// the backing store (e.g. Worker CR annotations). Implementations live
// outside the auth package to avoid a circular dependency on api/v1beta1.
type IdentityEnricher interface {
	EnrichIdentity(ctx context.Context, identity *CallerIdentity) error
}

// Middleware provides HTTP authentication middleware.
type Middleware struct {
	keyStore *KeyStore
	enricher IdentityEnricher // optional; nil skips enrichment
}

// NewMiddleware creates an auth Middleware.
func NewMiddleware(keyStore *KeyStore) *Middleware {
	return &Middleware{keyStore: keyStore}
}

// SetEnricher attaches an identity enricher (called after key validation).
func (m *Middleware) SetEnricher(e IdentityEnricher) {
	m.enricher = e
}

// RequireManager returns middleware that only allows manager callers.
func (m *Middleware) RequireManager(next http.Handler) http.Handler {
	return m.requireRole(RoleManager, next)
}

// RequireWorker returns middleware that only allows worker callers.
func (m *Middleware) RequireWorker(next http.Handler) http.Handler {
	return m.requireRole(RoleWorker, next)
}

func (m *Middleware) requireRole(role string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !m.keyStore.AuthEnabled() {
			next.ServeHTTP(w, r)
			return
		}

		identity, ok := m.authenticateAndEnrich(r)
		if !ok {
			httputil.WriteError(w, http.StatusUnauthorized, "invalid or missing API key")
			return
		}
		if identity.Role != role {
			httputil.WriteError(w, http.StatusForbidden, role+" access required")
			return
		}

		ctx := context.WithValue(r.Context(), callerKey, identity)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequireAny returns middleware that authenticates any valid caller (all roles).
// The enriched CallerIdentity is placed in the request context.
func (m *Middleware) RequireAny(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !m.keyStore.AuthEnabled() {
			next.ServeHTTP(w, r)
			return
		}

		identity, ok := m.authenticateAndEnrich(r)
		if !ok {
			httputil.WriteError(w, http.StatusUnauthorized, "invalid or missing API key")
			return
		}

		ctx := context.WithValue(r.Context(), callerKey, identity)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequireRoles returns middleware that requires the caller to have one of the given roles.
func (m *Middleware) RequireRoles(roles []string, next http.Handler) http.Handler {
	roleSet := make(map[string]bool, len(roles))
	for _, r := range roles {
		roleSet[r] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !m.keyStore.AuthEnabled() {
			next.ServeHTTP(w, r)
			return
		}

		identity, ok := m.authenticateAndEnrich(r)
		if !ok {
			httputil.WriteError(w, http.StatusUnauthorized, "invalid or missing API key")
			return
		}
		if !roleSet[identity.Role] {
			httputil.WriteError(w, http.StatusForbidden, "insufficient permissions")
			return
		}

		ctx := context.WithValue(r.Context(), callerKey, identity)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (m *Middleware) authenticateAndEnrich(r *http.Request) (*CallerIdentity, bool) {
	identity, ok := m.authenticateFromHeader(r)
	if !ok {
		return nil, false
	}
	if m.enricher != nil {
		_ = m.enricher.EnrichIdentity(r.Context(), identity)
	}
	return identity, true
}

func (m *Middleware) authenticateFromHeader(r *http.Request) (*CallerIdentity, bool) {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return nil, false
	}

	key := strings.TrimPrefix(authHeader, "Bearer ")
	if key == authHeader {
		return nil, false
	}

	return m.keyStore.ValidateKey(key)
}
