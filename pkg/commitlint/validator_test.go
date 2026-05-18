package commitlint

import (
	"strings"
	"testing"
)

func TestValidator_Validate(t *testing.T) {
	validator := NewValidator()

	tests := []struct {
		name    string
		message string
		errRule string
		wantErr bool
	}{
		// Valid commits
		{
			name:    "valid: feat without JIRA prefix",
			message: "feat: add new feature",
			wantErr: false,
		},
		{
			name:    "valid: feat with JIRA prefix",
			message: "HYPERFLEET-123 - feat: add new feature",
			wantErr: false,
		},
		{
			name:    "valid: fix with JIRA prefix",
			message: "HYPERFLEET-999 - fix: resolve null pointer",
			wantErr: false,
		},
		{
			name:    "valid: docs",
			message: "docs: update README",
			wantErr: false,
		},
		{
			name:    "valid: style",
			message: "style: run gofmt",
			wantErr: false,
		},
		{
			name:    "valid: refactor",
			message: "refactor: extract helper function",
			wantErr: false,
		},
		{
			name:    "valid: perf",
			message: "perf: optimize query",
			wantErr: false,
		},
		{
			name:    "valid: test",
			message: "test: add unit tests",
			wantErr: false,
		},
		{
			name:    "valid: build",
			message: "build: update Makefile",
			wantErr: false,
		},
		{
			name:    "valid: ci",
			message: "ci: add validation job",
			wantErr: false,
		},
		{
			name:    "valid: chore",
			message: "chore: update gitignore",
			wantErr: false,
		},
		{
			name:    "valid: revert",
			message: "revert: undo last change",
			wantErr: false,
		},
		{
			name:    "valid: feat with OCM prefix",
			message: "OCM-42 - feat: add feature",
			wantErr: false,
		},
		{
			name:    "valid: fix with MGDAPI prefix",
			message: "MGDAPI-100 - fix: resolve timeout",
			wantErr: false,
		},
		{
			name:    "valid: docs with RHCLOUD prefix",
			message: "RHCLOUD-1 - docs: update readme",
			wantErr: false,
		},
		{
			name:    "valid: chore with TFMRHCLOUD prefix",
			message: "TFMRHCLOUD-55 - chore: cleanup",
			wantErr: false,
		},
		{
			name:    "invalid: lowercase jira prefix",
			message: "ocm-42 - feat: add feature",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name:    "invalid: digits-first jira prefix",
			message: "123OCM-42 - feat: add feature",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name:    "invalid: with scope (not supported)",
			message: "feat(api): add cluster endpoint",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name: "valid: with body",
			message: `feat: add cluster provisioning

This commit adds auto-scaling capabilities.`,
			wantErr: false,
		},

		// Invalid commits
		{
			name:    "invalid: empty message",
			message: "",
			wantErr: true,
			errRule: "message-empty",
		},
		{
			name:    "invalid: no type",
			message: "this is not valid",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name:    "invalid: invalid type",
			message: "invalid: not a valid type",
			wantErr: true,
			errRule: "type-enum",
		},
		{
			name:    "invalid: subject only whitespace",
			message: "feat:    ", // Will be trimmed to "feat:", matching header-format check
			wantErr: true,
			errRule: "header-format", // After trim, becomes "feat:" which doesn't match pattern
		},
		{
			name:    "invalid: uppercase type",
			message: "Feat: add new feature",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name:    "invalid: missing colon",
			message: "feat add new feature",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name:    "invalid: missing space after colon",
			message: "feat:add new feature",
			wantErr: true,
			errRule: "header-format",
		},
		{
			name: "invalid: header too long",
			message: "feat: this is a very long commit message that exceeds the maximum" +
				" allowed length of seventy two characters",
			wantErr: true,
			errRule: "header-max-length",
		},
		{
			name: "invalid: JIRA prefix should not count toward length - but this is still too long",
			message: "HYPERFLEET-12345 - feat: this is a very long commit message that exceeds" +
				" the maximum allowed length of seventy two characters",
			wantErr: true,
			errRule: "header-max-length",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validator.Validate(tt.message)

			if tt.wantErr && result.Valid {
				t.Errorf("Validate() expected error but got valid result")
			}

			if !tt.wantErr && !result.Valid {
				t.Errorf("Validate() expected valid but got errors: %v", result.Errors)
			}

			if tt.wantErr && tt.errRule != "" {
				found := false
				for _, err := range result.Errors {
					if err.Rule == tt.errRule {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("Validate() expected error rule %s but got %v", tt.errRule, result.Errors)
				}
			}
		})
	}
}

func TestValidator_JIRAPrefixExcludedFromLength(t *testing.T) {
	validator := NewValidator()

	// This is exactly 72 characters (type: subject), JIRA prefix not counted
	// "feat: " (6) + 66 characters = 72
	msg := "HYPERFLEET-123 - feat: " + strings.Repeat("a", 66)

	result := validator.Validate(msg)
	if !result.Valid {
		t.Errorf("Message with 72 chars (excluding JIRA) should be valid, got errors: %v", result.Errors)
	}

	// Add one more character - should fail
	msgTooLong := msg + "a"
	result = validator.Validate(msgTooLong)
	if result.Valid {
		t.Errorf("Message with 73 chars (excluding JIRA) should be invalid")
	}

	// Non-HYPERFLEET prefix: same length logic applies
	msgOCM := "OCM-999 - feat: " + strings.Repeat("a", 66)
	result = validator.Validate(msgOCM)
	if !result.Valid {
		t.Errorf("Message with 72 chars (excluding non-HYPERFLEET JIRA) should be valid, got errors: %v", result.Errors)
	}

	msgOCMTooLong := msgOCM + "a"
	result = validator.Validate(msgOCMTooLong)
	if result.Valid {
		t.Errorf("Message with 73 chars (excluding non-HYPERFLEET JIRA) should be invalid")
	}
}

func TestValidator_ValidatePRTitle(t *testing.T) {
	validator := NewValidator()

	tests := []struct {
		name    string
		title   string
		errRule string
		wantErr bool
	}{
		{
			name:    "valid: PR title with JIRA",
			title:   "HYPERFLEET-123 - feat: add cluster validation",
			wantErr: false,
		},
		{
			name:    "valid: PR title with JIRA and long subject",
			title:   "HYPERFLEET-456 - fix: resolve memory leak in controller",
			wantErr: false,
		},
		{
			name:    "valid: PR title with OCM prefix",
			title:   "OCM-42 - feat: add cluster feature",
			wantErr: false,
		},
		{
			name:    "valid: PR title with MGDAPI prefix",
			title:   "MGDAPI-100 - fix: resolve timeout",
			wantErr: false,
		},
		{
			name:    "invalid: PR title without JIRA",
			title:   "feat: add cluster validation",
			wantErr: true,
			errRule: "pr-title-requires-jira",
		},
		{
			name:    "invalid: PR title without JIRA (fix type)",
			title:   "fix: resolve memory leak",
			wantErr: true,
			errRule: "pr-title-requires-jira",
		},
		{
			name:    "invalid: PR title with invalid format",
			title:   "Add cluster validation",
			wantErr: true,
			errRule: "header-format",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := validator.ValidatePRTitle(tt.title)

			if tt.wantErr && result.Valid {
				t.Errorf("ValidatePRTitle() expected error but got valid result")
			}

			if !tt.wantErr && !result.Valid {
				t.Errorf("ValidatePRTitle() expected valid but got errors: %v", result.Errors)
			}

			if tt.wantErr && tt.errRule != "" {
				found := false
				for _, err := range result.Errors {
					if err.Rule == tt.errRule {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("ValidatePRTitle() expected error rule %s but got %v", tt.errRule, result.Errors)
				}
			}
		})
	}
}

func TestValidator_IsWhitelistedAuthor(t *testing.T) {
	validator := NewValidator()

	tests := []struct {
		name  string
		email string
		want  bool
	}{
		{
			name:  "konflux bot is whitelisted",
			email: "konflux@no-reply.konflux-ci.dev",
			want:  true,
		},
		{
			name:  "konflux bot case insensitive",
			email: "Konflux@No-Reply.Konflux-CI.Dev",
			want:  true,
		},
		{
			name:  "konflux bot github login is whitelisted",
			email: "red-hat-konflux-kflux-prd-rh02[bot]",
			want:  true,
		},
		{
			name:  "github bot noreply email is whitelisted",
			email: "190377777+red-hat-konflux-kflux-prd-rh02[bot]@users.noreply.github.com",
			want:  true,
		},
		{
			name:  "different numeric prefix still whitelisted",
			email: "999999+red-hat-konflux-kflux-prd-rh02[bot]@users.noreply.github.com",
			want:  true,
		},
		{
			name:  "non-bot noreply email is not whitelisted",
			email: "12345+someuser@users.noreply.github.com",
			want:  false,
		},
		{
			name:  "regular user is not whitelisted",
			email: "developer@redhat.com",
			want:  false,
		},
		{
			name:  "empty email is not whitelisted",
			email: "",
			want:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := validator.IsWhitelistedAuthor(tt.email); got != tt.want {
				t.Errorf("IsWhitelistedAuthor(%q) = %v, want %v", tt.email, got, tt.want)
			}
		})
	}
}

func TestValidator_IsWhitelistedAuthor_Variadic(t *testing.T) {
	validator := NewValidator()

	if !validator.IsWhitelistedAuthor("unknown@example.com", "red-hat-konflux-kflux-prd-rh02[bot]") {
		t.Error("expected whitelisted when name matches exact whitelist entry")
	}

	if !validator.IsWhitelistedAuthor("190377777+some-other-bot[bot]@users.noreply.github.com", "irrelevant") {
		t.Error("expected whitelisted when email matches bot noreply pattern")
	}

	if validator.IsWhitelistedAuthor("user@example.com", "some-user") {
		t.Error("expected not whitelisted when neither identifier matches")
	}
}
